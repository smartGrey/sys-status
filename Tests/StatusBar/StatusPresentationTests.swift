import AppKit
import XCTest
@testable import StatusBarCore

final class StatusPresentationTests: XCTestCase {
    @MainActor
    func testFeedbackUsesOneCenteredClickThroughPanel() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let toast = OperationToast()
        defer { toast.hide() }
        let key = NSApp.keyWindow
        toast.show("站点探测已启用", on: screen)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "操作提示" && $0.isVisible })
        toast.show("Google · 新建已切换为快速", on: screen)
        XCTAssertEqual(NSApp.windows.filter { $0.title == "操作提示" && $0.isVisible }.count, 1)
        XCTAssertEqual(panel.frame.midX, screen.frame.midX, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, screen.frame.midY, accuracy: 1)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(NSApp.keyWindow === key)
        XCTAssertNotNil(view(try XCTUnwrap(panel.contentView)) { (field: NSTextField) in field.stringValue == "Google · 新建已切换为快速" })
        try await waitUntil(timeout: .seconds(3)) { !panel.isVisible }
    }

    @MainActor
    func testStatusColorsAcrossAppearances() throws {
        let face = StatusFace()
        XCTAssertEqual(face.width, 34)
        for color in [ArrowColor.normal, .green, .orange, .red] {
            let image = face.image(upload: RateText(999000), download: RateText(1.4e6), color: color)
            try checkColors(image, color: color)
        }
    }

    @MainActor
    private func checkColors(_ image: NSImage, color: ArrowColor) throws {
        for (name, expected) in [(NSAppearance.Name.aqua, 0.0), (.darkAqua, 1.0), (.aqua, 0.0)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 40,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            appearance.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                image.draw(in: NSRect(x: 0, y: 0, width: image.size.width * 2, height: 40))
                NSGraphicsContext.restoreGraphicsState()
                var solidPixels = 0
                var arrowPixels = [0, 0]
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              pixel.alphaComponent > 0.95 else { continue }
                        solidPixels += 1
                        if x < 8 {
                            arrowPixels[y / 20] += 1
                            switch color {
                            case .normal: break
                            case .green:
                                XCTAssertGreaterThan(pixel.greenComponent, pixel.redComponent)
                                XCTAssertGreaterThan(pixel.greenComponent, pixel.blueComponent)
                                continue
                            case .red:
                                XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent)
                                XCTAssertGreaterThan(pixel.redComponent, pixel.blueComponent)
                                continue
                            case .orange:
                                XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent)
                                XCTAssertGreaterThan(pixel.greenComponent, pixel.blueComponent)
                                continue
                            }
                        }
                        for component in [pixel.redComponent, pixel.greenComponent, pixel.blueComponent] {
                            XCTAssertEqual(component, expected, accuracy: 0.04)
                        }
                    }
                }
                XCTAssertGreaterThan(solidPixels, 100)
                for count in arrowPixels { XCTAssertGreaterThan(count, 20) }
            }
        }
    }

    @MainActor
    func testHoverPanelStaysOnTheDisplayWithTheButton() {
        let size = NSSize(width: 148, height: 99)
        for screen in [
            NSRect(x: 65, y: 0, width: 1663, height: 1083),
            NSRect(x: -3200, y: -229, width: 1280, height: 1409),
            NSRect(x: -1920, y: 37, width: 1920, height: 1049)
        ] {
            let button = NSRect(x: screen.maxX - 64, y: screen.maxY + 4, width: 34, height: 22)
            let panel = StatusPanelGeometry.frame(size: size, under: button, within: screen)
            XCTAssertTrue(screen.contains(panel))
            XCTAssertEqual(panel.maxX, screen.maxX)
            XCTAssertEqual(panel.maxY, screen.maxY - 4)
        }
    }

    @MainActor
    func testInactiveMenuBarUsesItsOwnScreenCoordinates() throws {
        let source = NSRect(x: -1920, y: 37, width: 1920, height: 1080)
        let button = NSRect(x: -548, y: 1090.5, width: 34, height: 22)
        let external = NSRect(x: -3200, y: -229, width: 1280, height: 1440)
        let externalButton = try XCTUnwrap(StatusPanelShell.replicaFrame(of: button, from: source, to: external,
                                                                   topRightArea: nil))
        XCTAssertEqual(externalButton, NSRect(x: -2468, y: 1184.5, width: 34, height: 22))

        let builtIn = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let rightOfNotch = NSRect(x: 956.5, y: 1085, width: 771.5, height: 32)
        let builtInButton = try XCTUnwrap(StatusPanelShell.replicaFrame(of: button, from: source, to: builtIn,
                                                                  topRightArea: rightOfNotch))
        XCTAssertEqual(builtInButton, NSRect(x: 1180, y: 1090.5, width: 34, height: 22))
        XCTAssertNil(StatusPanelShell.replicaFrame(of: button.offsetBy(dx: -250, dy: 0), from: source, to: builtIn,
                                              topRightArea: rightOfNotch))
        XCTAssertNil(StatusPanelShell.replicaFrame(of: button.offsetBy(dx: 0, dy: -60), from: source, to: external,
                                              topRightArea: nil))
    }

    @MainActor
    func testCardTruncationAndAccessibleReadings() throws {
        let row = ConnectivityState.Row(id: "c", name: String(repeating: "长站名", count: 12), enabled: true,
                                        daily: .success(0.132), fresh: .wrongStatus(403),
                                        dailyCount: .init(successes: 7, completed: 7),
                                        freshCount: .init(successes: 2, completed: 2))
        let state = ConnectivityState(rows: [row], rate: "5.2 MB/h")
        let card = HoverCard()
        let size = card.update(state, availableHeight: 200)
        let entry = StatusEntry()
        defer { entry.removeForExit() }
        let button = try XCTUnwrap(entry.item.button)
        let network = NetworkPanel()
        network.setTooltip = { button.toolTip = $0 }
        entry.updateNetwork(speed: nil, connectivity: state)
        network.update(state)
        XCTAssertEqual(button.toolTip, state.hoverTooltip)
        XCTAssertEqual(button.accessibilityHelp(), state.summary)
        XCTAssertTrue(state.summary.contains(row.name + "，复用 132 ms，新建 非预期状态码 403"))
        XCTAssertTrue(state.summary.contains("复用成功率 100%，成功 7 次，完成 7 次，新建成功率 100%，成功 2 次，完成 2 次"))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        func fields() -> [NSTextField] { descendants(card).compactMap { $0 as? NSTextField } }
        let percentages = fields().filter { $0.stringValue == "100" }.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(percentages.count, 2)
        let dailyRate = try XCTUnwrap(percentages.first)
        let freshRate = try XCTUnwrap(percentages.last)
        let slashes = fields().filter { $0.stringValue == "/" }
        XCTAssertEqual(slashes.count, 2)
        let slash = try XCTUnwrap(slashes.last)
        XCTAssertEqual(dailyRate.alignment, .center)
        XCTAssertEqual(freshRate.alignment, .center)
        XCTAssertGreaterThanOrEqual(dailyRate.frame.width, dailyRate.intrinsicContentSize.width)
        let header = try XCTUnwrap(fields().first { $0.stringValue == "成功率(%)" })
        XCTAssertEqual(header.maximumNumberOfLines, 1)
        XCTAssertEqual(header.frame.midX, slash.frame.midX)
        for (title, rate) in [("复用请求", dailyRate), ("新建请求", freshRate)] {
            let subheading = try XCTUnwrap(fields().first { $0.stringValue == title })
            XCTAssertEqual(subheading.frame.midX, rate.frame.midX)
            XCTAssertGreaterThanOrEqual(subheading.frame.width, subheading.intrinsicContentSize.width)
        }
        XCTAssertTrue(fields().contains { $0.stringValue == "网络状况" })
        XCTAssertFalse(fields().contains { $0.stringValue == state.title })
        XCTAssertEqual(fields().filter { $0.stringValue == "当前等待" }.count, 2)
        let countdownHeadings = fields().filter { $0.stringValue == "下次发起" }.sorted { $0.frame.minX < $1.frame.minX }
        let timingViews = descendants(card).compactMap { $0 as? ProbeTimingView }.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(countdownHeadings.count, 2)
        XCTAssertEqual(timingViews.count, 2)
        for (heading, timing) in zip(countdownHeadings, timingViews) {
            XCTAssertEqual(heading.frame.midX, timing.frame.minX + ProbeTimingView.nextContentRect.midX)
        }
        XCTAssertNotNil(view(card) { (button: NSButton) in button.accessibilityLabel() == row.spoken + "，快捷配置" })
        XCTAssertEqual(size.width, 886)

        let many = ConnectivityState(rows: Array(repeating: row, count: 15))
        let compact = card.update(many, availableHeight: 185, availableWidth: 320)
        XCTAssertEqual(compact, NSSize(width: 320, height: 185))
        let scrolls = descendants(card).compactMap { $0 as? NSScrollView }
        XCTAssertTrue(scrolls.contains { $0.hasHorizontalScroller })
        XCTAssertTrue(scrolls.contains { $0.hasVerticalScroller })
        XCTAssertEqual(fields().filter { $0.stringValue == row.name }.count, 15)
        XCTAssertEqual(fields().filter { $0.stringValue == "/" }.map(\.frame.minX), Array(repeating: slash.frame.minX, count: 16))
        XCTAssertEqual(size.width, card.update(many, availableHeight: 185).width)
    }

    @MainActor
    func testHoverDwellRequiresPointerToRemainOverNetwork() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let entry = StatusEntry()
        let network = NetworkPanel()
        let hover = StatusPanelShell(item: entry.item, content: network.panelContent)
        defer { hover.stop(); entry.removeForExit() }
        let anchor = NSRect(x: screen.frame.midX, y: screen.visibleFrame.maxY, width: 40, height: 24)
        let inside = NSPoint(x: anchor.midX, y: anchor.midY)
        var pointer = inside
        func schedule() { hover.schedulePresentation(under: anchor, within: screen.visibleFrame, pointerLocation: { pointer }) }
        func visiblePanel() -> NSWindow? { NSApp.windows.first { $0.title == "网络状况" && $0.isVisible } }

        schedule()
        XCTAssertNil(visiblePanel())
        pointer.x = anchor.maxX + 10
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertNil(visiblePanel())

        pointer = inside
        schedule()
        hover.setMenuOpen(true)
        hover.setMenuOpen(false)
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertNil(visiblePanel())

        schedule()
        try await waitUntil { visiblePanel()?.alphaValue == 1 }
    }

    @MainActor
    func testSiteFilterKeepsQuickConfigurationAnchoredUntilDismissed() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let anchor = NSRect(x: screen.frame.midX, y: screen.visibleFrame.maxY, width: 30, height: 22)
        let panel = NetworkPanel()
        var site = ConnectivityState.Row(id: "id", name: "测试服务", enabled: true)
        panel.update(.init(rows: [site]))
        let window = try XCTUnwrap(panel.panelContent.show(anchor, screen, false))
        defer { panel.panelContent.close() }
        let card = try XCTUnwrap(window.contentView)
        func siteButton() -> NSButton? { view(card) { (b: NSButton) in b.toolTip == "测试服务 · 快捷配置" } }
        let button = try XCTUnwrap(siteButton())
        panel.openSite = { id, anchor in
            XCTAssertEqual(id, site.id)
            XCTAssertTrue(anchor === button)
            site = .init(id: site.id, name: site.name, enabled: false)
            panel.update(.init(rows: [site]))
            XCTAssertTrue(window.protectsInteraction())
            XCTAssertTrue(siteButton() === button)
        }
        button.performClick(nil)
        XCTAssertNil(siteButton())
        XCTAssertFalse(window.protectsInteraction())
        let filter = try XCTUnwrap(view(card) { (b: NSButton) in b.title == "显示所有站点" })
        panel.setShowAllSites = { $0 }
        filter.performClick(nil)
        XCTAssertNotNil(siteButton())
        XCTAssertFalse(site.enabled)
    }

    @MainActor
    func testPinnedHoverKeepsItsPositionAndAllowsBackgroundDrag() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let bounds = screen.visibleFrame
        let anchor = NSRect(x: bounds.midX, y: bounds.maxY, width: 40, height: 24)
        let entry = StatusEntry()
        let network = NetworkPanel()
        let hover = StatusPanelShell(item: entry.item, content: network.panelContent)
        defer { hover.stop(); entry.removeForExit() }
        hover.resetPosition()
        let row = ConnectivityState.Row(id: "site", name: "测试服务", enabled: true)
        network.update(.init(rows: [row]))
        let key = NSApp.keyWindow
        hover.show(under: anchor, within: screen.visibleFrame)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "网络状况" && $0.isVisible })
        let card = try XCTUnwrap(panel.contentView as? HoverCard)
        let pin = try XCTUnwrap(view(card) { (button: NSButton) in button.toolTip == "固定在最前" })
        let probe = try XCTUnwrap(view(card) { (button: NSButton) in button.title == "立即探测" })
        XCTAssertFalse(panel.isMovable)
        XCTAssertTrue(pin.acceptsFirstMouse(for: nil))
        XCTAssertFalse(pin.isBordered)
        let center = NSPoint(x: card.bounds.midX, y: card.bounds.midY)
        XCTAssertTrue(card.canDrag(at: center))
        pin.performClick(nil)
        XCTAssertEqual(pin.state, .on)
        XCTAssertTrue(pin.isBordered)
        XCTAssertTrue(panel.isMovable)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertTrue(NSApp.keyWindow === key)
        func hit(at point: NSPoint) -> NSView? {
            card.hitTest(card.superview?.convert(point, from: nil) ?? point)
        }
        let dragTarget = try XCTUnwrap(hit(at: center))
        XCTAssertTrue(dragTarget.acceptsFirstMouse(for: nil))
        // Check AppKit's actual target across the full card, including inside the scrolling table.
        let site = try XCTUnwrap(view(card) { (button: NSButton) in button.accessibilityLabel()?.contains("快捷配置") == true })
        let config = try XCTUnwrap(view(card) { (button: NSButton) in button.title == "探测配置" })
        let all = try XCTUnwrap(view(card) { (button: NSButton) in button.title == "显示所有站点" })
        let controls = [pin, probe, site, config, all]
        for x in stride(from: 3.0, to: card.bounds.width, by: 13) {
            for y in stride(from: 3.0, to: card.bounds.height, by: 13) {
                let point = NSPoint(x: x, y: y)
                if controls.contains(where: { $0.bounds.contains($0.convert(point, from: nil)) }) { continue }
                XCTAssertTrue(card.canDrag(at: point))
                XCTAssertTrue(hit(at: point) === dragTarget, "Different drag target at \(point)")
            }
        }
        for title in ["网络状况", "下次发起", "站点", "预计探测流量 0 B/h"] {
            let label = try XCTUnwrap(view(card) { (field: NSTextField) in field.stringValue == title })
            let point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: nil)
            XCTAssertTrue(hit(at: point) === dragTarget, title)
        }
        for button in controls {
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            XCTAssertTrue(hit(at: center) === button, button.title)
            XCTAssertFalse(card.canDrag(at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)))
        }

        panel.setFrameOrigin(NSPoint(x: bounds.minX + 30, y: bounds.minY + 80))
        let moved = panel.frame
        hover.trackAnchor { _ in XCTFail("A pinned panel must not follow the menu bar"); return anchor }
        hover.setMenuOpen(true)
        network.update(.init(rows: [row], rate: "10 KB/h"))
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame, moved)
        network.update(.init(rows: [row, row]))
        XCTAssertEqual(panel.frame.minX, moved.minX)
        XCTAssertEqual(panel.frame.maxY, moved.maxY)
        pin.performClick(nil)
        XCTAssertEqual(pin.state, .off)
        XCTAssertFalse(pin.isBordered)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isMovable)
    }

    @MainActor
    func testProbeWaitStaysHiddenForFirst250Milliseconds() throws {
        let timing = ProbeTimingView()
        func configure(starts: [TimeInterval]) {
            timing.configure(ProbeLaneTimeline(result: .success(0.08), next: 30, settings: ProbeLane.fresh.defaults,
                                               full: false, starts: starts), name: "站点 · 新建", enabled: true)
        }

        configure(starts: [10, 10.125])
        XCTAssertNil(timing.liveWaitDetail(at: 10.249))
        let first = try XCTUnwrap(timing.liveWaitDetail(at: 10.25))
        XCTAssertTrue(first.contains("请求 1"))
        XCTAssertFalse(first.contains("请求 2"))
        XCTAssertTrue(try XCTUnwrap(timing.liveWaitDetail(at: 10.375)).contains("请求 2"))
        configure(starts: [10.125])
        XCTAssertFalse(try XCTUnwrap(timing.liveWaitDetail(at: 10.375)).contains("请求 2"))
        configure(starts: [])
        XCTAssertNil(timing.liveWaitDetail(at: 10.4))
        XCTAssertTrue((timing.accessibilityValue() as? String)?.hasPrefix("80 ms") == true)
    }

    @MainActor
    func testHoverBridgeAndButtonOnFirstClick() throws {
        let anchor = NSRect(x: -180, y: 800, width: 40, height: 24)
        let panel = NSRect(x: -790, y: 580, width: 780, height: 216)
        XCTAssertTrue(StatusPanelShell.retainsHover(at: .init(x: -170, y: 798), anchor: anchor, panel: panel))
        XCTAssertTrue(StatusPanelShell.retainsHover(at: .init(x: -20, y: 588), anchor: anchor, panel: panel))
        XCTAssertFalse(StatusPanelShell.retainsHover(at: .init(x: -30, y: 798), anchor: anchor, panel: panel))
        let now = ProcessInfo.processInfo.systemUptime
        let card = HoverCard()
        let sites = [ConnectivityState.Row(id: "g", name: "Google", enabled: true,
                                           dailyCount: .init(successes: 20, completed: 20),
                                           freshCount: .init(successes: 8, completed: 10)),
                     .init(id: "c", name: "Cursor", enabled: true, freshCount: .init(successes: 0, completed: 2)),
                     .init(id: "n", name: "NAS", enabled: true, isTCP: true)]
        let size = card.update(.init(rows: sites), availableHeight: 400)
        let fast = ProbeLaneTimeline(result: .success(0.8), next: now + 3, settings: ProbeLane.fresh.defaults, full: true, starts: [now - 7, now - 1])
        let slow = ProbeLaneTimeline(result: .success(0.801), next: now + 12, settings: ProbeLane.daily.defaults, full: false, starts: [])
        let failed = ProbeLaneTimeline(result: .connectionRefused, next: now + 123, settings: ProbeLane.fresh.defaults, full: false, starts: [])
        card.setTimeline(.init(lanes: ["g": [.fresh: fast, .daily: slow], "c": [.fresh: slow], "n": [.fresh: failed]]))
        for value in ["0", "80", "801 ms", "连接被拒绝"] {
            let field = try XCTUnwrap(view(card) { (field: NSTextField) in field.stringValue == value })
            XCTAssertEqual(field.textColor, HoverPalette.warning, value)
        }
        for (value, color) in [("800 ms", NSColor.labelColor), ("100", .secondaryLabelColor)] {
            let field = try XCTUnwrap(view(card) { (field: NSTextField) in field.stringValue == value })
            XCTAssertEqual(field.textColor, color, value)
        }
        XCTAssertNotNil(view(card) { (field: NSTextField) in field.stringValue == "—" && field.textColor == .secondaryLabelColor })
        XCTAssertNil(view(card) { (field: NSTextField) in field.stringValue == "—" && field.textColor == HoverPalette.warning })
        XCTAssertNil(card.clock)
        card.setVisible(true)
        let clock = try XCTUnwrap(card.clock)
        let button = try XCTUnwrap(card.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "立即探测" })
        var clicks = 0
        card.probeNow = { clicks += 1 }
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        XCTAssertTrue(button.isEnabled)
        button.performClick(nil)
        XCTAssertEqual(clicks, 1)
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = card
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            card.setPinned(appearance == .darkAqua)
            window.appearance = NSAppearance(named: appearance)
            window.display()
            let bitmap = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
            card.cacheDisplay(in: card.bounds, to: bitmap)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "probe-hover-" + appearance.rawValue
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        card.setVisible(false)
        XCTAssertFalse(clock.isValid)
        XCTAssertNil(card.clock)
        card.setTimeline(.init())
        XCTAssertFalse(button.isEnabled)
    }
}
