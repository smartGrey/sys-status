import AppKit
import XCTest
@testable import StatusBarCore

@MainActor
final class SystemStatusTests: XCTestCase {
    func testIdleDemandAndIndependentStatusSelection() {
        var settings = SystemStatusSettings()
        XCTAssertEqual(ResourceDemand(settings, panelVisible: true, details: true).metrics, [])
        settings.enabled = true
        let idle = ResourceDemand(settings, panelVisible: false, details: true)
        XCTAssertNil(idle.interval(charging: false))
        XCTAssertFalse(idle.batteryDetail)
        XCTAssertNotNil(idle.interval(charging: true))
        settings.hidden = [.cpu, .temperature, .battery]
        settings.metrics = [.gpuTemperature, .cpu]
        let active = ResourceDemand(settings, panelVisible: true, details: true)
        XCTAssertEqual(active.metrics, [.cpu, .gpuTemperature, .memory, .disk])
        XCTAssertFalse(active.cores)
        XCTAssertFalse(active.batteryPanel)
        XCTAssertEqual(ResourceDemand(settings, panelVisible: false, details: false).metrics, [.gpuTemperature, .cpu])
    }

    func testModuleAndStatusBarOrderPersistIndependently() throws {
        let url = AppDataFile.systemStatus.url(in: try temporaryDirectory())
        let controller = SystemStatusController(url: url)
        controller.restore()
        XCTAssertEqual(controller.menuItem.state, .off)
        XCTAssertTrue(controller.change {
            $0.enabled = true
            $0.metrics = [.disk,.memory,.cpu,.memory]
            SystemStatusView.move(.cpu, to: .disk, in: &$0.metrics)
            $0.modules = [.temperature,.battery,.cpu,.battery]
            $0.hidden = [.disk]
            $0.width = 400
        })
        let restored = SystemStatusController(url: url)
        restored.restore()
        XCTAssertEqual(restored.settings, controller.settings)
        XCTAssertEqual(restored.settings.metrics, [.cpu,.disk,.memory])
        XCTAssertEqual(restored.settings.modules, [.temperature,.battery,.cpu,.memory,.disk])
        XCTAssertEqual(restored.menuItem.state, .on)
    }

    func testBatteryFootprintAndStatusRegion() throws {
        var reading = SystemReading()
        reading.battery = BatteryReading(percent: 99)
        let entry = StatusEntry()
        defer { entry.removeForExit() }
        func face(_ metrics: [StatusMetric] = []) -> SystemStatusFace { .init(reading: reading, metrics: metrics) }
        let initial = entry.item.length
        let compact = face().width
        entry.updateSystem(face())
        XCTAssertEqual(entry.item.length, initial + StatusFace.moduleGap + compact)
        reading.battery?.percent = 100
        XCTAssertEqual(face().width, compact)
        reading.battery?.connected = true
        XCTAssertEqual(face().width, compact)
        reading.battery?.charging = true
        reading.battery?.watts = 9.2
        let chargeWidth = face().width
        XCTAssertGreaterThan(chargeWidth, compact)
        reading.battery?.watts = 102.8
        XCTAssertEqual(face().width, chargeWidth)
        entry.updateSystem(face([.gpuTemperature,.cpu]))
        let frame = NSRect(x: 10, y: 10, width: entry.item.length + 8, height: 24)
        let system = try XCTUnwrap(entry.region(.system, of: frame))
        XCTAssertEqual(system.minX, entry.networkRegion(of: frame).maxX)
        XCTAssertEqual(system.maxX, frame.maxX)
        entry.updateSystem(nil)
        XCTAssertEqual(entry.item.length, initial)
    }

    func testUnavailableValuesAndPowerStates() {
        var reading = SystemReading()
        for metric in StatusMetric.allCases { XCTAssertEqual(reading.statusValue(metric), "—") }
        reading.hasBattery = false
        XCTAssertEqual(SystemStatusFace(reading: reading, metrics: []).spoken, "系统状态")
        var battery = BatteryReading(percent: 94)
        XCTAssertEqual(battery.timeLabel, "估算中")
        battery.minutes = 91
        XCTAssertEqual(battery.timeLabel, "1 小时 31 分")
        battery.connected = true
        XCTAssertEqual(battery.timeLabel, "未在充电")
        battery.full = true
        XCTAssertEqual(battery.source, "已充满")
        battery.full = false
        battery.charging = true
        battery.watts = 32
        reading.battery = battery
        reading.hasBattery = true
        reading.temperatures = [.cpuTemperature: 55.8]
        let face = SystemStatusFace(reading: reading, metrics: [.cpuTemperature, .gpuTemperature])
        XCTAssertEqual(face.spoken, "电池 94%，充电 32W，CPU 温度 56°，GPU 温度 —")
    }

    func testSystemCardBodyDragPreservesControlsAndLayoutEditing() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let entry = StatusEntry()
        let model = SystemStatusController(url: AppDataFile.systemStatus.url(in: try temporaryDirectory()))
        model.change { $0.enabled = true }
        let shell = StatusPanelShell(item: entry.item, content: model.panelContent)
        defer { shell.stop(); entry.removeForExit() }
        shell.start()
        let anchor = NSRect(x: screen.frame.midX, y: screen.visibleFrame.maxY, width: 40, height: 22)
        shell.show(under: anchor, within: screen.visibleFrame)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "系统状态" && $0.isVisible })
        let chrome = try XCTUnwrap(window.contentView as? PanelChrome)
        chrome.layoutSubtreeIfNeeded()
        let readout = NSPoint(x: chrome.bounds.width * 0.3, y: chrome.bounds.height * 0.73)
        XCTAssertTrue(chrome.hitTest(readout, primaryClick: true) is PanelDragView)
        let pin = chrome.pin.frame
        XCTAssertTrue(chrome.hitTest(NSPoint(x: pin.midX, y: pin.midY), primaryClick: true) === chrome.pin)
        XCTAssertTrue(shell.previewing)
        model.editing = true
        chrome.layoutSubtreeIfNeeded()
        XCTAssertFalse(chrome.hitTest(readout, primaryClick: true) is PanelDragView)
    }

    func testShellPromotionOutsideClickAndIndependentPinRestoration() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let entry = StatusEntry()
        let a = NetworkPanel(), b = NetworkPanel()
        let first = StatusPanelShell(item: entry.item, content: a.panelContent)
        let second = StatusPanelShell(item: entry.item, content: b.panelContent)
        defer { first.stop(); second.stop(); entry.removeForExit() }
        first.start()
        second.start()
        let anchor = NSRect(x: screen.frame.midX, y: screen.visibleFrame.maxY, width: 36, height: 24)
        first.show(under: anchor, within: screen.visibleFrame)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "网络状况" && $0.isVisible } as? StatusPanelWindow)
        XCTAssertTrue(first.previewing)
        first.click(under: anchor, on: screen)
        XCTAssertTrue(first.opened)
        XCTAssertTrue(window.isVisible)
        let next = anchor.offsetBy(dx: 85, dy: 0)
        second.show(under: next, within: screen.visibleFrame)
        XCTAssertTrue(second.previewing)
        XCTAssertTrue(first.opened)
        second.setMenuOpen(true)
        XCTAssertFalse(second.previewing)
        window.togglePinned?()
        XCTAssertTrue(first.isPinned)
        XCTAssertFalse(first.opened)
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX+80, y: screen.visibleFrame.minY+80))
        let placed = window.frame
        first.click(under: next, on: screen)
        XCTAssertEqual(window.frame, placed)
        first.setMenuOpen(true)
        XCTAssertTrue(window.isVisible)
        first.stop(rememberPins: true)
        XCTAssertFalse(window.isVisible)
        first.start()
        XCTAssertTrue(first.isPinned)
        XCTAssertEqual(window.frame, placed)
        window.togglePinned?()
        XCTAssertFalse(window.isVisible)
        first.setMenuOpen(false)
        first.click(under: anchor, on: screen)
        XCTAssertTrue(first.opened)
        let outside = NSPoint(x: screen.frame.minX - 10, y: screen.frame.minY - 10)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: outside, modifierFlags: [],
                                                     timestamp: 0, windowNumber: 0, context: nil,
                                                     eventNumber: 1, clickCount: 1, pressure: 1))
        first.handle(event, at: outside)
        XCTAssertFalse(first.opened)
        XCTAssertFalse(window.isVisible)
    }
}
