@testable import StatusBarCore
import XCTest

final class PolicyTests: XCTestCase {
    let microphone = AudioDevice(id: 1, key: .init(uid: "mic", source: nil), name: "内置麦克风",
        kind: "内置", inputChannels: 1, outputChannels: 0, rate: 44100, bufferFrames: 512, rejection: nil)
    func output(_ id: UInt32 = 2, uid: String = "headphone", source: UInt32? = nil, rejected: Bool = false) -> AudioDevice {
        .init(id: id, key: .init(uid: uid, source: source), name: "耳机", kind: "蓝牙",
              inputChannels: 0, outputChannels: 2, rate: 48000, bufferFrames: 512,
              rejection: rejected ? "内置扬声器不允许" : nil)
    }
    func preferences(_ device: AudioDevice) -> HearingPreferences {
        var p = HearingPreferences(); p.enabled = true
        p.allowed = [.init(key: device.key, name: device.name, kind: device.kind)]
        return p
    }
    func decide(_ p: HearingPreferences, _ outputs: [AudioDevice], current: UInt32 = 2,
                authorized: Bool = true, asleep: Bool = false, calibrating: Bool = false) -> RouteDecision {
        RoutePolicy.decide(p, catalog: .init(input: microphone, outputs: outputs, defaultOutputID: current),
                           authorized: authorized, sleeping: asleep, calibrating: calibrating)
    }
    func testMasterOffOverridesAllowedRoute() {
        let d = output(); var p = preferences(d); p.enabled = false
        XCTAssertEqual(decide(p, [d]), .stopped(.disabled))
    }
    func testAllowedCurrentRouteStarts() {
        let d = output()
        XCTAssertEqual(decide(preferences(d), [d]), .run(.init(input: microphone, output: d)))
    }
    func testDoesNotFallbackToAnotherAllowedDevice() {
        let allowed = output(3, uid: "other"), current = output()
        XCTAssertEqual(decide(preferences(allowed), [allowed, current]), .stopped(.notAllowed("耳机")))
    }
    func testSpeakerStillRejectedWhenPersistedInAllowlist() {
        let d = output(rejected: true)
        XCTAssertEqual(decide(preferences(d), [d]), .stopped(.unsupported("内置扬声器不允许")))
    }
    func testReconnectionUsesUIDNotTransientObjectID() {
        let old = output(2), reconnected = output(19)
        XCTAssertEqual(decide(preferences(old), [reconnected], current: 19),
                       .run(.init(input: microphone, output: reconnected)))
    }
    func testSameNameWithNewUIDIsNotTrusted() {
        XCTAssertEqual(decide(preferences(output(uid: "old")), [output(uid: "new")]), .stopped(.notAllowed("耳机")))
    }
    func testDifferentPortDoesNotInheritTrust() {
        XCTAssertEqual(decide(preferences(output(source: 1)), [output(source: 2)]), .stopped(.notAllowed("耳机")))
    }
    func testCalibrationCapturesOnlyAndDoesNotRequireOutput() {
        XCTAssertEqual(decide(HearingPreferences(), [], current: 0, calibrating: true),
                       .run(.init(input: microphone, output: nil)))
    }
    func testCalibrationStillRequiresPermissionAndWake() {
        XCTAssertEqual(decide(HearingPreferences(), [], authorized: false, calibrating: true), .stopped(.permission))
        XCTAssertEqual(decide(HearingPreferences(), [], asleep: true, calibrating: true), .stopped(.sleeping))
    }
    func testNoMicrophoneDoesNotSelectAlternativeInput() {
        XCTAssertEqual(RoutePolicy.decide(preferences(output()), catalog: .init(input: nil, outputs: [output()], defaultOutputID: 2),
            authorized: true, sleeping: false, calibrating: false), .stopped(.noMicrophone))
    }
    func testPersistenceRoundtripAndDeduplication() throws {
        var p = preferences(output()); p.allowed += p.allowed
        p.thresholdDB = -100; p.gainDB = 40; p.holdSeconds = -1
        p.normalize()
        XCTAssertEqual(p.allowed.count, 1)
        XCTAssertEqual(p.thresholdDB, 3); XCTAssertEqual(p.gainDB, 36); XCTAssertEqual(p.holdSeconds, 0.2)
        XCTAssertEqual(try JSONDecoder().decode(HearingPreferences.self, from: JSONEncoder().encode(p)), p)
    }
    func testRecommendationsRemainDistinctAndBounded() {
        for normal in [-100.0, 6, 9, 27, 100] {
            let values = Calibration.recommendations(normal: normal).map(\.value)
            XCTAssertEqual(values.count, 3)
            XCTAssertEqual(values[1] - values[0], 3)
            XCTAssertEqual(values[2] - values[1], 3)
            XCTAssertGreaterThanOrEqual(values[0], 3)
            XCTAssertLessThanOrEqual(values[2], 30)
        }
        XCTAssertTrue(Calibration.recommendations(normal: .nan).isEmpty)
    }
    func testNewParametersNormalizeNonfiniteAndOutOfRangeValues() {
        var p = HearingPreferences(); p.thresholdDB = .nan; p.noiseReductionDB = .infinity
        p.normalize()
        XCTAssertEqual(p.thresholdDB, 9); XCTAssertEqual(p.noiseReductionDB, 12)
        p.noiseReductionDB = -1; p.thresholdDB = 100; p.normalize()
        XCTAssertEqual(p.noiseReductionDB, 0); XCTAssertEqual(p.thresholdDB, 30)
    }
    func testExtendedReductionPreservesSavedSettingsAndClampsMaximum() throws {
        var p = preferences(output()); p.gainDB = 30; p.holdSeconds = 0.6
        for value in [0.0,12,18,24,30] {
            p.noiseReductionDB = value; p.normalize()
            let restored = try JSONDecoder().decode(HearingPreferences.self, from: JSONEncoder().encode(p))
            XCTAssertEqual(restored, p); XCTAssertEqual(restored.noiseReductionDB, value)
            XCTAssertEqual(restored.gainDB, 30); XCTAssertEqual(restored.holdSeconds, 0.6)
        }
        p.noiseReductionDB = 300; p.normalize(); XCTAssertEqual(p.noiseReductionDB, 30)
        XCTAssertEqual(HearingPreferences().noiseReductionDB, 12)
    }
}
