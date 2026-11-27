import AppKit
import XCTest
@testable import StatusBarCore

final class StatusPresentationTests: XCTestCase {
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
        let externalButton = try XCTUnwrap(StatusHover.replicaFrame(of: button, from: source, to: external,
                                                                   topRightArea: nil))
        XCTAssertEqual(externalButton, NSRect(x: -2468, y: 1184.5, width: 34, height: 22))

        let builtIn = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let rightOfNotch = NSRect(x: 956.5, y: 1085, width: 771.5, height: 32)
        let builtInButton = try XCTUnwrap(StatusHover.replicaFrame(of: button, from: source, to: builtIn,
                                                                  topRightArea: rightOfNotch))
        XCTAssertEqual(builtInButton, NSRect(x: 1180, y: 1090.5, width: 34, height: 22))
        XCTAssertNil(StatusHover.replicaFrame(of: button.offsetBy(dx: -250, dy: 0), from: source, to: builtIn,
                                              topRightArea: rightOfNotch))
        XCTAssertNil(StatusHover.replicaFrame(of: button.offsetBy(dx: 0, dy: -60), from: source, to: external,
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
        let hover = StatusHover(item: entry.item)
        entry.updateNetwork(speed: nil, connectivity: state)
        hover.update(state)
        XCTAssertEqual(button.toolTip, state.hoverTooltip)
        XCTAssertEqual(button.accessibilityHelp(), state.summary)
        XCTAssertTrue(state.summary.contains(row.name + "，复用 132 ms，新建 非预期状态码 403"))
        XCTAssertTrue(state.summary.contains("复用成功率 100%，成功 7 次，完成 7 次，新建成功率 100%，成功 2 次，完成 2 次"))
        let fields = try XCTUnwrap(card.contentView).subviews.compactMap { $0 as? NSTextField }
        let percentages = fields.filter { $0.stringValue == "100" }.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(percentages.count, 2)
        let dailyRate = try XCTUnwrap(percentages.first)
        let freshRate = try XCTUnwrap(percentages.last)
        let slash = try XCTUnwrap(fields.first { $0.stringValue == "/" })
        XCTAssertEqual(dailyRate.alignment, .right)
        XCTAssertEqual(freshRate.alignment, .left)
        XCTAssertGreaterThanOrEqual(dailyRate.frame.width, dailyRate.intrinsicContentSize.width)
        XCTAssertGreaterThanOrEqual(freshRate.frame.width, freshRate.intrinsicContentSize.width)
        XCTAssertGreaterThan(slash.frame.width, slash.intrinsicContentSize.width)
        XCTAssertGreaterThan(slash.frame.minX, dailyRate.frame.maxX)
        XCTAssertEqual(slash.frame.minX - dailyRate.frame.maxX, freshRate.frame.minX - slash.frame.maxX)
        XCTAssertEqual(card.update(state, availableHeight: 180, availableWidth: 320).width, 320)
        let header = try XCTUnwrap(fields.first { $0.stringValue == "复用/新建请求成功率(%)" })
        XCTAssertEqual(header.maximumNumberOfLines, 1)
        XCTAssertGreaterThanOrEqual(header.frame.width, header.intrinsicContentSize.width)
        XCTAssertEqual(header.frame.maxX, freshRate.frame.maxX)
        let fresh = try XCTUnwrap(fields.first { $0.stringValue == "新建" })
        XCTAssertEqual(header.frame.minY, fresh.frame.minY)
        XCTAssertGreaterThan(header.frame.minX, fresh.frame.maxX)
        let name = try XCTUnwrap(fields.first { $0.stringValue == row.name })
        XCTAssertEqual(name.accessibilityLabel(), row.spoken)
        XCTAssertGreaterThan(size.width, 402)
        let shorter = ConnectivityState.Row(id: "short", name: "Short", enabled: true,
                                            freshCount: .init(successes: 97, completed: 100))
        let zero = ConnectivityState.Row(id: "zero", name: "Zero", enabled: true,
                                         dailyCount: .init(successes: 0, completed: 1))
        _ = card.update(.init(rows: [row, shorter, zero]), availableHeight: 185, availableWidth: 320)
        let rateFields = try XCTUnwrap(card.contentView).subviews.compactMap { $0 as? NSTextField }
        func column(_ reference: NSTextField) -> [String] {
            rateFields.filter { $0.frame.minX == reference.frame.minX && $0.frame.height == reference.frame.height }
                .sorted { $0.frame.minY > $1.frame.minY }
                .map(\.stringValue)
        }
        XCTAssertEqual(column(dailyRate), ["100", "—", "0"])
        XCTAssertEqual(column(slash), ["/", "/", "/"])
        XCTAssertEqual(column(freshRate), ["100", "97", "—"])
        XCTAssertEqual(state.color, .red)
        let many = ConnectivityState(rows: Array(repeating: row, count: 15))
        XCTAssertLessThanOrEqual(card.update(many, availableHeight: 185).height, 185)
        XCTAssertEqual(size.width, card.update(many, availableHeight: 185).width)
    }
}
