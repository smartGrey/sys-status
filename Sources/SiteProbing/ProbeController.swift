import AppKit

@MainActor
final class ProbeController: NSObject {
    private let configurationStore: ProbeConfigurationStore
    private var configurationError: Error?
    private var configuration: ProbeConfiguration {
        configurationStore.configuration ?? ProbeConfiguration(probingEnabled: false, sites: ProbeSite.builtIns)
    }
    private var siteWindow: SiteSettingsWindow?
    private var activeSite: (layout: SiteMenuLayout, item: NSMenuItem)?
    private lazy var moduleSwitch: StatusMenuToggleItem = {
        let item = StatusMenuToggleItem.make(title: StatusModule.network.title, action: #selector(toggleProbing))
        item.target = self
        item.setAccessibilityHelp(HelpField.global.tip())
        return item
    }()
    var menuItem: NSMenuItem { moduleSwitch }

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
        refreshMenu()
    }

    private func refreshMenu() {
        moduleSwitch.state = configurationError == nil && configuration.probingEnabled ? .on : .off
        moduleSwitch.toolTip = configurationError == nil ? HelpField.global.tip() : "打开探测配置以修复配置文件"
        moduleSwitch.refreshRow()
        guard let activeSite else { return }
        guard let site = configuration.sites.first(where: { $0.id == activeSite.layout.id }),
              SiteMenuLayout(site) == activeSite.layout else {
            activeSite.item.submenu?.cancelTrackingWithoutAnimation()
            return
        }
        SiteProbeCommand.refreshMenuItem(activeSite.item, for: site, available: configurationError == nil)
    }

    func withSiteMenu(id: String, present: (NSMenu) -> Void) {
        guard activeSite == nil, configurationError == nil,
              let site = configuration.sites.first(where: { $0.id == id }) else { return }
        let item = SiteProbeCommand.menuItem(for: site, target: self, action: #selector(changeSite(_:)))
        guard let menu = item.submenu else { return }
        activeSite = (SiteMenuLayout(site), item)
        defer { activeSite = nil }
        present(menu)
    }

    func configureSites() { _ = presentSiteSettings() }

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
            let site = updated.sites[index]
            let message: String
            switch command.operation {
            case .toggleSite: message = site.name + (site.enabled ? "探测已启用" : "探测已暂停")
            case .disable(let lane): message = site.name + " · " + lane.title + "探测已停止"
            case .select(let lane, _):
                let selected = site[strength: lane].selected(in: lane)
                message = site.name + " · " + lane.title + "已切换为" + (selected?.name ?? "")
            }
            OperationFeedback.menu.show(message)
        } catch {
            showConfigurationError(error, from: sender as? StatusMenuToggleItem)
        }
    }

    @objc private func toggleProbing() {
        guard configurationError == nil else {
            moduleSwitch.afterClosingMenu { [weak self] in self?.configureSites() }
            return
        }
        var updated = configuration
        updated.probingEnabled.toggle()
        do {
            try saveConfiguration(updated)
            OperationFeedback.menu.show(updated.probingEnabled ? "网络状况已开启" : "网络状况已关闭")
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
        refreshMenu()
        monitor.apply(configuration)
        siteWindow?.syncMenu(configuration)
    }

    private func showConfigurationError(_ error: Error, from sender: StatusMenuToggleItem? = nil) {
        (sender ?? moduleSwitch).afterClosingMenu { [self] in
            NSApp.activate()
            let alert = NSAlert(error: error)
            alert.informativeText = configurationStore.url.path(percentEncoded: false)
            alert.runModal()
        }
    }

}
