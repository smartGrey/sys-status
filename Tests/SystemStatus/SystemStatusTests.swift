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
            $0.metrics.swapAt(0, 2)
            $0.modules = [.temperature,.battery,.cpu,.battery]
            $0.hidden = [.disk]
            $0.width = 400
        })
        let restored = SystemStatusController(url: url)
        restored.restore()
        XCTAssertEqual(restored.settings, controller.settings)
        XCTAssertEqual(restored.settings.metrics, [.cpu,.memory,.disk])
        XCTAssertEqual(restored.settings.modules, [.temperature,.battery,.cpu,.memory,.disk])
        XCTAssertEqual(restored.menuItem.state, .on)
    }

    func testLegacyMetricSettingsKeepSelectionAndRememberPaletteAndInactiveOrder() throws {
        let url = AppDataFile.systemStatus.url(in: try temporaryDirectory())
        let legacy = #"{"version":1,"enabled":true,"metrics":["memory","cpu"],"modules":["temperature"],"hidden":[],"width":400,"height":380}"#
        try Data(legacy.utf8).write(to: url)
        let model = SystemStatusController(url: url)
        model.restore()
        XCTAssertEqual(model.settings.metrics, [.memory, .cpu])
        XCTAssertEqual(model.settings.inactiveMetrics, [.disk, .cpuTemperature, .gpuTemperature, .batteryTemperature])
        XCTAssertEqual(model.settings.color(for: .cpu), .standard(for: .cpu))
        XCTAssertEqual(MetricColor.allCases.count, 12)
        model.change {
            $0.metrics = []
            $0.inactiveMetricOrder = [.memory, .cpu, .batteryTemperature]
            $0.metricColors = ["cpu": .rose, "memory": .rose]
        }
        let restored = SystemStatusController(url: url)
        restored.restore()
        XCTAssertEqual(restored.settings, model.settings)
        XCTAssertEqual(restored.settings.inactiveMetrics.prefix(3), [.memory, .cpu, .batteryTemperature])
        XCTAssertEqual(restored.settings.color(for: .cpu), .rose)
        XCTAssertEqual(restored.settings.color(for: .memory), .rose)
    }

    func testReorderPreviewAcrossMidpointsEmptySectionsAndOutsideBoard() {
        let list = BoardGeometry(counts: [2, 0], width: 200, columns: 1, cellHeight: 32, gap: 4, header: 25)
        let groups = [[1, 2], []]
        let second = list.cell(0, 1)
        XCTAssertEqual(list.destination(at: CGPoint(x: 90, y: second.midY-1), groups: groups, moving: 1), groups)
        XCTAssertEqual(list.destination(at: CGPoint(x: 90, y: second.midY+1), groups: groups, moving: 1), [[2, 1], []])
        XCTAssertEqual(list.destination(at: CGPoint(x: 90, y: list.top(1) + list.header/2), groups: groups, moving: 2), [[1], [2]])
        XCTAssertNil(list.destination(at: CGPoint(x: -1, y: 40), groups: groups, moving: 1))
        let grid = BoardGeometry(counts: [5], width: 560, columns: 2, cellHeight: 118, gap: 10, header: 0)
        let end = grid.cell(0, 4)
        XCTAssertEqual(end.width, grid.cell(0, 0).width)
        XCTAssertEqual(grid.destination(at: CGPoint(x: end.midX+2, y: end.midY), groups: [[1,2,3,4,5]], moving: 2),
                       [[1,3,4,5,2]])
    }

    func testOrderPersistsAndEveryVisibleArrangementPartitionsTheButton() throws {
        let url = AppDataFile.preferences.url(in: try temporaryDirectory())
        let prefs = StatusPreferences(url: url)
        let entry = StatusEntry()
        defer { entry.removeForExit() }
        prefs.didChange = { entry.applyOrder($0) }
        prefs.restore()
        XCTAssertEqual(entry.moduleOrder, StatusModule.allCases)
        prefs.save([.system, .stopwatch, .network, .hearing])
        XCTAssertEqual(entry.moduleOrder, [.system, .stopwatch, .network, .hearing])
        prefs.restore()
        XCTAssertEqual(prefs.order, entry.moduleOrder)
        let widths: [StatusModule: CGFloat] = [.hearing: 16, .network: 34, .stopwatch: 23, .system: 95]
        func verify(_ prefix: [StatusModule], _ rest: [StatusModule]) throws {
            if prefix.contains(.network) {
                let layout = StatusStripLayout(order: prefix, widths: widths)
                let frame = CGRect(x: -310, y: 200, width: layout.width+6, height: 24)
                var edge = frame.minX
                for slot in layout.slots {
                    let region = try XCTUnwrap(layout.region(slot.module, in: frame))
                    XCTAssertEqual(region.minX, edge)
                    XCTAssertTrue(region.contains(CGPoint(x: frame.minX+3+slot.x+slot.width/2, y: frame.midY)))
                    edge = region.maxX
                }
                XCTAssertEqual(edge, frame.maxX)
            }
            for item in rest { try verify(prefix + [item], rest.filter { $0 != item }) }
        }
        try verify([], StatusModule.allCases)
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
        XCTAssertEqual(entry.item.length, initial + StatusStripLayout.moduleGap + compact)
        reading.battery?.percent = 100
        XCTAssertGreaterThan(face().width, compact)
        reading.battery?.connected = true
        XCTAssertGreaterThan(face().width, compact)
        reading.battery?.charging = true
        reading.battery?.watts = 9.2
        let chargeWidth = face().width
        XCTAssertGreaterThan(chargeWidth, compact)
        reading.battery?.watts = 102.8
        XCTAssertGreaterThan(face().width, chargeWidth)
        reading.battery?.full = true
        XCTAssertLessThan(face().width, chargeWidth)
        XCTAssertTrue(face().spoken.contains("已接电"))
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
