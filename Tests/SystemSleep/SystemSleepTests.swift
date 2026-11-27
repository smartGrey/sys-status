import AppKit
import Security
import XCTest
@testable import StatusBarCore

final class SystemSleepTests: XCTestCase {
    @MainActor
    func testSleepSwitchFollowsSystemAndSerializesWrites() async throws {
        var actual: Bool? = false
        var requests: [Bool] = []
        var authorize: CheckedContinuation<Void, Error>?
        var failures: [String] = []
        var powerChange: CheckedContinuation<Void, Never>?
        let control = SystemSleepMenu(read: { actual }, write: { requested in
            requests.append(requested)
            try await withCheckedThrowingContinuation { authorize = $0 }
        }, waitForPowerChange: { await withCheckedContinuation { powerChange = $0 } }, report: { failures.append($0.title) })
        XCTAssertEqual(control.item.state, .off)
        control.toggle()
        control.refresh()
        control.toggle()
        XCTAssertFalse(control.item.isEnabled)
        try await waitUntil { authorize != nil }
        XCTAssertEqual(requests, [true])
        authorize?.resume()
        authorize = nil
        // A successful command can return before the kernel has applied it.
        try await waitUntil { powerChange != nil }
        XCTAssertFalse(control.item.isEnabled)
        actual = true
        powerChange?.resume()
        try await waitUntil { control.item.isEnabled }
        XCTAssertEqual(control.item.state, .on)

        control.toggle()
        try await waitUntil { authorize != nil }
        authorize?.resume(throwing: CancellationError())
        authorize = nil
        try await waitUntil { control.item.isEnabled }
        XCTAssertEqual(control.item.state, .on)
        XCTAssertTrue(failures.isEmpty)
        control.toggle()
        try await waitUntil { authorize != nil }
        actual = false
        authorize?.resume()
        try await waitUntil { control.item.isEnabled }
        XCTAssertEqual(control.item.state, .off)
        XCTAssertEqual(requests, [true, false, false])

        actual = true
        control.toggle() // The action shown in the open menu has already taken effect externally.
        XCTAssertEqual(control.item.state, .on)
        XCTAssertTrue(control.item.isEnabled)
        actual = nil
        control.refresh()
        XCTAssertEqual(control.item.state, .mixed)
        XCTAssertTrue(control.item.title.contains("状态待确认"))
        XCTAssertFalse(control.item.isEnabled)
        control.toggle()
        actual = false
        control.refresh()
        XCTAssertTrue(control.item.isEnabled)
        XCTAssertEqual(control.item.state, .off)
        XCTAssertEqual(requests.count, 3)
    }

    @MainActor
    func testSleepSwitchReportsFailedWritesAndReadsBackActualState() async throws {
        var system: Bool? = true
        var reports: [String] = []
        var commandFails = true
        let control = SystemSleepMenu(read: { system }, write: { _ in
            if commandFails { throw CocoaError(.fileWriteNoPermission) }
        }, waitForPowerChange: {}, report: { reports.append($0.title) })
        control.toggle()
        try await waitUntil { reports.count == 1 }
        XCTAssertEqual(control.item.state, .on)
        commandFails = false
        control.toggle()
        try await waitUntil { reports.count == 2 }
        XCTAssertEqual(control.item.state, .on)
        system = false
        control.refresh()
        XCTAssertEqual(control.item.state, .off)
    }

    func testSleepServiceRequirementsCompile() {
        for identifier in [SleepService.appIdentifier, SleepService.label] {
            let source = SleepService.signingRequirement(for: identifier, team: "ABCDEFGHIJ")
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(source as CFString, [], &requirement), errSecSuccess)
            XCTAssertNotNil(requirement)
        }
    }

    @MainActor
    func testLostReplyReportsTheVerifiedStateInBothDirectionsWithoutRetrying() async throws {
        for target in [true, false] {
            var system = !target
            var writes = 0
            var notices: [SleepNotice] = []
            let control = SystemSleepMenu(read: { system }, write: { value in
                XCTAssertEqual(value, target)
                writes += 1
                throw SleepCommunicationError("连接中断")
            }, waitForPowerChange: { system = target }, report: { notices.append($0) })
            control.toggle()
            try await waitUntil { !notices.isEmpty }
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(control.item.state, target ? .on : .off)
            XCTAssertEqual(notices.first?.title, target ? "系统睡眠已禁用" : "系统睡眠已恢复")
            XCTAssertTrue(notices[0].detail.contains("无需重试"))
        }
    }

    @MainActor
    func testLostReplyWithUnchangedOrUnreadableState() async throws {
        for afterWrite in [false, nil] as [Bool?] {
            var system: Bool? = false
            var notices: [SleepNotice] = []
            let control = SystemSleepMenu(read: { system }, write: { _ in
                system = afterWrite
                throw SleepCommunicationError("连接中断")
            }, waitForPowerChange: {}, report: { notices.append($0) })
            control.toggle()
            try await waitUntil { !notices.isEmpty }
            XCTAssertEqual(control.item.state, afterWrite == nil ? .mixed : .off)
            XCTAssertEqual(notices.first?.title, afterWrite == nil ? "系统睡眠状态待确认" : "未能切换系统睡眠")
            XCTAssertEqual(control.item.isEnabled, afterWrite != nil)
        }
    }
}
