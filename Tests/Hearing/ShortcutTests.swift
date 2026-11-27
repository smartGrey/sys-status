@testable import StatusBarCore
import XCTest
import AppKit
import Carbon

@MainActor
private final class FakeHotKey: HotKeyRegistering {
    var onRelease: (() -> Void)?
    var current: ShortcutBinding?
    var blocked: ShortcutBinding?
    func register(_ binding: ShortcutBinding) -> String? {
        current = nil
        if binding == blocked { return "已占用" }
        current = binding; return nil
    }
    func unregister() { current = nil }
}

final class ShortcutTests: XCTestCase {
    @MainActor private func fixture() -> (HearingShortcutController, FakeHotKey, HearingStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = HearingStore(url: directory.appending(path: "hearing.json"))
        let service = FakeHotKey()
        return (HearingShortcutController(store: store, registration: service), service, store, directory)
    }
    private var first: ShortcutBinding { .init(keyCode: 4, modifiers: UInt32(controlKey | optionKey)) }
    private var second: ShortcutBinding { .init(keyCode: 40, modifiers: UInt32(controlKey | optionKey)) }
    func testValidationAndEncoding() throws {
        XCTAssertNil(first.hearingValidationError)
        XCTAssertNil(ShortcutBinding(keyCode: 90, modifiers: 0).hearingValidationError)
        XCTAssertNotNil(ShortcutBinding(keyCode: 4, modifiers: 0).hearingValidationError)
        XCTAssertNotNil(ShortcutBinding(keyCode: 4, modifiers: UInt32(shiftKey)).hearingValidationError)
        XCTAssertNotNil(ShortcutBinding(keyCode: 63, modifiers: UInt32(cmdKey)).hearingValidationError)
        XCTAssertNotNil(ShortcutBinding(keyCode: 12, modifiers: UInt32(cmdKey)).hearingValidationError)
        XCTAssertNotNil(ShortcutBinding(keyCode: 4, modifiers: UInt32(alphaLock)).hearingValidationError)
        XCTAssertEqual(try JSONDecoder().decode(ShortcutBinding.self, from: JSONEncoder().encode(first)), first)
    }
    @MainActor func testRecordingConflictCancelAndClear() async {
        let (controller, service, store, directory) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(controller.binding)
        controller.beginRecording(); controller.accept(first)
        XCTAssertEqual(service.current, first)
        controller.beginRecording()
        XCTAssertNil(service.current)
        service.blocked = second; controller.accept(second)
        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(controller.binding, first)
        XCTAssertNotNil(controller.message)
        controller.cancelRecording()
        XCTAssertEqual(service.current, first)
        XCTAssertTrue(controller.isRegistered)
        controller.clear()
        XCTAssertNil(service.current); XCTAssertNil(controller.binding)
        let restored = HearingShortcutController(store: store, registration: FakeHotKey())
        XCTAssertNil(restored.binding); restored.shutdown()
    }
    @MainActor func testRestoreFailureRetainsSettingAndRetryWorks() async {
        let (controller, service, store, directory) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.beginRecording(); controller.accept(first); controller.beginRecording()
        service.blocked = first; controller.cancelRecording()
        XCTAssertEqual(controller.binding, first); XCTAssertFalse(controller.isRegistered)
        XCTAssertNotNil(controller.message)
        service.blocked = nil; controller.retryIfNeeded()
        XCTAssertTrue(controller.isRegistered)
        controller.shutdown()
        let other = FakeHotKey(); other.blocked = first
        let restored = HearingShortcutController(store: store, registration: other)
        XCTAssertEqual(restored.binding, first); XCTAssertFalse(restored.isRegistered)
        restored.shutdown()
    }
    @MainActor func testRecordingSleepAndShutdownSuppressActions() async {
        let (controller, service, _, directory) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        var toggles = 0; controller.onToggle = { toggles += 1 }
        controller.beginRecording(); controller.accept(first)
        service.onRelease?(); XCTAssertEqual(toggles, 1)
        controller.beginRecording(); service.onRelease?(); XCTAssertEqual(toggles, 1)
        controller.setSleeping(true); service.onRelease?(); XCTAssertEqual(toggles, 1)
        XCTAssertFalse(controller.isRecording); XCTAssertNil(service.current)
        controller.setSleeping(false); service.onRelease?(); XCTAssertEqual(toggles, 2)
        controller.shutdown(); service.onRelease?(); XCTAssertEqual(toggles, 2)
    }
    @MainActor func testEscapeTabDeleteAndInvalidKeys() async {
        let (controller, _, _, directory) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        func key(_ code: UInt16, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                            isARepeat: repeatKey, keyCode: code)!
        }
        controller.beginRecording(); controller.accept(first); controller.beginRecording()
        XCTAssertTrue(controller.handleRecordingKey(key(4)))
        XCTAssertTrue(controller.isRecording); XCTAssertEqual(controller.binding, first)
        XCTAssertTrue(controller.handleRecordingKey(key(53)))
        XCTAssertFalse(controller.isRecording); XCTAssertEqual(controller.binding, first)
        controller.beginRecording(); XCTAssertFalse(controller.handleRecordingKey(key(48)))
        XCTAssertFalse(controller.isRecording)
        controller.beginRecording(); XCTAssertTrue(controller.handleRecordingKey(key(51, repeatKey: true)))
        XCTAssertEqual(controller.binding, first)
        XCTAssertTrue(controller.handleRecordingKey(key(51))); XCTAssertNil(controller.binding)
    }
    @MainActor func testConflictWithStopwatchNamesOwnerAndRetainsPreviousKey() throws {
        let (_, service, store, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let occupied = second
        let controller = HearingShortcutController(store: store, registration: service) {
            $0 == occupied ? "已用于秒表启停" : nil
        }
        defer { controller.shutdown() }
        controller.beginRecording(); controller.accept(first)
        controller.beginRecording(); controller.accept(second)
        XCTAssertEqual(controller.message, "已用于秒表启停")
        XCTAssertEqual(store.settings.shortcut, first)
        XCTAssertTrue(controller.isRecording)
        controller.cancelRecording()
        XCTAssertEqual(service.current, first)
    }
    @MainActor func testSystemRegistrationIsExclusiveAndCanBeReacquired() async throws {
        let first = SystemHotKey(), second = SystemHotKey()
        defer { first.unregister(); second.unregister() }
        let binding = ShortcutBinding(keyCode: 90, modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey))
        if let error = first.register(binding) { throw XCTSkip("Test combination unavailable: \(error)") }
        XCTAssertNotNil(second.register(binding))
        first.unregister()
        XCTAssertNil(second.register(binding))
    }
    @MainActor func testRemappedModifierFlagsAndPeriodRecording() async {
        let (controller, _, _, directory) = fixture()
        defer { controller.shutdown(); try? FileManager.default.removeItem(at: directory) }
        controller.beginRecording()
        // macOS has already applied the user's Command -> Control remapping.
        // The right-side device bit, Caps Lock and Fn must not enter the binding.
        let flags = NSEvent.ModifierFlags.control.union([.capsLock, .function])
            .union(NSEvent.ModifierFlags(rawValue: 0x2000))
        controller.updateRecordingModifiers(flags)
        XCTAssertEqual(controller.title, "⌃ …")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: 0, context: nil, characters: ".", charactersIgnoringModifiers: ".",
                                    isARepeat: false, keyCode: 47)!
        XCTAssertTrue(controller.handleRecordingKey(event))
        XCTAssertEqual(controller.binding, ShortcutBinding(keyCode: 47, modifiers: UInt32(controlKey)))
        XCTAssertTrue(controller.isRegistered)
        XCTAssertEqual(controller.title, "⌃.")
    }
}
