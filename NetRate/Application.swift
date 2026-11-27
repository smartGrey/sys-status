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
    private lazy var statusEntry = StatusEntry()
    private let stopwatch = StopwatchController()
    private let hearing = HearingController()
    private var hover: StatusHover!
    private let configurationStore = ProbeConfigurationStore()
    private var configurationError: Error?
    private var configuration: ProbeConfiguration {
        configurationStore.configuration ?? ProbeConfiguration(probingEnabled: false, sites: ProbeSite.builtIns)
    }
    private var siteWindow: SiteSettingsWindow?
    private var probeItem: StatusMenuToggleItem!
    private var siteMenuLayout: [SiteMenuLayout] = []
    private let siteMenuStart = NSMenuItem.separator()
    private let systemSleep = SystemSleepMenu()
    private let volumeKeys = VolumeKeyMenu()
    private let fileTools = FileToolsMenu()
    private var loginItem: StatusMenuToggleItem!
    private let service = SMAppService.mainApp
    private let queue = DispatchQueue(label: "netrate.sample", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var latestSpeed: Speed?
    private var networkStore: SCDynamicStore?
    private var isTerminating = false
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
        let entry = statusEntry
        hover = StatusHover(item: entry.item, networkRegion: { [weak entry] frame in
            entry?.networkRegion(of: frame) ?? frame
        }, showsButtonTooltip: { [weak entry] in entry?.isSplit != true },
           menuIsOpening: { [weak entry] in entry?.isOpeningMenu == true })
        entry.onLayoutChange = { [weak self] in
            self?.hover.resetPosition()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stopwatch.trackPanelAnchor { self.statusEntry.region(.stopwatch, on: $0) }
                self.hearing.trackPanelAnchor { self.statusEntry.region(.hearing, on: $0) }
            }
        }
        entry.onClosePanel = { [weak self] part in
            switch part {
            case .hearing: self?.hearing.closePanel()
            case .stopwatch: self?.stopwatch.closePanel()
            case .network: break
            }
        }
        entry.onTogglePanel = { [weak self] part, anchor, screen in
            switch part {
            case .hearing: self?.hearing.togglePanel(under: anchor, on: screen)
            case .stopwatch: self?.stopwatch.togglePanel(under: anchor, on: screen)
            case .network: break
            }
        }
        stopwatch.statusEntryContains = { [weak entry] in entry?.containsButton(at: $0) == true }
        stopwatch.handlePanelStatusClick = { [weak entry] in entry?.handlePanelStatusClick($0) == true }
        hearing.containsButton = stopwatch.statusEntryContains
        hearing.handleStatusClick = stopwatch.handlePanelStatusClick
        stopwatch.panelVisibilityChanged = { [weak entry] in entry?.panelVisibilityChanged(.stopwatch, visible: $0) }
        hearing.visibilityChanged = { [weak entry] in entry?.panelVisibilityChanged(.hearing, visible: $0) }
        hearing.didUpdate = { [weak entry] in entry?.updateHearing($0) }
        hearing.shortcutConflict = { [weak stopwatch] binding in
            let key = StopwatchShortcut(keyCode: binding.keyCode, modifiers: binding.modifiers)
            return stopwatch?.owner(of: key).map { key.label + " 已用于秒表" + $0.title }
        }
        stopwatch.hearingUsesShortcut = { [weak hearing] key in
            hearing?.savedShortcut == ShortcutBinding(keyCode: key.keyCode, modifiers: key.modifiers)
        }
        stopwatch.interceptShortcut = { [weak hearing] key in
            guard let shortcuts = hearing?.model?.shortcuts, shortcuts.isRecording else { return false }
            shortcuts.accept(.init(keyCode: key.keyCode, modifiers: key.modifiers))
            return true
        }
        hearing.interceptShortcut = { [weak stopwatch] key in
            stopwatch?.receiveWhileRecording(.init(keyCode: key.keyCode, modifiers: key.modifiers)) == true
        }
        stopwatch.didUpdate = { [weak entry] in entry?.updateStopwatch($0) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        probeItem = StatusMenuToggleItem.make(title: "启用站点探测", action: #selector(toggleProbing))
        menu.addItem(probeItem)
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
        menu.addItem(stopwatch.menuItem)
        menu.addItem(hearing.menuItem)
        menu.addItem(.separator())
        loginItem = StatusMenuToggleItem.make(title: "登录时启动", action: #selector(toggleLogin))
        menu.addItem(loginItem)
        loginItem.target = self
        let quit = menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        refreshSiteMenu(menu, rebuilding: true)
        entry.installMenu(menu)
        stopwatch.restore()
        hearing.restore()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemWillPowerOff), name: NSWorkspace.willPowerOffNotification, object: nil)
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
        guard !isTerminating else { return }
        latestSpeed = speed
        var state = connectivity.state
        if configurationError != nil { state.configurationUnavailable = true }
        statusEntry.updateNetwork(speed: speed, connectivity: state)
        hover.update(state)
    }

    @objc private func systemWillSleep() {
        hearing.closePanel()
        stopwatch.pauseForSystemSleep()
        stopSampling()
    }

    @objc private func systemWillPowerOff() { stopwatch.pauseForSystemSleep() }

    func applicationDidChangeScreenParameters(_ notification: Notification) { resetHoverPosition() }

    @objc private func resetHoverPosition() {
        hover?.resetPosition()
        stopwatch.closePanel()
        hearing.closePanel()
    }

    private func refreshSiteMenu(_ menu: NSMenu, rebuilding: Bool = false) {
        let loaded = configuration
        let available = configurationError == nil
        probeItem.state = loaded.probingEnabled ? .on : .off
        probeItem.isEnabled = available
        probeItem.refreshRow()
        let layout = loaded.sites.map(SiteMenuLayout.init)
        let entries = menu.items.filter { $0.representedObject is String && $0.hasSubmenu }
        if rebuilding && layout != siteMenuLayout {
            entries.forEach { menu.removeItem($0) }
            let start = menu.index(of: siteMenuStart) + 1
            for (offset, site) in loaded.sites.enumerated() {
                let entry = SiteProbeCommand.menuItem(for: site, target: self, action: #selector(changeSite(_:)))
                entry.isEnabled = available
                menu.insertItem(entry, at: start + offset)
            }
            siteMenuLayout = layout
            return
        }
        let sites = Dictionary(uniqueKeysWithValues: zip(layout.map(\.id), loaded.sites.indices))
        for (entry, previous) in zip(entries, siteMenuLayout) {
            guard let index = sites[previous.id], layout[index] == previous else {
                entry.isEnabled = false
                entry.submenu?.items.forEach {
                    $0.isEnabled = false
                    ($0 as? StatusMenuToggleItem)?.refreshRow()
                }
                continue
            }
            SiteProbeCommand.refreshMenuItem(entry, for: loaded.sites[index], available: available)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshSiteMenu(menu, rebuilding: true)
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
        probeItem.afterClosingMenu { [self] in
            NSApp.activate()
            let alert = NSAlert(error: error)
            alert.informativeText = configurationStore.url.path(percentEncoded: false)
            alert.runModal()
        }
    }

    private func refreshLogin() {
        let status = service.status
        loginItem.title = status == .requiresApproval ? "登录时启动（待批准）" : "登录时启动"
        loginItem.state = status == .enabled ? .on : status == .requiresApproval ? .mixed : .off
        loginItem.refreshRow()
    }

    @objc private func toggleLogin() {
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: loginItem.afterClosingMenu { SMAppService.openSystemSettingsLoginItems() }
            default: try service.register()
            }
            refreshLogin()
        } catch {
            refreshLogin()
            loginItem.afterClosingMenu { NSAlert(error: error).runModal() }
        }
    }

    @objc private func quitApp() {
        // Leave AppKit's menu selection stack before starting termination.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        statusEntry.removeForExit()
        // Runtime cleanup must not resize or repaint the removed status item.
        hearing.didUpdate = nil
        stopwatch.didUpdate = nil
        stopwatch.stopForExit()
        volumeKeys.stop()
        if let networkStore { SCDynamicStoreSetDispatchQueue(networkStore, nil) }
        stopSampling()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        guard let stop = hearing.stop() else { return .terminateNow }
        Task.detached {
            await stop.value
            // AppKit waits for .terminateLater in the modal run-loop mode.
            RunLoop.main.perform(inModes: [.modalPanel, .default]) {
                MainActor.assumeIsolated { sender.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }
}
