import AppKit
import XCTest

@MainActor
final class HearingIntegrationTests: XCTestCase {
    private func fixture() -> HearingStore {
        HearingStore(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/hearing.json"))
    }

    func testMasterSwitchStopsRuntimeAndRetainsPreferencesThroughRapidChanges() async throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try store.update { $0.audio.thresholdDB = 14; $0.audio.noiseReductionDB = 26 }
        let tool = HearingController(store: store)
        tool.restore()
        XCTAssertNil(tool.model)
        try tool.setEnabled(true)
        let first = try XCTUnwrap(tool.model)
        XCTAssertEqual(first.preferences.thresholdDB, 14)
        try tool.setEnabled(false)
        try tool.setEnabled(true)
        try tool.setEnabled(false)
        try tool.setEnabled(true)
        for _ in 0..<100 where tool.model == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(tool.model)
        XCTAssertFalse(tool.model === first)
        XCTAssertEqual(tool.model?.preferences.noiseReductionDB, 26)
        XCTAssertNil(tool.model?.shortcuts.binding)
        try tool.setEnabled(false)
        await tool.stop()?.value
        XCTAssertNil(tool.model)
        let restored = HearingStore(url: store.url)
        try restored.load()
        XCTAssertFalse(restored.settings.enabled)
        XCTAssertEqual(restored.settings.audio, store.settings.audio)
    }

    func testPermissionCompletingAfterShutdownCannotStartCalibration() async throws {
        let store = fixture()
        let shortcuts = HearingShortcutController(store: store)
        var granted = false
        var request: CheckedContinuation<Bool, Never>?
        let model = HearingModel(store: store, shortcuts: shortcuts, authorization: { granted ? .authorized : .notDetermined },
                                 requestAccess: { await withCheckedContinuation { request = $0 } })
        model.measureBackground()
        await Task.yield()
        let completion = try XCTUnwrap(request)
        let stop = model.shutdown()
        granted = true
        completion.resume(returning: true)
        await stop.value
        await Task.yield()
        XCTAssertFalse(model.calibrating)
        XCTAssertFalse(model.isListening)
        XCTAssertEqual(model.handle.snapshot().running, 0)
    }

    func testCorruptSettingsAreNotOverwrittenByMenu() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try store.update { $0.enabled = true }
        let invalid = Data("damaged".utf8)
        try invalid.write(to: store.url)
        let tool = HearingController(store: store)
        tool.restore()
        XCTAssertThrowsError(try tool.setEnabled(true))
        XCTAssertNil(tool.model)
        XCTAssertEqual(try Data(contentsOf: store.url), invalid)
    }

    func testOptionalRegionsShareOneButtonAndIconUpdatesKeepWidth() throws {
        _ = NSApplication.shared
        let entry = StatusEntry()
        defer { NSStatusBar.system.removeStatusItem(entry.item) }
        entry.installMenu(NSMenu())
        entry.updateNetwork(speed: nil, connectivity: ConnectivityState())
        let base = entry.item.length
        entry.updateHearing(.init(icon: .init(enabled: false, passing: false, level: 0), title: "已关闭"))
        XCTAssertEqual(entry.item.length, base + 25)
        entry.updateHearing(.init(icon: .init(enabled: true, passing: true, level: 20), title: "透传中"))
        XCTAssertEqual(entry.item.length, base + 25)
        var state = StopwatchState()
        state.setEnabled(true, at: 0)
        entry.updateStopwatch(state.presentation(at: 0))
        let frame = CGRect(x: -400, y: 600, width: entry.item.length + 8, height: 24)
        let audio = try XCTUnwrap(entry.region(.hearing, of: frame))
        let network = entry.networkRegion(of: frame)
        let watch = try XCTUnwrap(entry.region(.stopwatch, of: frame))
        XCTAssertEqual(audio.minX, frame.minX)
        XCTAssertEqual(audio.maxX, network.minX)
        XCTAssertEqual(network.maxX, watch.minX)
        XCTAssertEqual(watch.maxX, frame.maxX)
        XCTAssertEqual(entry.item.button?.accessibilityCustomActions()?.count, 2)
        entry.updateStopwatch(nil)
        XCTAssertTrue(entry.isSplit)
        entry.updateHearing(nil)
        XCTAssertFalse(entry.isSplit)
        XCTAssertEqual(entry.item.length, base)
    }
}
