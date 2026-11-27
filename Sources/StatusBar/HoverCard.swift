import AppKit

@MainActor
private func label(_ text: String = "", size: CGFloat = 14, alignment: NSTextAlignment = .left) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size)
    field.textColor = .secondaryLabelColor
    field.alignment = alignment
    field.maximumNumberOfLines = 1
    field.lineBreakMode = .byTruncatingTail
    return field
}

enum HoverPalette {
    static let warning = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.92, green: 0.31, blue: 0.28, alpha: 1)
        }
        return NSColor(srgbRed: 0.72, green: 0.14, blue: 0.11, alpha: 1)
    }
}

@MainActor
private enum HoverColumns {
    static let groupGap: CGFloat = 16
    static let daily: CGFloat = 138
    static let fresh = daily + ProbeTimingView.width + groupGap
    static let rate = fresh + ProbeTimingView.width + groupGap
    static let rateWidths: [CGFloat] = [75, 16, 75]
    static let rateColumns = rateWidths.enumerated().map { index, width in
        (x: rate + rateWidths.prefix(index).reduce(0, +), width: width)
    }
    static let width = rate + rateWidths.reduce(0, +)
    static let rowHeight = ProbeTimingView.resultRect.height
    static let headerHeight: CGFloat = 49
}

@MainActor
private final class HoverGrid: NSView {
    var showsDividers = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard showsDividers else { return }
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        for x in [HoverColumns.daily, HoverColumns.fresh, HoverColumns.rate] {
            NSRect(x: x - HoverColumns.groupGap / 2, y: bounds.minY, width: 0.65, height: bounds.height).fill()
        }
    }
}

@MainActor
private final class HoverSiteRow: NSView {
    let name = label(size: 16)
    let daily = ProbeTimingView()
    let fresh = ProbeTimingView()
    private let dot = NSImageView()
    private let percentages = ["", "/", ""].map { label($0, alignment: .center) }
    private(set) var site: ConnectivityState.Row?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: HoverColumns.width, height: HoverColumns.rowHeight))
        dot.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        dot.frame = NSRect(x: 3, y: 11, width: 13, height: 13)
        name.frame = NSRect(x: 22, y: 5, width: HoverColumns.daily - 40, height: 24)
        name.font = .systemFont(ofSize: 16, weight: .medium)
        name.textColor = .labelColor
        daily.setFrameOrigin(NSPoint(x: HoverColumns.daily, y: 0))
        fresh.setFrameOrigin(NSPoint(x: HoverColumns.fresh, y: 0))
        for (field, column) in zip(percentages, HoverColumns.rateColumns) {
            field.font = .monospacedDigitSystemFont(ofSize: 16, weight: .regular)
            field.frame = NSRect(x: column.x, y: 5, width: column.width, height: 24)
        }
        for view in [dot, name, daily, fresh] + percentages { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }

    func update(_ row: ConnectivityState.Row) {
        site = row
        name.stringValue = row.name
        name.setAccessibilityLabel(row.spoken)
        name.toolTip = row.name
        dot.image = NSImage(systemSymbolName: row.enabled ? "circle.fill" : "circle", accessibilityDescription: nil)
        dot.contentTintColor = switch row.color {
        case .normal: .tertiaryLabelColor
        case .green: .systemGreen
        case .orange: .systemOrange
        case .red: .systemRed
        }
        for (field, lane) in [(percentages[0], ProbeLane.daily), (percentages[2], .fresh)] {
            let value = row.percentage(for: lane)
            field.stringValue = value
            field.textColor = value == "100" || value == "—" ? .secondaryLabelColor : HoverPalette.warning
        }
    }

    func setTiming(_ timeline: ProbeTimeline) {
        guard let site else { return }
        let lanes = timeline.lanes[site.id]
        daily.configure(lanes?[.daily], name: site.name + " · 复用", enabled: site.enabled && site.dailySettings.enabled)
        fresh.configure(lanes?[.fresh], name: site.name + " · 新建", enabled: site.enabled && site.freshSettings.enabled)
    }
}

private final class HoverBodyScroll: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
           let outer = superview?.enclosingScrollView, outer.hasHorizontalScroller {
            outer.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

private final class HoverButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private enum BackgroundCursor {
    // A nonactivating panel needs WindowServer's permission to display its cursor.
    // Resolve the SPI at runtime and use it only while this panel owns the pointer.
    static let setEnabled: ((Bool) -> Bool)? = {
        guard let symbols = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(symbols) }
        guard let connectionSymbol = dlsym(symbols, "CGSMainConnectionID"),
              let propertySymbol = dlsym(symbols, "SLSSetConnectionProperty") else { return nil }
        typealias MainConnection = @convention(c) () -> UInt32
        typealias SetProperty = @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32
        let connection = unsafeBitCast(connectionSymbol, to: MainConnection.self)
        let setProperty = unsafeBitCast(propertySymbol, to: SetProperty.self)
        return { enabled in
            let id = connection()
            return setProperty(id, id, "SetsCursorInBackground" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse) == 0
        }
    }()
}

@MainActor
private final class HoverDragSurface: NSView {
    weak var card: HoverCard?
    private var pointerTracking: NSTrackingArea?
    private var dragStart: (pointer: NSPoint, origin: NSPoint)?
    private var backgroundCursorEnabled = false

    // The panel stays nonactivating, so the drag target must accept the first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (screenPoint(for: event, in: window), window.frame.origin)
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let window else { return }
        if !window.isMovable { card?.beginDrag?() }
        let pointer = screenPoint(for: event, in: window)
        let origin = NSPoint(x: dragStart.origin.x + pointer.x - dragStart.pointer.x,
                             y: dragStart.origin.y + pointer.y - dragStart.pointer.y)
        window.setFrameOrigin(origin)
    }

    private func screenPoint(for event: NSEvent, in window: NSWindow) -> NSPoint {
        guard let point = event.cgEvent?.location, let primary = NSScreen.screens.first else {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSPoint(x: point.x, y: primary.frame.maxY - point.y)
    }

    override func scrollWheel(with event: NSEvent) { card?.scrollTable(with: event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self, userInfo: nil)
        pointerTracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { updateCursor(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { endCursorTracking() }

    private func updateCursor(at point: NSPoint) {
        guard let window, window.isVisible,
              NSWindow.windowNumber(at: window.convertPoint(toScreen: point), belowWindowWithWindowNumber: 0) == window.windowNumber
        else { endCursorTracking(); return }
        if !backgroundCursorEnabled, BackgroundCursor.setEnabled?(true) == true {
            backgroundCursorEnabled = true
            // The WindowServer may install the frontmost app's cursor on entry.
            // Reapply once after that transition, using the actual pointer position.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
                guard let self, self.backgroundCursorEnabled, let window = self.window else { return }
                self.updateCursor(at: window.mouseLocationOutsideOfEventStream)
            }
        }
        let cursor: NSCursor = card?.canDrag(at: point) == true ? .openHand : .arrow
        cursor.set()
    }

    func endCursorTracking() {
        if backgroundCursorEnabled {
            _ = BackgroundCursor.setEnabled?(false)
            backgroundCursorEnabled = false
        }
        // Reset AppKit's local cursor after giving the frontmost app control.
        // Reentering must select the hand again even if that was our last cursor.
        NSCursor.arrow.set()
    }
}

@MainActor
final class HoverCard: NSBox {
    private let heading = label("网络状况", size: 17)
    private let footer = label()
    private var traffic = ""
    private let action = HoverButton(title: "立即探测", target: nil, action: nil)
    private let pin = HoverButton()
    private let tableScroll = NSScrollView()
    private let grid = HoverGrid()
    private let bodyScroll = HoverBodyScroll()
    private let body = HoverGrid()
    private let dragSurface = HoverDragSurface()
    private var rows: [HoverSiteRow] = []
    private var timeline = ProbeTimeline()
    private var available = false
    private var visible = false
    private(set) var clock: Timer?
    var probeNow: (() -> Void)?
    var togglePin: (() -> Void)?
    var beginDrag: (() -> Void)?

    init() {
        super.init(frame: .zero)
        boxType = .custom
        titlePosition = .noTitle
        contentViewMargins = .zero
        cornerRadius = 16
        borderWidth = 0.65
        borderColor = .separatorColor
        fillColor = .windowBackgroundColor
        contentView = NSView()
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.textColor = .labelColor
        action.controlSize = .large
        action.font = .systemFont(ofSize: 14)
        action.bezelStyle = .rounded
        action.target = self
        action.action = #selector(probe)
        pin.bezelStyle = .rounded
        pin.controlSize = .large
        pin.imagePosition = .imageOnly
        pin.setButtonType(.pushOnPushOff)
        pin.target = self
        pin.action = #selector(togglePinned)
        dragSurface.card = self
        dragSurface.setAccessibilityElement(false)
        dragSurface.autoresizingMask = [.width, .height]
        dragSurface.frame = contentView?.bounds ?? .zero
        setPinned(false)
        // Keep both buttons in front of the single mouse target for the rest of the card.
        for view in [heading, tableScroll, footer, dragSurface, action, pin] { contentView?.addSubview(view) }
        for scroll in [tableScroll, bodyScroll] {
            scroll.drawsBackground = false
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
        }
        tableScroll.documentView = grid
        bodyScroll.documentView = body
        body.showsDividers = true
        grid.addSubview(bodyScroll)
        func header(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat, group: Bool = false,
                    alignment: NSTextAlignment = .center) {
            let field = label(title, alignment: alignment)
            if group { field.font = .systemFont(ofSize: 16, weight: .semibold); field.textColor = .labelColor }
            field.frame = NSRect(x: x, y: y, width: width, height: 23)
            grid.addSubview(field)
        }
        header("站点", x: 3, y: 25, width: HoverColumns.daily - HoverColumns.groupGap, alignment: .left)
        header("成功率(%)", x: HoverColumns.rate, y: 0, width: HoverColumns.width - HoverColumns.rate, group: true)
        for (title, column) in zip(["复用请求", "/", "新建请求"], HoverColumns.rateColumns) {
            header(title, x: column.x, y: 25, width: column.width)
        }
        for (lane, x) in [(ProbeLane.daily, HoverColumns.daily), (.fresh, HoverColumns.fresh)] {
            header(lane.title, x: x, y: 0, width: ProbeTimingView.width, group: true)
            for (title, column) in [("最近结果", ProbeTimingView.resultRect), ("当前等待", ProbeTimingView.waitRect)] {
                header(title, x: x + column.minX, y: 25, width: column.width)
            }
            let headerWidth = ProbeTimingView.nextRect.width
            let headerX = x + ProbeTimingView.nextContentRect.midX - headerWidth / 2
            header("下次发起", x: headerX, y: 25, width: headerWidth)
        }
    }

    required init?(coder: NSCoder) { nil }
    @objc private func probe() { probeNow?() }
    @objc private func togglePinned() { togglePin?() }

    func setPinned(_ pinned: Bool) {
        let title = pinned ? "取消固定" : "固定在最前"
        pin.state = pinned ? .on : .off
        pin.isBordered = pinned
        pin.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        pin.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        pin.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
        pin.toolTip = title
        pin.setAccessibilityLabel(title)
    }

    func canDrag(at pointInWindow: NSPoint) -> Bool {
        guard dragSurface.bounds.contains(dragSurface.convert(pointInWindow, from: nil)) else { return false }
        return ![pin, action].contains { $0.bounds.contains($0.convert(pointInWindow, from: nil)) }
    }

    fileprivate func scrollTable(with event: NSEvent) {
        guard !tableScroll.isHidden else { return }
        let point = event.locationInWindow
        guard tableScroll.bounds.contains(tableScroll.convert(point, from: nil)) else { return }
        if bodyScroll.bounds.contains(bodyScroll.convert(point, from: nil)) {
            bodyScroll.scrollWheel(with: event)
        } else {
            tableScroll.scrollWheel(with: event)
        }
    }

    func setVisible(_ value: Bool) {
        visible = value
        if !value { dragSurface.endCursorTracking() }
        updateClock()
    }

    func setTimeline(_ value: ProbeTimeline) {
        guard timeline != value else { return }
        timeline = value
        rows.forEach { $0.setTiming(value) }
        updateClock()
        refreshTime()
    }

    private func updateClock() {
        guard visible, available, !timeline.lanes.isEmpty else {
            clock?.invalidate()
            clock = nil
            return
        }
        let interval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.0 : 1.0 / 12
        guard clock?.timeInterval != interval else { return }
        clock?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTime() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func refreshTime() {
        let now = ProcessInfo.processInfo.systemUptime
        let cooling = now < timeline.manualAvailableAt
        let enabled = available && !cooling && !timeline.lanes.isEmpty
        if action.isEnabled != enabled { action.isEnabled = enabled }
        let title = cooling ? "已触发探测" : "立即探测"
        if action.title != title { action.title = title }
        let pointer = window?.mouseLocationOutsideOfEventStream
        var detail: String?
        for row in rows where row.frame.intersects(body.visibleRect) {
            for cell in [row.daily, row.fresh] {
                cell.needsDisplay = true
                if visible, let pointer {
                    let point = cell.convert(pointer, from: nil)
                    if cell.visibleRect.contains(point), ProbeTimingView.waitRect.contains(point) {
                        detail = cell.liveWaitDetail(at: now)
                    }
                }
            }
        }
        let message = detail ?? traffic
        if footer.stringValue != message { footer.stringValue = message }
    }

    func update(_ state: ConnectivityState, availableHeight: CGFloat, availableWidth: CGFloat = .greatestFiniteMagnitude) -> NSSize {
        available = state.enabled && !state.configurationUnavailable
        let sites = available ? state.rows : []
        let inset: CGFloat = 18
        let width = min(availableWidth, sites.isEmpty ? 429 : HoverColumns.width + 2 * inset)
        let bodyHeight = CGFloat(sites.count) * HoverColumns.rowHeight
        let chromeHeight: CGFloat = 99
        let size = NSSize(width: width, height: min(availableHeight, sites.isEmpty ? chromeHeight : chromeHeight + HoverColumns.headerHeight + bodyHeight))
        heading.frame = NSRect(x: inset, y: size.height - 39, width: width - 80, height: 24)
        pin.frame = NSRect(x: width - 55, y: size.height - 46, width: 37, height: 35)
        traffic = state.footer
        footer.frame = NSRect(x: inset, y: 17, width: max(0, width - 161), height: 22)
        action.frame = NSRect(x: width - 131, y: 10, width: 114, height: 34)
        tableScroll.isHidden = sites.isEmpty
        let gridHeight = max(0, size.height - chromeHeight)
        tableScroll.frame = NSRect(x: inset, y: 52, width: max(0, width - 2 * inset), height: gridHeight)
        tableScroll.hasHorizontalScroller = tableScroll.frame.width < HoverColumns.width
        grid.frame.size = NSSize(width: HoverColumns.width, height: gridHeight)
        bodyScroll.frame = NSRect(x: 0, y: HoverColumns.headerHeight, width: HoverColumns.width,
                                  height: max(0, gridHeight - HoverColumns.headerHeight))
        bodyScroll.hasVerticalScroller = bodyHeight > bodyScroll.frame.height
        body.frame.size = NSSize(width: HoverColumns.width, height: bodyHeight)
        while rows.count > sites.count { rows.removeLast().removeFromSuperview() }
        for (index, site) in sites.enumerated() {
            if index == rows.count {
                let row = HoverSiteRow()
                row.setFrameOrigin(NSPoint(x: 0, y: CGFloat(index) * HoverColumns.rowHeight))
                body.addSubview(row)
                rows.append(row)
            }
            let row = rows[index]
            if row.site != site {
                row.update(site)
                row.setTiming(timeline)
            }
        }
        updateClock()
        refreshTime()
        return size
    }
}
