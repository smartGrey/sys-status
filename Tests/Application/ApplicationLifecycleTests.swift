import AppKit
import XCTest
@testable import StatusBarCore

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
    func testLaunchSleepWakeAndQuitPreserveStopwatchAndRejectLateUpdates() throws {
        let directory = try temporaryDirectory()
        let defaults = try isolatedDefaults()
        var sites = ProbeSite.builtIns
        for index in sites.indices { sites[index].enabled = false }
        let config = ProbeConfiguration(probingEnabled: false, sites: sites)
        try AppDataFile.write(config, to: AppDataFile.probes.url(in: directory))
        let app = NSApplication.shared
        let coordinator = ApplicationCoordinator(dataDirectory: directory, defaults: defaults)
        coordinator.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let entry = coordinator.statusEntry
        XCTAssertTrue(entry.enabledModules.isEmpty)
        XCTAssertNil(entry.region(.network, of: CGRect(x: 0, y: 0, width: 40, height: 24)))
        XCTAssertNotNil(entry.item.button?.image)
        let menu = try XCTUnwrap(coordinator.stopwatch.menuItem.menu)
        XCTAssertEqual(menu.items.prefix(4).map(\.title), ["监听环境音", "网络状况", "StopWatch", "系统状态"])
        XCTAssertFalse(menu.items.contains { $0.hasSubmenu && $0.representedObject is String })
        let toggle = try XCTUnwrap(menu.item(withTitle: "网络状况")?.view)
        XCTAssertTrue(toggle.accessibilityPerformPress())
        XCTAssertEqual(entry.enabledModules, [.network])
        XCTAssertTrue(toggle.accessibilityPerformPress())
        XCTAssertEqual(entry.enabledModules, [])
        let watch = coordinator.stopwatch
        watch.setEnabled(true)
        watch.toggle(watch.presentation.focus)
        XCTAssertTrue(watch.presentation.readings[0].isRunning)
        coordinator.systemWillSleep()
        XCTAssertFalse(watch.presentation.readings[0].isRunning)
        coordinator.startSampling()
        XCTAssertFalse(watch.presentation.readings[0].isRunning)

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
