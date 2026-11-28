@testable import StatusBarCore
import AppKit
import Carbon
import XCTest

final class StopwatchStateTests: XCTestCase {
    func testExclusiveHandoffUsesRunningEntryInsteadOfFocusAndWraps() throws {
        var (state, first, second, last) = try threeEntries()
        state.toggle(first, at: 10)
        state.select(last)
        XCTAssertEqual(state.presentation(at: 13).focus, last)

        state.advance(at: 13.75)
        var snapshot = state.snapshot(at: 14.25)
        XCTAssertEqual(snapshot.entries.map(\.elapsed), [3.75, 0.5, 0])
        XCTAssertEqual(snapshot.focus, second)
        XCTAssertEqual(running(state, at: 14.25), [second])

        state.advance(at: 14.5)
        state.advance(at: 14.5)
        state.advance(at: 14.5)
        snapshot = state.snapshot(at: 15.5)
        XCTAssertEqual(snapshot.entries.map(\.elapsed), [3.75, 1.75, 0])
        XCTAssertEqual(snapshot.focus, second)
        XCTAssertEqual(running(state, at: 15.5), [second])

        state.select(last)
        state.toggle(state.settings.focus, at: 16)
        XCTAssertEqual(running(state, at: 17), [last])
        state.toggle(last, at: 17.25)
        state.advance(at: 17.25)
        XCTAssertEqual(state.settings.focus, first)
        XCTAssertTrue(running(state, at: 22).isEmpty)
        XCTAssertEqual(state.snapshot(at: 22).entries.map(\.elapsed), [3.75, 2.25, 1.25])
    }

    func testParallelAccumulationFocusAndModeHint() throws {
        var (state, first, second, last) = try threeEntries()
        state.setMode(.parallel)
        state.toggle(first, at: 20)
        state.toggle(second, at: 21)
        state.toggle(last, at: 22)
        state.advance(at: 23)
        XCTAssertEqual(state.settings.focus, first)
        XCTAssertEqual(state.snapshot(at: 23).entries.map(\.elapsed), [3, 2, 1])

        state.setMode(.exclusive)
        XCTAssertEqual(state.settings.mode, .parallel)
        XCTAssertEqual(state.settings.focus, first)
        XCTAssertEqual(state.presentation(at: 25).modeHint, "请先暂停 2 个秒表")
        state.toggle(first, at: 25)
        XCTAssertEqual(state.presentation(at: 26).modeHint, "请先暂停 1 个秒表")
        state.reset(second)
        XCTAssertNil(state.presentation(at: 26).modeHint)
        XCTAssertEqual(state.settings.mode, .parallel)

        state.setMode(.exclusive)
        XCTAssertEqual(state.settings.mode, .exclusive)
        XCTAssertEqual(state.settings.focus, first)
        XCTAssertEqual(running(state, at: 27), [last])
        state.setMode(.parallel)
        XCTAssertEqual(state.snapshot(at: 27).entries.map(\.elapsed), [5, 0, 5])
    }

    func testNamingAdditionDeletionAndResetInvariants() throws {
        var (state, first, second, last) = try threeEntries()
        XCTAssertNil(state.add())
        state.rename(first, to: "网速🌤️计时列表")
        XCTAssertEqual(state.settings.entries[0].name, "网速🌤️计时")
        state.rename(first, to: " \n ")
        XCTAssertEqual(state.settings.entries[0].name, "")
        XCTAssertTrue(state.settings.isValid)
        state.select(second)
        state.toggle(second, at: 2)
        state.remove(second)
        XCTAssertEqual(state.settings.focus, last)
        XCTAssertTrue(running(state, at: 10).isEmpty)
        state.toggle(first, at: 10)
        state.select(last)
        state.reset(first)
        XCTAssertEqual(state.settings.focus, last)
        XCTAssertFalse(try XCTUnwrap(state.presentation(at: 12).readings.first).canReset)
        state.remove(last)
        XCTAssertEqual(state.settings.focus, first)
        state.remove(first)
        state.advance(at: 13)
        XCTAssertEqual(state.settings.entries.map(\.id), [first])
        XCTAssertEqual(state.settings.focus, first)
        XCTAssertFalse(state.hasRunningEntries)
    }

    func testClockFormatsAndLosslessSubsecondResume() {
        let expected = [
            (0, "0s", "00:00:00"), (59, "59s", "00:00:59"), (60, "1m00s", "00:01:00"),
            (3599, "59m59s", "00:59:59"), (3600, "1h00m", "01:00:00"), (4279, "1h11m", "01:11:19"),
            (360061, "100h01m", "100:01:01")
        ]
        for (seconds, compact, full) in expected {
            let time = StopwatchTime(seconds: seconds)
            XCTAssertEqual(time.compact, compact)
            XCTAssertEqual(time.full, full)
            XCTAssertEqual(time.total, "\(seconds)s")
        }
        var state = StopwatchState()
        let first = state.settings.focus
        state.setEnabled(true, at: 1)
        for time in [2.0, 5.0, 8.0] {
            state.toggle(first, at: time)
            state.advance(at: time + 0.25)
            state.toggle(first, at: time + 0.5)
        }
        XCTAssertEqual(state.snapshot(at: 10).entries[0].elapsed, 1.5)
        XCTAssertEqual(state.presentation(at: 10).readings[0].seconds, 1)
    }

    private func threeEntries() throws -> (StopwatchState, UUID, UUID, UUID) {
        var state = StopwatchState()
        state.setEnabled(true, at: 0)
        let first = state.settings.focus
        let second = try XCTUnwrap(state.add())
        let last = try XCTUnwrap(state.add())
        return (state, first, second, last)
    }

    private func running(_ state: StopwatchState, at time: TimeInterval) -> [UUID] {
        state.presentation(at: time).readings.filter(\.isRunning).map(\.id)
    }
}

final class StopwatchIntegrationTests: XCTestCase {
    @MainActor
    func testCheckpointDisableSystemSleepAndRestartWithNoOfflineTime() throws {
        try withStore { store in
            var time = 50.0
            let controller = StopwatchController(store: store, now: { time })
            controller.restore()
            defer { controller.stopForExit() }
            XCTAssertFalse(controller.enabled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path(percentEncoded: false)))
            controller.setEnabled(true)
            let first = controller.presentation.focus
            let second = try XCTUnwrap(controller.add())
            controller.rename(first, to: "阅读")
            controller.setMode(.parallel)
            controller.toggle(first)

            time = 54.9
            controller.tick()
            XCTAssertEqual(controller.presentation.readings[0].seconds, 4)
            XCTAssertEqual(try store.load().entries[0].elapsed, 0)
            time = 55.2
            controller.tick()
            let checkpoint = try store.load()
            XCTAssertEqual(checkpoint.entries[0].elapsed, 5.2, accuracy: 0.001)
            XCTAssertEqual(checkpoint.focus, first)
            XCTAssertEqual(checkpoint.entries[1].id, second)
            let recovered = StopwatchState(settings: checkpoint).presentation(at: 2000)
            XCTAssertFalse(recovered.readings[0].isRunning)
            XCTAssertEqual(recovered.readings[0].seconds, 5)

            controller.toggle(second)
            time = 58
            controller.pauseForSystemSleep()
            let sleep = try store.load()
            XCTAssertTrue(sleep.enabled)
            XCTAssertEqual(sleep.entries[0].elapsed, 8)
            XCTAssertEqual(sleep.entries[1].elapsed, 2.8, accuracy: 0.001)
            XCTAssertEqual(sleep.focus, second)

            time = 950
            controller.toggle(second)
            time = 951
            controller.setEnabled(false)
            let disabled = try store.load()
            XCTAssertFalse(disabled.enabled)
            XCTAssertEqual(disabled.entries[1].elapsed, 3.8, accuracy: 0.001)
            controller.setEnabled(true)
            XCTAssertEqual(controller.presentation.focus, second)
            XCTAssertTrue(controller.presentation.readings.allSatisfy { !$0.isRunning })
            controller.toggle(second)
            time = 954.5
            controller.stopForExit()
            let restart = StopwatchController(store: store, now: { 1800 })
            restart.restore()
            defer { restart.stopForExit() }
            XCTAssertTrue(restart.enabled)
            XCTAssertEqual(restart.presentation.readings.map(\.name), ["阅读", "秒表2"])
            XCTAssertEqual(restart.presentation.readings.map(\.seconds), [8, 7])
            XCTAssertEqual(restart.presentation.focus, second)
            XCTAssertEqual(restart.presentation.mode, .parallel)
            XCTAssertTrue(restart.presentation.readings.allSatisfy { !$0.isRunning })
        }
    }

    @MainActor
    func testSystemHotKeyConflictDuplicateRollbackAndRelease() throws {
        _ = NSApplication.shared
        try withStore { store in
            let previous = shortcut(kVK_ANSI_Keypad9)
            let occupied = shortcut(kVK_ANSI_Keypad8)
            let existing = StopwatchHotKeys()
            defer { existing.stop() }
            try existing.replace(.switchFocus, with: occupied) { }

            let controller = StopwatchController(store: store)
            controller.restore()
            controller.setEnabled(true)
            defer { controller.stopForExit() }

            try controller.replaceShortcut(.toggle, with: previous)
            XCTAssertThrowsError(try controller.replaceShortcut(.switchFocus, with: previous)) { error in
                guard case StopwatchHotKeyError.duplicate = error else { return XCTFail("\(error)") }
            }
            XCTAssertThrowsError(try controller.replaceShortcut(.toggle, with: occupied)) { error in
                guard case StopwatchHotKeyError.occupied = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(controller.presentation.shortcuts[.toggle], previous)
            XCTAssertEqual(try store.load().shortcuts[.toggle], previous)
            XCTAssertThrowsError(try existing.replace(.toggle, with: previous) { })

            controller.setEnabled(false)
            try existing.replace(.toggle, with: previous) { }
            XCTAssertEqual(try store.load().shortcuts[.toggle], previous)
            try existing.replace(.toggle, with: nil) { }
            controller.setEnabled(true)

            XCTAssertThrowsError(try existing.replace(.toggle, with: previous) { })
            try controller.replaceShortcut(.toggle, with: nil)
            try existing.replace(.toggle, with: previous) { }
            XCTAssertNil(try store.load().shortcuts[.toggle])
        }
    }

    @MainActor
    func testHotKeyRollsBackWhenSavingFails() throws {
        _ = NSApplication.shared
        let registry = StopwatchHotKeys()
        let verifier = StopwatchHotKeys()
        defer { registry.stop(); verifier.stop() }
        let original = shortcut(kVK_ANSI_Keypad7)
        let replacement = shortcut(kVK_ANSI_Keypad6)
        try registry.replace(.toggle, with: original) { }
        XCTAssertThrowsError(try registry.replace(.toggle, with: replacement) { throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try verifier.replace(.toggle, with: original) { })
        try verifier.replace(.toggle, with: replacement) { }
    }

    @MainActor
    func testStatusItemWidthAndAccessiblePanelCommand() throws {
        _ = NSApplication.shared
        let entry = StatusEntry()
        defer { NSStatusBar.system.removeStatusItem(entry.item) }
        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "StopWatch", action: nil, keyEquivalent: "")
        menu.addItem(toggleItem)
        entry.installMenu(menu)
        XCTAssertNil(menu.item(withTitle: "打开秒表面板"))
        entry.updateNetwork(speed: nil, connectivity: ConnectivityState())
        let original = entry.item.length
        var state = StopwatchState()
        state.setEnabled(true, at: 0)
        let first = state.settings.focus
        state.toggle(first, at: 0)

        var widths: [CGFloat] = []
        for time in [0, 9, 10, 59, 60, 119, 600, 3599, 3600, 35999, 36000] {
            entry.updateStopwatch(state.presentation(at: Double(time)))
            widths.append(entry.item.length)
        }
        XCTAssertEqual(widths[0], widths[1])
        XCTAssertLessThan(widths[1], widths[2])
        XCTAssertEqual(widths[2], widths[3])
        XCTAssertEqual(widths[4], widths[5])
        XCTAssertLessThan(widths[5], widths[6])
        XCTAssertEqual(widths[6], widths[7])
        XCTAssertEqual(Set(widths[8..<10]).count, 1)
        XCTAssertLessThan(widths[9], widths[10])
        XCTAssertTrue(widths.allSatisfy { $0 > original })

        let second = try XCTUnwrap(state.add())
        let third = try XCTUnwrap(state.add())
        state.rename(first, to: "阅读计时表")
        state.rename(second, to: "写作计时表")
        state.rename(third, to: "散步计时表")
        entry.updateStopwatch(state.presentation(at: 3600))
        let button = try XCTUnwrap(entry.item.button)
        XCTAssertTrue(try XCTUnwrap(button.accessibilityValue() as? String).contains("散步计时表"))
        XCTAssertEqual(button.accessibilityCustomActions()?.map(\.name), ["打开网络状况", "打开秒表面板", "打开总菜单"])
        XCTAssertLessThan(entry.networkRegion(of: button.bounds).width, button.bounds.width)
        XCTAssertNil(entry.item.menu)

        let focusedWidth = entry.item.length
        let previousImage = try XCTUnwrap(button.image)
        state.select(second)
        entry.updateStopwatch(state.presentation(at: 3600))
        XCTAssertEqual(entry.item.length, focusedWidth)
        XCTAssertFalse(button.image === previousImage)
        XCTAssertTrue(try XCTUnwrap(button.accessibilityValue() as? String).contains("写作计时表，0 秒，待开始，快捷键焦点"))

        entry.updateStopwatch(nil)
        XCTAssertEqual(entry.item.length, original)
        XCTAssertNil(entry.item.menu)
        XCTAssertNotNil(button.action)
        XCTAssertEqual(button.accessibilityCustomActions()?.map(\.name), ["打开网络状况", "打开总菜单"])
        XCTAssertEqual(button.accessibilityLabel(), "网络状况")
    }

    @MainActor
    func testBlankNamesKeepTimeLabelsAndSurviveReload() throws {
        _ = NSApplication.shared
        try withStore { store in
            var state = StopwatchState()
            state.setEnabled(true, at: 0)
            let first = state.settings.focus
            let second = try XCTUnwrap(state.add())
            state.rename(first, to: "")
            state.rename(second, to: "阅读")
            let mixed = StopwatchStatusFace(state.presentation(at: 0))
            state.rename(second, to: "   ")
            try store.save(state.snapshot(at: 0))
            let restored = StopwatchState(settings: try store.load())
            XCTAssertEqual(restored.settings.entries.map(\.name), ["", ""])
            XCTAssertEqual(restored.settings.entries.map(\.id), [first, second])
            let empty = StopwatchStatusFace(restored.presentation(at: 0))
            XCTAssertLessThan(empty.width, mixed.width)
            var single = restored
            single.remove(second)
            let one = StopwatchStatusFace(single.presentation(at: 0))
            // There is only one 3-point marker slot and one 3-point gap.
            XCTAssertEqual(empty.width, 2 * one.width + 6)
            single.toggle(first, at: 1)
            XCTAssertTrue(single.presentation(at: 1).readings[0].canReset)
            single.reset(first)
            XCTAssertFalse(single.presentation(at: 1).readings[0].canReset)
        }
    }

    @MainActor
    func testFocusTransitionTransfersOnlyOneMarkerWidthWhenInterrupted() throws {
        let initial = StopwatchStatusFace.FocusTransition(from: [1, 0, 0], to: [0, 1, 0], start: 0)
        let halfway = try XCTUnwrap(initial.amounts(at: 0.07))
        XCTAssertEqual(halfway, [0.5, 0.5, 0])

        let interrupted = StopwatchStatusFace.FocusTransition(from: halfway, to: [0, 0, 1], start: 0.07)
        XCTAssertEqual(interrupted.amounts(at: 0.07), halfway)
        for offset in [0.01, 0.035, 0.07, 0.12, 0.13] {
            let amounts = try XCTUnwrap(interrupted.amounts(at: 0.07 + offset))
            XCTAssertEqual(amounts.reduce(0, +), 1, accuracy: 0.000001)
        }
        XCTAssertNil(interrupted.amounts(at: 0.22))
    }

    @MainActor
    func testCompactPanelFitsSharedColumnsAndBothShortcuts() throws {
        _ = NSApplication.shared
        let content = StopwatchPanelContent()
        var settings = StopwatchSettings()
        settings.entries[0].name = "阅读计时器"
        func update(recording: StopwatchAction? = nil) -> NSSize {
            let presentation = StopwatchState(settings: settings).presentation(at: 0)
            return content.update(presentation, availableWidth: 800, recording: recording, issues: [:], hasSaveError: false)
        }

        for count in 1...3 {
            if count > 1 { settings.entries.append(StopwatchEntry(name: "五个中文字")) }
            for elapsed in [0.0, 59, 3600, 359_999] {
                settings.entries[0].elapsed = elapsed
                XCTAssertEqual(update().width, 452)
            }
        }
        settings.entries[0].elapsed = 123_456_789
        XCTAssertGreaterThan(update().width, 452)
        settings.shortcuts[.switchFocus] = shortcut(kVK_ANSI_Keypad7)
        settings.shortcuts[.toggle] = shortcut(kVK_ANSI_Keypad6)
        for recording in [nil, StopwatchAction.toggle] {
            let size = update(recording: recording)
            let rows = content.subviews.compactMap { $0 as? StopwatchPanelRow }
            XCTAssertEqual(rows.count, 3)
            var previousColumns: [NSRect]?
            for row in rows {
                let cells = row.subviews.filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }
                XCTAssertEqual(cells.count, 6)
                let frames = cells.map(\.frame)
                if let previousColumns { XCTAssertEqual(frames, previousColumns) }
                previousColumns = frames
                for (a, b) in zip(frames, frames.dropFirst()) { XCTAssertLessThan(a.maxX, b.minX) }
                for field in cells.compactMap({ $0 as? NSTextField }) {
                    XCTAssertGreaterThanOrEqual(field.frame.width, field.intrinsicContentSize.width)
                }
                XCTAssertLessThan(row.frame.maxX, size.width)
            }
            let controls = content.subviews.filter { ($0 is NSButton || $0 is NSSegmentedControl) && !$0.isHidden }
                .map(\.frame).sorted { $0.minX < $1.minX }
            XCTAssertEqual(controls.count, 5)
            for (a, b) in zip(controls, controls.dropFirst()) { XCTAssertLessThanOrEqual(a.maxX, b.minX) }
            XCTAssertLessThan(try XCTUnwrap(controls.last).maxX, size.width)
        }
    }

    @MainActor
    func testPanelEditingModeRejectionAndShortcutGuidance() throws {
        let app = NSApplication.shared
        try withStore { store in
            let controller = StopwatchController(store: store)
            controller.restore()
            controller.setEnabled(true)
            defer { controller.stopForExit() }

            let screen = try XCTUnwrap(NSScreen.main)
            let anchor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 70, height: 20)
            controller.togglePanel(under: anchor, on: screen)
            let window = try XCTUnwrap(app.windows.first { $0.isVisible && $0.title == "StopWatch" })
            let content = try XCTUnwrap(window.contentView)
            @MainActor func descendants(of view: NSView) -> [NSView] {
                view.subviews + view.subviews.flatMap { descendants(of: $0) }
            }

            let add = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSButton }.first { $0.title == "添加秒表" })
            add.performClick(nil)
            let field = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSTextField }.first {
                $0.isEditable && !$0.isHidden
            })
            let editor = try XCTUnwrap(field.currentEditor())
            XCTAssertEqual(editor.string, "秒表2")
            XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: editor.string.utf16.count))

            controller.setMode(.parallel)
            for row in controller.presentation.readings { controller.toggle(row.id) }
            let mode = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSSegmentedControl }.first)
            let action = try XCTUnwrap(mode.action)
            for _ in 0..<2 {
                mode.selectedSegment = 0
                app.sendAction(action, to: mode.target, from: mode)
                XCTAssertEqual(mode.selectedSegment, 1)
                XCTAssertEqual(controller.presentation.modeHint, "请先暂停 1 个秒表")
            }

            let keycap = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "启停快捷键"
            })
            let originalHeight = window.frame.height
            XCTAssertLessThan(keycap.frame.width, 100)
            content.layoutSubtreeIfNeeded()
            let addRect = add.convert(add.bounds, to: content)
            let modeRect = mode.convert(mode.bounds, to: content)
            let keyRect = keycap.convert(keycap.bounds, to: content)
            XCTAssertGreaterThan(addRect.minY, modeRect.maxY)
            XCTAssertLessThan(modeRect.maxX, keyRect.minX)
            XCTAssertEqual(modeRect.midY, keyRect.midY, accuracy: 2)
            keycap.performClick(nil)
            XCTAssertEqual(keycap.title, "按下快捷键")
            XCTAssertEqual(window.frame.height, originalHeight)
            let binding = shortcut(kVK_ANSI_Keypad4)
            try controller.replaceShortcut(.toggle, with: binding)
            keycap.performClick(nil)
            let clear = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "清除启停快捷键"
            })
            XCTAssertFalse(clear.isHidden)
            clear.performClick(nil)
            XCTAssertTrue(clear.isHidden)
            XCTAssertNil(controller.presentation.shortcuts[.toggle])
            XCTAssertNil(try store.load().shortcuts[.toggle])
            XCTAssertEqual(keycap.title, "未设置")
            XCTAssertEqual(window.frame.height, originalHeight)

        }
    }

    func testCorruptDataIsRejectedWithoutReplacingIt() throws {
        try withStore { store in
            let invalid = Data("{invalid".utf8)
            try invalid.write(to: store.url)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(try Data(contentsOf: store.url), invalid)
        }
    }

    private func shortcut(_ code: Int) -> ShortcutBinding {
        ShortcutBinding(keyCode: UInt16(code), modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
    }

    private func withStore<T>(_ run: (StopwatchStore) throws -> T) throws -> T {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try run(StopwatchStore(url: folder.appending(path: "stopwatch.json")))
    }

}
