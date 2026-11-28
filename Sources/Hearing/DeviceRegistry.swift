import CoreAudio
import Foundation

@MainActor
final class DeviceRegistry {
    private struct Observation {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var observations: [Observation] = []
    private var observedDevices = Set<AudioObjectID>()
    private let observerQueue = DispatchQueue(label: "com.smartgrey.netrate.hearing.device-events", qos: .userInitiated)
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var active = false
    private(set) var catalog = DeviceCatalog()
    var onChange: ((DeviceCatalog) -> Void)?
    var emergencyMute: (@Sendable () -> Void)?
    var onInvalidation: (() -> Void)?

    func start() {
        guard !active else { return }
        active = true
        observeSystem()
        refresh()
    }

    func setMonitoringAudio(_ monitoring: Bool) {
        guard active, monitoring else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    private func observeSystem() {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyServiceRestarted] {
            observe(AudioObjectID(kAudioObjectSystemObject), selector, scope: kAudioObjectPropertyScopeGlobal)
        }
    }
    func stop() {
        active = false
        timer?.invalidate(); timer = nil
        refreshTask?.cancel()
        removeObservations()
    }
    private func removeObservations() {
        for observation in observations {
            var address = observation.address
            AudioObjectRemovePropertyListenerBlock(observation.object, &address, observerQueue, observation.block)
        }
        observations.removeAll(); observedDevices.removeAll()
    }
    private func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return }
        let mute = emergencyMute
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            mute?()
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                if selector == kAudioHardwarePropertyServiceRestarted {
                    self.removeObservations()
                    self.observeSystem()
                }
                self.onInvalidation?()
                self.refreshTask?.cancel()
                self.refreshTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    guard let self, self.active else { return }
                    self.refresh(force: true)
                }
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, observerQueue, block) == noErr {
            observations.append(.init(object: object, address: address, block: block))
        }
    }
    func refresh(force: Bool = false) {
        let ids: [AudioDeviceID] = Self.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        let currentIDs = Set(ids)
        if active && observedDevices != currentIDs {
            let retained = observations.filter { $0.object == kAudioObjectSystemObject }
            for observation in observations where observation.object != kAudioObjectSystemObject {
                var address = observation.address
                AudioObjectRemovePropertyListenerBlock(observation.object, &address, observerQueue, observation.block)
            }
            observations = retained
            observedDevices = currentIDs
            for id in ids {
                for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate,
                                 kAudioDevicePropertyBufferFrameSize, kAudioDevicePropertyDeviceHasChanged] {
                    observe(id, selector, scope: kAudioObjectPropertyScopeGlobal)
                }
                for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                    for selector in [kAudioDevicePropertyStreams, kAudioDevicePropertyDataSource,
                                     kAudioDevicePropertyJackIsConnected] {
                        observe(id, selector, scope: scope)
                    }
                }
            }
        }
        var next = DeviceCatalog()
        next.defaultOutputID = Self.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: UInt32(0))
        for id in ids {
            let device = Self.describe(id)
            let transport = Self.value(id, kAudioDevicePropertyTransportType, default: UInt32(0))
            let alive = Self.value(id, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0)) != 0
            if transport == kAudioDeviceTransportTypeBuiltIn && device.inputChannels > 0 && alive {
                if next.input == nil || device.key.uid == "BuiltInMicrophoneDevice" { next.input = device }
            }
            if device.outputChannels > 0 { next.outputs.append(device) }
        }
        next.outputs.sort {
            if $0.id == next.defaultOutputID { return true }
            if $1.id == next.defaultOutputID { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if next != catalog || force {
            emergencyMute?()
            catalog = next
            onChange?(next)
        }
    }
    static func describe(_ id: AudioDeviceID) -> AudioDevice {
        let uid = string(id, kAudioDevicePropertyDeviceUID)
        let name = string(id, kAudioObjectPropertyName)
        let transport = value(id, kAudioDevicePropertyTransportType, default: UInt32(0))
        let input = channels(id, scope: kAudioObjectPropertyScopeInput)
        let output = channels(id, scope: kAudioObjectPropertyScopeOutput)
        let alive = value(id, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0)) != 0
        let rate = value(id, kAudioDevicePropertyNominalSampleRate, default: Double(0))
        let buffer = value(id, kAudioDevicePropertyBufferFrameSize, default: UInt32(0))
        let sources: [UInt32] = array(id, kAudioDevicePropertyDataSources, scope: kAudioObjectPropertyScopeOutput)
        let source: UInt32? = sources.count > 1
            ? optionalValue(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, default: UInt32(0))
            : nil
        let streams: [AudioStreamID] = array(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        let terminals: [UInt32] = streams.map { value($0, kAudioStreamPropertyTerminalType, default: UInt32(0)) }
        let jack: UInt32? = optionalValue(id, kAudioDevicePropertyJackIsConnected,
                                         scope: kAudioObjectPropertyScopeOutput, default: UInt32(0))
        let kind: String
        var rejection: String?
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            let headphone = terminals.contains(kAudioStreamTerminalTypeHeadphones) || uid == "BuiltInHeadphoneOutputDevice"
            if headphone && !terminals.contains(kAudioStreamTerminalTypeSpeaker) && jack != 0 {
                kind = "耳机插孔"
            } else {
                kind = "内置设备"
                rejection = "内置扬声器不播放环境声。请切换到耳机。"
            }
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: kind = "蓝牙"
        case kAudioDeviceTransportTypeUSB: kind = "USB"
        case kAudioDeviceTransportTypeHDMI: kind = "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: kind = "DisplayPort"
        case kAudioDeviceTransportTypeThunderbolt: kind = "Thunderbolt"
        case kAudioDeviceTransportTypePCI: kind = "PCI"
        case kAudioDeviceTransportTypeFireWire: kind = "FireWire"
        case kAudioDeviceTransportTypeAggregate:
            kind = "聚合 / 多输出"; rejection = "暂不支持聚合及多输出设备。"
        case kAudioDeviceTransportTypeVirtual:
            kind = "虚拟设备"; rejection = "暂不支持虚拟音频路由。"
        case kAudioDeviceTransportTypeAirPlay:
            kind = "AirPlay"; rejection = "暂不支持网络音频输出。"
        default:
            kind = "其他"; rejection = "无法确认该设备为直接连接的实体输出。"
        }
        if !alive { rejection = "设备目前不可用。" }
        if uid.isEmpty { rejection = "设备没有可保存的稳定标识。" }
        return AudioDevice(id: id, key: DeviceKey(uid: uid, source: source),
                           name: name.isEmpty ? "未命名设备" : name, kind: kind,
                           inputChannels: input, outputChannels: output,
                           rate: rate, bufferFrames: buffer, rejection: rejection)
    }
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func optionalValue<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default initial: T) -> T? {
        var a = address(selector, scope)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        return status == noErr ? result : nil
    }
    static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default initial: T) -> T {
        optionalValue(id, selector, scope: scope, default: initial) ?? initial
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        let result: CFString? = value(id, selector, default: Optional<CFString>.none)
        return result as String? ?? ""
    }
    static func array<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
        var a = address(selector, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: T.self), count: Int(size) / MemoryLayout<T>.stride))
    }
    private static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + $1.mNumberChannels }
    }
}
