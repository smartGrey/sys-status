import AppKit

@MainActor
final class HearingController: NSObject {
    private let store: HearingStore
    private var loadError: Error?
    private var stopping: Task<Void, Never>?
    private var pendingActivation: UUID?
    private(set) var model: HearingModel?
    private var panel: HearingPanelController?
    var savedShortcut: ShortcutBinding? { store.settings.shortcut }
    var didUpdate: ((HearingPresentation?) -> Void)?
    var visibilityChanged: ((Bool) -> Void)?
    var containsButton: ((NSPoint) -> Bool)?
    var handleStatusClick: ((NSEvent) -> Bool)?
    var shortcutConflict: (ShortcutBinding) -> String? = { _ in nil }
    var interceptShortcut: ((ShortcutBinding) -> Bool)?

    lazy var menuItem: StatusMenuToggleItem = {
        let item = StatusMenuToggleItem.make(title: "监听环境音", action: #selector(toggle))
        item.target = self
        return item
    }()

    init(store: HearingStore = HearingStore()) { self.store = store }

    func restore() {
        do {
            try store.load()
            loadError = nil
            if store.settings.enabled { activate(feedback: nil) }
        } catch { loadError = error }
    }

    @objc private func toggle() {
        do { try setEnabled(menuItem.state != .on) }
        catch { menuItem.afterClosingMenu { NSAlert(error: error).runModal() } }
    }

    func setEnabled(_ enabled: Bool) throws {
        if loadError != nil { try store.load(); loadError = nil }
        // Stop immediately even if the disk can no longer save changes.
        if !enabled { stop() }
        try store.update { $0.enabled = enabled }
        if enabled { activate(feedback: .menu) }
        else { OperationFeedback.menu.show("监听环境音入口已关闭") }
    }

    private func activate(feedback: OperationFeedback?) {
        guard model == nil, pendingActivation == nil else { return }
        if let stopping {
            let token = UUID()
            pendingActivation = token
            menuItem.title = "监听环境音（正在开启…）"
            menuItem.isEnabled = false
            menuItem.refreshRow()
            Task.detached { [weak self] in
                await stopping.value
                RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.pendingActivation == token else { return }
                        self.stopping = nil
                        self.pendingActivation = nil
                        self.startModel(feedback: feedback)
                    }
                }
            }
        } else {
            startModel(feedback: feedback)
        }
    }

    private func startModel(feedback: OperationFeedback?) {
        let shortcuts = HearingShortcutController(store: store, conflict: shortcutConflict)
        let model = HearingModel(store: store, shortcuts: shortcuts)
        self.model = model
        model.panelFeedback = { [weak self] in OperationFeedback(screen: self?.panel?.operationScreen) }
        shortcuts.interceptToggle = { [weak self] binding in self?.interceptShortcut?(binding) == true }
        model.onStatusChange = { [weak self, weak model] in
            guard let self, let model, self.model === model else { return }
            self.didUpdate?(model.statusPresentation)
        }
        model.start()
        menuItem.title = "监听环境音"
        menuItem.state = .on
        menuItem.isEnabled = true
        menuItem.refreshRow()
        didUpdate?(model.statusPresentation)
        feedback?.show("监听环境音入口已开启")
    }

    func togglePanel(under anchor: NSRect, on screen: NSScreen) {
        guard let model else { return }
        if panel?.isVisible == true { closePanel(); return }
        let panel = self.panel ?? HearingPanelController(model: model)
        self.panel = panel
        panel.onVisibilityChange = visibilityChanged
        panel.containsButton = containsButton
        panel.handleStatusClick = handleStatusClick
        model.refresh()
        panel.show(under: anchor, on: screen)
    }

    func closePanel() { panel?.close() }
    func trackPanelAnchor(_ resolve: (NSScreen) -> NSRect?) { panel?.trackAnchor(resolve) }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        pendingActivation = nil
        if let model { stopping = model.shutdown() }
        closePanel()
        panel = nil
        model = nil
        menuItem.title = "监听环境音"
        menuItem.state = .off
        menuItem.isEnabled = true
        menuItem.refreshRow()
        didUpdate?(nil)
        return stopping
    }
}
