import AppKit
import QuartzCore

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
    private var isPinned: Bool { panel?.isMovable == true }
    var readTimeline: () -> ProbeTimeline = { ProbeTimeline() }
    var probeNow: (() -> Void)?
    private var presentation: (anchor: NSRect, timer: Timer)?
    private var dismissal: Timer?
    private lazy var card: HoverCard = {
        let card = HoverCard()
        card.probeNow = { [weak self] in self?.probeNow?() }
        card.togglePin = { [weak self] in self?.togglePin() }
        card.beginDrag = { [weak self] in self?.pinPanel() }
        return card
    }()

    func refreshTiming() {
        guard anchor != nil else { return }
        card.setTimeline(readTimeline())
    }

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
        screens = NSScreen.screens
        menuBarWindow = nil
        if isPinned {
            layoutPinned(constrain: true)
        } else {
            hide()
            updateButtonTooltip()
        }
    }

    func trackAnchor(_ resolve: (NSScreen) -> NSRect?) {
        guard !isPinned else { return }
        cancelPresentation()
        guard let anchor else { updateButtonTooltip(); return }
        guard let screen = screens.first(where: { $0.frame.contains(anchor) }),
              let rect = resolve(screen) else { hide(); return }
        self.anchor = rect
        layoutCard(under: rect, on: screen.visibleFrame)
    }

    func setMenuOpen(_ open: Bool) {
        menuIsOpen = open
        if open && !isPinned { hide() }
    }

    func update(_ state: ConnectivityState) {
        guard connectivity != state else { return }
        connectivity = state
        if isPinned {
            layoutPinned()
        } else if anchor == nil {
            updateButtonTooltip()
        } else {
            if let anchor, let screen = screens.first(where: { $0.frame.contains(anchor) }) {
                layoutCard(under: anchor, on: screen.visibleFrame)
            }
        }
    }

    private func handle(_ event: NSEvent) {
        guard !isPinned else { return }
        if event.type == .mouseMoved {
            updatePosition(for: event.cgEvent)
        } else if let panel, event.window === panel {
            cancelDismissal()
        } else if panel?.isVisible != true || panel?.frame.contains(NSEvent.mouseLocation) != true {
            hide()
        }
    }

    static func retainsHover(at point: NSPoint, anchor: NSRect, panel: NSRect) -> Bool {
        let bridge = NSRect(x: anchor.minX, y: panel.maxY, width: anchor.width,
                            height: max(0, anchor.minY - panel.maxY))
        return panel.contains(point) || bridge.contains(point)
    }

    private func cancelDismissal() {
        dismissal?.invalidate()
        dismissal = nil
    }

    private func deferDismissal() {
        cancelPresentation()
        guard anchor != nil, dismissal == nil else { return }
        let timer = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        dismissal = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updatePosition(for event: CGEvent?) {
        let pointer = NSEvent.mouseLocation
        if !menuIsOpen, !menuIsOpening(), let anchor, let panel,
           Self.retainsHover(at: pointer, anchor: anchor, panel: panel.frame) {
            cancelDismissal()
            return
        }
        // Most moves are outside the menu bar. Only resolve the button frame near the top of a screen.
        guard !menuIsOpen, !menuIsOpening(), let screen = screens.first(where: { $0.frame.contains(pointer) }),
              pointer.y >= screen.frame.maxY - 48,
              item.isVisible, let button = item.button, let window = button.window, window.isVisible else {
            deferDismissal()
            return
        }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = screen.visibleFrame
        guard let rect = hoverFrame(button: buttonFrame, pointer: pointer, screen: screen, event: event),
              rect.midY >= visibleFrame.maxY else {
            deferDismissal()
            return
        }

        if anchor == nil {
            schedulePresentation(under: rect, within: visibleFrame)
        } else {
            show(under: rect, within: visibleFrame)
        }
    }

    private func cancelPresentation() {
        presentation?.timer.invalidate()
        presentation = nil
    }

    func schedulePresentation(under rect: NSRect, within visibleFrame: NSRect,
                              pointerLocation: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation }) {
        guard presentation?.anchor != rect else { return }
        cancelPresentation()
        let timer = Timer(timeInterval: 0.16, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentation = nil
                guard !self.menuIsOpen, !self.menuIsOpening(), self.item.isVisible,
                      rect.contains(pointerLocation()) else { return }
                self.show(under: rect, within: visibleFrame)
            }
        }
        presentation = (rect, timer)
        RunLoop.main.add(timer, forMode: .common)
    }

    func show(under rect: NSRect, within visibleFrame: NSRect) {
        guard !isPinned else { return }
        cancelPresentation()
        cancelDismissal()
        guard anchor != rect else { return }
        let panel = panel ?? makePanel()
        layoutCard(under: rect, on: visibleFrame)
        if anchor == nil {
            item.button?.toolTip = nil
            card.setTimeline(readTimeline())
            card.setVisible(true)
            reveal(panel)
        }
        anchor = rect
    }

    private func reveal(_ panel: NSPanel) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0.2
        panel.orderFrontRegardless()
        guard !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func togglePin() {
        if isPinned {
            hide()
        } else {
            pinPanel()
        }
    }

    private func pinPanel() {
        guard !isPinned, let panel, panel.isVisible else { return }
        cancelDismissal()
        panel.isMovable = true
        card.setPinned(true)
    }

    private func layoutPinned(constrain: Bool = false) {
        guard let panel, let screen = panel.screen ?? screens.first else { return }
        let bounds = screen.visibleFrame
        let size = card.update(connectivity, availableHeight: bounds.height, availableWidth: bounds.width)
        guard constrain || panel.frame.size != size else { return }
        let frame = StatusPanelGeometry.pinnedFrame(size: size, previous: panel.frame, within: bounds)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func layoutCard(under rect: NSRect, on screen: NSRect) {
        let availableHeight = StatusPanelGeometry.top(under: rect, within: screen) - screen.minY
        let size = card.update(connectivity, availableHeight: availableHeight, availableWidth: screen.width)
        let frame = StatusPanelGeometry.frame(size: size, under: rect, within: screen)
        if panel?.frame != frame { panel?.setFrame(frame, display: true) }
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
        cancelPresentation()
        cancelDismissal()
        guard anchor != nil else { return }
        card.setVisible(false)
        panel?.isMovable = false
        card.setPinned(false)
        anchor = nil
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        updateButtonTooltip()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "网络状况"
        panel.isMovable = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
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
