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
    var hearingUsesShortcut: ((ShortcutBinding) -> Bool)?
    var interceptShortcut: ((ShortcutBinding) -> Bool)?
    var panelContent: PanelContent {
        PanelContent(show: { [weak self] anchor, screen, focus in
            guard let self, enabled else { return nil }
            return panel.show(under: anchor, on: screen, focus: focus)
        }, close: { [weak self] in self?.closePanel() },
        follow: { [weak self] anchor, screen in self?.panel.follow(anchor, on: screen) },
        isEditing: { [weak self] in self?.panel.isRecording == true })
    }

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
        else { OperationFeedback.menu.show(enabled ? "秒表入口已开启" : "秒表入口已关闭") }
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

    // Screen sleep and session lock do not call this method.
    func pauseForSystemSleep() {
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
    private func name(for id: UUID) -> String {
        guard let index = state.settings.entries.firstIndex(where: { $0.id == id }) else { return "秒表" }
        let name = state.settings.entries[index].name
        return name.isEmpty ? "第 \(index + 1) 个秒表" : name
    }

    func reset(_ id: UUID) {
        if change({ state, _ in state.reset(id) }) { panel.feedback.show(name(for: id) + "已重置") }
    }

    func setMode(_ mode: StopwatchMode) {
        let previous = state.settings.mode
        if change({ state, _ in state.setMode(mode) }), state.settings.mode != previous {
            panel.feedback.show(mode == .exclusive ? "计时模式已切换为互斥" : "计时模式已切换为并行")
        }
    }

    func toggle(_ id: UUID, feedback: OperationFeedback? = nil) {
        if change({ state, time in state.toggle(id, at: time) }),
           let reading = presentation.readings.first(where: { $0.id == id }) {
            (feedback ?? panel.feedback).show(name(for: id) + (reading.isRunning ? "已开始" : "已暂停"))
        }
    }

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
        case .toggle: toggle(state.settings.focus, feedback: .shortcut)
        case .switchFocus:
            if change({ state, time in state.advance(at: time) }) {
                OperationFeedback.shortcut.show("已切换到" + name(for: state.settings.focus))
            }
        }
    }

    @discardableResult
    private func change(_ update: (inout StopwatchState, TimeInterval) -> Void) -> Bool {
        let time = now()
        let previous = state
        update(&state, time)
        if state.needsSave(comparedTo: previous) {
            commit(at: time)
            return saveError == nil
        } else if state != previous {
            publish(at: time)
        }
        return false
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
