import AppKit

@MainActor
final class ApplicationCoordinator: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) lazy var statusEntry = StatusEntry()
    let stopwatch: StopwatchController
    let systemStatus: SystemStatusController
    private let hearing: HearingController
    private let networkPanel = NetworkPanel()
    private var panels: [StatusEntry.Region: StatusPanelShell] = [:]
    private var localPointer: Any?
    private var globalPointer: Any?
    private var samplingActive = false
    private let probes: ProbeController
    private let login = LoginItemMenu()
    private let systemSleep = SystemSleepMenu()
    private let volumeKeys: VolumeKeyMenu
    private lazy var toast = OperationToast()
    private let fileTools = FileToolsMenu()
    private var latestSpeed: Speed?
    private var isTerminating = false

    private lazy var sampler = NetworkSampler(sampled: { [weak self] speed in self?.display(speed) },
                                             networkChanged: { [weak self] in self?.probes.monitor.networkDidChange() })

    init(dataDirectory: URL = AppDataFile.directory, defaults: UserDefaults = .standard) {
        systemStatus = SystemStatusController(url: AppDataFile.systemStatus.url(in: dataDirectory))
        probes = ProbeController(store: ProbeConfigurationStore(url: AppDataFile.probes.url(in: dataDirectory), defaults: defaults))
        volumeKeys = VolumeKeyMenu(store: VolumeKeyStore(url: AppDataFile.volumeKeys.url(in: dataDirectory), defaults: defaults))
        stopwatch = StopwatchController(store: StopwatchStore(url: AppDataFile.stopwatch.url(in: dataDirectory)))
        hearing = HearingController(store: HearingStore(url: AppDataFile.hearing.url(in: dataDirectory)))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        OperationFeedback.deliver = { [weak self] message, screen in self?.toast.show(message, on: screen) }
        probes.load()
        probes.didUpdate = { [weak self] in
            guard let self else { return }
            self.display(self.latestSpeed)
        }
        let entry = statusEntry
        networkPanel.setTooltip = { [weak entry] in entry?.item.button?.toolTip = entry?.isSplit == true ? nil : $0 }
        networkPanel.readTimeline = { [weak probes] in probes?.monitor.timeline ?? ProbeTimeline() }
        networkPanel.probeNow = { [weak probes] in _ = probes?.monitor.probeNow() }
        probes.monitor.timingDidChange = { [weak self] in self?.networkPanel.refreshTiming() }
        connectPanels(to: entry)
        connectShortcuts()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        probes.addItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(systemSleep.item)
        menu.addItem(volumeKeys.item)
        menu.addItem(.separator())
        fileTools.add(to: menu)
        menu.addItem(.separator())
        menu.addItem(stopwatch.menuItem)
        menu.addItem(hearing.menuItem)
        menu.addItem(systemStatus.menuItem)
        menu.addItem(.separator())
        menu.addItem(login.item)
        let quit = menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        entry.installMenu(menu)
        stopwatch.restore()
        hearing.restore()
        systemStatus.restore()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemWillPowerOff), name: NSWorkspace.willPowerOffNotification, object: nil)
        center.addObserver(self, selector: #selector(startSampling), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(resetHoverPosition),
                           name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        volumeKeys.restore()
        sampler.observeNetworkChanges()
        startSampling()
    }

    private func connectPanels(to entry: StatusEntry) {
        let contents: [(StatusEntry.Region, PanelContent)] = [
            (.network, networkPanel.panelContent), (.stopwatch, stopwatch.panelContent),
            (.hearing, hearing.panelContent), (.system, systemStatus.panelContent)
        ]
        for (region, content) in contents {
            let shell = StatusPanelShell(item: entry.item, content: content,
                                         region: { [weak entry] in entry?.region(region, of: $0) ?? .zero },
                                         menuIsOpening: { [weak entry] in entry?.isOpeningMenu == true })
            panels[region] = shell
        }
        for (region, shell) in panels {
            shell.openedChanged = { [weak entry] in entry?.panelVisibilityChanged(region, visible: $0) }
            shell.containsEntry = { [weak entry] in entry?.containsButton(at: $0) == true }
            shell.allowsPreview = { [weak self] in self?.panels.values.contains(where: { $0.editing }) != true }
            shell.didPresentPreview = { [weak self] in
                for (other, panel) in self?.panels ?? [:] where other != region && panel.previewing { panel.dismissPreview() }
            }
        }
        entry.onLayoutChange = { [weak self, weak entry] in
            DispatchQueue.main.async { [weak self, weak entry] in
                guard let self, let entry, !isTerminating else { return }
                for (part, panel) in panels {
                    if let button = entry.item.button, entry.region(part, of: button.bounds) == nil { panel.hide() }
                    else { panel.trackAnchor { entry.region(part, on: $0) } }
                }
            }
        }
        entry.onClosePanel = { [weak self] part in self?.panels[part]?.hide() }
        entry.onTogglePanel = { [weak self] part, anchor, screen in
            for (other, shell) in self?.panels ?? [:] where other != part { shell.dismissPreview() }
            self?.panels[part]?.click(under: anchor, on: screen)
        }
        systemStatus.didUpdate = { [weak entry] in entry?.updateSystem($0) }
        hearing.didUpdate = { [weak entry] in entry?.updateHearing($0) }
        stopwatch.didUpdate = { [weak entry] in entry?.updateStopwatch($0) }
    }

    private func connectShortcuts() {
        hearing.shortcutConflict = { [weak stopwatch] key in
            stopwatch?.owner(of: key).map { key.stopwatchLabel + " 已用于秒表" + $0.title }
        }
        stopwatch.hearingUsesShortcut = { [weak hearing] key in
            hearing?.savedShortcut == key
        }
        stopwatch.interceptShortcut = { [weak hearing] key in
            guard let shortcuts = hearing?.model?.shortcuts, shortcuts.isRecording else { return false }
            shortcuts.accept(key)
            return true
        }
        hearing.interceptShortcut = { [weak stopwatch] key in
            stopwatch?.receiveWhileRecording(key) == true
        }
    }

    @objc func startSampling() {
        guard !isTerminating, !samplingActive else { return }
        samplingActive = true
        systemStatus.setAwake(true)
        probes.monitor.start()
        for shell in panels.values { shell.start() }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp]
        localPointer = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.handlePointer(event, global: false)
            return event
        }
        globalPointer = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handlePointer(event, global: true) }
        }
        sampler.start()
    }

    private func handlePointer(_ event: NSEvent, global: Bool) {
        if global, statusEntry.handlePanelStatusClick(event) { return }
        let pointer = NSEvent.mouseLocation
        for shell in panels.values { shell.handle(event, at: pointer) }
    }

    private func stopSampling(rememberPins: Bool = false) {
        samplingActive = false
        systemStatus.setAwake(false)
        for token in [localPointer, globalPointer].compactMap({ $0 }) { NSEvent.removeMonitor(token) }
        localPointer = nil
        globalPointer = nil
        sampler.stop()
        for shell in panels.values { shell.stop(rememberPins: rememberPins) }
        probes.monitor.stop()
        display(nil)
    }

    private func display(_ speed: Speed?) {
        guard !isTerminating else { return }
        latestSpeed = speed
        let state = probes.state
        statusEntry.updateNetwork(speed: speed, connectivity: state)
        networkPanel.update(state)
    }

    @objc func systemWillSleep() {
        guard samplingActive else { return }
        stopwatch.pauseForSystemSleep()
        stopSampling(rememberPins: true)
    }

    @objc private func systemWillPowerOff() { stopwatch.pauseForSystemSleep() }

    func applicationDidChangeScreenParameters(_ notification: Notification) { resetHoverPosition() }

    @objc private func resetHoverPosition() {
        panels.values.forEach { $0.resetPosition() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        probes.refreshSiteMenu(menu, rebuilding: true)
        panels.values.forEach { $0.setMenuOpen(true) }
        systemSleep.refresh()
        login.refresh()
    }

    func menuDidClose(_ menu: NSMenu) { panels.values.forEach { $0.setMenuOpen(false) } }

    @objc private func quitApp() {
        // Leave AppKit's menu selection stack before starting termination.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        OperationFeedback.deliver = nil
        toast.hide()
        statusEntry.removeForExit()
        // Runtime cleanup must not resize or repaint the removed status item.
        systemStatus.didUpdate = nil
        hearing.didUpdate = nil
        stopwatch.didUpdate = nil
        stopwatch.stopForExit()
        volumeKeys.stop()
        sampler.stopObservingNetworkChanges()
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
