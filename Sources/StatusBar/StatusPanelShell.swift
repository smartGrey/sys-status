import AppKit
import QuartzCore

@MainActor
final class StatusPanelShell {
    private let item: NSStatusItem
    private let region: (NSRect) -> NSRect
    private let content: PanelContent
    var allowsPreview: () -> Bool = { true }
    var didPresentPreview: (() -> Void)?
    var openedChanged: ((Bool) -> Void)?
    var containsEntry: (NSPoint) -> Bool = { _ in false }
    private(set) var opened = false
    private var waitingForWake: NSRect?
    var editing: Bool { panel?.isVisible == true && (content.isEditing() || panel?.protectsInteraction() == true || (panel?.firstResponder as? NSTextView)?.isFieldEditor == true) }
    var previewing: Bool { anchor != nil && !opened && !isPinned }
    private let menuIsOpening: () -> Bool
    private var screens: [NSScreen] = []
    private var menuBarWindow: (id: CGWindowID, bounds: CGRect?)?
    private var menuIsOpen = false
    private var suppressedAnchor: NSRect?
    private var anchor: NSRect?
    private var panel: StatusPanelWindow?
    var isPinned: Bool { panel?.isMovable == true }
    private var presentation: (anchor: NSRect, timer: Timer)?
    private var dismissal: Timer?
    init(item: NSStatusItem, content: PanelContent, region: @escaping (NSRect) -> NSRect = { $0 },
         menuIsOpening: @escaping () -> Bool = { false }) {
        self.item = item
        self.content = content
        self.region = region
        self.menuIsOpening = menuIsOpening
    }

    func start() {
        screens = NSScreen.screens
        if let previous = waitingForWake, let screen = screens.first(where: { $0.frame.intersects(previous) }) ?? screens.first {
            waitingForWake = nil
            let rect = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 1, height: 1)
            show(under: rect, within: screen.visibleFrame)
            pinPanel()
            if let panel { panel.setFrame(StatusPanelGeometry.pinnedFrame(size: panel.frame.size, previous: previous, within: screen.visibleFrame), display: true) }
        }
    }

    func stop(rememberPins: Bool = false) {
        waitingForWake = rememberPins && isPinned ? panel?.frame : nil
        hide()
    }

    func resetPosition() {
        screens = NSScreen.screens
        menuBarWindow = nil
        if isPinned, let panel, let screen = panel.screen ?? screens.first {
            panel.setFrame(StatusPanelGeometry.pinnedFrame(size: panel.frame.size, previous: panel.frame, within: screen.visibleFrame), display: true)
        } else {
            hide()
        }
    }

    func trackAnchor(_ resolve: (NSScreen) -> NSRect?) {
        guard !isPinned else { return }
        if let pending = presentation?.anchor {
            // A change of digit count can resize the strip while the pointer is
            // stationary. Keep the pending hover if it still hits this module.
            if let screen = screens.first(where: { $0.frame.contains(pending) }),
               let next = resolve(screen), next.contains(NSEvent.mouseLocation) {
                schedulePresentation(under: next, within: screen.visibleFrame)
            } else { cancelPresentation() }
        }
        guard let anchor else { return }
        guard let screen = screens.first(where: { $0.frame.contains(anchor) }),
              let rect = resolve(screen) else {
            // A status item may temporarily disappear or move while its width
            // changes. Keep a click-opened panel at its last valid position.
            dismissPreview()
            return
        }
        self.anchor = rect
        content.follow(rect, screen)
    }

    func setMenuOpen(_ open: Bool) {
        menuIsOpen = open
        if open { cancelPresentation(); if !isPinned { hide() } }
    }

    func handle(_ event: NSEvent, at pointer: NSPoint) {
        guard !isPinned else { return }
        if event.type == .mouseMoved || event.type == .leftMouseUp {
            guard !opened, event.type == .mouseMoved || previewing else { return }
            updatePosition(for: event.cgEvent, at: pointer)
        } else if let panel, event.window === panel || event.window?.parent === panel || panel.protectsInteraction() {
            cancelDismissal()
        } else if panel?.isVisible != true || panel?.frame.contains(pointer) != true {
            if !containsEntry(pointer) { hide() }
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
        guard previewing, !editing, dismissal == nil else { return }
        let timer = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dismissal = nil
                if self.previewing && !self.editing && NSEvent.pressedMouseButtons == 0 { self.hide() }
            }
        }
        dismissal = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updatePosition(for event: CGEvent?, at pointer: NSPoint) {
        if let suppressedAnchor {
            if suppressedAnchor.contains(pointer) { return }
            self.suppressedAnchor = nil
        }
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

        guard allowsPreview(), NSEvent.pressedMouseButtons == 0 else { cancelPresentation(); return }
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
                guard !self.menuIsOpen, !self.menuIsOpening(), self.item.isVisible, self.allowsPreview(), !self.opened, !self.isPinned,
                      NSEvent.pressedMouseButtons == 0, rect.contains(pointerLocation()) else { return }
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
        let wasHidden = anchor == nil
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame == visibleFrame }) ?? NSScreen.main else { return }
        if wasHidden {
            guard let window = content.show(rect, screen, opened) else { return }
            panel = window
            window.isMovable = false
            window.togglePinned = { [weak self] in self?.togglePin() }
            window.beginPinning = { [weak self] in self?.pinPanel() }
            window.dismissPanel = { [weak self] in self?.hide() }
        } else { content.follow(rect, screen) }
        anchor = rect
        if wasHidden, let panel {
            if !opened { didPresentPreview?() }
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + (opened ? 0 : 1))
            reveal(panel)
        }
    }

    func click(under rect: NSRect, on screen: NSScreen) {
        if isPinned { panel?.orderFrontRegardless(); return }
        if opened {
            suppressedAnchor = rect
            hide()
            return
        }
        cancelDismissal()
        opened = true
        show(under: rect, within: screen.visibleFrame)
        guard let panel, panel.isVisible else { opened = false; return }
        panel.level = .statusBar
        panel.makeKeyAndOrderFront(nil)
        openedChanged?(true)
    }

    func dismissPreview() { cancelPresentation(); if previewing { hide() } }

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
        panel.level = .statusBar
        if opened { opened = false; openedChanged?(false) }
        panel.pinChanged?(true)
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
        let target = region(frame)
        return target.contains(pointer) ? target : nil
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

    func hide() {
        cancelPresentation()
        cancelDismissal()
        guard anchor != nil else { return }
        if opened { opened = false; openedChanged?(false) }
        panel?.isMovable = false
        panel?.pinChanged?(false)
        anchor = nil
        content.close()
        panel?.alphaValue = 1
        panel = nil
    }

    static func replicaFrame(of button: NSRect, from source: NSRect, to destination: NSRect,
                             topRightArea: NSRect?) -> NSRect? {
        guard !button.isEmpty, source.contains(button), source.maxY - button.midY < 48 else { return nil }
        let frame = button.offsetBy(dx: destination.maxX - source.maxX, dy: destination.maxY - source.maxY)
        guard destination.contains(frame), frame.minX >= (topRightArea ?? destination).minX else { return nil }
        return frame
    }
}
