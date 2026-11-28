import AppKit

/// The WindowServer replicates this one system button on each menu bar.
@MainActor
final class StatusEntry: NSObject, NSViewToolTipOwner {
    typealias Region = StatusModule
    private(set) var moduleOrder = Region.allCases
    var onModulesChanged: (() -> Void)?
    private var usesNativeHighlight = false
    private var hearing: HearingPresentation?
    private var systemFace: SystemStatusFace?
    private var systemImage: NSImage?
    private var hearingImage: NSImage?
    private var appearanceObservation: NSKeyValueObservation?
    private var contrastObservation: NSObjectProtocol?
    private var hearingAppearance: NSAppearance.Name?
    private var increasedContrast = false
    private var hearingTip: NSView.ToolTipTag?

    let item: NSStatusItem
    private var face = StatusFace()
    private var networkEnabled = true
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
        let width = face.width + 2 * StatusStripLayout.inset
        item = NSStatusBar.system.statusItem(withLength: width)
        super.init()
        item.autosaveName = "NetRate"
        item.button?.setAccessibilityLabel(StatusModule.network.title)
    }

    var isSplit: Bool { watch != nil || hearing != nil || systemFace != nil }
    private var layout: StatusStripLayout {
        var widths: [Region: CGFloat] = [:]
        if networkEnabled { widths[.network] = face.width }
        widths[.hearing] = hearing.map { _ in StatusIconState.size.width }
        widths[.stopwatch] = watch?.width
        widths[.system] = systemFace?.width
        return StatusStripLayout(order: moduleOrder, widths: widths)
    }
    private var totalWidth: CGFloat { layout.width }
    var enabledModules: [Region] { layout.slots.map(\.module) }

    func applyOrder(_ order: [Region]) {
        let next = Region.ordered(order)
        guard !removed, next != moduleOrder else { return }
        moduleOrder = next
        item.length = totalWidth
        configureInput()
        draw()
        updateAccessibility()
        layoutChanged()
    }

    func updateSystem(_ next: SystemStatusFace?) {
        guard !removed, systemFace != next else { return }
        let oldWidth = totalWidth
        let wasEnabled = systemFace != nil
        systemFace = next
        systemImage = next?.image()
        if oldWidth != totalWidth { item.length = totalWidth }
        if wasEnabled != (next != nil) { configureInput(); onModulesChanged?() }
        draw()
        updateAccessibility()
        if oldWidth != totalWidth { layoutChanged() }
    }
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
        guard !removed else { return }
        let imageChanged = face.update(speed: speed, connectivity: connectivity)
        let changed = networkEnabled != connectivity.enabled
        networkEnabled = connectivity.enabled
        if changed {
            item.length = totalWidth
            configureInput()
            onModulesChanged?()
            layoutChanged()
        }
        if imageChanged || changed { draw() }
        updateAccessibility()
    }

    func updateStopwatch(_ presentation: StopwatchPresentation?) {
        guard !removed else { return }
        let previousWidth = watch?.width
        let hadWatch = watch != nil
        let next = presentation.map(StopwatchStatusFace.init)
        let imageChanged = !(next?.hasSameLabels(as: watch) ?? (watch == nil))
        updateFocusTransition(to: next)
        watch = next
        if next?.width != previousWidth { item.length = totalWidth }
        if hadWatch != (watch != nil) { configureInput(); onModulesChanged?() }
        if imageChanged { draw() }
        updateAccessibility()
        if next?.width != previousWidth { layoutChanged() }
    }

    func updateHearing(_ next: HearingPresentation?) {
        guard !removed else { return }
        guard next != hearing else { return }
        let layoutChanged = (next == nil) != (hearing == nil)
        let iconChanged = next?.icon != hearing?.icon
        hearing = next
        if layoutChanged {
            onModulesChanged?()
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
        region(.network, of: frame) ?? .zero
    }

    func region(_ part: Region, of frame: NSRect) -> NSRect? {
        layout.region(part, in: frame)
    }

    private func target(at point: NSPoint, in frame: NSRect) -> Region? {
        let layout = self.layout
        return layout.slots.first { layout.region($0.module, in: frame)?.contains(point) == true }?.module
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
        let layout = self.layout
        var images: [Region: NSImage] = [:]
        images[.network] = face.renderedImage
        images[.system] = systemImage
        images[.hearing] = hearingImage
        images[.stopwatch] = watch?.image(focusAmounts: amounts)
        let native = usesNativeHighlight
        item.button?.image = NSImage(size: NSSize(width: layout.width, height: NSStatusBar.system.thickness), flipped: false) { bounds in
            if !native {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 0.8
                shadow.shadowOffset = NSSize(width: 0, height: -0.5)
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.19)
                shadow.set()
                let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0), xRadius: 6, yRadius: 6)
                NSColor.labelColor.withAlphaComponent(0.16).setFill()
                shape.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if layout.slots.isEmpty {
                let icon = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
                icon?.draw(in: NSRect(x: bounds.midX-7, y: bounds.midY-7, width: 14, height: 14))
            }
            for slot in layout.slots {
                guard let part = images[slot.module] else { continue }
                part.draw(at: NSPoint(x: slot.x, y: (bounds.height-part.size.height)/2),
                          from: .zero, operation: .sourceOver, fraction: 1)
            }
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
        button.setAccessibilityCustomActions(enabledModules.map { part in
            let name = switch part {
            case .network: "打开网络状况"
            case .hearing: "打开环境音面板"
            case .stopwatch: "打开秒表面板"
            case .system: "打开系统状态"
            }
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
        } + [NSAccessibilityCustomAction(name: "打开总菜单") { [weak self] in
            self?.openMainMenu()
            return true
        }])
        button.target = self
        button.action = #selector(pressed(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        button.setAccessibilityLabel(enabledModules.isEmpty ? "状态栏扩展" : enabledModules.map { $0 == .stopwatch ? "StopWatch" : $0.title }.joined(separator: "、"))
        NSAccessibility.post(element: button, notification: .layoutChanged)
    }

    private func updateAccessibility() {
        guard let button = item.button else { return }
        let parts = enabledModules.compactMap { part -> String? in
            switch part {
            case .hearing: hearing.map { "监听环境音，" + $0.title }
            case .network: face.accessibilityValue
            case .stopwatch: watch.map { "StopWatch，" + $0.accessibilityValue }
            case .system: systemFace?.spoken
            }
        }
        button.setAccessibilityValue(parts.joined(separator: "。"))
        button.setAccessibilityHelp(enabledModules.isEmpty ? "点击打开状态栏扩展菜单。" : isSplit ? "悬停预览，左键打开对应面板。右键点击任意位置打开状态栏扩展菜单。" : face.accessibilityHelp)
    }

    @objc private func pressed(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .rightMouseUp else {
            openMainMenu()
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
            let frame = StatusPanelGeometry.menuAnchor(at: point, replica: replica, visibleFrame: screen.visibleFrame)
            scheduleMainMenu(at: frame, on: screen)
        } else if let (frame, screen) = location(at: point) {
            primaryClick(at: point, in: frame, on: screen)
        }
    }

    private func openMainMenu() {
        guard let (frame, screen) = location(at: nil) else { return }
        showMainMenu(at: frame, on: screen)
    }

    private func scheduleMainMenu(at frame: NSRect, on screen: NSScreen) {
        let token = UUID()
        pendingMenuOpen = token
        // Let AppKit finish closing its previous menu session before reopening.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, pendingMenuOpen == token else { return }
            pendingMenuOpen = nil
            showMainMenu(at: frame, on: screen)
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
        if open != usesNativeHighlight {
            usesNativeHighlight = open
            draw()
        }
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

    private func showMainMenu(at frame: NSRect, on screen: NSScreen) {
        guard let menu, !removed, !trackingMenu, NSScreen.screens.contains(screen) else { return }
        pendingMenuOpen = nil
        trackingMenu = true
        OperationFeedback.menuScreen = screen
        trackingMenuOnAnotherScreen = buttonLocation()?.screen != screen
        if let visiblePanel { onClosePanel?(visiblePanel) }
        synchronizeHighlight()
        let start = ProcessInfo.processInfo.systemUptime
        // WindowServer can consume a click on the status item and return from
        // native tracking without an NSApp.currentEvent.
        let clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.menuDismissalClick = event }
        }
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
            handOffMenuClick(at: point, in: buttonFrame, on: destination)
        }
        synchronizeHighlight()
    }

    func handOffMenuClick(at point: NSPoint, in frame: NSRect, on screen: NSScreen) {
        guard !removed, !enabledModules.isEmpty else { return }
        primaryClick(at: point, in: frame, on: screen)
    }

    private static func primaryClickPoint(of event: NSEvent) -> NSPoint? {
        guard event.type == .leftMouseDown || event.type == .leftMouseUp,
              !event.modifierFlags.contains(.control),
              let point = event.cgEvent?.location, let primary = NSScreen.screens.first else { return nil }
        return NSPoint(x: point.x, y: primary.frame.maxY - point.y)
    }

    private func primaryClick(at point: NSPoint, in frame: NSRect, on screen: NSScreen) {
        guard let part = target(at: point, in: frame) else { scheduleMainMenu(at: frame, on: screen); return }
        showPanel(part, at: frame, on: screen)
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
        guard let projected = StatusPanelShell.replicaFrame(of: frame, from: source.frame, to: destination.frame,
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
        let event = NSApp.currentEvent
        let openedBySecondaryClick = NSEvent.modifierFlags.contains(.control) ||
            event?.type == .rightMouseDown || event?.type == .rightMouseUp
        let part = target(at: NSEvent.mouseLocation, in: frame)
        if !openedBySecondaryClick, let part {
            showPanel(part, at: frame, on: screen)
        } else {
            // Allow AppKit to finish establishing the session before entering
            // the native menu's synchronous tracking loop.
            DispatchQueue.main.async { [weak self] in
                guard let self, item.expandedInterfaceSession === session else { return }
                showMainMenu(at: frame, on: screen)
            }
        }
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        // AppKit can end menu-bar tracking while a click-opened panel is still
        // in use. The panel shell owns dismissal and reports when to clear the highlight.
        if !switchingPanels { synchronizeHighlight() }
    }
}
