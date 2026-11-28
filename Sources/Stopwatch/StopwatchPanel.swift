import AppKit
import Carbon

@MainActor
final class StopwatchPanel {
    private weak var controller: StopwatchController?
    private var window: StatusPanelWindow?
    private var content: StopwatchPanelContent?
    private var anchor: NSRect = .zero
    private var screen: NSScreen?
    private var localMonitor: Any?
    var isRecording: Bool { recording != nil }
    private var presentation: StopwatchPresentation?
    private var shortcutIssues: [StopwatchAction: String] = [:]
    private var hasSaveError = false
    private var recording: StopwatchAction?
    private var sawModifier = false
    private var inputTimeout: Timer?

    var feedback: OperationFeedback { OperationFeedback(screen: window?.screen) }
    var isVisible: Bool { window?.isVisible == true }

    init(controller: StopwatchController) { self.controller = controller }

    @discardableResult
    func show(under anchor: NSRect, on screen: NSScreen, focus: Bool = true) -> StatusPanelWindow {
        self.anchor = anchor
        self.screen = screen
        let window = window ?? makeWindow()
        refresh()
        if focus { window.makeKeyAndOrderFront(nil) }
        installMonitors()
        return window
    }

    func dismissIfVisible() {
        guard isVisible else { return }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        endRecording()
        content?.finishEditing(commit: false)
        window?.orderOut(nil)
        content?.clearInputIssues()
    }

    func update(_ presentation: StopwatchPresentation, shortcutIssues: [StopwatchAction: String], hasSaveError: Bool) {
        self.presentation = presentation
        self.shortcutIssues = shortcutIssues
        self.hasSaveError = hasSaveError
        if isVisible { refresh() }
    }

    func follow(_ anchor: NSRect, on screen: NSScreen) {
        self.anchor = anchor
        self.screen = screen
        refresh()
    }

    private func refresh() {
        guard let presentation, let content, let window, let screen else { return }
        let bounds = screen.visibleFrame
        let size = content.update(presentation, availableWidth: bounds.width - 16, recording: recording,
                                  issues: shortcutIssues, hasSaveError: hasSaveError)
        window.place(size: CGSize(width: size.width, height: size.height + PanelChrome.headerHeight), under: anchor, on: screen)
    }

    private func makeWindow() -> StatusPanelWindow {
        let window = StatusPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.title = "StopWatch"
        window.setAccessibilityLabel("StopWatch")

        let content = StopwatchPanelContent()
        content.autoresizingMask = [.width, .height]
        content.onSelect = { [weak self] id in
            self?.endRecording()
            self?.content?.finishEditing(commit: true)
            self?.controller?.select(id)
        }
        content.onRename = { [weak self] id, name in self?.controller?.rename(id, to: name) }
        content.onToggle = { [weak self] id in
            self?.endRecording()
            self?.controller?.toggle(id)
        }
        content.onReset = { [weak self] id in
            self?.endRecording()
            self?.controller?.reset(id)
        }
        content.onRemove = { [weak self] id in
            self?.endRecording()
            self?.controller?.remove(id)
        }
        content.onAdd = { [weak self] in
            self?.endRecording()
            if let id = self?.controller?.add() { self?.content?.beginEditing(id) }
        }
        content.onMode = { [weak self] mode in
            self?.endRecording()
            self?.controller?.setMode(mode)
            self?.refresh()
        }
        content.onRecord = { [weak self] action in self?.beginRecording(action) }
        content.onClear = { [weak self] action in
            self?.endRecording()
            self?.finishRecording(action, shortcut: nil)
        }
        _ = PanelChrome(title: "", body: content, window: window, leadingControl: content.addButton)
        window.dismissPanel = { [weak self] in self?.dismissIfVisible() }
        self.content = content
        self.window = window
        return window
    }

    private func installMonitors() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            if event.type == .keyDown { return self.handleKey(event) ? nil : event }
            self.captureModifiers(event)
            return event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === window || window?.isKeyWindow == true else { return false }
        let shortcut = ShortcutBinding(event: event)
        let code = Int(event.keyCode)
        if let recording {
            if event.isARepeat { return true }
            if shortcut.modifiers == 0 {
                switch code {
                case kVK_Escape: endRecording(); return true
                case kVK_Tab: endRecording(); return false
                case kVK_Delete, kVK_ForwardDelete: finishRecording(recording, shortcut: nil); return true
                default: break
                }
            }
            finishRecording(recording, shortcut: shortcut)
            return true
        }
        guard shortcut.modifiers == 0, content?.editorHasMarkedText != true else { return false }
        switch code {
        case kVK_Escape:
            if content?.finishEditing(commit: false) != true { window?.dismissPanel?() }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return content?.finishEditing(commit: true) == true
        default:
            return false
        }
    }

    // Another app can receive the primary key before AppKit sees it. Keep the
    // original binding in that case so recording cannot take over the chord.
    private func captureModifiers(_ event: NSEvent) {
        guard let recording, event.window === window || window?.isKeyWindow == true else { return }
        if ShortcutBinding(event: event).modifiers != 0 {
            if !sawModifier {
                content?.clearInputIssue(recording)
                refresh()
            }
            sawModifier = true
        } else if sawModifier {
            sawModifier = false
            inputTimeout?.invalidate()
            content?.showShortcutError("未收到按键", for: recording)
            refresh()
        }
    }

    private func beginRecording(_ action: StopwatchAction) {
        if recording == action {
            endRecording()
            return
        }
        content?.finishEditing(commit: true)
        if recording != nil { endRecording() }
        sawModifier = false
        content?.clearInputIssue(action)
        recording = action
        controller?.record(action)
        // Some global bindings consume the complete chord, including modifier events.
        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recording == action else { return }
                self.content?.showShortcutError("未收到按键", for: action)
                self.refresh()
            }
        }
        inputTimeout = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    private func endRecording() {
        guard let recording else { return }
        inputTimeout?.invalidate()
        inputTimeout = nil
        self.recording = nil
        controller?.record(nil)
        content?.clearInputIssue(recording)
        if isVisible { refresh() }
    }

    func receiveRegisteredShortcut(_ shortcut: ShortcutBinding) {
        guard let recording, window?.isKeyWindow == true else { return }
        finishRecording(recording, shortcut: shortcut)
    }

    private func finishRecording(_ action: StopwatchAction, shortcut: ShortcutBinding?) {
        inputTimeout?.invalidate()
        sawModifier = false
        content?.clearInputIssue(action)
        do {
            try controller?.replaceShortcut(action, with: shortcut)
            endRecording()
        } catch {
            content?.showShortcutError((error as? StopwatchHotKeyError)?.shortMessage ?? "未能保存", for: action)
        }
        refresh()
    }
}
