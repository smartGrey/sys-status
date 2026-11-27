import ServiceManagement
import XCTest
@testable import StatusBarCore

@MainActor
private final class TestSleepService: SleepServiceManaging {
    var status: SMAppService.Status
    var registeredStatus = SMAppService.Status.enabled
    var registrationError: Error?
    var events: [String] = []

    init(_ status: SMAppService.Status) { self.status = status }

    func unregister() async throws {
        events.append("stopping")
        await Task.yield()
        status = .notRegistered
        events.append("stopped")
    }

    func register() throws {
        events.append("register")
        status = registeredStatus
        if let registrationError { throw registrationError }
    }
}

@MainActor
final class SleepRegistrationTests: XCTestCase {
    func testFingerprintTracksSignedExecutableAndLaunchPlistIndependentlyOfMainApp() throws {
        let fm = FileManager.default
        let app = try temporaryDirectory().appending(path: "Fixture.app")
        let contents = app.appending(path: "Contents")
        let executable = contents.appending(path: "MacOS/NetRateSleepHelper")
        let plist = contents.appending(path: "Library/LaunchDaemons/\(SleepService.label).plist")
        for directory in [executable.deletingLastPathComponent(), plist.deletingLastPathComponent()] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let info = ["CFBundleIdentifier": "test.sleep.fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        try fm.copyItem(at: URL(filePath: "/usr/bin/true"), to: executable)
        try Data("first plist".utf8).write(to: plist)
        let bundle = try XCTUnwrap(Bundle(url: app))
        func fingerprint() throws -> String {
            try SleepRegistration.fingerprint(in: bundle, requirement: "anchor apple")
        }
        let original = try fingerprint()
        try Data("changed app".utf8).write(to: contents.appending(path: "MacOS/Fixture"))
        XCTAssertEqual(try fingerprint(), original)
        try Data("updated plist".utf8).write(to: plist)
        let changedPlist = try fingerprint()
        XCTAssertNotEqual(changedPlist, original)
        try fm.removeItem(at: executable)
        try fm.copyItem(at: URL(filePath: "/usr/bin/false"), to: executable)
        XCTAssertNotEqual(try fingerprint(), changedPlist)
        XCTAssertThrowsError(try SleepRegistration.fingerprint(in: bundle, requirement: "identifier \"wrong\""))
    }

    func testLegacyRegistrationAndChangedHelperRefreshOnlyOnce() async throws {
        let service = TestSleepService(.enabled)
        let defaults = try isolatedDefaults()
        for fingerprint in ["A", "A", "B", "B"] {
            try await SleepRegistration.prepare(service, fingerprint: fingerprint, defaults: defaults)
        }
        XCTAssertEqual(service.events, ["stopping", "stopped", "register", "stopping", "stopped", "register"])
    }

    func testApprovalCanBeCompletedOnTheNextClickWithoutRegisteringAgain() async throws {
        let defaults = try isolatedDefaults()
        let service = TestSleepService(.notFound)
        service.registeredStatus = .requiresApproval
        service.registrationError = NSError(domain: SMAppServiceErrorDomain, code: Int(kSMErrorLaunchDeniedByUser))
        for _ in 0..<2 {
            do {
                try await SleepRegistration.prepare(service, fingerprint: "new", defaults: defaults)
                XCTFail("Expected approval instructions")
            } catch is SleepRegistration.NeedsApproval {}
        }
        service.status = .enabled
        try await SleepRegistration.prepare(service, fingerprint: "new", defaults: defaults)
        XCTAssertEqual(service.events, ["register"])
        service.status = .requiresApproval
        do {
            try await SleepRegistration.prepare(service, fingerprint: "later", defaults: defaults)
            XCTFail("Expected the user's revoked approval to be respected")
        } catch is SleepRegistration.NeedsApproval {}
        XCTAssertEqual(service.events, ["register"])
    }

    func testFailedReplacementCanRecoverAfterUnregistering() async throws {
        let service = TestSleepService(.enabled)
        let defaults = try isolatedDefaults()
        service.registeredStatus = .notRegistered
        service.registrationError = CocoaError(.fileNoSuchFile)
        do {
            try await SleepRegistration.prepare(service, fingerprint: "new", defaults: defaults)
            XCTFail("Expected registration failure")
        } catch is CocoaError {}
        service.registrationError = nil
        service.registeredStatus = .enabled
        try await SleepRegistration.prepare(service, fingerprint: "new", defaults: defaults)
        XCTAssertEqual(service.events, ["stopping", "stopped", "register", "register"])
    }

    func testRetriesTemporaryRegistrationDenialWithoutStoppingTheServiceAgain() async throws {
        let defaults = try isolatedDefaults()
        let service = TestSleepService(.enabled)
        service.registeredStatus = .notRegistered
        service.registrationError = NSError(domain: SMAppServiceErrorDomain, code: Int(POSIXErrorCode.EPERM.rawValue))
        var delays: [Duration] = []
        try await SleepRegistration.prepare(service, fingerprint: "new", defaults: defaults) { delay in
            delays.append(delay)
            if delays.count == 2 {
                service.registeredStatus = .enabled
                service.registrationError = nil
            }
        }
        XCTAssertEqual(delays, [.milliseconds(250), .milliseconds(500)])
        try await SleepRegistration.prepare(service, fingerprint: "new", defaults: defaults) { _ in
            XCTFail("A successful registration is remembered")
        }
        XCTAssertEqual(service.events, ["stopping", "stopped", "register", "register", "register"])
    }

    func testPersistentPermissionErrorStopsRetryingAndAllowsALaterClick() async throws {
        let defaults = try isolatedDefaults()
        let service = TestSleepService(.notRegistered)
        service.registeredStatus = .notRegistered
        service.registrationError = NSError(domain: SMAppServiceErrorDomain, code: Int(POSIXErrorCode.EPERM.rawValue))
        var waits = 0
        do {
            try await SleepRegistration.prepare(service, fingerprint: "new", defaults: defaults) { _ in waits += 1 }
            XCTFail("Expected a registration failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("macOS 暂未允许启动睡眠助手"))
        }
        XCTAssertEqual(waits, 4)
        XCTAssertEqual(service.events, Array(repeating: "register", count: 5))

        service.registeredStatus = .requiresApproval
        do {
            try await SleepRegistration.prepare(service, fingerprint: "new", defaults: defaults) { _ in
                XCTFail("The user needs to approve the service before proceeding")
            }
            XCTFail("Expected approval instructions")
        } catch is SleepRegistration.NeedsApproval {}
        service.status = .enabled
        try await SleepRegistration.prepare(service, fingerprint: "new", defaults: defaults)
        XCTAssertEqual(service.events, Array(repeating: "register", count: 6))
    }
}
