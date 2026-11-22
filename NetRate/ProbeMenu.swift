import AppKit

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
            guard site[strength: lane].enabled else { return }
            let other: ProbeLane = lane == .daily ? .fresh : .daily
            guard !site.enabled || site[strength: other].enabled else { throw SiteConfigurationError.noLane }
            site[strength: lane].enabled = false
        case let .select(lane, id):
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
        parent.state = site.enabled ? .on : .off
        let menu = NSMenu(title: site.name)
        menu.autoenablesItems = false
        parent.submenu = menu

        func command(_ title: String, _ operation: Operation) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = SiteProbeCommand(siteID: site.id, operation: operation)
            return item
        }
        let toggle = command("启用此站点", .toggleSite)
        toggle.state = parent.state
        toggle.isEnabled = site.enabled || site.hasEnabledLane
        if !toggle.isEnabled { menu.addItem(.sectionHeader(title: "请先为一种探测方式选择强度")) }
        for kind in ProbeLane.allCases {
            let selection = site[strength: kind]
            menu.addItem(.separator())
            let heading = kind.title + "探测强度 · 预计 8 小时"
            menu.addItem(.sectionHeader(title: heading))
            for strength in kind.strengths + selection.personal {
                let values = strength.values
                let budget = ProbeBudget(lane: kind, interval: values.interval)
                let item = command("\(strength.name) · \(values.interval) 秒　\(budget.display)",
                                   .select(kind, strength.id))
                item.state = selection.enabled && strength.id == selection.selectedID ? .on : .off
                item.toolTip = "\(values.warning) 秒提醒，\(values.cutoff) 秒截止，最多 \(values.capacity) 条在途。"
            }
            let stop = command("停止探测", .disable(kind))
            let other: ProbeLane = kind == .daily ? .fresh : .daily
            stop.state = selection.enabled ? .off : .on
            stop.isEnabled = !selection.enabled || !site.enabled || site[strength: other].enabled
            let description = "停止本站的" + kind.title + "探测"
            stop.setAccessibilityLabel(description)
            stop.toolTip = description + (stop.isEnabled ? "。" : "。暂停整站请取消勾选「启用此站点」。")
            stop.setAccessibilityHelp(stop.toolTip)
        }
        return parent
    }
}
