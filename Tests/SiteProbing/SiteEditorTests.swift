import AppKit
import XCTest
@testable import StatusBarCore

final class SiteEditorTests: XCTestCase {
    @MainActor
    func testSiteWindowStagesChangesAndProtectsBuiltIns() throws {
        let custom = try ProbeSite.custom(name: "Example", address: "https://example.com/status")
        let sites = ProbeSite.builtIns + [custom]
        for shouldSave in [false, true] {
            var commits: [[ProbeSite]] = []
            var closed = false
            let controller = SiteSettingsWindow(sites: sites, probingEnabled: true, didClose: { closed = true }) {
                commits.append($0)
            }
            let root = try XCTUnwrap(controller.window?.contentView)
            root.layoutSubtreeIfNeeded()
            func button(_ title: String) throws -> NSButton { try XCTUnwrap(view(root) { (b: NSButton) in b.title == title }) }
            let table = try XCTUnwrap(view(root) { (_: NSTableView) in true })
            let remove = try button("删除站点")
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            XCTAssertFalse(remove.isEnabled)
            table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            remove.performClick(nil)
            XCTAssertEqual(table.numberOfRows, 2)
            try button(shouldSave ? "保存" : "取消").performClick(nil)
            XCTAssertTrue(closed)
            XCTAssertEqual(commits, shouldSave ? [ProbeSite.builtIns] : [])
        }
    }

    @MainActor
    func testApplyKeepsWindowOpenAndOnlyLaterEditsAreCancelled() throws {
        let custom = try ProbeSite.custom(name: "Example", address: "https://example.com/status")
        let sites = ProbeSite.builtIns + [custom]
        let domain = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let url = try temporaryDirectory().appending(path: "config.json")
        let store = ProbeConfigurationStore(url: url, defaults: defaults)
        try store.loadOnLaunch()
        try store.save(.init(probingEnabled: false, sites: sites))
        var closed = false
        let controller = SiteSettingsWindow(sites: sites, probingEnabled: false, didClose: { closed = true }) {
            try store.save(.init(probingEnabled: false, sites: $0))
        }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(window.contentMinSize)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        func button(_ label: String, in area: NSView) throws -> NSButton {
            try XCTUnwrap(view(area) { (button: NSButton) in button.title == label || button.accessibilityLabel() == label })
        }
        let table = try XCTUnwrap(view(root) { (_: NSTableView) in true })
        let row = try XCTUnwrap(table.rowView(atRow: 2, makeIfNecessary: true))
        try button("展开或折叠Example", in: row).performClick(nil)
        let nameCell = try XCTUnwrap(table.view(atColumn: 0, row: 2, makeIfNecessary: true))
        let name = try XCTUnwrap(view(nameCell) { (field: NSTextField) in field.accessibilityLabel() == "名称" })
        func typeName(_ value: String) {
            name.stringValue = value
            name.delegate?.controlTextDidChange?(.init(name: NSControl.textDidChangeNotification, object: name))
        }
        let apply = try button("应用", in: root)
        XCTAssertEqual(try button("保存", in: root).keyEquivalent, "")
        XCTAssertNil(window.defaultButtonCell)
        XCTAssertFalse(apply.isEnabled)
        XCTAssertTrue(window.makeFirstResponder(name))
        let fieldEditor = try XCTUnwrap(name.currentEditor())
        fieldEditor.selectAll(nil)
        fieldEditor.insertText(" Applied ")
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        if !window.performKeyEquivalent(with: enter) { window.firstResponder?.keyDown(with: enter) }
        XCTAssertNil(name.currentEditor())
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(closed)
        XCTAssertEqual(try store.read().configuration.sites.last?.name, "Example")
        XCTAssertTrue(apply.isEnabled)
        apply.performClick(nil)
        XCTAssertEqual(try store.read().configuration.sites.last?.name, "Applied")
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(closed)
        XCTAssertFalse(apply.isEnabled)
        XCTAssertEqual(table.numberOfRows, 4)
        XCTAssertEqual(table.selectedRow, 2)
        typeName("Draft")
        XCTAssertTrue(apply.isEnabled)
        try button("取消", in: root).performClick(nil)
        XCTAssertTrue(closed)
        XCTAssertEqual(try store.read().configuration.sites.last?.name, "Applied")
    }

    @MainActor
    func testSiteWindowSavesHoverOrderAndKeepsProbeHistory() async throws {
        let custom = try ProbeSite.custom(name: "Example", address: "https://example.com/status", enabled: false)
        let sites = ProbeSite.builtIns + [custom]
        let expected = [custom, sites[1], sites[0]]
        let domain = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let url = try temporaryDirectory().appending(path: "config.json")
        let settings = ProbeConfigurationStore(url: url, defaults: defaults)
        try settings.loadOnLaunch()
        try settings.save(.init(probingEnabled: true, sites: sites))
        let h = ProbeHarness(sites: sites)
        defer { h.stop() }
        try await waitUntil { h.daily.count == 2 && h.fresh.count == 2 }
        for probe in h.daily { probe.reply(204) }
        try await waitUntil { h.monitor.state.rows.prefix(2).allSatisfy { $0.dailyCount.successes == 1 } }
        let originalRows = h.monitor.state.rows
        let originalSessions = h.sessions

        func editOrder(save: Bool) throws {
            let controller = SiteSettingsWindow(sites: try settings.read().configuration.sites,
                                                probingEnabled: true) { updated in
                let configuration = ProbeConfiguration(probingEnabled: true, sites: updated)
                try settings.save(configuration)
                h.monitor.apply(configuration)
            }
            let window = try XCTUnwrap(controller.window)
            let content = try XCTUnwrap(window.contentView)
            window.setContentSize(window.contentMinSize)
            content.layoutSubtreeIfNeeded()
            let table = try XCTUnwrap(view(content) { (_: NSTableView) in true })
            let up = try XCTUnwrap(view(content) { (button: NSButton) in button.title == "上移" })
            let down = try XCTUnwrap(view(content) { (button: NSButton) in button.title == "下移" })
            for button in [up, down] {
                XCTAssertGreaterThanOrEqual(button.frame.width, button.intrinsicContentSize.width)
                XCTAssertFalse(button.isEnabled)
            }
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            XCTAssertFalse(up.isEnabled)
            down.performClick(nil)
            XCTAssertEqual(table.selectedRow, 1)
            XCTAssertTrue(up.isEnabled)
            down.performClick(nil)
            XCTAssertEqual(table.selectedRow, 2)
            XCTAssertFalse(down.isEnabled)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            up.performClick(nil)
            XCTAssertEqual(table.selectedRow, 0)
            XCTAssertFalse(up.isEnabled)
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
            XCTAssertNotNil(view(cell) { (label: NSTextField) in label.stringValue == custom.name })
            XCTAssertEqual(try settings.read().configuration.sites, sites)
            XCTAssertEqual(h.monitor.state.rows, originalRows)
            let done = try XCTUnwrap(view(content) { (button: NSButton) in button.title == (save ? "保存" : "取消") })
            done.performClick(nil)
        }

        try editOrder(save: false)
        XCTAssertEqual(try settings.read().configuration.sites, sites)
        XCTAssertEqual(h.monitor.state.rows, originalRows)
        try editOrder(save: true)
        XCTAssertEqual(try ProbeConfigurationStore(url: url, defaults: defaults).read().configuration.sites, expected)
        XCTAssertEqual(h.monitor.state.rows, Array(originalRows.reversed()))
        XCTAssertEqual(h.sessions, originalSessions)
        XCTAssertFalse(h.fresh.contains(where: \.stopped))

        let hover = HoverCard()
        _ = hover.update(h.monitor.state, availableHeight: 240)
        let hoverContent = try XCTUnwrap(hover.contentView)
        let expectedNames = expected.map(\.name)
        let names = hoverContent.subviews.compactMap { $0 as? NSTextField }
            .filter { expectedNames.contains($0.stringValue) }
            .sorted { $0.frame.minY > $1.frame.minY }
        XCTAssertEqual(names.map(\.stringValue), expectedNames)
    }

    @MainActor
    func testConfigurationWindowReloadProtectsUnsavedDraft() async throws {
        let domain = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let url = try temporaryDirectory().appending(path: "config.json")
        let store = ProbeConfigurationStore(url: url, defaults: defaults)
        try store.loadOnLaunch()
        let initial = try XCTUnwrap(store.configuration)
        let monitor = ConnectivityMonitor(sites: initial.sites, automaticTimer: false) {}
        let file = SiteSettingsWindow.ConfigurationFile(store: store, startupError: nil) {
            if let configuration = store.configuration { monitor.apply(configuration) }
        }
        let controller = SiteSettingsWindow(sites: initial.sites, probingEnabled: true, configurationFile: file) { sites in
            try store.save(.init(probingEnabled: true, sites: sites))
        }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(window.contentMinSize)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let fileMenu = try XCTUnwrap(view(content) { (popup: NSPopUpButton) in popup.title == "配置文件" })
        XCTAssertLessThanOrEqual(fileMenu.frame.width, content.bounds.width)
        let menu = try XCTUnwrap(fileMenu.menu)
        XCTAssertNotNil(menu.item(withTitle: "在 Finder 中显示"))
        let reload = try XCTUnwrap(menu.item(withTitle: "重新读取配置"))
        let table = try XCTUnwrap(view(content) { (_: NSTableView) in true })
        func alertButton(_ title: String) throws -> NSButton {
            let root = try XCTUnwrap(window.attachedSheet?.contentView)
            return try XCTUnwrap(view(root) { (button: NSButton) in button.title == title })
        }
        try addSite("HTTPS", in: content)
        XCTAssertEqual(table.numberOfRows, 3)
        var updated = initial
        updated.probingEnabled = false
        updated.sites[0].fresh.interval = 10
        updated.sites.append(try ProbeSite.custom(name: "Cursor", address: "https://api2.cursor.sh/"))
        let external = try JSONEncoder().encode(updated)
        try external.write(to: url, options: .atomic)
        XCTAssertEqual(monitor.state.rows.count, 2)

        menu.performActionForItem(at: menu.index(of: reload))
        try alertButton("继续编辑").performClick(nil)
        try await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(store.configuration, initial)
        XCTAssertEqual(try Data(contentsOf: url), external)

        menu.performActionForItem(at: menu.index(of: reload))
        try alertButton("丢弃并重新读取").performClick(nil)
        try await waitUntil { window.attachedSheet == nil && store.configuration == updated }
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(monitor.state.rows.map(\.name), ["Google", "Cloudflare", "Cursor"])
        XCTAssertEqual(monitor.state.rows.first?.freshSettings.interval, 10)
        XCTAssertFalse(monitor.state.enabled)
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    @MainActor
    func testInlineEditorsKeepInputsAndFollowMenuSelections() throws {
        var sites = ProbeSite.builtIns
        var personal = ProbeLane.fresh.strengths[1]
        personal = ProbeStrength(id: "personal", name: "办公", values: personal.values)
        sites[0][strength: .fresh] = LaneStrength(selectedID: personal.id, personal: [personal])
        var saved: [ProbeSite]?
        let controller = SiteSettingsWindow(sites: sites, probingEnabled: true) { saved = $0 }
        let window = try XCTUnwrap(controller.window)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(view(root) { (_: NSTableView) in true })
        func row(_ index: Int) throws -> NSView {
            try XCTUnwrap(table.rowView(atRow: index, makeIfNecessary: true))
        }
        func click(_ title: String, in root: NSView) throws {
            let button = try XCTUnwrap(view(root) { (b: NSButton) in b.title == title || b.accessibilityLabel() == title })
            button.performClick(nil)
        }
        XCTAssertEqual(table.numberOfColumns, 4)
        XCTAssertEqual(table.numberOfRows, 2)
        let address = try XCTUnwrap(view(try row(0)) { (f: NSTextField) in f.accessibilityLabel() == "HTTPS 地址" })
        XCTAssertFalse(address.isEditable)
        XCTAssertTrue(try XCTUnwrap(address.toolTip).contains(address.stringValue))
        try click("展开或折叠Google", in: row(0))
        try click("展开或折叠Cloudflare", in: row(2))
        XCTAssertEqual(table.numberOfRows, 4)
        let google = try XCTUnwrap(view(try row(1)) { (_: SiteEditor) in true })
        try click("管理新建探测强度", in: google)
        let field = try XCTUnwrap(view(google) { (f: NSTextField) in f.accessibilityLabel() == "新建发起间隔" })
        func type(_ value: String, into field: NSTextField) {
            field.stringValue = value
            field.delegate?.controlTextDidChange?(.init(name: NSControl.textDidChangeNotification, object: field))
        }
        type("12", into: field)
        XCTAssertNotNil(view(google) { (f: NSTextField) in f.stringValue == "16.8 MB" })
        XCTAssertNotNil(view(google) { (f: NSTextField) in f.stringValue == "个人 · 已选" })
        sites[0][strength: .fresh].selectedID = "low"
        controller.syncMenu(.init(probingEnabled: false, sites: sites))
        XCTAssertEqual(field.stringValue, "12")
        XCTAssertNotNil(view(root) { (f: NSTextField) in f.stringValue.contains("恢复探测后预计") })
        func chooseTemplate(_ title: String) throws {
            let popup = try XCTUnwrap(view(google) { (b: NSPopUpButton) in b.accessibilityLabel() == "新建新增强度" })
            let menu = try XCTUnwrap(popup.menu)
            menu.update()
            XCTAssertEqual(menu.items[1].title, "低频（当前）")
            XCTAssertEqual(menu.items.filter { $0.title.hasPrefix("低频") }.count, 1)
            let index = menu.indexOfItem(withTitle: title)
            XCTAssertGreaterThan(index, 0)
            if index > 0 { menu.performActionForItem(at: index) }
        }
        try chooseTemplate("办公")
        XCTAssertEqual(google.draft.form.personal[.fresh]?.last?.numbers.first, "12")
        let nameEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual((nameEditor.string as NSString).substring(with: nameEditor.selectedRange()), "自定义 1")
        try chooseTemplate("温和")
        XCTAssertEqual(google.draft.form.personal[.fresh]?.last?.numbers.first, "15")
        google.toggle()
        google.toggle()
        XCTAssertEqual(google.draft.form.personal[.fresh]?.first?.numbers.first, "12")
        try addSite("HTTPS", in: root)
        XCTAssertEqual(table.numberOfRows, 5)
        try click("保存", in: root)
        XCTAssertNil(saved)
        XCTAssertNil(window.attachedSheet)
        let newAddress = try XCTUnwrap(view(try row(4)) { (f: NSTextField) in f.accessibilityLabel() == "HTTPS 地址" })
        XCTAssertTrue(newAddress.currentEditor() === window.firstResponder)
        type("https://example.com/ready", into: newAddress)
        try click("保存", in: root)
        let committed = try XCTUnwrap(saved)
        XCTAssertEqual(committed[0].fresh.interval, 30)
        XCTAssertEqual(committed[0][strength: .fresh].personal.first?.values.interval, 12)
        XCTAssertEqual(committed[0][strength: .fresh].personal.count, 3)
        XCTAssertEqual(committed[2].name, "example.com")
        XCTAssertFalse(committed[2].enabled)
        XCTAssertFalse(committed[2].daily.enabled)
        XCTAssertTrue(committed[2].fresh.enabled)
        XCTAssertEqual(committed[2][strength: .fresh].selectedID, "balanced")
    }

    @MainActor
    func testTCPFormMenuAndConfigurationRoundTrip() throws {
        var saved: [ProbeSite] = []
        let controller = SiteSettingsWindow(sites: ProbeSite.builtIns, probingEnabled: true) { saved = $0 }
        let window = try XCTUnwrap(controller.window)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        try addSite("TCP 端口", in: root)
        func field(_ name: String) throws -> NSTextField {
            try XCTUnwrap(view(root) { (f: NSTextField) in f.accessibilityLabel() == name })
        }
        func type(_ value: String, into field: NSTextField) {
            field.stringValue = value
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        type("nas", into: try field("TCP 主机"))
        let port = try field("TCP 端口")
        let apply = try XCTUnwrap(view(root) { (b: NSButton) in b.title == "应用" })
        type("65536", into: port)
        apply.performClick(nil)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(port.currentEditor() === window.firstResponder)
        type("445", into: port)
        apply.performClick(nil)
        var site = try XCTUnwrap(saved.last)
        XCTAssertFalse(site.enabled)
        XCTAssertEqual(site.endpoint, .tcp(host: "nas", port: 445))
        XCTAssertEqual(site.name, "nas")
        XCTAssertEqual(site.lanes, [.fresh])
        XCTAssertEqual(site.fresh.interval, 10)
        XCTAssertFalse(site.daily.enabled)
        let menu = try XCTUnwrap(SiteProbeCommand.menuItem(for: site, target: controller, action: NSSelectorFromString("performSiteProbeCommand:")).submenu)
        XCTAssertFalse(menu.items.contains { $0.title.contains("复用") || $0.title == "停止探测" })
        let low = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("低频") })
        XCTAssertFalse(low.title.contains("KB") || low.title.contains("MB"))
        try XCTUnwrap(low.representedObject as? SiteProbeCommand).apply(to: &site)
        XCTAssertFalse(site.enabled)
        XCTAssertEqual(site.fresh.interval, 30)
        try XCTUnwrap(menu.item(withTitle: "启用此站点")?.representedObject as? SiteProbeCommand).apply(to: &site)
        XCTAssertTrue(site.enabled)
        let config = ProbeConfiguration(probingEnabled: true, sites: ProbeSite.builtIns + [site])
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try ProbeConfiguration.decode(data), config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sites = try XCTUnwrap(json["sites"] as? [[String: Any]])
        let tcp = try XCTUnwrap(sites.last)
        XCTAssertEqual(tcp["type"] as? String, "tcp")
        for key in ["url", "method", "statusCodes", "daily"] { XCTAssertNil(tcp[key]) }
        var legacy = Array(sites.dropLast().reversed())
        for index in legacy.indices { legacy[index].removeValue(forKey: "type") }
        let v2 = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "probingEnabled": false, "sites": legacy])
        let migrated = try ProbeConfiguration.decode(v2)
        XCTAssertEqual(migrated.sites, Array(ProbeSite.builtIns.reversed()))
        XCTAssertFalse(migrated.probingEnabled)
        XCTAssertEqual(try ProbeEndpoint.tcpHost("[::1]"), "::1")
        for invalid in ["", "smb://nas/share", "nas:445", "user@nas", "bad host", "nas..local"] {
            XCTAssertThrowsError(try ProbeEndpoint.tcpHost(invalid))
        }
    }
}
