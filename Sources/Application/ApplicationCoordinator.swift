import AppKit

@MainActor
final class ApplicationCoordinator: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) lazy var statusEntry = StatusEntry()
    let stopwatch: StopwatchController
    private let hearing: HearingController
    private var hover: StatusHover!
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
        hover = StatusHover(item: entry.item, networkRegion: { [weak entry] frame in
            entry?.networkRegion(of: frame) ?? frame
        }, showsButtonTooltip: { [weak entry] in entry?.isSplit != true },
           menuIsOpening: { [weak entry] in entry?.isOpeningMenu == true })
        hover.readTimeline = { [weak probes] in probes?.monitor.timeline ?? ProbeTimeline() }
        hover.probeNow = { [weak probes] in _ = probes?.monitor.probeNow() }
        probes.monitor.timingDidChange = { [weak self] in self?.hover.refreshTiming() }
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
        menu.addItem(.separator())
        menu.addItem(login.item)
        let quit = menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
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
        sampler.observeNetworkChanges()
        startSampling()
    }

    private func connectPanels(to entry: StatusEntry) {
        entry.onLayoutChange = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTerminating else { return }
                self.hover.trackAnchor { self.statusEntry.region(.network, on: $0) }
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
        guard !isTerminating else { return }
        stopSampling()
        probes.monitor.start()
        hover.start()
        sampler.start()
    }

    @objc private func stopSampling() {
        sampler.stop()
        hover.stop()
        probes.monitor.stop()
        display(nil)
    }

    private func display(_ speed: Speed?) {
        guard !isTerminating else { return }
        latestSpeed = speed
        let state = probes.state
        statusEntry.updateNetwork(speed: speed, connectivity: state)
        hover.update(state)
    }

    @objc func systemWillSleep() {
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

    func menuWillOpen(_ menu: NSMenu) {
        probes.refreshSiteMenu(menu, rebuilding: true)
        hover.setMenuOpen(true)
        systemSleep.refresh()
        login.refresh()
    }

    func menuDidClose(_ menu: NSMenu) { hover.setMenuOpen(false) }

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
