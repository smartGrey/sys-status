import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class VolumeKeyMenu: NSObject {
    private static let title = "音量键微调"
    let item = StatusMenuToggleItem.make(title: VolumeKeyMenu.title, action: nil)
    private let store: VolumeKeyStore
    private var storageError: Error?
    private let trusted: () -> Bool
    private let prompt: () -> Void
    private let makeSession: () -> VolumeKeyListening
    private let workspace: NotificationCenter
    private var session: VolumeKeyListening?
    private var healthTimer: Timer?
    private var startupTimeout: Timer?

    init(store: VolumeKeyStore = VolumeKeyStore(),
         trusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         prompt: @escaping () -> Void = {
             let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
             _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
         },
         makeSession: @escaping () -> VolumeKeyListening = { VolumeKeySession() },
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.store = store
        self.trusted = trusted
        self.prompt = prompt
        self.makeSession = makeSession
        self.workspace = workspace
        super.init()
        item.target = self
        item.action = #selector(toggle)
        display()
    }

    func restore() {
        do {
            let saved = try store.load()
            storageError = nil
            if saved.enabled { enable(interactive: false) }
            else { display(failure: saved.failure) }
        } catch {
            storageError = error
            display()
        }
    }

    @objc func toggle() {
        guard item.isEnabled else { return }
        if storageError != nil {
            do { _ = try store.load(); storageError = nil }
            catch {
                item.afterClosingMenu { NSAlert(error: error).runModal() }
                return
            }
        }
        if session != nil {
            stop()
            persist(VolumeKeySettings())
            display()
            if storageError == nil { OperationFeedback.menu.show("音量键微调已关闭") }
        } else {
            enable(interactive: true)
        }
    }

    private func enable(interactive: Bool) {
        guard session == nil else { return }
        guard trusted() else {
            fail(.permission)
            if interactive { item.afterClosingMenu { [self] in prompt() } }
            return
        }
        let feedback = interactive ? OperationFeedback.menu : nil
        let current = makeSession()
        session = current
        item.title = Self.title + "（正在开启…）"
        item.isEnabled = false
        item.refreshRow()
        let timeout = Timer(timeInterval: 5, target: self, selector: #selector(startupDidTimeOut(_:)),
                            userInfo: nil, repeats: false)
        startupTimeout = timeout
        RunLoop.main.add(timeout, forMode: .common)
        current.start { [weak self, weak current] event in
            guard let self, let current, self.session === current else { return }
            switch event {
            case .ready:
                guard self.startupTimeout != nil, self.checkHealth() else { return }
                self.startupTimeout?.invalidate()
                self.startupTimeout = nil
                self.beginMonitoring()
                self.persist(VolumeKeySettings(enabled: true))
                self.display()
                if self.storageError == nil { feedback?.show("音量键微调已开启") }
            case .disabled:
                _ = self.checkHealth()
            case .unavailable:
                self.fail(self.trusted() ? .unavailable : .permission)
            }
        }
    }

    @objc private func startupDidTimeOut(_ timer: Timer) {
        guard startupTimeout === timer else { return }
        fail(.unavailable)
    }

    private func beginMonitoring() {
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(refreshHealth), name: name, object: nil)
        }
        let timer = Timer(timeInterval: 5, target: self, selector: #selector(refreshHealth), userInfo: nil, repeats: true)
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    @objc private func refreshHealth() { _ = checkHealth() }

    private func checkHealth() -> Bool {
        guard let session else { return false }
        if !trusted() { fail(.permission); return false }
        if let failure = session.checkHealth() { fail(failure); return false }
        return true
    }

    private func fail(_ reason: VolumeKeyFailure) {
        stop()
        persist(VolumeKeySettings(failure: reason))
        display(failure: reason)
    }

    private func persist(_ settings: VolumeKeySettings) {
        do { try store.save(settings); storageError = nil }
        catch {
            stop()
            storageError = error
        }
    }

    // Shutdown preserves the preference for the next launch.
    func stop() {
        let current = session
        session = nil
        current?.stop()
        startupTimeout?.invalidate()
        startupTimeout = nil
        healthTimer?.invalidate()
        healthTimer = nil
        workspace.removeObserver(self)
    }

    private func display(failure: VolumeKeyFailure? = nil) {
        item.title = Self.title + (failure == nil ? "" : "（需重新启用）")
        item.state = session == nil ? .off : .on
        item.isEnabled = true
        item.toolTip = failure?.help ?? "让音量加减键以更小的步长调节音量。"
        item.setAccessibilityHelp(item.toolTip)
        if let storageError {
            item.title = Self.title + "（配置不可用）"
            item.toolTip = storageError.localizedDescription
            item.setAccessibilityHelp(item.toolTip)
        }
        item.refreshRow()
    }
}
