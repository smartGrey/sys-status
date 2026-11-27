import Foundation

// C++ publishes snapshots and parameters through lock-free atomics. Hardware
// mutations are confined to AudioBackend; deinit runs after shutdown completes.
final class AudioHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init() { pointer = HearingCreate()! }
    deinit { HearingDestroy(pointer) }
    func mute() { HearingSetOutputAllowed(pointer, 0) }
    func allowOutput() { HearingSetOutputAllowed(pointer, 1) }
    func snapshot() -> HearingSnapshot { HearingReadSnapshot(pointer) }
    func configure(_ preferences: HearingPreferences) {
        HearingSetParameters(pointer, .init(thresholdDB: Float(preferences.thresholdDB),
                                           gainDB: Float(preferences.gainDB),
                                           holdSeconds: Float(preferences.holdSeconds),
                                           noiseReductionDB: Float(preferences.noiseReductionDB)))
    }
}

actor AudioBackend {
    let handle: AudioHandle
    private var current: EngineRoute?
    private var generation: UInt64 = 0
    private var lastInputKey: DeviceKey?
    private var stoppedAt: Date?
    init(handle: AudioHandle) { self.handle = handle }
    func apply(_ route: EngineRoute?, generation token: UInt64, force: Bool = false) -> Int32 {
        guard token >= generation else { return 0 }
        generation = token
        if !force && current == route { return 0 }
        handle.mute()
        if current != nil { stoppedAt = Date() }
        HearingStop(handle.pointer)
        current = nil
        guard let route else { return 0 }
        if lastInputKey != route.input.key || (stoppedAt.map { Date().timeIntervalSince($0) > 30 } ?? true) {
            HearingInvalidateEnvironment(handle.pointer)
        }
        lastInputKey = route.input.key
        let status = HearingStart(handle.pointer, route.input.id, route.output?.id ?? 0)
        if status == 0 { current = route }
        return status
    }
    func completeCalibration(request: UInt64, generation token: UInt64) -> Bool {
        guard token >= generation else { return false }
        generation = token
        handle.mute()
        HearingStop(handle.pointer)
        current = nil; stoppedAt = Date()
        return HearingCommitCalibration(handle.pointer, request) != 0
    }
    func stop(generation token: UInt64) {
        guard token >= generation else { return }
        generation = token
        handle.mute()
        if current != nil { stoppedAt = Date() }
        HearingStop(handle.pointer)
        current = nil
    }
}
