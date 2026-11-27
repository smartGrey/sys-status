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
    private var face = StatusFace()
    private var item: NSStatusItem!
    private var hover: StatusHover!
    private let configurationStore = ProbeConfigurationStore()
    private var configurationError: Error?
    private var configuration: ProbeConfiguration {
        configurationStore.configuration ?? ProbeConfiguration(probingEnabled: false, sites: ProbeSite.builtIns)
    }
    private var siteWindow: SiteSettingsWindow?
    private var probeItem: NSMenuItem!
    private let siteMenuStart = NSMenuItem.separator()
    private let systemSleep = SystemSleepMenu()
    private let volumeKeys = VolumeKeyMenu()
    private let fileTools = FileToolsMenu()
    private var loginItem: NSMenuItem!
    private let service = SMAppService.mainApp
    private let queue = DispatchQueue(label: "netrate.sample", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var latestSpeed: Speed?
    private var networkStore: SCDynamicStore?
    private lazy var connectivity = ConnectivityMonitor(sites: configuration.sites, enabled: configuration.probingEnabled) { [weak self] in
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
        do {
            try configurationStore.loadOnLaunch()
        } catch {
            configurationError = error
        }
        // The menu bar on this Mac adds its own horizontal padding to the button.
        item = NSStatusBar.system.statusItem(withLength: face.width)
        item.autosaveName = "NetRate"
        item.button?.setAccessibilityLabel("网速")
        hover = StatusHover(item: item)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        probeItem = menu.addItem(withTitle: "启用站点探测", action: #selector(toggleProbing), keyEquivalent: "")
        probeItem.target = self
        probeItem.toolTip = HelpField.global.tip()
        probeItem.setAccessibilityHelp(HelpField.global.tip())
        let sites = menu.addItem(withTitle: "探测站点配置", action: #selector(configureSites), keyEquivalent: "")
        sites.target = self
        menu.addItem(siteMenuStart)
        menu.addItem(.separator())
        menu.addItem(systemSleep.item)
        menu.addItem(volumeKeys.item)
        menu.addItem(.separator())
        fileTools.add(to: menu)
        menu.addItem(.separator())
        loginItem = menu.addItem(withTitle: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        let quit = menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        refreshSiteMenu(menu)
        item.button?.menu = menu
        item.menu = menu
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(stopSampling), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(startSampling), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(resetHoverPosition),
                           name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        volumeKeys.restore()
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
                app.connectivity.networkDidChange()
            }
        }, &context) else { return }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6",
                    "State:/Network/Global/DNS", "State:/Network/Global/Proxies"]
        // A tunnel can keep the primary route, and a physical link can cycle without changing its IP.
        let interfaces = ["State:/Network/Interface/[^/]+/IPv[46]",
                          "State:/Network/Interface/en[0-9]+/Link"]
        guard SCDynamicStoreSetNotificationKeys(store, keys as CFArray, interfaces as CFArray),
              SCDynamicStoreSetDispatchQueue(store, .main) else { return }
        networkStore = store
    }

    @objc private func startSampling() {
        stopSampling()
        connectivity.start()
        hover.start()
        let token = generation
        let session = SamplingSession()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(80))
        source.setEventHandler { @Sendable [weak self] in
            let speed = session.read()
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
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
        hover.stop()
        connectivity.stop()
        display(nil)
    }

    private func display(_ speed: Speed?) {
        latestSpeed = speed
        var state = connectivity.state
        if configurationError != nil { state.configurationUnavailable = true }
        if let button = item.button {
            face.update(button, speed: speed, connectivity: state)
        }
        hover.update(state)
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) { hover?.resetPosition() }

    @objc private func resetHoverPosition() { hover.resetPosition() }

    private func refreshSiteMenu(_ menu: NSMenu) {
        for entry in menu.items where entry.representedObject is String && entry.hasSubmenu {
            menu.removeItem(entry)
        }
        let loaded = configuration
        probeItem.state = loaded.probingEnabled ? .on : .off
        probeItem.isEnabled = configurationError == nil
        let start = menu.index(of: siteMenuStart) + 1
        for (offset, site) in loaded.sites.enumerated() {
            let entry = SiteProbeCommand.menuItem(for: site, target: self, action: #selector(changeSite(_:)))
            entry.isEnabled = configurationError == nil
            menu.insertItem(entry, at: start + offset)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        hover.setMenuOpen(true)
        systemSleep.refresh()
        refreshLogin()
    }

    func menuDidClose(_ menu: NSMenu) { hover.setMenuOpen(false) }

    @objc private func configureSites() { _ = presentSiteSettings() }

    private func presentSiteSettings() -> SiteSettingsWindow {
        if let siteWindow {
            siteWindow.present()
            return siteWindow
        }
        let files = SiteSettingsWindow.ConfigurationFile(store: configurationStore, startupError: configurationError) { [weak self] in
            self?.applyConfiguration()
        }
        let window = SiteSettingsWindow(sites: configuration.sites, probingEnabled: configuration.probingEnabled,
                                        configurationFile: files, didClose: { [weak self] in
            self?.siteWindow = nil
        }) { [weak self] sites in
            guard let self else { return }
            var updated = self.configuration
            updated.sites = sites
            try self.saveConfiguration(updated)
        }
        siteWindow = window
        window.present()
        return window
    }

    @objc private func changeSite(_ sender: NSMenuItem) {
        var updated = configuration
        guard configurationError == nil, let command = sender.representedObject as? SiteProbeCommand,
              let index = updated.sites.firstIndex(where: { $0.id == command.siteID }) else { return }
        let previous = updated.sites[index]
        do {
            try command.apply(to: &updated.sites[index])
            guard updated.sites[index] != previous else { return }
            try saveConfiguration(updated)
        } catch {
            showConfigurationError(error)
        }
    }

    @objc private func toggleProbing() {
        guard configurationError == nil else { return }
        var updated = configuration
        updated.probingEnabled.toggle()
        do {
            try saveConfiguration(updated)
        } catch {
            showConfigurationError(error)
        }
    }

    private func saveConfiguration(_ updated: ProbeConfiguration) throws {
        try configurationStore.save(updated)
        applyConfiguration()
    }

    private func applyConfiguration() {
        configurationError = nil
        if let menu = probeItem.menu { refreshSiteMenu(menu) }
        connectivity.apply(configuration)
        siteWindow?.syncMenu(configuration)
    }

    private func showConfigurationError(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert(error: error)
        alert.informativeText = configurationStore.url.path(percentEncoded: false)
        alert.runModal()
    }

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
        volumeKeys.stop()
        if let networkStore { SCDynamicStoreSetDispatchQueue(networkStore, nil) }
        stopSampling()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NSStatusBar.system.removeStatusItem(item)
    }
}
