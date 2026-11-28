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
    private let name = label(size: 16)
    let nameButton = SiteNameButton()
    var openSite: ((String, NSView) -> Void)?
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
        nameButton.frame = NSRect(x: 0, y: 0, width: HoverColumns.daily - HoverColumns.groupGap / 2, height: HoverColumns.rowHeight)
        nameButton.target = self
        nameButton.action = #selector(open)
        name.font = .systemFont(ofSize: 16, weight: .medium)
        name.textColor = .labelColor
        daily.setFrameOrigin(NSPoint(x: HoverColumns.daily, y: 0))
        fresh.setFrameOrigin(NSPoint(x: HoverColumns.fresh, y: 0))
        for (field, column) in zip(percentages, HoverColumns.rateColumns) {
            field.font = .monospacedDigitSystemFont(ofSize: 16, weight: .regular)
            field.frame = NSRect(x: column.x, y: 5, width: column.width, height: 24)
        }
        for view in [dot, name, nameButton, daily, fresh] + percentages { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }

    @objc private func open() { if let site { openSite?(site.id, nameButton) } }

    func update(_ row: ConnectivityState.Row) {
        site = row
        name.stringValue = row.name
        name.setAccessibilityElement(false)
        nameButton.setAccessibilityLabel(row.spoken + "，快捷配置")
        nameButton.toolTip = row.name + " · 快捷配置"
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

private final class SiteNameButton: NSButton {
    private var tracking: NSTrackingArea?
    private var pointing = false { didSet { needsDisplay = true } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { pointing = true }
    override func mouseExited(with event: NSEvent) { pointing = false }
    override func draw(_ dirtyRect: NSRect) {
        guard pointing else { return }
        NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .draw(in: NSRect(x: bounds.maxX - 12, y: bounds.midY - 5, width: 10, height: 10))
    }
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
private final class HoverDragSurface: PanelDragView {
    weak var card: HoverCard?
    private var pointerTracking: NSTrackingArea?
    private var backgroundCursorEnabled = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let superview, card?.siteButton(at: superview.convert(point, to: nil)) != nil { return nil }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) { card?.scrollContent(with: event) }

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
    private let summary = NetworkSummary()
    private let bandwidth = HoverButton(title: "公网测速", target: nil, action: nil)
    private var summaryTipRect: NSRect?
    var measureBandwidth: (() -> Void)?
    private let heading = label("网络状况", size: 17)
    private let footer = label()
    private var traffic = ""
    private let action = HoverButton(title: "立即探测", target: nil, action: nil)
    private let configure = HoverButton(title: "探测配置", target: nil, action: nil)
    private let allSites = HoverButton(checkboxWithTitle: "显示所有站点", target: nil, action: nil)
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
    var openSettings: (() -> Void)?
    var toggleSites: ((Bool) -> Void)?
    var openSite: ((String, NSView) -> Void)?
    var showAllSites = false
    var trackingSiteID: String?

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
        bandwidth.target = self
        bandwidth.action = #selector(measure)
        bandwidth.bezelStyle = .rounded
        bandwidth.controlSize = .mini
        bandwidth.font = .systemFont(ofSize: 12)
        configure.target = self
        configure.action = #selector(settingsClicked)
        allSites.target = self
        allSites.action = #selector(filterClicked)
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
        for view in [heading, tableScroll, footer, summary, dragSurface, configure, allSites, action, bandwidth, pin] { contentView?.addSubview(view) }
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
    @objc private func measure() { measureBandwidth?() }

    func showDiagnostics(_ wireless: WirelessLink, _ state: BandwidthTest.State) {
        summary.update(wireless: wireless, state: state)
        switch state {
        case .running, .cancelling:
            bandwidth.title = "取消测速"
            bandwidth.toolTip = "取消后恢复站点探测"
        case .complete(let result) where result.hasFailures:
            bandwidth.title = "重试测速"
            bandwidth.toolTip = "重新测量公网下载和上传速度"
        default:
            bandwidth.title = "公网测速"
            bandwidth.toolTip = "依次测量公网下载和上传速度，会占用网络带宽"
        }
        bandwidth.isEnabled = state != .cancelling
        if bounds.width > 0 { layoutHeader(in: bounds.size) }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                    userData data: UnsafeMutableRawPointer?) -> String {
        [summary.wirelessTip, summary.resultTip].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    @objc private func settingsClicked() { openSettings?() }
    @objc private func filterClicked() { toggleSites?(allSites.state == .on) }
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

    fileprivate func siteButton(at point: NSPoint) -> NSButton? {
        guard !tableScroll.isHidden else { return nil }
        return rows.lazy.map(\.nameButton).first { button in
            let local = button.convert(point, from: nil)
            return button.bounds.contains(local) && button.visibleRect.contains(local)
        }
    }

    func canDrag(at pointInWindow: NSPoint) -> Bool {
        guard dragSurface.bounds.contains(dragSurface.convert(pointInWindow, from: nil)) else { return false }
        return siteButton(at: pointInWindow) == nil && ![pin, action, configure, allSites, bandwidth].contains { $0.bounds.contains($0.convert(pointInWindow, from: nil)) }
    }

    fileprivate func scrollContent(with event: NSEvent) {
        let point = event.locationInWindow
        if summary.hasHorizontalScroller, summary.bounds.contains(summary.convert(point, from: nil)) {
            summary.scrollWheel(with: event)
            return
        }
        guard !tableScroll.isHidden else { return }
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
        let enabled = available && !timeline.suspended && !cooling && !timeline.lanes.isEmpty
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

    private func layoutHeader(in size: NSSize) {
        let inset: CGFloat = 18
        let bottom = size.height - NetworkHeaderLine.insetFromTop
        let titleSize = heading.intrinsicContentSize
        let titleY = NetworkHeaderLine.textOrigin(heading, height: titleSize.height, bottom: bottom,
                                                   reference: heading.stringValue)
        heading.frame = NSRect(x: inset, y: titleY,
                               width: ceil(titleSize.width) + 6, height: titleSize.height)
        // Align the visible symbol within its larger hit area.
        pin.frame = NSRect(x: size.width - 55, y: bottom - 10, width: 37, height: 35)
        let buttonWidth: CGFloat = 74
        let actionGap: CGFloat = 8
        let summaryX = heading.frame.maxX + 11
        let available = max(0, pin.frame.minX - summaryX - buttonWidth - actionGap - 4)
        summary.frame = summary.frame(at: summaryX, bottom: bottom, available: available)
        // The rounded mini bezel sits 2.5 points below the text's lower edge.
        bandwidth.frame = NSRect(x: summary.frame.maxX + actionGap, y: bottom - 8, width: buttonWidth, height: 26)
        if summaryTipRect != summary.frame {
            dragSurface.removeAllToolTips()
            dragSurface.addToolTip(summary.frame, owner: self, userData: nil)
            summaryTipRect = summary.frame
        }
    }

    func update(_ state: ConnectivityState, availableHeight: CGFloat, availableWidth: CGFloat = .greatestFiniteMagnitude) -> NSSize {
        available = state.enabled && !state.configurationUnavailable
        let sites = available ? state.rows.filter { showAllSites || $0.enabled || $0.id == trackingSiteID } : []
        allSites.state = showAllSites ? .on : .off
        let inset: CGFloat = 18
        let width = min(availableWidth, sites.isEmpty ? 680 : HoverColumns.width + 2 * inset)
        let bodyHeight = CGFloat(sites.count) * HoverColumns.rowHeight
        let wrapped = width < 630
        let footerHeight: CGFloat = wrapped ? 75 : 52
        let chromeHeight = 49 + footerHeight
        let size = NSSize(width: width, height: min(availableHeight, sites.isEmpty ? chromeHeight : chromeHeight + HoverColumns.headerHeight + bodyHeight))
        layoutHeader(in: size)
        traffic = state.footer
        configure.frame = NSRect(x: inset - 3, y: 10, width: 82, height: 34)
        allSites.sizeToFit()
        allSites.setFrameOrigin(NSPoint(x: configure.frame.maxX + 8, y: 27 - allSites.frame.height/2))
        let footerX = wrapped ? inset : allSites.frame.maxX + 12
        let footerEnd = wrapped ? width - inset : width - 139
        let footerMiddle = wrapped ? 56 : allSites.frame.midY
        let footerTextHeight = ceil(footer.intrinsicContentSize.height)
        footer.frame = NSRect(x: footerX, y: footerMiddle - footerTextHeight / 2,
                              width: max(0, footerEnd - footerX), height: footerTextHeight)
        let actionWidth: CGFloat = width < 370 ? 85 : 114
        action.frame = NSRect(x: width - inset - actionWidth, y: 10, width: actionWidth, height: 34)
        tableScroll.isHidden = sites.isEmpty
        let gridHeight = max(0, size.height - chromeHeight)
        tableScroll.frame = NSRect(x: inset, y: footerHeight, width: max(0, width - 2 * inset), height: gridHeight)
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
                row.openSite = { [weak self] id, view in self?.openSite?(id, view) }
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
