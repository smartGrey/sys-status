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
        settings.hidden = [.temperature, .battery, .compute]
        settings.metrics = [.metric(.gpuTemperature), .metric(.cpu)]
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
            $0.metrics = [.metric(.disk), .metric(.memory), .metric(.cpu), .metric(.memory)]
            $0.metrics.swapAt(0, 2)
            $0.modules = [.temperature,.battery,.compute,.battery]
            $0.hidden = [.disk]
            $0.width = 400
        })
        let restored = SystemStatusController(url: url)
        restored.restore()
        XCTAssertEqual(restored.settings, controller.settings)
        XCTAssertEqual(restored.settings.metrics, [.metric(.cpu), .metric(.memory), .metric(.disk)])
        XCTAssertEqual(restored.settings.modules, [.temperature,.battery,.compute,.memory,.disk])
        XCTAssertEqual(restored.menuItem.state, .on)
    }

    func testRemovingCPUCardPreservesLayoutAcrossUpgradeAndSave() throws {
        let url = AppDataFile.systemStatus.url(in: try temporaryDirectory())
        let legacy = ["memory", "cpu", "disk", "battery", "temperature"]
        let modern = legacy + ["compute"]
        for order in [legacy, modern] {
            for hidden in [[], ["cpu"], ["compute"], ["compute", "cpu"]] as [[String]] {
                let saved: [String: Any] = ["version": 1, "enabled": true, "metrics": ["cpu"], "metricColors": ["cpu": "rose"],
                                             "modules": order, "hidden": hidden + ["disk"], "width": 470, "height": 355]
                try JSONSerialization.data(withJSONObject: saved).write(to: url)
                let controller = SystemStatusController(url: url)
                controller.restore()
                let hasCompute = order == modern
                let expected: [ResourceModule] = hasCompute ? [.memory,.disk,.battery,.temperature,.compute]
                                                           : [.memory,.compute,.disk,.battery,.temperature]
                let settings = controller.settings
                XCTAssertEqual(settings.modules, expected)
                XCTAssertTrue(settings.hidden.contains(.disk))
                XCTAssertEqual(settings.hidden.contains(.compute), hidden.contains("compute") || (!hasCompute && hidden.contains("cpu")))
                XCTAssertEqual(settings.metrics, [.battery, .metric(.cpu)])
                XCTAssertEqual(settings.color(for: .cpu), .rose)
                XCTAssertEqual(settings.width, 470)
                XCTAssertEqual(settings.height, 355)
                XCTAssertTrue(controller.change { $0.width += 1 })
                let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                for key in ["modules", "hidden"] { XCTAssertFalse(try XCTUnwrap(file[key] as? [String]).contains("cpu")) }
                let reopened = SystemStatusController(url: url)
                reopened.restore()
                XCTAssertEqual(reopened.settings, controller.settings)
            }
        }
    }

    func testLegacyMetricSettingsKeepSelectionAndRememberPaletteAndInactiveOrder() throws {
        let url = AppDataFile.systemStatus.url(in: try temporaryDirectory())
        let legacy = #"{"version":1,"enabled":true,"metrics":["memory","cpu"],"modules":["temperature"],"hidden":[],"width":400,"height":380}"#
        try Data(legacy.utf8).write(to: url)
        let model = SystemStatusController(url: url)
        model.restore()
        XCTAssertEqual(model.settings.metrics, [.battery, .metric(.memory), .metric(.cpu)])
        XCTAssertEqual(model.settings.inactiveMetrics, [.metric(.disk), .metric(.cpuTemperature), .metric(.gpuTemperature), .metric(.batteryTemperature)])
        XCTAssertEqual(model.settings.color(for: .cpu), .standard(for: .cpu))
        XCTAssertEqual(MetricColor.allCases.count, 12)
        model.change {
            $0.metrics = [.battery]
            $0.inactiveMetricOrder = [.metric(.memory), .metric(.cpu), .metric(.batteryTemperature)]
            $0.metricColors = ["cpu": .rose, "memory": .rose]
        }
        let restored = SystemStatusController(url: url)
        restored.restore()
        XCTAssertEqual(restored.settings, model.settings)
        XCTAssertEqual(restored.settings.inactiveMetrics.prefix(3), [.metric(.memory), .metric(.cpu), .metric(.batteryTemperature)])
        XCTAssertEqual(restored.settings.color(for: .cpu), .rose)
        XCTAssertEqual(restored.settings.color(for: .memory), .rose)
    }

    func testBatteryPositionAndVisibilitySurviveReopening() throws {
        let url = AppDataFile.systemStatus.url(in: try temporaryDirectory())
        let controller = SystemStatusController(url: url)
        let disk = StatusIndicator.metric(.disk), cpu = StatusIndicator.metric(.cpu)
        XCTAssertFalse(controller.settings.canMoveIndicator(.battery))
        for order in [[.battery, disk, cpu], [disk, .battery, cpu], [disk, cpu, .battery], [disk]] {
            controller.change {
                $0.enabled = true
                $0.metrics = order
                $0.inactiveMetricOrder = [cpu, .battery]
            }
            let reopened = SystemStatusController(url: url)
            reopened.restore()
            let settings = reopened.settings
            XCTAssertEqual(settings, controller.settings)
            XCTAssertEqual(settings.metrics, order)
            XCTAssertEqual(settings.inactiveMetrics.contains(.battery), !order.contains(.battery))
            XCTAssertEqual(settings.canMoveIndicator(disk), order.count > 1)
            XCTAssertTrue(settings.canMoveIndicator(.battery))
            let demand = ResourceDemand(settings, panelVisible: false, details: false)
            XCTAssertEqual(demand.needsBattery, order.contains(.battery))
            if order == [disk] {
                XCTAssertEqual(demand.interval(charging: true), 30)
                XCTAssertTrue(ResourceDemand(settings, panelVisible: true, details: false).batteryPanel)
            }
        }
        var empty = controller.settings
        empty.metrics = []
        empty.normalize()
        XCTAssertEqual(empty.metrics, [.battery])
        XCTAssertFalse(empty.inactiveMetrics.contains(.battery))
    }

    func testReorderPreviewAcrossMidpointsEmptySectionsAndOutsideBoard() {
        let list = BoardGeometry(counts: [2, 0], width: 200, columns: 1, cellHeight: 32, gap: 4, header: 25)
        let groups = [[1, 2], []]
        let second = list.cell(0, 1)
        XCTAssertEqual(list.destination(at: CGPoint(x: 90, y: second.midY-1), groups: groups, moving: 1), groups)
        XCTAssertEqual(list.destination(at: CGPoint(x: 90, y: second.midY+1), groups: groups, moving: 1), [[2, 1], []])
        XCTAssertEqual(list.destination(at: CGPoint(x: 90, y: list.top(1) + list.header/2), groups: groups, moving: 2), [[1], [2]])
        XCTAssertNil(list.destination(at: CGPoint(x: -1, y: 40), groups: groups, moving: 1))
        let grid = BoardGeometry(counts: [5], width: 560, columns: 2, cellHeight: SystemPanelLayout.cellHeight, gap: 10, header: 0)
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
            if !prefix.isEmpty {
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
        let empty = StatusStripLayout(order: StatusModule.allCases, widths: [:])
        XCTAssertTrue(empty.slots.isEmpty)
        XCTAssertEqual(empty.width, 22)
    }

    func testComputeDemandAndAdaptiveLayoutReset() throws {
        let controller = SystemStatusController(url: AppDataFile.systemStatus.url(in: try temporaryDirectory()))
        controller.change {
            $0.enabled = true
            $0.hidden = Set(ResourceModule.allCases).subtracting([.compute])
            $0.width = 300
            $0.height = 200
        }
        let panel = ResourceDemand(controller.settings, panelVisible: true, details: false)
        XCTAssertTrue(panel.cores)
        XCTAssertEqual(panel.metrics, [.cpu])
        XCTAssertFalse(ResourceDemand(controller.settings, panelVisible: false, details: false).cores)
        controller.editing = true
        controller.restoreLayout()
        XCTAssertTrue(controller.settings.hidden.isEmpty)
        XCTAssertEqual(controller.settings.width, 580)
        XCTAssertEqual(controller.settings.height, SystemPanelLayout.heightToFit(width: 532))
        XCTAssertEqual(controller.settings.height, 40 + 3 * 110 + 2 * 10 + 8)
        XCTAssertEqual(SystemPanelLayout.heightToFit(width: 531), 40 + 5 * 110 + 4 * 10 + 8)
    }

    func testResetFitsCardsAfterEditingAndReopening() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let url = AppDataFile.systemStatus.url(in: try temporaryDirectory())
        let controller = SystemStatusController(url: url)
        controller.change { $0.enabled = true; $0.height = 550 }
        let panel = controller.panelContent
        defer { panel.close() }
        let anchor = CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 40, height: 22)
        let window = try XCTUnwrap(panel.show(anchor, screen, false))
        controller.editing = true
        controller.restoreLayout()
        let normal = controller.settings.height
        XCTAssertEqual(window.frame.height, normal + SystemPanelLayout.editingFooterHeight)
        controller.editing = false
        XCTAssertEqual(window.frame.height, normal)
        controller.editing = true
        controller.restoreLayout()
        panel.close()
        let reopened = try XCTUnwrap(panel.show(anchor, screen, false))
        XCTAssertEqual(reopened.frame.height, normal)
        controller.editing = true
        reopened.setContentSize(CGSize(width: 540, height: normal + SystemPanelLayout.editingFooterHeight + 20))
        let delegate = try XCTUnwrap(reopened.delegate as? SystemStatusPanel)
        delegate.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: reopened))
        controller.editing = false
        XCTAssertEqual(reopened.frame.height, normal + 20)
        let restored = SystemStatusController(url: url)
        restored.restore()
        XCTAssertEqual(restored.settings.height, normal + 20)
    }

    func testLegacyStripOrderSurvivesSiteVisibilityChanges() throws {
        let url = AppDataFile.preferences.url(in: try temporaryDirectory())
        try AppDataFile.write(["system", "stopwatch", "network", "hearing"], to: url)
        let prefs = StatusPreferences(url: url)
        prefs.restore()
        XCTAssertEqual(prefs.order, [.system, .stopwatch, .network, .hearing])
        XCTAssertFalse(prefs.showAllSites)
        XCTAssertTrue(prefs.setShowAllSites(true))
        let reopened = StatusPreferences(url: url)
        reopened.restore()
        XCTAssertEqual(reopened.order, prefs.order)
        XCTAssertTrue(reopened.showAllSites)
        reopened.save([.network])
        prefs.restore()
        XCTAssertTrue(prefs.showAllSites)
        XCTAssertEqual(prefs.order.first, .network)
    }

    func testBatteryFootprintAndStatusRegion() throws {
        var reading = SystemReading()
        reading.battery = BatteryReading(percent: 99)
        let entry = StatusEntry()
        defer { entry.removeForExit() }
        func face(_ metrics: [StatusIndicator] = [.battery]) -> SystemStatusFace { .init(reading: reading, metrics: metrics) }
        let initial = entry.item.length
        let compact = face().width
        let cpuAfterBattery = face([.battery, .metric(.cpu)]).width - compact
        let cpuAfterMemory = face([.metric(.memory), .metric(.cpu)]).width - face([.metric(.memory)]).width
        XCTAssertEqual(cpuAfterBattery, cpuAfterMemory + 1)
        XCTAssertEqual(face([.metric(.cpu), .battery]).width, face([.battery, .metric(.cpu)]).width)
        let cpu = StatusIndicator.metric(.cpu), memory = StatusIndicator.metric(.memory)
        XCTAssertEqual(face([cpu, .battery, memory]).width, face([cpu]).width + compact + face([memory]).width + 10)
        XCTAssertEqual(face([cpu, .battery, memory]).spoken, "CPU 占用率 —，电池 99%，内存用量 —")
        let hiddenBattery = face([cpu, memory])
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
        XCTAssertEqual(face([cpu, memory]), hiddenBattery)
        entry.updateSystem(face([.metric(.gpuTemperature), .battery, .metric(.cpu)]))
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
        XCTAssertEqual(SystemStatusFace(reading: reading, metrics: [.battery]).spoken, "系统状态")
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
        let face = SystemStatusFace(reading: reading, metrics: [.battery, .metric(.cpuTemperature), .metric(.gpuTemperature)])
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
        // AppKit can briefly have no frame for the status item during layout.
        first.trackAnchor { _ in nil }
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
