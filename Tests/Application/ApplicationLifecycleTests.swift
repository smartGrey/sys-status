import AppKit
import XCTest
@testable import StatusBarCore

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
    func testLaunchSleepWakeAndQuitPreserveStopwatchAndRejectLateUpdates() throws {
        let directory = try temporaryDirectory()
        let defaults = try isolatedDefaults()
        let config = ProbeConfiguration(probingEnabled: false, sites: ProbeSite.builtIns)
        try AppDataFile.write(config, to: AppDataFile.probes.url(in: directory))
        let app = NSApplication.shared
        let coordinator = ApplicationCoordinator(dataDirectory: directory, defaults: defaults)
        coordinator.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let watch = coordinator.stopwatch
        watch.setEnabled(true)
        watch.toggle(watch.presentation.focus)
        XCTAssertTrue(watch.presentation.readings[0].isRunning)
        coordinator.systemWillSleep()
        XCTAssertFalse(watch.presentation.readings[0].isRunning)
        coordinator.startSampling()
        XCTAssertFalse(watch.presentation.readings[0].isRunning)

        let entry = coordinator.statusEntry
        let width = entry.item.length
        XCTAssertEqual(coordinator.applicationShouldTerminate(app), .terminateNow)
        entry.updateStopwatch(nil)
        entry.updateHearing(.init(icon: .init(enabled: false, passing: false, level: 0), title: "已关闭"))
        coordinator.startSampling()
        XCTAssertEqual(entry.item.length, width)
        let stored = try StopwatchStore(url: AppDataFile.stopwatch.url(in: directory)).load()
        XCTAssertTrue(stored.enabled)
        XCTAssertEqual(stored.focus, watch.presentation.focus)
    }
}
