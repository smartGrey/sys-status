import Foundation

struct DeviceKey: Codable, Hashable, Sendable {
    let uid: String
    let source: UInt32?
}

struct AllowedDevice: Codable, Identifiable, Equatable, Sendable {
    var key: DeviceKey
    var name: String
    var kind: String
    var id: DeviceKey { key }
}

struct HearingPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var thresholdDB: Double = 9 // relative spectral prominence, not dBFS
    var noiseReductionDB: Double = 12
    var gainDB: Double = 6
    var holdSeconds: Double = 1
    var allowed: [AllowedDevice] = []

    mutating func normalize() {
        thresholdDB = thresholdDB.isFinite ? min(30, max(3, thresholdDB)) : 9
        noiseReductionDB = noiseReductionDB.isFinite ? min(30, max(0, noiseReductionDB)) : 12
        gainDB = gainDB.isFinite ? min(36, max(-12, gainDB)) : 6
        holdSeconds = holdSeconds.isFinite ? min(3, max(0.2, holdSeconds)) : 1
        var seen = Set<DeviceKey>()
        allowed = allowed.filter { !$0.key.uid.isEmpty && seen.insert($0.key).inserted }
    }
    func allows(_ key: DeviceKey) -> Bool { allowed.contains { $0.key == key } }

}

struct AudioDevice: Equatable, Identifiable, Sendable {
    let id: UInt32
    let key: DeviceKey
    let name: String
    let kind: String
    let inputChannels: UInt32
    let outputChannels: UInt32
    let rate: Double
    let bufferFrames: UInt32
    let rejection: String?
    var supported: Bool { rejection == nil && outputChannels > 0 && !key.uid.isEmpty }
}

struct DeviceCatalog: Equatable, Sendable {
    var input: AudioDevice?
    var outputs: [AudioDevice] = []
    var defaultOutputID: UInt32 = 0
    var currentOutput: AudioDevice? { outputs.first { $0.id == defaultOutputID } }
}

struct EngineRoute: Equatable, Sendable {
    let input: AudioDevice
    let output: AudioDevice?
}

enum StopReason: Equatable, Sendable {
    case disabled, sleeping, permission, noMicrophone, noOutput, unsupported(String), notAllowed(String)
    var title: String {
        switch self {
        case .disabled: "已关闭"
        case .sleeping: "睡眠暂停"
        case .permission: "需要麦克风权限"
        case .noMicrophone: "内置麦克风不可用"
        case .noOutput: "等待音频输出"
        case .unsupported: "当前输出不支持"
        case .notAllowed: "等待允许的设备"
        }
    }

}

enum RouteDecision: Equatable, Sendable {
    case stopped(StopReason), run(EngineRoute)
}

enum RoutePolicy {
    static func decide(_ preferences: HearingPreferences, catalog: DeviceCatalog,
                       authorized: Bool, sleeping: Bool, calibrating: Bool) -> RouteDecision {
        if sleeping { return .stopped(.sleeping) }
        if !preferences.enabled && !calibrating { return .stopped(.disabled) }
        guard authorized else { return .stopped(.permission) }
        guard let input = catalog.input else { return .stopped(.noMicrophone) }
        if calibrating { return .run(EngineRoute(input: input, output: nil)) }
        guard let output = catalog.currentOutput else { return .stopped(.noOutput) }
        guard output.supported else {
            return .stopped(.unsupported(output.rejection ?? "该输出设备目前不可用。"))
        }
        guard preferences.allows(output.key) else { return .stopped(.notAllowed(output.name)) }
        return .run(EngineRoute(input: input, output: output))
    }
}

struct ThresholdRecommendation: Identifiable, Equatable {
    enum Kind: Int, CaseIterable { case sensitive, normal, resistant
        var title: String { switch self { case .sensitive: "敏感"; case .normal: "常规"; case .resistant: "抗扰" } }
    }
    let kind: Kind
    let value: Double
    var id: Kind { kind }
}

enum Calibration {
    static func recommendations(normal: Double) -> [ThresholdRecommendation] {
        guard normal.isFinite else { return [] }
        let center = min(27, max(6, normal.rounded()))
        return ThresholdRecommendation.Kind.allCases.map {
            .init(kind: $0, value: center + Double($0.rawValue - 1) * 3)
        }
    }
}

/// Both thumb and live fill represent the same relative spectral prominence.
enum ThresholdScale {
    static func fraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, (value - 3) / 27))
    }
    static func value(at fraction: Double) -> Double {
        guard fraction.isFinite else { return 9 }
        return (3 + min(1, max(0, fraction)) * 27).rounded()
    }
}
