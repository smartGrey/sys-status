import AppKit

/// The WindowServer replicates this one system button on each menu bar.
@MainActor
final class StatusEntry: NSObject {
    let item: NSStatusItem
    private var face = StatusFace()
    private var watch: StopwatchStatusFace?
    private var menu: NSMenu?
    private var trackingMenu = false
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
        guard let image = face.renderedImage else { return }
        item.button?.image = watch?.combinedImage(with: image) ?? image
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
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("网速和 StopWatch")
        } else {
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
            button.setAccessibilityHelp("左侧打开网速菜单，右侧打开秒表面板。")
        } else {
            button.setAccessibilityValue(face.accessibilityValue)
            button.setAccessibilityHelp(face.accessibilityHelp)
        }
    }

    @objc private func pressed(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .rightMouseDown,
              let (frame, screen) = location(at: NSEvent.mouseLocation) else {
            openNetworkMenu()
            return
        }
        if networkRegion(of: frame).contains(NSEvent.mouseLocation) {
            showNetworkMenu(at: frame, on: screen)
        } else if stopwatchRegion(of: frame).contains(NSEvent.mouseLocation) {
            showStopwatch(at: frame, on: screen)
        }
    }

    private func openNetworkMenu() {
        guard let (frame, screen) = location(at: nil) else { return }
        showNetworkMenu(at: frame, on: screen)
    }

    func panelVisibilityChanged(_ visible: Bool) {
        panelVisible = visible
        synchronizeHighlight()
    }

    func handlePanelStatusClick(_ event: NSEvent) -> Bool {
        // WindowServer tracks primary clicks during a native expanded session.
        // Secondary clicks continue to arrive as regular status button actions.
        guard #available(macOS 27.0, *), item.expandedInterfaceSession != nil,
              event.type == .leftMouseDown, panelVisible, let point = Self.screenPoint(of: event),
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

    private func showNetworkMenu(at frame: NSRect, on screen: NSScreen) {
        guard let menu, !trackingMenu else { return }
        trackingMenu = true
        onCloseStopwatch?()
        synchronizeHighlight()
        let start = ProcessInfo.processInfo.systemUptime
        // Link the tracking menu to its status item so VoiceOver can traverse
        // its native commands as well as the separate stopwatch action.
        item.menu = menu
        let origin = NSPoint(x: frame.minX, y: min(frame.minY, screen.visibleFrame.maxY))
        let selected = menu.popUp(positioning: nil, at: origin, in: nil)
        if isSplit { item.menu = nil }
        trackingMenu = false
        // NSMenu consumes the dismissal click. Its terminating mouse event still
        // identifies the actual location; the live pointer alone could also be
        // over the timer when Esc or a menu command closed the menu.
        if showPanelAfterMenu {
            showPanelAfterMenu = false
            if isSplit, !panelVisible { showStopwatch(at: frame, on: screen) }
        } else if !selected, isSplit, let event = NSApp.currentEvent, event.timestamp >= start,
           let point = Self.screenPoint(of: event), containsButton(at: point),
           let (buttonFrame, destination) = location(at: point),
           stopwatchRegion(of: buttonFrame).contains(point), !panelVisible {
            showStopwatch(at: buttonFrame, on: destination)
        }
        synchronizeHighlight()
    }

    private static func screenPoint(of event: NSEvent) -> NSPoint? {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            guard let point = event.cgEvent?.location, let primary = NSScreen.screens.first else { return nil }
            return NSPoint(x: point.x, y: primary.frame.maxY - point.y)
        default: return nil
        }
    }

    private func showStopwatch(at frame: NSRect, on screen: NSScreen) {
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
        if stopwatchRegion(of: frame).contains(NSEvent.mouseLocation) {
            showStopwatch(at: frame, on: screen)
        } else {
            // Allow AppKit to finish establishing the session before entering
            // the native menu's synchronous tracking loop.
            DispatchQueue.main.async { [weak self] in
                guard let self, item.expandedInterfaceSession === session else { return }
                showNetworkMenu(at: frame, on: screen)
            }
        }
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        if trackingMenu { menu?.cancelTrackingWithoutAnimation() }
        if panelVisible { onCloseStopwatch?() }
    }
}
