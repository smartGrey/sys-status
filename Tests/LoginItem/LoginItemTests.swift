import AppKit
import ServiceManagement
import XCTest
@testable import StatusBarCore

private final class LoginServiceFixture: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrationFails = false
    func register() throws {
        if registrationFails { throw CocoaError(.featureUnsupported) }
        status = .enabled
    }
    func unregister() throws { status = .notRegistered }
}

final class LoginItemTests: XCTestCase {
    @MainActor func testLoginSwitchTracksServiceApprovalAndErrors() throws {
        _ = NSApplication.shared
        let service = LoginServiceFixture()
        var opened = 0, failures = 0
        let menu = LoginItemMenu(service: service, openSettings: { opened += 1 }, report: { _ in failures += 1 })
        let row = try XCTUnwrap(menu.item.view)
        menu.refresh()
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(menu.item.state, .on)
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(menu.item.state, .off)
        service.registrationFails = true
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(menu.item.state, .off)
        service.status = .requiresApproval
        menu.refresh()
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(menu.item.state, .mixed)
    }
}
