import AppKit

/// The WindowServer replicates this one system button on each menu bar.
@MainActor
final class StatusEntry: NSObject {
    let item: NSStatusItem
    private var face = StatusFace()
    private var watch: StopwatchStatusFace?
    private var focusTransition: StopwatchStatusFace.FocusTransition?
    private var focusTimer: Timer?
    private var menu: NSMenu?
    private var trackingMenu = false
    private var pendingMenuOpen: UUID?
    private var secondaryMenuClick: NSEvent?
    private var showPanelAfterMenu = false
    private var panelVisible = false
    var onLayoutChange: (() -> Void)?
    var onCloseStopwatch: (() -> Void)?
    var onToggleStopwatch: ((NSRect, NSScreen) -> Void)?

    override init() {
        let width = face.width
        item = NSStatusBar.system.statusItem(withLength: width)
        super.init()
        item.autosaveName = "NetRate"
        item.button?.setAccessibilityLabel("网速")
    }

    var isSplit: Bool { watch != nil }
    var isOpeningMenu: Bool { pendingMenuOpen != nil }

    func installMenu(_ menu: NSMenu) {
        self.menu = menu
        if !isSplit { item.menu = menu }
    }

    func updateNetwork(speed: Speed?, connectivity: ConnectivityState) {
        let imageChanged = face.update(speed: speed, connectivity: connectivity)
        if imageChanged { draw() }
        updateAccessibility()
    }

    func updateStopwatch(_ presentation: StopwatchPresentation?) {
        let previousWidth = watch?.width
        let wasSplit = isSplit
        let next = presentation.map(StopwatchStatusFace.init)
        let imageChanged = !(next?.hasSameLabels(as: watch) ?? (watch == nil))
        updateFocusTransition(to: next)
        watch = next
        if next?.width != previousWidth {
            item.length = face.width + (next.map { StopwatchStatusFace.leadingGap + $0.width } ?? 0)
        }
        if wasSplit != isSplit {
            configureInput()
        }
        if imageChanged { draw() }
        updateAccessibility()
        if next?.width != previousWidth { onLayoutChange?() }
    }

    func networkRegion(of frame: NSRect) -> NSRect {
        guard let watch else { return frame }
        // The button has a system-defined margin beyond the centered image.
        let total = face.width + StopwatchStatusFace.leadingGap + watch.width
        let padding = max(0, (frame.width - total) / 2)
        let boundary = padding + face.width + StopwatchStatusFace.leadingGap / 2
        return frame.divided(atDistance: boundary, from: .minXEdge).slice
    }

    // Only exempt an actual button from outside-click dismissal. A projection on
    // an inactive screen can cover a different application's menu bar item.
    func containsButton(at point: NSPoint) -> Bool {
        guard let (frame, _) = location(at: nil) else { return false }
        return frame.contains(point)
    }

    func stopwatchRegion(on screen: NSScreen) -> NSRect? {
        guard isSplit, let (frame, _) = location(at: nil, preferred: screen) else { return nil }
        return stopwatchRegion(of: frame)
    }

    private func stopwatchRegion(of frame: NSRect) -> NSRect {
        let network = networkRegion(of: frame)
        return frame.divided(atDistance: network.width, from: .minXEdge).remainder
    }

    private func draw() {
        let amounts = focusTransition?.amounts(at: ProcessInfo.processInfo.systemUptime)
        if focusTransition != nil, amounts == nil { finishFocusTransition() }
        guard let image = face.renderedImage else { return }
        item.button?.image = watch?.combinedImage(with: image, focusAmounts: amounts) ?? image
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
        if isSplit {
            item.menu = nil
            button.menu = nil
            if #available(macOS 27.0, *) { item.expandedInterfaceDelegate = self }
            button.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "打开秒表面板") { [weak self] in
                    guard let self, isSplit, let (frame, screen) = location(at: nil) else { return false }
                    if trackingMenu {
                        showPanelAfterMenu = true
                        menu?.cancelTrackingWithoutAnimation()
                    } else if !panelVisible {
                        showStopwatch(at: frame, on: screen)
                    }
                    return true
                }
            ])
            button.target = self
            button.action = #selector(pressed(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
            button.setAccessibilityLabel("网速和 StopWatch")
        } else {
            pendingMenuOpen = nil
            if #available(macOS 27.0, *) {
                item.expandedInterfaceSession?.cancel()
                item.expandedInterfaceDelegate = nil
            }
            button.setAccessibilityCustomActions(nil)
            button.action = nil
            button.target = nil
            button.sendAction(on: .leftMouseUp)
            item.menu = menu
            button.setAccessibilityLabel("网速")
        }
        NSAccessibility.post(element: button, notification: .layoutChanged)
    }

    private func updateAccessibility() {
        guard let button = item.button else { return }
        if let watch {
            button.setAccessibilityValue(face.accessibilityValue + "。StopWatch，" + watch.accessibilityValue)
            button.setAccessibilityHelp("左键点击秒表打开面板。右键点击任意位置打开网速菜单。")
        } else {
            button.setAccessibilityValue(face.accessibilityValue)
            button.setAccessibilityHelp(face.accessibilityHelp)
        }
    }

    @objc private func pressed(_ sender: NSStatusBarButton) {
        let point = NSEvent.mouseLocation
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .rightMouseUp,
              let (frame, screen) = location(at: point) else {
            openNetworkMenu()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            scheduleNetworkMenu(at: frame, on: screen, openedBySecondaryClick: true)
        } else if networkRegion(of: frame).contains(point) {
            showNetworkMenu(at: frame, on: screen)
        } else if stopwatchRegion(of: frame).contains(point) {
            showStopwatch(at: frame, on: screen)
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

    func panelVisibilityChanged(_ visible: Bool) {
        panelVisible = visible
        synchronizeHighlight()
    }

    func handlePanelStatusClick(_ event: NSEvent) -> Bool {
        // WindowServer tracks primary clicks during a native expanded session.
        // Secondary clicks continue to arrive as regular status button actions.
        guard #available(macOS 27.0, *), item.expandedInterfaceSession != nil,
              event.type == .leftMouseDown, panelVisible, let point = Self.primaryClickPoint(of: event),
              containsButton(at: point), let (frame, screen) = location(at: point) else { return false }
        if networkRegion(of: frame).contains(point) {
            showNetworkMenu(at: frame, on: screen)
        } else {
            showStopwatch(at: frame, on: screen)
        }
        return true
    }

    private func synchronizeHighlight() {
        let open = panelVisible || trackingMenu
        if #available(macOS 27.0, *), let session = item.expandedInterfaceSession {
            if !open { session.cancel() }
        } else {
            item.button?.highlight(open)
            // Momentary button tracking clears its pressed appearance on mouse-up.
            DispatchQueue.main.async { [weak self] in
                guard let self, isSplit else { return }
                item.button?.highlight(panelVisible || trackingMenu)
            }
        }
    }

    private func showNetworkMenu(at frame: NSRect, on screen: NSScreen, openedBySecondaryClick: Bool = false) {
        guard let menu, !trackingMenu else { return }
        pendingMenuOpen = nil
        trackingMenu = true
        onCloseStopwatch?()
        synchronizeHighlight()
        let start = ProcessInfo.processInfo.systemUptime
        // WindowServer can consume a click on the status item and return from
        // native tracking without an NSApp.currentEvent.
        let clickMonitor = openedBySecondaryClick ? NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.secondaryMenuClick = event }
        } : nil
        // Link the tracking menu to its status item so VoiceOver can traverse
        // its native commands as well as the separate stopwatch action.
        item.menu = menu
        let selected: Bool
        if #available(macOS 27.0, *), let button = item.button {
            // The native button owns the menu's tracking and selected appearance
            // even when the click did not start an expanded interface session.
            button.performClick(nil)
            // The native call returns no selection result. A handoff still
            // requires a primary click inside the stopwatch region.
            selected = false
        } else {
            let origin = NSPoint(x: frame.minX, y: min(frame.minY, screen.visibleFrame.maxY))
            selected = menu.popUp(positioning: nil, at: origin, in: nil)
        }
        let dismissalPoint = [NSApp.currentEvent, secondaryMenuClick].lazy.compactMap { event -> NSPoint? in
            guard let event, event.timestamp >= start else { return nil }
            return Self.primaryClickPoint(of: event)
        }.first
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        secondaryMenuClick = nil
        if isSplit { item.menu = nil }
        trackingMenu = false
        // NSMenu consumes the dismissal click. Its terminating mouse event still
        // identifies the actual location; the live pointer alone could also be
        // over the timer when Esc or a menu command closed the menu.
        if showPanelAfterMenu {
            showPanelAfterMenu = false
            if isSplit, !panelVisible { showStopwatch(at: frame, on: screen) }
        } else if !selected, isSplit, let point = dismissalPoint, containsButton(at: point),
           let (buttonFrame, destination) = location(at: point) {
            if stopwatchRegion(of: buttonFrame).contains(point), !panelVisible {
                showStopwatch(at: buttonFrame, on: destination)
            } else if openedBySecondaryClick, networkRegion(of: buttonFrame).contains(point) {
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

    private func showStopwatch(at frame: NSRect, on screen: NSScreen) {
        pendingMenuOpen = nil
        let region = stopwatchRegion(of: frame)
        onToggleStopwatch?(region, screen)
    }

    private func location(at point: NSPoint?, preferred: NSScreen? = nil) -> (NSRect, NSScreen)? {
        guard let button = item.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screens = NSScreen.screens
        guard let source = screens.first(where: { $0.frame.contains(frame) }) else { return nil }
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
        guard isSplit, !trackingMenu, !panelVisible,
              let (frame, screen) = location(at: NSEvent.mouseLocation) else { return }
        let openedBySecondaryClick = NSEvent.modifierFlags.contains(.control)
        if !openedBySecondaryClick, stopwatchRegion(of: frame).contains(NSEvent.mouseLocation) {
            showStopwatch(at: frame, on: screen)
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
        if panelVisible { onCloseStopwatch?() }
    }
}
