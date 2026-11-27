import AppKit

@MainActor
final class StatusHover {
    private let item: NSStatusItem
    private let networkRegion: (NSRect) -> NSRect
    private let showsButtonTooltip: () -> Bool
    private let menuIsOpening: () -> Bool
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screens: [NSScreen] = []
    private var menuBarWindow: (id: CGWindowID, bounds: CGRect?)?
    private var connectivity = ConnectivityState()
    private var menuIsOpen = false
    private var anchor: NSRect?
    private var panel: NSPanel?
    private lazy var card = HoverCard()

    init(item: NSStatusItem, networkRegion: @escaping (NSRect) -> NSRect = { $0 },
         showsButtonTooltip: @escaping () -> Bool = { true }, menuIsOpening: @escaping () -> Bool = { false }) {
        self.item = item
        self.networkRegion = networkRegion
        self.showsButtonTooltip = showsButtonTooltip
        self.menuIsOpening = menuIsOpening
        updateButtonTooltip()
    }

    private func updateButtonTooltip() {
        item.button?.toolTip = showsButtonTooltip() ? connectivity.hoverTooltip : nil
    }

    func start() {
        resetPosition()
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        hide()
    }

    func resetPosition() {
        hide()
        screens = NSScreen.screens
        menuBarWindow = nil
        updateButtonTooltip()
    }

    func setMenuOpen(_ open: Bool) {
        menuIsOpen = open
        if open { hide() }
    }

    func update(_ state: ConnectivityState) {
        guard connectivity != state else { return }
        connectivity = state
        if anchor == nil {
            updateButtonTooltip()
        } else {
            if let anchor, let screen = screens.first(where: { $0.frame.contains(anchor) }) {
                layoutCard(under: anchor, on: screen.visibleFrame)
            }
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .mouseMoved {
            updatePosition(for: event.cgEvent)
        } else {
            hide()
        }
    }

    private func updatePosition(for event: CGEvent?) {
        let pointer = NSEvent.mouseLocation
        // Most moves are outside the menu bar. Only resolve the button frame near the top of a screen.
        guard !menuIsOpen, !menuIsOpening(), let screen = screens.first(where: { $0.frame.contains(pointer) }),
              pointer.y >= screen.frame.maxY - 48,
              item.isVisible, let button = item.button, let window = button.window, window.isVisible else {
            hide()
            return
        }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = screen.visibleFrame
        guard let rect = hoverFrame(button: buttonFrame, pointer: pointer, screen: screen, event: event),
              rect.midY >= visibleFrame.maxY else {
            hide()
            return
        }

        guard anchor != rect else { return }
        let panel = panel ?? makePanel()
        layoutCard(under: rect, on: visibleFrame)
        if anchor == nil {
            button.toolTip = nil
            panel.orderFrontRegardless()
        }
        anchor = rect
    }

    private func layoutCard(under rect: NSRect, on screen: NSRect) {
        let availableHeight = StatusPanelGeometry.top(under: rect, within: screen) - screen.minY
        let size = card.update(connectivity, availableHeight: availableHeight, availableWidth: screen.width)
        panel?.setFrame(StatusPanelGeometry.frame(size: size, under: rect, within: screen), display: true)
    }

    private func hoverFrame(button: NSRect, pointer: NSPoint, screen: NSScreen, event: CGEvent?) -> NSRect? {
        let frame: NSRect
        if screen.frame.contains(button) {
            frame = button
        } else {
            // AppKit reports the active menu bar's button. Project its trailing
            // position onto the inactive bar, then apply the same region check.
            guard NSScreen.screensHaveSeparateSpaces, let event,
                  let source = screens.first(where: { $0.frame.contains(button) }),
                  let projected = Self.replicaFrame(of: button, from: source.frame, to: screen.frame,
                                                   topRightArea: screen.auxiliaryTopRightArea),
                  projected.contains(pointer), isOverMenuBar(event, screen: screen.frame)
            else { return nil }
            frame = projected
        }
        let network = networkRegion(frame)
        return network.contains(pointer) ? network : nil
    }

    private func isOverMenuBar(_ event: CGEvent, screen: NSRect) -> Bool {
        guard let id = CGWindowID(exactly: event.getIntegerValueField(.mouseEventWindowUnderMousePointer)),
              let rawID = UnsafeRawPointer(bitPattern: Int(id)), let primary = screens.first
        else { return false }
        if menuBarWindow?.id != id {
            // Core Graphics takes window IDs as unretained pointer-sized values in this CFArray.
            var value: UnsafeRawPointer? = rawID
            let ids = CFArrayCreate(nil, &value, 1, nil)
            let description = (CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]])?.first
            let bounds: CGRect?
            if description?[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.mainMenuWindow)),
               let dictionary = description?[kCGWindowBounds as String] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: dictionary)
            } else {
                bounds = nil
            }
            menuBarWindow = (id, bounds)
        }
        guard let bounds = menuBarWindow?.bounds else { return false }
        let screenTop = primary.frame.maxY - screen.maxY
        // Do not project over a hidden menu bar (for example, an unrevealed full-screen menu bar).
        return abs(bounds.minX - screen.minX) < 1 && abs(bounds.maxX - screen.maxX) < 1 &&
            abs(bounds.minY - screenTop) < 1 && bounds.contains(event.location)
    }

    private func hide() {
        guard anchor != nil else { return }
        anchor = nil
        panel?.orderOut(nil)
        updateButtonTooltip()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = card
        self.panel = panel
        return panel
    }

    static func replicaFrame(of button: NSRect, from source: NSRect, to destination: NSRect,
                             topRightArea: NSRect?) -> NSRect? {
        guard !button.isEmpty, source.contains(button), source.maxY - button.midY < 48 else { return nil }
        let frame = button.offsetBy(dx: destination.maxX - source.maxX, dy: destination.maxY - source.maxY)
        guard destination.contains(frame), frame.minX >= (topRightArea ?? destination).minX else { return nil }
        return frame
    }
}

@MainActor
final class HoverCard: NSBox {
    private let heading = NSTextField(labelWithString: "")
    private let headers = ["站点", ProbeLane.daily.title, ProbeLane.fresh.title, "复用/新建请求成功率(%)"].map { NSTextField(labelWithString: $0) }
    private let divider = NSBox()
    private let footer = NSTextField(labelWithString: "")
    private let overflow = NSTextField(labelWithString: "")
    private struct Row {
        let dot: NSImageView
        let name: NSTextField
        let daily: NSTextField
        let fresh: NSTextField
        let dailyRate: NSTextField
        let separator: NSTextField
        let freshRate: NSTextField

        var views: [NSView] { [dot, name, daily, fresh, dailyRate, separator, freshRate] }
    }

    private var rows: [Row] = []
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let percentWidth = ceil(("100" as NSString).size(withAttributes: [.font: valueFont]).width) + 4
    private static let slashWidth: CGFloat = 12

    init() {
        super.init(frame: .zero)
        boxType = .custom
        titlePosition = .noTitle
        cornerRadius = 12
        borderWidth = 0.5
        borderColor = .separatorColor
        fillColor = .windowBackgroundColor
        contentViewMargins = .zero
        contentView = NSView()
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        divider.boxType = .separator
        for label in headers + [footer, overflow] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            contentView?.addSubview(label)
        }
        for header in headers.dropFirst() { header.alignment = .right }
        headers[3].maximumNumberOfLines = 1
        contentView?.addSubview(heading)
        contentView?.addSubview(divider)
    }

    required init?(coder: NSCoder) { nil }

    private func addRow() {
        let dot = NSImageView()
        dot.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        let name = NSTextField(labelWithString: "")
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        func valueField(_ text: String = "", aligned alignment: NSTextAlignment = .right) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = Self.valueFont
            field.alignment = alignment
            field.setAccessibilityElement(false)
            return field
        }
        let separator = valueField("/", aligned: .center)
        separator.textColor = .secondaryLabelColor
        let row = Row(dot: dot, name: name, daily: valueField(), fresh: valueField(),
                      dailyRate: valueField(), separator: separator, freshRate: valueField(aligned: .left))
        for view in row.views { contentView?.addSubview(view) }
        rows.append(row)
    }

    func update(_ state: ConnectivityState, availableHeight: CGFloat, availableWidth: CGFloat = .greatestFiniteMagnitude) -> NSSize {
        let rateGap: CGFloat = 2
        let rateWidth = max(ceil(headers[3].intrinsicContentSize.width) + 4,
                            2 * Self.percentWidth + Self.slashWidth + 2 * rateGap)
        let hasTCP = state.rows.contains(where: \.isTCP)
        let freshWidth: CGFloat = hasTCP ? 84 : 61
        let width = min(304 + rateWidth + freshWidth - 61, availableWidth)
        let count = state.enabled ? state.rows.count : 0
        let slots = max(1, Int((availableHeight - 91) / 22))
        let visible = count > slots ? slots - 1 : count
        let hidden = count - visible
        let size = NSSize(width: width, height: count == 0 ? 65 : 91 + CGFloat(min(count, slots)) * 22)
        heading.stringValue = state.title
        heading.frame = NSRect(x: 14, y: size.height - 29, width: width - 28, height: 17)
        footer.frame = NSRect(x: 14, y: 10, width: width - 28, height: 16)
        footer.stringValue = state.footer
        divider.frame = NSRect(x: 14, y: 32, width: width - 28, height: 1)
        let rateX = width - 14 - rateWidth
        let freshRateX = width - 14 - Self.percentWidth
        let slashX = freshRateX - rateGap - Self.slashWidth
        let dailyRateX = slashX - rateGap - Self.percentWidth
        // Leave room for a recognizable site name when the visible screen is narrow.
        let latencyWidth = min(61, max(48, floor((rateX - 90) / 2)))
        let freshColumnWidth = latencyWidth + freshWidth - 61
        let freshX = rateX - 4 - freshColumnWidth
        let dailyX = freshX - 4 - latencyWidth
        let columns: [(x: CGFloat, width: CGFloat)] = [(14, max(0, dailyX - 18)), (dailyX, latencyWidth),
                                                       (freshX, freshColumnWidth), (rateX, rateWidth)]
        for (index, column) in columns.enumerated() {
            headers[index].isHidden = count == 0
            headers[index].frame = NSRect(x: column.x, y: size.height - 51, width: column.width,
                                          height: 15)
        }
        overflow.isHidden = hidden == 0
        overflow.stringValue = "另有 \(hidden) 个站点"
        overflow.frame = NSRect(x: 14, y: 40, width: width - 28, height: 16)
        while rows.count < visible { addRow() }
        while rows.count > visible {
            let row = rows.removeLast()
            for view in row.views { view.removeFromSuperview() }
        }
        for (index, site) in state.rows.prefix(visible).enumerated() {
            let row = rows[index]
            let y = size.height - 75 - CGFloat(index) * 22
            row.dot.image = NSImage(systemSymbolName: site.enabled ? "circle.fill" : "circle", accessibilityDescription: nil)
            row.dot.contentTintColor = switch site.color {
            case .normal: .tertiaryLabelColor
            case .green: .systemGreen
            case .orange: .systemOrange
            case .red: .systemRed
            }
            row.dot.frame = NSRect(x: 14, y: y + 3, width: 10, height: 10)
            row.name.frame = NSRect(x: 30, y: y, width: max(0, dailyX - 34), height: 17)
            row.name.stringValue = site.name
            row.name.setAccessibilityLabel(site.spoken)
            row.daily.frame = NSRect(x: dailyX, y: y, width: latencyWidth, height: 17)
            row.fresh.frame = NSRect(x: freshX, y: y, width: freshColumnWidth, height: 17)
            row.dailyRate.frame = NSRect(x: dailyRateX, y: y, width: Self.percentWidth, height: 17)
            row.separator.frame = NSRect(x: slashX, y: y, width: Self.slashWidth, height: 17)
            row.freshRate.frame = NSRect(x: freshRateX, y: y, width: Self.percentWidth, height: 17)
            row.daily.stringValue = site.text(for: .daily)
            row.fresh.stringValue = site.text(for: .fresh)
            row.dailyRate.stringValue = site.percentage(for: .daily)
            row.freshRate.stringValue = site.percentage(for: .fresh)
        }
        return size
    }
}
