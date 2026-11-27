import AppKit
import XCTest
@testable import StatusBarCore

final class ProbeConfigurationTests: XCTestCase {
    @MainActor
    func testMenuControlsStrengthWhilePausedAndProtectsLastLane() throws {
        var site = try ProbeSite.custom(name: "Example", address: "https://example.com", enabled: false)
        site[strength: .daily].enabled = false
        site[strength: .fresh].enabled = false
        site[strength: .fresh].personal = [ProbeStrength(id: "work", name: "办公", values: ProbeLane.fresh.strengths[1].values)]
        let selector = NSSelectorFromString("choose:")
        func command(_ item: NSMenuItem) throws -> SiteProbeCommand { try XCTUnwrap(item.representedObject as? SiteProbeCommand) }
        let parent = SiteProbeCommand.menuItem(for: site, target: self, action: selector)
        let children = try XCTUnwrap(parent.submenu)
        XCTAssertEqual(parent.state, .off)
        XCTAssertFalse(try XCTUnwrap(children.item(withTitle: "启用此站点")).isEnabled)
        XCTAssertFalse(children.items.contains(where: \.hasSubmenu))
        let initiallyChecked = children.items.filter { $0.state == .on }
        XCTAssertEqual(initiallyChecked.map(\.title), ["停止探测", "停止探测"])
        let previous = site
        try command(XCTUnwrap(initiallyChecked.first)).apply(to: &site)
        XCTAssertEqual(site, previous)
        XCTAssertNotNil(children.items.first { $0.title.hasPrefix("办公 · 10 秒") })
        let balanced = try XCTUnwrap(children.items.first { $0.title.hasPrefix("均衡 · 10 秒") })
        XCTAssertTrue(balanced.title.contains("20.2 MB"))
        try command(balanced).apply(to: &site)
        XCTAssertTrue(site.fresh.enabled)
        XCTAssertFalse(site.enabled)
        try SiteProbeCommand(siteID: site.id, operation: .toggleSite).apply(to: &site)
        XCTAssertTrue(site.enabled)
        XCTAssertThrowsError(try SiteProbeCommand(siteID: site.id, operation: .disable(.fresh)).apply(to: &site))
        SiteProbeCommand.refreshMenuItem(parent, for: site, available: true)
        XCTAssertTrue(parent.submenu === children)
        XCTAssertTrue(children.items.contains { $0 === balanced })
        XCTAssertEqual(parent.state, .on)
        XCTAssertEqual(balanced.state, .on)
        XCTAssertEqual(balanced.view?.accessibilityValue() as? Int, 1)
        XCTAssertEqual(children.item(withTitle: "启用此站点")?.view?.accessibilityValue() as? Int, 1)
        let checked = SiteProbeCommand.menuItem(for: site, target: self, action: selector)
        XCTAssertEqual(checked.state, .on)
        let lastStop = try XCTUnwrap(checked.submenu?.items.first { $0.accessibilityLabel() == "停止本站的新建探测" })
        XCTAssertFalse(lastStop.isEnabled)
        XCTAssertEqual(lastStop.state, .off)
        XCTAssertEqual(lastStop.accessibilityLabel(), "停止本站的新建探测")
        site[strength: .daily].enabled = true
        let both = SiteProbeCommand.menuItem(for: site, target: self, action: selector)
        let stops = try XCTUnwrap(both.submenu).items.filter { $0.title == "停止探测" }
        XCTAssertEqual(stops.count, 2)
        for (lane, stop) in zip(ProbeLane.allCases, stops) {
            var copy = site
            XCTAssertTrue(stop.isEnabled)
            XCTAssertEqual(stop.state, .off)
            XCTAssertTrue(try XCTUnwrap(stop.toolTip).contains(lane.title))
            XCTAssertEqual(stop.accessibilityLabel(), "停止本站的" + lane.title + "探测")
            try command(stop).apply(to: &copy)
            XCTAssertFalse(copy[strength: lane].enabled)
            XCTAssertTrue(copy[strength: lane == .daily ? .fresh : .daily].enabled)
            XCTAssertTrue(copy.enabled)
            let refreshed = SiteProbeCommand.menuItem(for: copy, target: self, action: selector)
            let stopped = try XCTUnwrap(refreshed.submenu?.items.first { $0.accessibilityLabel() == stop.accessibilityLabel() })
            XCTAssertEqual(stopped.state, .on)
        }
        XCTAssertEqual(checked.submenu?.items.first { $0.title == balanced.title }?.state, .on)
    }

    func testTCPPersonalStrengthsAndMixedConnectionBudget() throws {
        let draft = SiteDraft.new(type: .tcp)
        draft.form.address = "nas"
        draft.form.port = "445"
        let values = StrengthValues(interval: 12, warning: 4, cutoff: 7, capacity: 1)
        let strength = ProbeStrength(id: "personal", name: "家庭", values: values)
        draft.form.personal[.fresh] = [StrengthInput(strength)]
        var site = try draft.build()
        try SiteProbeCommand(siteID: site.id, operation: .select(.fresh, strength.id)).apply(to: &site)
        let edit = SiteDraft(site)
        XCTAssertEqual(try edit.build().fresh.interval, 12)
        XCTAssertTrue(edit.canRemoveStrength(strength.id, lane: .fresh))
        edit.form.personal[.fresh] = []
        XCTAssertFalse(edit.sync(site))
        XCTAssertEqual(try edit.build()[strength: .fresh].selectedID, "balanced")
        site.enabled = true
        XCTAssertTrue(edit.sync(site))
        XCTAssertFalse(edit.canRemoveStrength(strength.id, lane: .fresh))

        var budget = ProbeBudget(lane: .fresh, interval: 10, type: .tcp)
        XCTAssertEqual(budget.requests, 2880)
        XCTAssertEqual(budget.trafficDisplay, "—")
        let https = ProbeBudget(lane: .fresh, interval: 10)
        budget.add(https)
        XCTAssertEqual(budget.requests, 5760)
        XCTAssertEqual(budget.bytes, https.bytes)
        XCTAssertTrue(budget.display.contains("HTTPS 流量"))
    }

    func testStoredSiteSettingsAndValidation() throws {
        let name = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LegacySiteSettings(defaults: defaults)
        func writeLegacy(_ sites: [ProbeSite]) throws {
            defaults.set(try legacySiteData(sites), forKey: "NetRate.ProbeSites.v1")
        }
        XCTAssertEqual(settings.load(), ProbeSite.builtIns)
        var sites = ProbeSite.builtIns
        sites[0].enabled = false
        let custom = try ProbeSite.custom(name: " ", address: " https://example.com/status ")
        XCTAssertEqual(custom.name, "example.com")
        try writeLegacy(sites + [custom])
        XCTAssertEqual(settings.load(), sites + [custom])
        XCTAssertEqual(settings.load().last?.statusCodes.text, "")
        sites[1].fresh = .init(enabled: false, interval: 9, warning: 3, cutoff: 15, capacity: 4)
        var exact = custom
        exact.method = .get
        exact.daily.capacity = 8
        exact.statusCodes = try StatusCodes("2XX, 405")
        try writeLegacy(sites + [exact])
        XCTAssertEqual(settings.load(), sites + [exact])
        XCTAssertTrue(settings.probingEnabled)
        defaults.set(false, forKey: "NetRate.ProbingEnabled")
        XCTAssertFalse(settings.probingEnabled)
        let legacy = Data(#"[{"id":"old","name":"Codex","url":"https://example.com/","enabled":true,"expectedStatusCode":405}]"#.utf8)
        defaults.set(legacy, forKey: "NetRate.ProbeSites.v1")
        XCTAssertEqual(Array(settings.load().dropLast()).map(\.daily), Array(repeating: ProbeLane.daily.legacyDefaults, count: 2))
        XCTAssertEqual(settings.load().last?.statusCodes.text, "405")
        XCTAssertFalse(settings.load().last!.accepts(statusCode: 200))
        XCTAssertEqual(settings.load().last?.method, .head)
        XCTAssertEqual(settings.load().last?.fresh, ProbeLane.fresh.defaults)
        XCTAssertEqual(settings.load().first?.method, .get)
        XCTAssertTrue(ProbeLane.daily.legacyDefaults.capacityHint?.contains("3 个名额") == true)
        XCTAssertNil(ProbeLane.fresh.defaults.capacityHint)
        exact.daily.warning = 9
        XCTAssertThrowsError(try exact.validate())
        exact.daily.warning = 0
        XCTAssertThrowsError(try exact.validate())
        exact.daily = ProbeLane.daily.defaults
        exact.daily.enabled = false
        exact.fresh.enabled = false
        XCTAssertThrowsError(try exact.validate())
        exact.enabled = false
        try writeLegacy([exact])
        XCTAssertEqual(settings.load().last, exact)
        let mixed = try StatusCodes(" 2XX， 204, 405, 405 ")
        XCTAssertEqual(mixed.text, "2xx, 405")
        for code in [200, 204, 299, 405] { XCTAssertTrue(mixed.accepts(code)) }
        for code in [301, 403, 500] { XCTAssertFalse(mixed.accepts(code)) }
        for invalid in ["199", "600", "201,", "2xy", "1xx", "4x5", "200-300"] {
            XCTAssertThrowsError(try StatusCodes(invalid))
        }
        for invalid in ["http://example.com", "https://", "https://user:secret@example.com", "https://example.com/#section"] {
            XCTAssertThrowsError(try ProbeSite.custom(name: "", address: invalid))
        }
    }

    @MainActor
    func testConfigurationFileMigratesOnceAndDoesNotOverwriteInvalidFiles() throws {
        let domain = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var github = try ProbeSite.custom(name: "GitHub", address: "https://github.com/", statusCodes: StatusCodes("200"))
        github.daily.enabled = false
        github.fresh = .init(interval: 10, warning: 5, cutoff: 8, capacity: 1)
        var google = ProbeSite.builtIns[0]
        google.enabled = false
        let sites = [github, ProbeSite.builtIns[1], google]
        let legacy = try legacySiteData(sites)
        defaults.set(legacy, forKey: "NetRate.ProbeSites.v1")
        defaults.set(false, forKey: "NetRate.ProbingEnabled")
        let url = try temporaryDirectory().appending(path: "NetRate/config.json")
        let store = ProbeConfigurationStore(url: url, defaults: defaults)
        try store.loadOnLaunch()
        let expected = ProbeConfiguration(probingEnabled: false, sites: sites)
        XCTAssertEqual(store.configuration, expected)
        let migrated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(migrated.contains("\"schemaVersion\" : 3"))
        XCTAssertTrue(migrated.contains("https://github.com/"))

        let reopened = ProbeConfigurationStore(url: url, defaults: defaults)
        try reopened.loadOnLaunch()
        XCTAssertEqual(reopened.configuration, expected)
        XCTAssertEqual(defaults.data(forKey: "NetRate.ProbeSites.v1"), legacy)
        XCTAssertFalse(defaults.bool(forKey: "NetRate.ProbingEnabled"))

        let invalid = Data(#"{"schemaVersion":99}"#.utf8)
        try invalid.write(to: url, options: .atomic)
        let startup = ProbeConfigurationStore(url: url, defaults: defaults)
        XCTAssertThrowsError(try startup.loadOnLaunch()) { XCTAssertEqual($0.localizedDescription, "当前版本不支持配置文件格式 99。") }
        XCTAssertNil(startup.configuration)
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try startup.loadOnLaunch())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testVersionOneIsReadWithoutOverwritingUntilNextSave() throws {
        var github = try ProbeSite.custom(name: "GitHub", address: "https://github.com/")
        github.daily = .init(enabled: false, interval: 2, warning: 5, cutoff: 5, capacity: 1)
        github.fresh = .init(interval: 10, warning: 5, cutoff: 8, capacity: 1)
        var cursor = try ProbeSite.custom(name: "Cursor", address: "https://example.com/")
        cursor.fresh = .init(interval: 10, warning: 5, cutoff: 10, capacity: 1)
        let sites = [github, ProbeSite.builtIns[1], cursor, ProbeSite.legacyGoogle]
        let v1 = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "probingEnabled": false,
            "sites": JSONSerialization.jsonObject(with: legacySiteData(sites))
        ])
        let url = try temporaryDirectory().appending(path: "config.json")
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try v1.write(to: url)
        let store = ProbeConfigurationStore(url: url, defaults: defaults)
        try store.loadOnLaunch()
        var config = try XCTUnwrap(store.configuration)
        XCTAssertEqual(config.sites, sites)
        XCTAssertEqual(try Data(contentsOf: url), v1)
        XCTAssertEqual(config.sites[0][strength: .daily].selectedID, "original")
        XCTAssertFalse(config.sites[0].daily.enabled)
        XCTAssertEqual(config.sites[0][strength: .fresh].personal.first?.name, "原有配置")
        XCTAssertEqual(config.sites[2][strength: .fresh].selectedID, "balanced")
        config.sites[0][strength: .fresh].selectedID = "balanced"
        try store.save(config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 3)
        XCTAssertEqual(try store.read().configuration, config)
        XCTAssertEqual(config.sites[0][strength: .fresh].personal.first?.values.cutoff, 8)

        var invalid = config
        invalid.sites[1][strength: .fresh].selectedID = "original"
        XCTAssertThrowsError(try store.save(invalid))
        invalid = config
        invalid.sites[0][strength: .fresh].personal.append(ProbeLane.fresh.strengths[1])
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.read().configuration, config)
    }

    @MainActor
    func testConfigurationFileChecksExternalChangesAndPreservesActiveSettings() throws {
        let domain = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let directory = try temporaryDirectory()
        let url = directory.appending(path: "config.json")
        let store = ProbeConfigurationStore(url: url, defaults: defaults)
        try store.loadOnLaunch()
        let initial = try XCTUnwrap(store.configuration)
        XCTAssertEqual(initial, .init(probingEnabled: true, sites: ProbeSite.builtIns))
        var updated = initial
        updated.probingEnabled = false
        updated.sites[0].fresh.interval = 10
        let edited = try JSONEncoder().encode(updated)
        try edited.write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.save(initial))
        XCTAssertEqual(store.configuration, initial)
        XCTAssertEqual(try Data(contentsOf: url), edited)
        let candidate = try store.read()
        XCTAssertEqual(candidate.configuration, updated)
        XCTAssertEqual(store.configuration, initial)
        let stale = Data("not json".utf8)
        try stale.write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.accept(candidate))
        XCTAssertThrowsError(try store.read())
        XCTAssertEqual(store.configuration, initial)
        XCTAssertEqual(try Data(contentsOf: url), stale)
        try edited.write(to: url, options: .atomic)
        try store.accept(store.read())
        XCTAssertEqual(store.configuration, updated)
        XCTAssertEqual(try Data(contentsOf: url), edited)

        var invalid = updated
        invalid.sites[0].fresh.interval = 0
        XCTAssertThrowsError(try store.save(invalid)) { XCTAssertTrue($0.localizedDescription.contains("sites[0]")) }
        invalid.sites = [updated.sites[0], updated.sites[0]]
        XCTAssertThrowsError(try ProbeConfiguration.decode(JSONEncoder().encode(invalid)))
        invalid.sites = Array(updated.sites.dropFirst())
        XCTAssertThrowsError(try ProbeConfiguration.decode(JSONEncoder().encode(invalid)))
        invalid.sites = updated.sites
        invalid.sites[0].endpoint = .https(URL(string: "https://example.com/")!)
        XCTAssertThrowsError(try ProbeConfiguration.decode(JSONEncoder().encode(invalid)))

        if geteuid() != 0 {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            XCTAssertThrowsError(try store.save(initial))
            XCTAssertEqual(store.configuration, updated)
            XCTAssertEqual(try Data(contentsOf: url), edited)
        }
    }
}
