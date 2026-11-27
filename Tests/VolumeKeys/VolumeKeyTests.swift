@testable import StatusBarCore
import AppKit
import XCTest

final class VolumeKeyTests: XCTestCase {
    private func mediaEvent(key: Int, state: Int = 0x0a, repeatKey: Bool = false,
                    flags: CGEventFlags = [], subtype: Int16 = 8) -> CGEvent {
        NSEvent.otherEvent(with: .systemDefined, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)), timestamp: 42,
            windowNumber: 0, context: nil, subtype: subtype,
            data1: (key << 16) | (state << 8) | (repeatKey ? 1 : 0), data2: -1)!.cgEvent!
    }

    func testMediaEventFilter() {
        let modifiers: [CGEventFlags] = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        for key in [0, 1] {
            for state in [0x0a, 0x0b] {
                for repeated in [false, true] {
                    for incidental: CGEventFlags in [[], .maskAlphaShift, .maskSecondaryFn, [.maskAlphaShift, .maskSecondaryFn]] {
                        for combination in 0..<16 {
                            var flags = incidental
                            for i in 0..<4 where combination & (1 << i) != 0 { flags.formUnion(modifiers[i]) }
                            let event = mediaEvent(key: key, state: state, repeatKey: repeated, flags: flags)
                            let originalFlags = event.flags
                            let originalData = NSEvent(cgEvent: event)!.data1
                            let originalTimestamp = event.timestamp
                            let changed = VolumeEventFilter.transform(event)
                            XCTAssertTrue(changed == (combination == 0), "wrong modifier filtering")
                            let expected = combination == 0 ? originalFlags.union([.maskAlternate, .maskShift]) : originalFlags
                            XCTAssertTrue(event.flags == expected, "lost flags or changed a user shortcut")
                            XCTAssertTrue(NSEvent(cgEvent: event)!.data1 == originalData, "media state/repeat changed")
                            XCTAssertTrue(event.timestamp == originalTimestamp, "timestamp changed")
                            XCTAssertTrue(event.type == VolumeEventFilter.mediaEventType, "event type changed")
                            XCTAssertTrue(!VolumeEventFilter.transform(event), "transform must be idempotent")
                        }
                    }
                }
            }
        }
        for key in [2, 3, 7, 16, 17, 18, 19, 20, 21, 0xffff] {
            let event = mediaEvent(key: key)
            let before = event.data
            XCTAssertTrue(!VolumeEventFilter.transform(event), "unrelated media key intercepted")
            XCTAssertTrue(event.data == before, "unrelated media event changed")
        }
        for subtype: Int16 in [0, 1, 7, 9] {
            let event = mediaEvent(key: 0, subtype: subtype)
            XCTAssertTrue(!VolumeEventFilter.transform(event), "unrelated system subtype intercepted")
        }
        for state in [0, 1, 0x0c] {
            XCTAssertTrue(!VolumeEventFilter.transform(mediaEvent(key: 0, state: state)), "invalid media state intercepted")
        }
        for code: CGKeyCode in [0, 103, 111] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
            let before = event.data
            XCTAssertTrue(!VolumeEventFilter.transform(event), "ordinary key intercepted")
            XCTAssertTrue(event.data == before, "ordinary key changed")
        }
    }
}

@MainActor
private final class TestVolumeSession: VolumeKeyListening {
    var notify: ((VolumeKeySessionEvent) -> Void)?
    var starts = 0
    var stops = 0
    var checks = 0
    var failure: VolumeKeyFailure?

    func start(_ notify: @escaping @MainActor @Sendable (VolumeKeySessionEvent) -> Void) {
        starts += 1
        self.notify = notify
    }

    func stop() { stops += 1 }

    func checkHealth() -> VolumeKeyFailure? {
        checks += 1
        return failure
    }
}

extension VolumeKeyTests {
    private func temporaryVolumeStore() throws -> VolumeKeyStore {
        VolumeKeyStore(url: AppDataFile.volumeKeys.url(in: try temporaryDirectory()), defaults: try isolatedDefaults())
    }

    @MainActor
    func testPermissionRetryRestoreAndDisable() throws {
        let store = try temporaryVolumeStore()
        var trusted = false
        var prompts = 0
        let first = TestVolumeSession()
        let control = VolumeKeyMenu(store: store, trusted: { trusted }, prompt: { prompts += 1 },
                                    makeSession: { first })
        control.restore()
        XCTAssertEqual(control.item.state, .off)
        XCTAssertEqual(prompts, 0)
        control.toggle()
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(first.starts, 0)
        trusted = true
        XCTAssertEqual(control.item.state, .off)
        control.toggle()
        control.toggle()
        XCTAssertEqual(first.starts, 1)
        XCTAssertFalse(control.item.isEnabled)
        XCTAssertEqual(control.item.state, .off)
        first.notify?(.ready)
        XCTAssertEqual(control.item.state, .on)
        control.stop()
        XCTAssertEqual(first.stops, 1)

        let second = TestVolumeSession()
        let next = VolumeKeyMenu(store: store, trusted: { true }, prompt: { XCTFail() },
                                 makeSession: { second })
        next.restore()
        XCTAssertEqual(second.starts, 1)
        second.notify?(.ready)
        next.toggle()
        XCTAssertEqual(second.stops, 1)
        XCTAssertEqual(next.item.state, .off)
        next.restore()
        XCTAssertEqual(second.starts, 1)
    }

    @MainActor
    func testStaleCallbacksAndWakeFailure() throws {
        let store = try temporaryVolumeStore()
        let first = TestVolumeSession(), second = TestVolumeSession()
        var sessions = [first, second]
        let workspace = NotificationCenter()
        let control = VolumeKeyMenu(store: store, trusted: { true }, prompt: { XCTFail() },
                                    makeSession: { sessions.removeFirst() }, workspace: workspace)
        control.toggle()
        first.notify?(.unavailable)
        XCTAssertEqual(control.item.state, .off)
        control.toggle()
        first.notify?(.ready)
        XCTAssertFalse(control.item.isEnabled)
        second.notify?(.ready)
        first.notify?(.unavailable)
        XCTAssertEqual(control.item.state, .on)
        second.notify?(.disabled)
        XCTAssertEqual(second.checks, 2)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(second.checks, 3)
        second.failure = .recovery
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(second.stops, 1)
        XCTAssertEqual(control.item.title, "音量键微调（需重新启用）")
        XCTAssertEqual(control.item.state, .off)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(second.checks, 4)

        let next = VolumeKeyMenu(store: store, trusted: { XCTFail(); return true }, prompt: { XCTFail() })
        next.restore()
        XCTAssertEqual(next.item.toolTip, VolumeKeyFailure.recovery.help)
        XCTAssertEqual(next.item.state, .off)
    }

    @MainActor
    func testRevokedPermissionDuringUseAndDuringLaunch() throws {
        let store = try temporaryVolumeStore()
        let workspace = NotificationCenter()
        var trusted = true
        let session = TestVolumeSession()
        let control = VolumeKeyMenu(store: store, trusted: { trusted }, prompt: { XCTFail() },
                                    makeSession: { session }, workspace: workspace)
        control.toggle()
        session.notify?(.ready)
        let enabledPreferences = try store.load()
        trusted = false
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(session.stops, 1)
        XCTAssertEqual(control.item.toolTip, VolumeKeyFailure.permission.help)
        try store.save(enabledPreferences)
        let next = VolumeKeyMenu(store: store, trusted: { false }, prompt: { XCTFail() },
                                 makeSession: { XCTFail(); return TestVolumeSession() })
        next.restore()
        XCTAssertEqual(next.item.toolTip, VolumeKeyFailure.permission.help)
        XCTAssertEqual(next.item.state, .off)
    }
}

extension VolumeKeyTests {
    func testLegacyMigrationIsRetryableAndExistingFileWins() throws {
        let defaults = try isolatedDefaults()
        let directory = try temporaryDirectory()
        let parent = directory.appending(path: "blocked")
        let store = VolumeKeyStore(url: AppDataFile.volumeKeys.url(in: parent), defaults: defaults)
        try Data().write(to: parent)
        defaults.set("recovery", forKey: "volumeKeyAdjustment")
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(defaults.string(forKey: "volumeKeyAdjustment"), "recovery")
        try FileManager.default.removeItem(at: parent)
        XCTAssertEqual(try store.load(), VolumeKeySettings(failure: .recovery))
        XCTAssertNil(defaults.string(forKey: "volumeKeyAdjustment"))

        defaults.set("enabled", forKey: "volumeKeyAdjustment")
        XCTAssertEqual(try store.load(), VolumeKeySettings(failure: .recovery))
        let invalid = Data(#"{"version":2,"enabled":false}"#.utf8)
        try invalid.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), invalid)
    }

    func testLegacyEnabledAndAbsentPreference() throws {
        let defaults = try isolatedDefaults()
        let store = VolumeKeyStore(url: AppDataFile.volumeKeys.url(in: try temporaryDirectory()), defaults: defaults)
        XCTAssertEqual(try store.load(), VolumeKeySettings())
        defaults.set("enabled", forKey: "volumeKeyAdjustment")
        XCTAssertEqual(try store.load(), VolumeKeySettings(enabled: true))
        try store.save(VolumeKeySettings())
        XCTAssertEqual(try store.load(), VolumeKeySettings())
    }
}
