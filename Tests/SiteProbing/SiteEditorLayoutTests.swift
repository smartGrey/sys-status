import AppKit
import XCTest
@testable import StatusBarCore

final class SiteEditorLayoutTests: XCTestCase {
    @MainActor
    func testStoppedLaneCanDeleteItsPreviouslySelectedStrength() throws {
        var site = try ProbeSite.custom(name: "Example", address: "https://example.com/")
        let original = ProbeStrength(id: "original", name: "原有配置", values: ProbeLane.daily.strengths[0].values)
        site[strength: .daily] = LaneStrength(enabled: false, selectedID: original.id, personal: [original])
        var config = ProbeConfiguration(probingEnabled: false, sites: [site] + ProbeSite.builtIns)
        var saved: [ProbeSite]?
        let controller = SiteSettingsWindow(sites: config.sites, probingEnabled: config.probingEnabled) { saved = $0 }
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let root = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(view(root) { (_: NSTableView) in true })
        root.layoutSubtreeIfNeeded()
        func button(_ title: String, in area: NSView) throws -> NSButton {
            try XCTUnwrap(view(area) { (button: NSButton) in button.title == title || button.accessibilityLabel() == title })
        }
        let siteRow = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true))
        try button("展开或折叠Example", in: siteRow).performClick(nil)
        let detail = try XCTUnwrap(table.rowView(atRow: 1, makeIfNecessary: true))
        let editor = try XCTUnwrap(view(detail) { (_: SiteEditor) in true })
        try button("管理复用探测强度", in: editor).performClick(nil)
        XCTAssertTrue(try button("删除", in: editor).isEnabled)
        try button("删除", in: editor).performClick(nil)

        controller.syncMenu(config)
        XCTAssertTrue(editor.draft.form.personal[.daily]?.isEmpty == true)
        config.sites[0][strength: .daily].enabled = true
        controller.syncMenu(config)
        XCTAssertEqual(editor.draft.form.personal[.daily]?.first?.id, original.id)
        try button("管理复用探测强度", in: editor).performClick(nil)
        XCTAssertFalse(try button("删除", in: editor).isEnabled)

        config.sites[0][strength: .daily].enabled = false
        controller.syncMenu(config)
        try button("删除", in: editor).performClick(nil)
        try button("保存", in: root).performClick(nil)
        config.sites = try XCTUnwrap(saved)
        let reopened = try ProbeConfiguration.decode(JSONEncoder().encode(config))
        let reuse = reopened.sites[0][strength: .daily]
        XCTAssertFalse(reuse.enabled)
        XCTAssertTrue(reuse.personal.isEmpty)
        XCTAssertEqual(reuse.selectedID, "balanced")
        XCTAssertEqual(reopened.sites[0][strength: .fresh], site[strength: .fresh])
    }

    @MainActor
    func testCompactGridAlignsValuesAndRevealsInvalidFieldAfterReordering() throws {
        var site = try ProbeSite.custom(name: "Work", address: "https://example.com/long/path")
        site[strength: .daily].enabled = false
        site[strength: .daily].personal = [ProbeStrength(id: "night", name: "夜间", values: ProbeLane.daily.strengths[1].values)]
        var saved: [ProbeSite]?
        let controller = SiteSettingsWindow(sites: [ProbeSite.builtIns[0], site], probingEnabled: true) { saved = $0 }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(window.contentMinSize)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(view(root) { (_: NSTableView) in true })
        func row(_ index: Int) throws -> NSView { try XCTUnwrap(table.rowView(atRow: index, makeIfNecessary: true)) }
        func button(_ title: String, in area: NSView) throws -> NSButton {
            try XCTUnwrap(view(area) { (button: NSButton) in button.title == title || button.accessibilityLabel() == title })
        }
        func label(_ title: String, in area: NSView) throws -> NSTextField {
            try XCTUnwrap(view(area) { (field: NSTextField) in field.accessibilityLabel() == title })
        }
        func type(_ value: String, into field: NSTextField) {
            field.stringValue = value
            field.delegate?.controlTextDidChange?(.init(name: NSControl.textDidChangeNotification, object: field))
        }
        try button("展开或折叠Work", in: row(1)).performClick(nil)
        try button("管理复用探测强度", in: row(2)).performClick(nil)
        let detail = try row(2)
        root.layoutSubtreeIfNeeded()
        XCTAssertNil(view(detail) { (field: NSTextField) in field.stringValue == "方式" })
        for title in ["复用", "新建"] {
            XCTAssertNotNil(view(detail) { (field: NSTextField) in field.stringValue == title })
        }
        XCTAssertEqual(try label("复用当前探测强度", in: detail).stringValue, "已停止 · 快速")
        XCTAssertEqual(try label("复用预计 8 小时请求数", in: detail).stringValue, "0")
        XCTAssertEqual(try label("复用预计 8 小时流量", in: detail).stringValue, "0 KB")
        let current = try label("复用当前截止时间", in: detail)
        let edit = try label("复用截止时间", in: detail)
        func textEdge(_ field: NSTextField) throws -> CGFloat {
            field.convert(try XCTUnwrap(field.cell).titleRect(forBounds: field.bounds), to: root).maxX
        }
        XCTAssertEqual(try textEdge(current), try textEdge(edit), accuracy: 1)
        let add = try button("复用新增强度", in: detail)
        XCTAssertGreaterThanOrEqual(add.bounds.width, add.intrinsicContentSize.width)
        XCTAssertLessThanOrEqual(add.convert(add.bounds, to: table).maxX, table.bounds.maxX)
        try button("上移", in: root).performClick(nil)
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertEqual(table.numberOfRows, 3)
        type("2", into: try label("复用截止时间", in: row(1)))
        try button("展开或折叠Work", in: row(0)).performClick(nil)
        XCTAssertEqual(table.numberOfRows, 2)
        try button("保存", in: root).performClick(nil)
        XCTAssertNil(saved)
        XCTAssertEqual(table.numberOfRows, 3)
        let invalid = try label("复用截止时间", in: row(1))
        XCTAssertEqual(invalid.stringValue, "2")
        XCTAssertTrue(invalid.currentEditor() === window.firstResponder)
        type("8", into: invalid)
        let name = try label("复用个人强度名称", in: row(1))
        type("均衡", into: name)
        try button("保存", in: root).performClick(nil)
        XCTAssertNil(saved)
        let duplicate = try label("复用个人强度名称", in: row(1))
        XCTAssertTrue(duplicate.currentEditor() === window.firstResponder)
        type("晚间", into: duplicate)
        try button("保存", in: root).performClick(nil)
        XCTAssertEqual(saved?.first?[strength: .daily].personal.first?.name, "晚间")
        XCTAssertEqual(saved?.first?.id, site.id)
    }

    @MainActor
    func testModelessHelpSharesTopicsWithFieldTipsAndReturnsToDraft() async throws {
        let controller = SiteSettingsWindow(sites: [], probingEnabled: true) { _ in }
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { controller.close() }
        let list = try XCTUnwrap(window.contentView)
        func button(_ title: String, in root: NSView) throws -> NSButton {
            try XCTUnwrap(view(root) { (b: NSButton) in b.title == title })
        }
        func visibleHelp() -> [NSWindow] {
            NSApp.windows.filter { $0.isVisible && $0.title == "配置说明" }
        }
        try button("配置说明", in: list).performClick(nil)
        let help = try XCTUnwrap(visibleHelp().first)
        let guide = try XCTUnwrap(help.contentView)
        XCTAssertGreaterThanOrEqual(guide.bounds.height, help.contentMinSize.height)
        let nav = try XCTUnwrap(view(guide) { (_: NSTableView) in true })
        func selectTopic(_ title: String) throws {
            let row = try XCTUnwrap((0..<nav.numberOfRows).first {
                (nav.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == title
            })
            nav.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        try selectTopic(HelpField.codes.rawValue)
        XCTAssertNotNil(view(guide) { (f: NSTextField) in f.stringValue == HelpField.codes.help.tip })
        try button(HelpRule.success.rawValue, in: guide).performClick(nil)
        XCTAssertNotNil(view(guide) { (f: NSTextField) in f.stringValue == "9 ÷ 10 = 90%" })
        for rule in HelpRule.allCases {
            try selectTopic(rule.rawValue)
            XCTAssertNotNil(view(guide) { (f: NSTextField) in f.stringValue == rule.note })
        }
        help.setContentSize(help.contentMinSize)
        try selectTopic(HelpRule.schedule.rawValue)
        guide.layoutSubtreeIfNeeded()
        let lastNote = try XCTUnwrap(view(guide) { (f: NSTextField) in f.stringValue == HelpRule.schedule.note })
        let scroller = try XCTUnwrap(lastNote.enclosingScrollView)
        XCTAssertGreaterThan(try XCTUnwrap(scroller.documentView).frame.height, scroller.contentSize.height)
        lastNote.scrollToVisible(lastNote.bounds)
        XCTAssertGreaterThan(scroller.contentView.bounds.minY, 0)
        try selectTopic(HelpField.codes.rawValue)
        XCTAssertEqual(scroller.contentView.bounds.minY, 0, accuracy: 1)
        try addSite("HTTPS", in: list)
        XCTAssertNil(window.attachedSheet)
        let root = list
        let address = try XCTUnwrap(view(root) { (f: NSTextField) in f.accessibilityLabel() == "HTTPS 地址" })
        let input = "https://example.com/status"
        address.stringValue = input
        XCTAssertEqual(address.toolTip, HelpField.address.help.tip)
        XCTAssertEqual(address.accessibilityHelp(), address.toolTip)
        try button("配置说明", in: root).performClick(nil)
        XCTAssertEqual(visibleHelp(), [help])
        XCTAssertTrue((help as? NSPanel)?.worksWhenModal == true)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(address))
        let fieldEditor = try XCTUnwrap(address.currentEditor())
        fieldEditor.insertText("/ready")
        let draft = address.stringValue
        XCTAssertTrue(draft.contains("/ready"))
        XCTAssertTrue(help.isVisible)
        try button("配置说明", in: root).performClick(nil)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: help.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(help.performKeyEquivalent(with: escape))
        XCTAssertTrue(visibleHelp().isEmpty)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(address.stringValue, draft)
        if NSApp.isActive { try await waitUntil { window.isKeyWindow } }
        // A background XCTest host can exercise the field editor without becoming the system key window.
        XCTAssertTrue(window.firstResponder === fieldEditor)
        fieldEditor.insertText("2")
        XCTAssertTrue(address.stringValue.hasSuffix("2"))
        try button("取消", in: root).performClick(nil)
    }
}
