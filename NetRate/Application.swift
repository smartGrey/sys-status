import AppKit
import ServiceManagement
import SystemConfiguration

// Each waking session owns a fresh reader and baseline. Only the serial timer
// queue calls read(); the main actor owns the source and all AppKit objects.
private final class SamplingSession: @unchecked Sendable {
    private var reader = InterfaceReader()
    private var meter = TrafficMeter()
    func read() -> Speed? { meter.measure(reader.sample()) }
}

@main
@MainActor
final class Application: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let face = StatusFace()
    private var item: NSStatusItem!
    private var loginItem: NSMenuItem!
    private let service = SMAppService.mainApp
    private let queue = DispatchQueue(label: "netrate.sample", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var displayed: [RateText] = []
    private var displayedConnectivity: ConnectivityState?
    private var latestSpeed: Speed?
    private var networkStore: SCDynamicStore?
    private lazy var connectivity = ConnectivityMonitor { [weak self] in
        guard let self else { return }
        self.display(self.latestSpeed)
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = Application()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The menu bar on this Mac adds its own horizontal padding to the button.
        item = NSStatusBar.system.statusItem(withLength: face.width)
        item.autosaveName = "NetRate"
        item.button?.setAccessibilityLabel("网速")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        loginItem = menu.addItem(withTitle: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        let quit = menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        item.button?.menu = menu
        item.menu = menu
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(stopSampling), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(startSampling), name: NSWorkspace.didWakeNotification, object: nil)
        observeNetworkChanges()
        startSampling()
    }

    private func observeNetworkChanges() {
        // The delegate outlives this registration; callbacks are delivered on the main queue.
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "NetRate" as CFString, { _, _, info in
            guard let info else { return }
            let app = Unmanaged<Application>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard app.timer != nil else { return }
                app.connectivity.start()
                app.connectivity.tick()
            }
        }, &context) else { return }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6",
                    "State:/Network/Global/DNS", "State:/Network/Global/Proxies"]
        // A split tunnel can appear or disappear without changing the primary interface.
        let addresses = ["State:/Network/Interface/[^/]+/IPv[46]"]
        guard SCDynamicStoreSetNotificationKeys(store, keys as CFArray, addresses as CFArray),
              SCDynamicStoreSetDispatchQueue(store, .main) else { return }
        networkStore = store
    }

    @objc private func startSampling() {
        stopSampling()
        connectivity.start()
        let token = generation
        let session = SamplingSession()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(80))
        source.setEventHandler { @Sendable [weak self] in
            let speed = session.read()
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.connectivity.tick()
                self.display(speed)
            }
        }
        timer = source
        source.resume()
    }

    @objc private func stopSampling() {
        generation += 1
        timer?.cancel()
        timer = nil
        connectivity.stop()
        display(nil)
    }

    private func display(_ speed: Speed?) {
        latestSpeed = speed
        let up = RateText(speed?.upload), down = RateText(speed?.download)
        let state = connectivity.state
        guard displayed != [up, down] || displayedConnectivity != state else { return }
        displayed = [up, down]
        displayedConnectivity = state
        item.button?.image = face.image(upload: up, download: down, reachable: state == .reachable)
        item.button?.setAccessibilityValue("上行" + up.spoken + "，下行" + down.spoken + "，" + state.rawValue)
    }

    func menuWillOpen(_ menu: NSMenu) { refreshLogin() }

    private func refreshLogin() {
        let status = service.status
        loginItem.title = status == .requiresApproval ? "登录时启动（待批准）" : "登录时启动"
        loginItem.state = status == .enabled ? .on : status == .requiresApproval ? .mixed : .off
    }

    @objc private func toggleLogin() {
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try service.register()
            }
            refreshLogin()
        } catch {
            NSAlert(error: error).runModal()
            refreshLogin()
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        if let networkStore { SCDynamicStoreSetDispatchQueue(networkStore, nil) }
        stopSampling()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NSStatusBar.system.removeStatusItem(item)
    }
}
