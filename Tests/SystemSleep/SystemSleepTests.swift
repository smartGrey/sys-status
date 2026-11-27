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
        }, waitForPowerChange: { await withCheckedContinuation { powerChange = $0 } }, report: { failures.append($0) })
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
        }, waitForPowerChange: {}, report: { reports.append($0) })
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
}
