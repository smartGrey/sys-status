import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class VolumeKeyMenu: NSObject {
    private static let title = "音量键微调"
    private static let preference = "volumeKeyAdjustment"
    let item = NSMenuItem(title: VolumeKeyMenu.title, action: nil, keyEquivalent: "")
    private let defaults: UserDefaults
    private let trusted: () -> Bool
    private let prompt: () -> Void
    private let makeSession: () -> VolumeKeyListening
    private let workspace: NotificationCenter
    private var session: VolumeKeyListening?
    private var healthTimer: Timer?
    private var startupTimeout: DispatchWorkItem?

    init(defaults: UserDefaults = .standard,
         trusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         prompt: @escaping () -> Void = {
             let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
             _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
         },
         makeSession: @escaping () -> VolumeKeyListening = { VolumeKeySession() },
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.defaults = defaults
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
        guard let saved = defaults.string(forKey: Self.preference) else { return }
        if saved == "enabled" {
            enable(interactive: false)
        } else if let failure = VolumeKeyFailure(rawValue: saved) {
            display(failure: failure)
        }
    }

    @objc func toggle() {
        guard item.isEnabled else { return }
        if session != nil {
            stop()
            defaults.removeObject(forKey: Self.preference)
            display()
        } else {
            enable(interactive: true)
        }
    }

    private func enable(interactive: Bool) {
        guard session == nil else { return }
        guard trusted() else {
            fail(.permission)
            if interactive { prompt() }
            return
        }
        let current = makeSession()
        session = current
        item.title = Self.title + "（正在开启…）"
        item.isEnabled = false
        let timeout = DispatchWorkItem { [weak self, weak current] in
            guard let self, let current, self.session === current else { return }
            self.fail(.unavailable)
        }
        startupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        current.start { [weak self, weak current] event in
            guard let self, let current, self.session === current else { return }
            switch event {
            case .ready:
                guard self.checkHealth() else { return }
                self.startupTimeout?.cancel()
                self.startupTimeout = nil
                self.beginMonitoring()
                self.defaults.set("enabled", forKey: Self.preference)
                self.display()
            case .disabled:
                _ = self.checkHealth()
            case .unavailable:
                self.fail(self.trusted() ? .unavailable : .permission)
            }
        }
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
        defaults.set(reason.rawValue, forKey: Self.preference)
        display(failure: reason)
    }

    // Shutdown preserves the preference for the next launch.
    func stop() {
        let current = session
        session = nil
        current?.stop()
        startupTimeout?.cancel()
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
    }
}
