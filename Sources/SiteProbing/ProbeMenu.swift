import AppKit

struct SiteMenuLayout: Equatable {
    let id: String
    let name: String
    let lanes: [ProbeLane]
    let personalStrengths: [[ProbeStrength]]

    init(_ site: ProbeSite) {
        id = site.id
        name = site.name
        lanes = site.lanes
        personalStrengths = lanes.map { site[strength: $0].personal }
    }
}

struct SiteProbeCommand {
    enum Operation { case toggleSite, disable(ProbeLane), select(ProbeLane, String) }
    let siteID: String
    let operation: Operation

    func apply(to site: inout ProbeSite) throws {
        switch operation {
        case .toggleSite:
            guard site.enabled || site.hasEnabledLane else { throw SiteConfigurationError.noLane }
            site.enabled.toggle()
        case .disable(let lane):
            guard site.endpoint.type == .https else { throw SiteConfigurationError.invalidTCPLane }
            guard site[strength: lane].enabled else { return }
            let other: ProbeLane = lane == .daily ? .fresh : .daily
            guard !site.enabled || site[strength: other].enabled else { throw SiteConfigurationError.noLane }
            site[strength: lane].enabled = false
        case let .select(lane, id):
            guard site.lanes.contains(lane) else { throw SiteConfigurationError.invalidTCPLane }
            var selection = site[strength: lane]
            selection.selectedID = id
            try selection.validate(for: lane)
            selection.enabled = true
            site[strength: lane] = selection
        }
    }

    @MainActor static func menuItem(for site: ProbeSite, target: AnyObject, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: site.name, action: nil, keyEquivalent: "")
        parent.representedObject = site.id
        let menu = NSMenu(title: site.name)
        menu.autoenablesItems = false
        parent.submenu = menu

        func command(_ title: String, _ operation: Operation) -> NSMenuItem {
            let item = StatusMenuToggleItem.make(title: title, action: action)
            item.target = target
            item.representedObject = SiteProbeCommand(siteID: site.id, operation: operation)
            menu.addItem(item)
            return item
        }
        _ = command("启用此站点", .toggleSite)
        menu.addItem(.sectionHeader(title: "请先为一种探测方式选择强度"))
        for kind in site.lanes {
            let selection = site[strength: kind]
            menu.addItem(.separator())
            let heading = kind.title + "探测强度 · 预计 8 小时"
            menu.addItem(.sectionHeader(title: heading))
            for strength in kind.strengths + selection.personal {
                let values = strength.values
                let budget = ProbeBudget(lane: kind, interval: values.interval, type: site.endpoint.type)
                let item = command("\(strength.name) · \(values.interval) 秒　\(budget.display)",
                                   .select(kind, strength.id))
                item.toolTip = "\(values.warning) 秒提醒，\(values.cutoff) 秒截止，最多 \(values.capacity) 条在途。"
            }
            guard site.endpoint.type == .https else { continue }
            let stop = command("停止探测", .disable(kind))
            stop.setAccessibilityLabel("停止本站的" + kind.title + "探测")
        }
        refreshMenuItem(parent, for: site, available: true)
        return parent
    }

    @MainActor static func refreshMenuItem(_ parent: NSMenuItem, for site: ProbeSite, available: Bool) {
        parent.state = site.enabled ? .on : .off
        parent.isEnabled = available
        guard let menu = parent.submenu else { return }
        let canToggle = site.enabled || site.hasEnabledLane
        menu.item(at: 1)?.isHidden = canToggle // The hint follows the site switch.
        for item in menu.items {
            guard let command = item.representedObject as? Self else { continue }
            switch command.operation {
            case .toggleSite:
                item.state = parent.state
                item.isEnabled = available && canToggle
            case let .select(lane, id):
                let selection = site[strength: lane]
                item.state = selection.enabled && id == selection.selectedID ? .on : .off
                item.isEnabled = available
            case .disable(let lane):
                let selection = site[strength: lane]
                let other: ProbeLane = lane == .daily ? .fresh : .daily
                let canStop = !selection.enabled || !site.enabled || site[strength: other].enabled
                item.state = selection.enabled ? .off : .on
                item.isEnabled = available && canStop
                let description = "停止本站的" + lane.title + "探测"
                item.toolTip = description + (canStop ? "。" : "。暂停整站请取消勾选「启用此站点」。")
                item.setAccessibilityHelp(item.toolTip)
            }
            (item as? StatusMenuToggleItem)?.refreshRow()
        }
    }
}
