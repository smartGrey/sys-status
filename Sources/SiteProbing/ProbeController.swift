import AppKit

@MainActor
final class ProbeController: NSObject {
    private let configurationStore: ProbeConfigurationStore
    private var configurationError: Error?
    private var configuration: ProbeConfiguration {
        configurationStore.configuration ?? ProbeConfiguration(probingEnabled: false, sites: ProbeSite.builtIns)
    }
    private var siteWindow: SiteSettingsWindow?
    private var probeItem: StatusMenuToggleItem!
    private var siteMenuLayout: [SiteMenuLayout] = []
    private let siteMenuStart = NSMenuItem.separator()

    var didUpdate: (() -> Void)?
    private(set) lazy var monitor = ConnectivityMonitor(sites: configuration.sites, enabled: configuration.probingEnabled) { [weak self] in
        self?.didUpdate?()
    }

    init(store: ProbeConfigurationStore = ProbeConfigurationStore()) {
        configurationStore = store
    }

    var state: ConnectivityState {
        var state = monitor.state
        if configurationError != nil { state.configurationUnavailable = true }
        return state
    }

    func load() {
        do {
            try configurationStore.loadOnLaunch()
        } catch {
            configurationError = error
        }
    }

    func addItems(to menu: NSMenu) {
        probeItem = StatusMenuToggleItem.make(title: "启用站点探测", action: #selector(toggleProbing))
        menu.addItem(probeItem)
        probeItem.target = self
        probeItem.toolTip = HelpField.global.tip()
        probeItem.setAccessibilityHelp(HelpField.global.tip())
        let sites = menu.addItem(withTitle: "探测站点配置", action: #selector(configureSites), keyEquivalent: "")
        sites.target = self
        menu.addItem(siteMenuStart)
        refreshSiteMenu(menu, rebuilding: true)
    }

    func refreshSiteMenu(_ menu: NSMenu, rebuilding: Bool = false) {
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
        monitor.apply(configuration)
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

}
