@testable import StatusBarCore
import XCTest
import Combine

final class PresentationTests: XCTestCase {
    @MainActor
    func testHiddenMeterPublishesNothingAndReopensWithLatestSnapshot() {
        let meter = PanelMeter()
        var received: [MeterState] = []
        let subscription = meter.$state.dropFirst().sink { received.append($0) }
        for i in 0..<100 {
            meter.accept(.init(level: Double(i), active: true, passing: true, calibrationProgress: Double(i)/100))
        }
        XCTAssertTrue(received.isEmpty)
        meter.setVisible(true)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(meter.state.level, 99)
        XCTAssertEqual(meter.state.calibrationProgress, 0.99)
        meter.accept(meter.state)
        XCTAssertEqual(received.count, 1)
        meter.setVisible(false)
        meter.accept(.init())
        XCTAssertEqual(received.count, 1)
        meter.setVisible(true)
        XCTAssertEqual(meter.state, MeterState())
        XCTAssertEqual(received.count, 2)
        withExtendedLifetime(subscription) {}
    }
    @MainActor
    func testVisibleMeterKeepsLevelAndCalibrationUpdates() {
        let meter = PanelMeter(); meter.setVisible(true)
        meter.accept(.init(level: 16, active: true, passing: false, calibrationProgress: 0.5))
        XCTAssertEqual(meter.state.level, 16)
        XCTAssertEqual(meter.state.calibrationProgress, 0.5)
        meter.accept(.init(level: 17, active: true, passing: true, calibrationProgress: 1))
        XCTAssertTrue(meter.state.passing)
        XCTAssertEqual(meter.state.calibrationProgress, 1)
    }
    func testIconQuantizationPreservesOriginalIlluminationAndDeduplicatesLevels() {
        var allStates = Set<StatusIconState>()
        for level in stride(from: -5.0, through: 40.0, by: 0.1) {
            for enabled in [false, true] {
                for passing in [false, true] {
                    let state = StatusIconState(enabled: enabled, passing: passing, level: level)
                    let fraction = max(0, min(1, (level-3)/27))
                    XCTAssertEqual(state.bars, (0..<4).filter { enabled && Double($0)/4 < fraction }.count)
                    allStates.insert(state)
                }
            }
        }
        XCTAssertEqual(allStates.count, 11)
        XCTAssertEqual(StatusIconState(enabled: true, passing: false, level: 4),
                       StatusIconState(enabled: true, passing: false, level: 5))
        XCTAssertNotEqual(StatusIconState(enabled: true, passing: false, level: 5),
                          StatusIconState(enabled: true, passing: true, level: 5))
        XCTAssertEqual(StatusIconState(enabled: true, passing: false, level: .nan).bars, 0)
    }
    func testPollingKeepsActiveResponseAndStopsDuringSleep() {
        XCTAssertEqual(RuntimePolling.interval(active: true, sleeping: false), 0.125)
        XCTAssertEqual(RuntimePolling.interval(active: false, sleeping: false), 1)
        XCTAssertNil(RuntimePolling.interval(active: true, sleeping: true))
        XCTAssertNil(RuntimePolling.interval(active: false, sleeping: true))
    }
}
