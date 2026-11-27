import AppKit
import OSLog

@MainActor
final class StopwatchController {
    private var state = StopwatchState()
    private let store: StopwatchStore
    private let now: () -> TimeInterval
    private let hotKeys = StopwatchHotKeys()
    private let log = Logger(subsystem: "com.smartgrey.netrate", category: "StopWatch")
    private var displayTimer: Timer?
    private var nextCheckpoint: TimeInterval?
    private var needsSave = false
    private var loadError: Error?
    private var saveError: Error?
    private var shortcutIssues: [StopwatchAction: String] = [:]
    private var recording: StopwatchAction?
    private lazy var panel = StopwatchPanel(controller: self)

    private(set) var presentation: StopwatchPresentation
    var didUpdate: ((StopwatchPresentation?) -> Void)?
    var enabled: Bool { state.settings.enabled }
    var panelVisibilityChanged: ((Bool) -> Void)?
    var handlePanelStatusClick: ((NSEvent) -> Bool)?
    var hearingUsesShortcut: ((ShortcutBinding) -> Bool)?
    var interceptShortcut: ((ShortcutBinding) -> Bool)?
    var statusEntryContains: ((NSPoint) -> Bool)?

    func isStatusEntry(at point: NSPoint) -> Bool { statusEntryContains?(point) == true }

    lazy var menuItem: StatusMenuToggleItem = {
        let item = StatusMenuToggleItem.make(title: "StopWatch", action: #selector(StopwatchMenuTarget.toggle(_:)))
        item.target = menuTarget
        return item
    }()
    private lazy var menuTarget = StopwatchMenuTarget(controller: self)

    init(store: StopwatchStore = StopwatchStore(),
         now: @escaping () -> TimeInterval = { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }) {
        self.store = store
        self.now = now
        presentation = state.presentation(at: now())
    }

    func restore() {
        do {
            state = StopwatchState(settings: try store.load())
        } catch {
            loadError = error
            log.error("Cannot read StopWatch data: \(String(describing: error), privacy: .public)")
        }
        hotKeys.onPress = { [weak self] action, shortcut in self?.handleHotKey(action, shortcut: shortcut) }
        if enabled { registerSavedBindings() }
        publish(at: now())
    }

    func setEnabled(_ enabled: Bool) {
        if let loadError {
            showError("无法读取 StopWatch 数据", error: loadError)
            return
        }
        guard enabled != self.enabled else { return }
        if !enabled {
            closePanel()
            hotKeys.stop()
            shortcutIssues.removeAll()
        }
        let time = now()
        state.setEnabled(enabled, at: time)
        if enabled { registerSavedBindings() }
        commit(at: time)
        if let saveError { showError("无法保存 StopWatch 设置", error: saveError) }
    }

    func togglePanel(under anchor: NSRect, on screen: NSScreen) {
        guard enabled else { return }
        if panel.isVisible {
            closePanel()
        } else {
            panel.show(under: anchor, on: screen)
        }
    }

    func closePanel() { panel.dismissIfVisible() }

    func trackPanelAnchor(_ resolve: (NSScreen) -> NSRect?) { panel.trackAnchor(resolve) }

    // Screen sleep and session lock do not call this method.
    func pauseForSystemSleep() {
        closePanel()
        hotKeys.clearHeldKeys()
        settle()
    }

    func stopForExit() {
        closePanel()
        settle()
        hotKeys.stop()
    }

    private func settle() {
        let time = now()
        if state.hasRunningEntries {
            state.pauseAll(at: time)
            commit(at: time)
        } else if needsSave {
            save(at: time)
            publish(at: time)
        }
    }

    func select(_ id: UUID) { change { state, _ in state.select(id) } }
    func rename(_ id: UUID, to name: String) { change { state, _ in state.rename(id, to: name) } }
    func remove(_ id: UUID) { change { state, _ in state.remove(id) } }
    func reset(_ id: UUID) { change { state, _ in state.reset(id) } }
    func setMode(_ mode: StopwatchMode) { change { state, _ in state.setMode(mode) } }
    func toggle(_ id: UUID) { change { state, time in state.toggle(id, at: time) } }

    func add() -> UUID? {
        guard let id = state.add() else { return nil }
        commit(at: now())
        return id
    }

    func owner(of key: ShortcutBinding) -> StopwatchAction? {
        StopwatchAction.allCases.first { state.settings.shortcuts[$0] == key }
    }

    func receiveWhileRecording(_ key: ShortcutBinding) -> Bool {
        guard recording != nil else { return false }
        panel.receiveRegisteredShortcut(key)
        return true
    }

    func record(_ action: StopwatchAction?) { recording = action }

    func replaceShortcut(_ action: StopwatchAction, with shortcut: ShortcutBinding?) throws {
        guard enabled else { return }
        if let shortcut {
            guard shortcut.isValidForStopwatch else { throw StopwatchHotKeyError.invalid }
            if hearingUsesShortcut?(shortcut) == true { throw StopwatchHotKeyError.hearing }
            guard !StopwatchAction.allCases.contains(where: { $0 != action && state.settings.shortcuts[$0] == shortcut })
            else { throw StopwatchHotKeyError.duplicate }
        }
        let time = now()
        var candidate = state.snapshot(at: time)
        candidate.shortcuts[action] = shortcut
        try hotKeys.replace(action, with: shortcut) { try store.save(candidate) }
        state.setShortcut(shortcut, for: action)
        shortcutIssues[action] = nil
        needsSave = false
        saveError = nil
        scheduleCheckpoint(after: time)
        publish(at: time)
    }

    private func registerSavedBindings() {
        for action in StopwatchAction.allCases {
            guard let shortcut = state.settings.shortcuts[action] else { continue }
            do {
                try hotKeys.replace(action, with: shortcut) {}
                shortcutIssues[action] = nil
            } catch {
                shortcutIssues[action] = (error as? StopwatchHotKeyError)?.shortMessage ?? "注册失败"
            }
        }
    }

    private func handleHotKey(_ action: StopwatchAction, shortcut: ShortcutBinding) {
        guard enabled else { return }
        if receiveWhileRecording(shortcut) || interceptShortcut?(shortcut) == true { return }
        switch action {
        case .toggle: toggle(state.settings.focus)
        case .switchFocus:
            change { state, time in state.advance(at: time) }
        }
    }

    private func change(_ update: (inout StopwatchState, TimeInterval) -> Void) {
        let time = now()
        let previous = state
        update(&state, time)
        if state.needsSave(comparedTo: previous) {
            commit(at: time)
        } else if state != previous {
            publish(at: time)
        }
    }

    private func commit(at time: TimeInterval) {
        save(at: time)
        updateTimer()
        publish(at: time)
    }

    private func scheduleCheckpoint(after time: TimeInterval) {
        nextCheckpoint = state.hasRunningEntries ? time + 5 : nil
    }

    private func save(at time: TimeInterval) {
        do {
            try store.save(state.snapshot(at: time))
            needsSave = false
            saveError = nil
        } catch {
            needsSave = true
            saveError = error
            log.error("Cannot save StopWatch data: \(String(describing: error), privacy: .public)")
        }
        scheduleCheckpoint(after: time)
    }

    private func updateTimer() {
        guard state.hasRunningEntries else {
            displayTimer?.invalidate()
            displayTimer = nil
            return
        }
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    func tick() {
        let time = now()
        let current = state.presentation(at: time)
        if let nextCheckpoint, time >= nextCheckpoint {
            save(at: time)
        } else if current == presentation {
            return
        }
        publish(at: time, current: current)
    }

    private func publish(at time: TimeInterval, current: StopwatchPresentation? = nil) {
        presentation = current ?? state.presentation(at: time)
        menuItem.state = enabled ? .on : .off
        menuItem.toolTip = if loadError != nil {
            "无法读取 StopWatch 数据"
        } else if saveError != nil {
            "秒表数据尚未保存"
        } else { nil }
        menuItem.refreshRow()
        panel.update(presentation, shortcutIssues: shortcutIssues, hasSaveError: saveError != nil)
        didUpdate?(enabled ? presentation : nil)
    }

    private func showError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(error.localizedDescription)\n\(store.url.path(percentEncoded: false))"
        menuItem.afterClosingMenu {
            NSApp.activate()
            alert.runModal()
        }
    }
}

@MainActor
private final class StopwatchMenuTarget: NSObject {
    weak var controller: StopwatchController?

    init(controller: StopwatchController) { self.controller = controller }

    @objc func toggle(_ sender: NSMenuItem) {
        guard let controller else { return }
        controller.setEnabled(!controller.enabled)
    }
}
