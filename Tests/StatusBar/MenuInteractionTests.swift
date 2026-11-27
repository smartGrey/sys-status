import AppKit
import XCTest
@testable import StatusBarCore

@MainActor
final class MenuInteractionTests: XCTestCase {
    func testSecondaryMenuAnchorUsesClickedDisplayEvenWhenItsReplicaIsDisplaced() {
        let visible = CGRect(x: -1920, y: 100, width: 1920, height: 1056)
        let point = CGPoint(x: -315, y: 1165)
        let replica = CGRect(x: -400, y: 1156, width: 200, height: 24)
        XCTAssertEqual(StatusPanelGeometry.menuAnchor(at: point, replica: replica, visibleFrame: visible), replica)
        for displaced in [nil, replica.offsetBy(dx: 1920, dy: -100)] {
            XCTAssertEqual(StatusPanelGeometry.menuAnchor(at: point, replica: displaced, visibleFrame: visible).origin,
                           CGPoint(x: point.x, y: visible.maxY))
        }
    }

    func testPrimaryDismissalClickSwitchesPanelOrReopensSecondaryMenu() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let entry = StatusEntry()
        defer { entry.removeForExit() }
        var state = StopwatchState()
        state.setEnabled(true, at: 0)
        entry.updateStopwatch(state.presentation(at: 0))
        entry.updateHearing(.init(icon: .init(enabled: false, passing: false, level: 0), title: "已关闭"))
        var opened: [StatusEntry.Region] = [], closed: [StatusEntry.Region] = []
        entry.onTogglePanel = { part, _, _ in opened.append(part); entry.panelVisibilityChanged(part, visible: true) }
        entry.onClosePanel = { part in closed.append(part); entry.panelVisibilityChanged(part, visible: false) }
        let frame = CGRect(x: 100, y: 800, width: entry.item.length, height: 24)
        for part in [StatusEntry.Region.stopwatch, .hearing, .network] {
            let region = try XCTUnwrap(entry.region(part, of: frame))
            entry.handOffMenuClick(at: CGPoint(x: region.midX, y: region.midY), in: frame, on: screen, openedBySecondaryClick: false)
        }
        XCTAssertEqual(opened, [.stopwatch, .hearing])
        XCTAssertEqual(closed, [.stopwatch])
        XCTAssertFalse(entry.isOpeningMenu)
        let network = entry.networkRegion(of: frame)
        entry.handOffMenuClick(at: CGPoint(x: network.midX, y: network.midY), in: frame, on: screen, openedBySecondaryClick: true)
        XCTAssertTrue(entry.isOpeningMenu)
        entry.removeForExit()
        XCTAssertFalse(entry.isOpeningMenu)
    }

    func testSubmenuToggleUpdatesTheExistingRowsAndSavedState() throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        let store = ProbeConfigurationStore(url: AppDataFile.probes.url(in: directory), defaults: try isolatedDefaults())
        let config = ProbeConfiguration(probingEnabled: false, sites: ProbeSite.builtIns)
        try AppDataFile.write(config, to: store.url)
        let controller = ProbeController(store: store)
        controller.load()
        let root = NSMenu()
        root.autoenablesItems = false
        controller.addItems(to: root)
        let id = config.sites[0].id
        let parent = try XCTUnwrap(root.items.first { $0.representedObject as? String == id })
        let submenu = try XCTUnwrap(parent.submenu)
        let toggle = try XCTUnwrap(submenu.items.first?.view)
        for enabled in [!config.sites[0].enabled, config.sites[0].enabled] {
            XCTAssertTrue(toggle.accessibilityPerformPress())
            XCTAssertTrue(parent.submenu === submenu && submenu.items.first?.view === toggle)
            XCTAssertEqual(toggle.accessibilityValue() as? Int, enabled ? 1 : 0)
            XCTAssertEqual(try store.read().configuration.sites[0].enabled, enabled)
        }
    }
}
