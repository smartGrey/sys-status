import AppKit

/// The WindowServer replicates this one system button on each menu bar.
@MainActor
final class StatusEntry: NSObject, NSViewToolTipOwner {
    enum Region { case hearing, network, stopwatch }
    private var hearing: HearingPresentation?
    private var hearingImage: NSImage?
    private var appearanceObservation: NSKeyValueObservation?
    private var contrastObservation: NSObjectProtocol?
    private var hearingAppearance: NSAppearance.Name?
    private var increasedContrast = false
    private var hearingTip: NSView.ToolTipTag?

    let item: NSStatusItem
    private var face = StatusFace()
    private var watch: StopwatchStatusFace?
    private var focusTransition: StopwatchStatusFace.FocusTransition?
    private var focusTimer: Timer?
    private var menu: NSMenu?
    private var trackingMenu = false
    private var trackingMenuOnAnotherScreen = false
    private var pendingMenuOpen: UUID?
    private var menuDismissalClick: NSEvent?
    private var panelAfterMenu: Region?
    private var visiblePanel: Region?
    private var panelVisible: Bool { visiblePanel != nil }
    private var switchingPanels = false
    private var removed = false
    var onLayoutChange: (() -> Void)?
    var onClosePanel: ((Region) -> Void)?
    var onTogglePanel: ((Region, NSRect, NSScreen) -> Void)?

    override init() {
        let width = face.width
        item = NSStatusBar.system.statusItem(withLength: width)
        super.init()
        item.autosaveName = "NetRate"
        item.button?.setAccessibilityLabel("网速")
    }

    var isSplit: Bool { watch != nil || hearing != nil }
    private static let hearingGap = StatusFace.moduleGap + 1
    private var hearingWidth: CGFloat { hearing == nil ? 0 : StatusIconState.size.width + Self.hearingGap }
    private var totalWidth: CGFloat { hearingWidth + face.width + (watch.map { StatusFace.moduleGap + $0.width } ?? 0) }
    var isOpeningMenu: Bool { pendingMenuOpen != nil || trackingMenu }

    func installMenu(_ menu: NSMenu) {
        self.menu = menu
        configureInput()
    }

    func removeForExit() {
        guard !removed else { return }
        removed = true
        pendingMenuOpen = nil
        panelAfterMenu = nil
        finishFocusTransition()
        if trackingMenu { menu?.cancelTrackingWithoutAnimation() }
        NSStatusBar.system.removeStatusItem(item)
    }

    func updateNetwork(speed: Speed?, connectivity: ConnectivityState) {
        let imageChanged = face.update(speed: speed, connectivity: connectivity)
        if imageChanged { draw() }
        updateAccessibility()
    }

    func updateStopwatch(_ presentation: StopwatchPresentation?) {
        let previousWidth = watch?.width
        let hadWatch = watch != nil
        let next = presentation.map(StopwatchStatusFace.init)
        let imageChanged = !(next?.hasSameLabels(as: watch) ?? (watch == nil))
        updateFocusTransition(to: next)
        watch = next
        if next?.width != previousWidth { item.length = totalWidth }
        if hadWatch != (watch != nil) { configureInput() }
        if imageChanged { draw() }
        updateAccessibility()
        if next?.width != previousWidth { layoutChanged() }
    }

    func updateHearing(_ next: HearingPresentation?) {
        guard next != hearing else { return }
        let layoutChanged = (next == nil) != (hearing == nil)
        let iconChanged = next?.icon != hearing?.icon
        hearing = next
        if layoutChanged {
            observeHearingAppearance()
            item.length = totalWidth
            configureInput()
        }
        if iconChanged {
            hearingImage = next?.icon.image()
            draw()
        }
        updateAccessibility()
        if layoutChanged { self.layoutChanged() }
    }

    private func observeHearingAppearance() {
        let center = NSWorkspace.shared.notificationCenter
        appearanceObservation = nil
        if let contrastObservation { center.removeObserver(contrastObservation); self.contrastObservation = nil }
        guard hearing != nil else { return }
        hearingAppearance = NSApp.effectiveAppearance.name
        increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshHearingAppearance() }
        }
        contrastObservation = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHearingAppearance() }
        }
    }

    private func refreshHearingAppearance() {
        guard let hearing else { return }
        let name = NSApp.effectiveAppearance.name
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        // Replica drawing can notify repeatedly without an actual appearance change.
        guard name != hearingAppearance || contrast != increasedContrast else { return }
        hearingAppearance = name
        increasedContrast = contrast
        hearingImage = hearing.icon.image()
        draw()
    }

    private func layoutChanged() {
        if let button = item.button {
            if let hearingTip { button.removeToolTip(hearingTip); self.hearingTip = nil }
            if let rect = region(.hearing, of: button.bounds) {
                hearingTip = button.addToolTip(rect, owner: self, userData: nil)
            }
        }
        onLayoutChange?()
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        hearing.map { "监听环境音 · " + $0.title } ?? ""
    }

    func networkRegion(of frame: NSRect) -> NSRect {
        let padding = max(0, (frame.width - totalWidth) / 2)
        let left = hearing == nil ? frame.minX : frame.minX + padding + hearingWidth - Self.hearingGap / 2
        let right = watch == nil ? frame.maxX : frame.minX + padding + hearingWidth + face.width + StatusFace.moduleGap / 2
        return NSRect(x: left, y: frame.minY, width: right - left, height: frame.height)
    }

    func region(_ part: Region, of frame: NSRect) -> NSRect? {
        let network = networkRegion(of: frame)
        switch part {
        case .network: return network
        case .hearing:
            guard hearing != nil else { return nil }
            return frame.divided(atDistance: network.minX - frame.minX, from: .minXEdge).slice
        case .stopwatch:
            guard watch != nil else { return nil }
            return frame.divided(atDistance: network.maxX - frame.minX, from: .minXEdge).remainder
        }
    }

    private func target(at point: NSPoint, in frame: NSRect) -> Region {
        if region(.hearing, of: frame)?.contains(point) == true { return .hearing }
        if region(.stopwatch, of: frame)?.contains(point) == true { return .stopwatch }
        return .network
    }

    // Only exempt an actual button from outside-click dismissal. A projection on
    // an inactive screen can cover a different application's menu bar item.
    func containsButton(at point: NSPoint) -> Bool {
        guard let (frame, _) = location(at: nil) else { return false }
        return frame.contains(point)
    }

    func region(_ part: Region, on screen: NSScreen) -> NSRect? {
        guard let (frame, _) = location(at: nil, preferred: screen) else { return nil }
        return region(part, of: frame)
    }

    private func draw() {
        let amounts = focusTransition?.amounts(at: ProcessInfo.processInfo.systemUptime)
        if focusTransition != nil, amounts == nil { finishFocusTransition() }
        guard let image = face.renderedImage else { return }
        let networkAndWatch = watch?.combinedImage(with: image, focusAmounts: amounts) ?? image
        guard let hearingImage else { item.button?.image = networkAndWatch; return }
        let offset = hearingWidth
        item.button?.image = NSImage(size: NSSize(width: totalWidth, height: image.size.height), flipped: false) { bounds in
            hearingImage.draw(at: NSPoint(x: 0, y: bounds.midY - hearingImage.size.height / 2),
                              from: .zero, operation: .sourceOver, fraction: 1)
            networkAndWatch.draw(at: NSPoint(x: offset, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    private func updateFocusTransition(to next: StopwatchStatusFace?) {
        guard let watch, let next, next.sharesTimerOrder(with: watch) else {
            finishFocusTransition()
            return
        }
        let target = next.focusAmounts
        guard target != watch.focusAmounts else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishFocusTransition()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        // A second shortcut press continues from the widths already on screen.
        let start = focusTransition?.amounts(at: now) ?? watch.focusAmounts
        focusTransition = .init(from: start, to: target, start: now)
        guard focusTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.draw() }
        }
        focusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishFocusTransition() {
        focusTransition = nil
        focusTimer?.invalidate()
        focusTimer = nil
    }

    private func configureInput() {
        guard let button = item.button else { return }
        if #available(macOS 27.0, *) { item.expandedInterfaceDelegate = self }
        let panels: [(Region, String)] = [(.hearing, "打开环境音面板"), (.stopwatch, "打开秒表面板")]
        button.setAccessibilityCustomActions(panels.compactMap { part, name in
            guard region(part, of: button.bounds) != nil else { return nil }
            return NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self, let (frame, screen) = location(at: nil) else { return false }
                if trackingMenu {
                    panelAfterMenu = part
                    menu?.cancelTrackingWithoutAnimation()
                } else if visiblePanel != part {
                    showPanel(part, at: frame, on: screen)
                }
                return true
            }
        })
        button.target = self
        button.action = #selector(pressed(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        button.setAccessibilityLabel([hearing == nil ? nil : "监听环境音", "网速", watch == nil ? nil : "StopWatch"].compactMap { $0 }.joined(separator: "、"))
        NSAccessibility.post(element: button, notification: .layoutChanged)
    }

    private func updateAccessibility() {
        guard let button = item.button else { return }
        let parts = [hearing.map { "监听环境音，" + $0.title }, face.accessibilityValue,
                     watch.map { "StopWatch，" + $0.accessibilityValue }]
        button.setAccessibilityValue(parts.compactMap { $0 }.joined(separator: "。"))
        button.setAccessibilityHelp(isSplit ? "左键点击对应区域打开菜单或面板。右键点击任意位置打开网速菜单。" : face.accessibilityHelp)
    }

    @objc private func pressed(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .rightMouseUp else {
            openNetworkMenu()
            return
        }
        // AppKit can deliver a secondary action with an event centered on the
        // active button, even when the pointer clicked a different replica.
        let point = NSEvent.mouseLocation
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
            let replica = location(at: point)?.0
            // System items can shift on a crowded display. Use the actual click
            // as the anchor if the projected button does not cover it.
            let frame = replica.flatMap { $0.contains(point) ? $0 : nil }
                ?? NSRect(x: point.x, y: screen.visibleFrame.maxY, width: 0, height: 0)
            scheduleNetworkMenu(at: frame, on: screen, openedBySecondaryClick: true)
        } else if let (frame, screen) = location(at: point) {
            primaryClick(at: point, in: frame, on: screen)
        }
    }

    private func openNetworkMenu() {
        guard let (frame, screen) = location(at: nil) else { return }
        showNetworkMenu(at: frame, on: screen)
    }

    private func scheduleNetworkMenu(at frame: NSRect, on screen: NSScreen, openedBySecondaryClick: Bool) {
        let token = UUID()
        pendingMenuOpen = token
        // Let AppKit finish closing its previous menu session before reopening.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, pendingMenuOpen == token else { return }
            pendingMenuOpen = nil
            showNetworkMenu(at: frame, on: screen, openedBySecondaryClick: openedBySecondaryClick)
        }
    }

    func panelVisibilityChanged(_ part: Region, visible: Bool) {
        if visible { visiblePanel = part }
        else if visiblePanel == part { visiblePanel = nil }
        if !switchingPanels { synchronizeHighlight() }
    }

    func handlePanelStatusClick(_ event: NSEvent) -> Bool {
        // WindowServer tracks primary clicks during a native expanded session.
        // Secondary clicks continue to arrive as regular status button actions.
        guard #available(macOS 27.0, *), item.expandedInterfaceSession != nil,
              event.type == .leftMouseDown, panelVisible, let point = Self.primaryClickPoint(of: event),
              containsButton(at: point), let (frame, screen) = location(at: point) else { return false }
        primaryClick(at: point, in: frame, on: screen)
        return true
    }

    private func synchronizeHighlight() {
        guard !removed else { return }
        let open = panelVisible || (trackingMenu && !trackingMenuOnAnotherScreen)
        if #available(macOS 27.0, *), let session = item.expandedInterfaceSession {
            if !open { session.cancel() }
        } else {
            item.button?.highlight(open)
            // Momentary button tracking clears its pressed appearance on mouse-up.
            DispatchQueue.main.async { [weak self] in
                guard let self, !removed else { return }
                item.button?.highlight(panelVisible || (trackingMenu && !trackingMenuOnAnotherScreen))
            }
        }
    }

    private func showNetworkMenu(at frame: NSRect, on screen: NSScreen, openedBySecondaryClick: Bool = false) {
        guard let menu, !removed, !trackingMenu, NSScreen.screens.contains(screen) else { return }
        pendingMenuOpen = nil
        trackingMenu = true
        trackingMenuOnAnotherScreen = buttonLocation()?.screen != screen
        if let visiblePanel { onClosePanel?(visiblePanel) }
        synchronizeHighlight()
        let start = ProcessInfo.processInfo.systemUptime
        // WindowServer can consume a click on the status item and return from
        // native tracking without an NSApp.currentEvent.
        let clickMonitor = (isSplit || openedBySecondaryClick) ? NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.menuDismissalClick = event }
        } : nil
        // Keep the menu reachable from the status item for VoiceOver during tracking.
        item.menu = menu
        let selected: Bool
        if #available(macOS 27.0, *), !trackingMenuOnAnotherScreen, let button = item.button {
            // The native button owns the menu's tracking and selected appearance
            // even when the click did not start an expanded interface session.
            button.performClick(nil)
            // The native call returns no selection result. A handoff still
            // requires a primary click inside an enabled region.
            selected = false
        } else {
            // A secondary click can arrive from a replica without moving the
            // AppKit button to that display. Screen coordinates anchor the same
            // NSMenu to the clicked replica.
            let origin = NSPoint(x: frame.minX, y: min(frame.minY, screen.visibleFrame.maxY))
            selected = menu.popUp(positioning: nil, at: origin, in: nil)
        }
        let dismissalPoint = [NSApp.currentEvent, menuDismissalClick].lazy.compactMap { event -> NSPoint? in
            guard let event, event.timestamp >= start else { return nil }
            return Self.primaryClickPoint(of: event)
        }.first
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        menuDismissalClick = nil
        item.menu = nil
        let trackedAnotherScreen = trackingMenuOnAnotherScreen
        trackingMenu = false
        trackingMenuOnAnotherScreen = false
        guard !removed else { return }
        // NSMenu consumes the dismissal click. Its terminating mouse event still
        // identifies the actual location; the live pointer alone could also be
        // over the status item when Esc or a menu command closed the menu.
        if let part = panelAfterMenu {
            panelAfterMenu = nil
            if visiblePanel != part { showPanel(part, at: frame, on: screen) }
        } else if !selected, let point = dismissalPoint,
                  let (buttonFrame, destination) = location(at: point),
                  containsButton(at: point) || (trackedAnotherScreen && destination == screen && frame.contains(point)) {
            let part = target(at: point, in: buttonFrame)
            if part != .network {
                showPanel(part, at: buttonFrame, on: destination)
            } else if openedBySecondaryClick {
                scheduleNetworkMenu(at: buttonFrame, on: destination, openedBySecondaryClick: false)
            }
        }
        synchronizeHighlight()
    }

    private static func primaryClickPoint(of event: NSEvent) -> NSPoint? {
        guard event.type == .leftMouseDown || event.type == .leftMouseUp,
              !event.modifierFlags.contains(.control),
              let point = event.cgEvent?.location, let primary = NSScreen.screens.first else { return nil }
        return NSPoint(x: point.x, y: primary.frame.maxY - point.y)
    }

    private func primaryClick(at point: NSPoint, in frame: NSRect, on screen: NSScreen) {
        let part = target(at: point, in: frame)
        if part == .network { showNetworkMenu(at: frame, on: screen) }
        else { showPanel(part, at: frame, on: screen) }
    }

    private func showPanel(_ part: Region, at frame: NSRect, on screen: NSScreen) {
        guard let anchor = region(part, of: frame) else { return }
        pendingMenuOpen = nil
        switchingPanels = true
        if let visiblePanel, visiblePanel != part { onClosePanel?(visiblePanel) }
        onTogglePanel?(part, anchor, screen)
        switchingPanels = false
        synchronizeHighlight()
    }

    private func buttonLocation() -> (frame: NSRect, screen: NSScreen)? {
        guard !removed, let button = item.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(frame) }) else { return nil }
        return (frame, screen)
    }

    private func location(at point: NSPoint?, preferred: NSScreen? = nil) -> (NSRect, NSScreen)? {
        guard let (frame, source) = buttonLocation() else { return nil }
        let screens = NSScreen.screens
        let destination = preferred ?? point.flatMap { point in screens.first(where: { $0.frame.contains(point) }) }
        guard let destination, source != destination else { return (frame, source) }
        guard let projected = StatusHover.replicaFrame(of: frame, from: source.frame, to: destination.frame,
                                                       topRightArea: destination.auxiliaryTopRightArea)
        else { return nil }
        return (projected, destination)
    }
}

@available(macOS 27.0, *)
extension StatusEntry: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        // A panel opened by a native menu dismissal may precede its first
        // expanded session. Route the initiating click even when a panel is visible.
        guard !trackingMenu,
              let (frame, screen) = location(at: NSEvent.mouseLocation) else { return }
        let openedBySecondaryClick = NSEvent.modifierFlags.contains(.control)
        let part = target(at: NSEvent.mouseLocation, in: frame)
        if !openedBySecondaryClick, part != .network {
            showPanel(part, at: frame, on: screen)
        } else {
            // Allow AppKit to finish establishing the session before entering
            // the native menu's synchronous tracking loop.
            DispatchQueue.main.async { [weak self] in
                guard let self, item.expandedInterfaceSession === session else { return }
                showNetworkMenu(at: frame, on: screen, openedBySecondaryClick: openedBySecondaryClick)
            }
        }
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        if let visiblePanel { onClosePanel?(visiblePanel) }
    }
}
