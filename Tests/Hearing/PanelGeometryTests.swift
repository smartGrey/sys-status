import XCTest

final class PanelGeometryTests: XCTestCase {
    func testDropdownStaysAnchoredBelowStatusItemAsContentGrows() {
        let visible = CGRect(x: 0, y: 60, width: 1512, height: 880)
        let anchor = CGRect(x: 1300, y: 940, width: 26, height: 24)
        let small = StatusPanelGeometry.frame(size: CGSize(width: 360, height: 460), under: anchor, within: visible, trailing: true)
        let expanded = StatusPanelGeometry.frame(size: CGSize(width: 360, height: 520), under: anchor, within: visible, trailing: true)
        XCTAssertEqual(small.maxY, expanded.maxY)
        XCTAssertEqual(small.maxX, anchor.maxX)
        XCTAssertLessThan(expanded.maxY, anchor.minY)
        XCTAssertTrue(visible.contains(expanded))
    }
    func testThresholdFillAndThumbShareScaleAndClampDrags() {
        for threshold in stride(from: 3.0, through: 30.0, by: 1) {
            XCTAssertEqual(ThresholdScale.value(at: ThresholdScale.fraction(threshold)), threshold)
        }
        XCTAssertEqual(ThresholdScale.value(at: -0.5), 3)
        XCTAssertEqual(ThresholdScale.value(at: 2), 30)
        XCTAssertEqual(ThresholdScale.fraction(-120), 0)
        XCTAssertEqual(ThresholdScale.fraction(30), 1)
        XCTAssertEqual(ThresholdScale.fraction(.nan), 0)
    }

    func testOversizedPanelFitsSecondaryScreenBelowMenuBar() {
        let screen = CGRect(x: -1920, y: -600, width: 1920, height: 1040)
        let button = CGRect(x: -26, y: screen.maxY, width: 24, height: 24)
        let frame = StatusPanelGeometry.frame(size: .init(width: 2000, height: 2000), under: button, within: screen)
        XCTAssertEqual(frame, CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height - 4))
    }
}
