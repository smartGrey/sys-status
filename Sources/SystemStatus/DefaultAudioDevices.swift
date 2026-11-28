import CoreAudio
import Foundation

struct AudioDeviceNames: Equatable {
    var input: String?
    var output: String?
}

/// Reads the system defaults without opening either device or starting an audio stream.
@MainActor
final class DefaultAudioDevices {
    private struct Observation {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var observations: [Observation] = []
    private var watchedDevices: Set<AudioObjectID> = []
    private let changed: (AudioDeviceNames) -> Void

    init(changed: @escaping (AudioDeviceNames) -> Void) {
        self.changed = changed
        subscribe()
    }

    isolated deinit { removeObservers(includeSystem: true) }

    private func subscribe() {
        for property in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDevices, kAudioHardwarePropertyServiceRestarted] {
            observe(system, property)
        }
        refresh()
    }

    private func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if selector == kAudioHardwarePropertyServiceRestarted {
                    removeObservers(includeSystem: true)
                    subscribe()
                } else { refresh() }
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            observations.append(Observation(object: object, address: address, block: block))
        }
    }

    private func removeObservers(includeSystem: Bool) {
        for var item in observations where includeSystem || item.object != system {
            AudioObjectRemovePropertyListenerBlock(item.object, &item.address, .main, item.block)
        }
        observations.removeAll { includeSystem || $0.object != system }
        watchedDevices.removeAll()
    }

    private func refresh() {
        let input = DeviceRegistry.value(system, kAudioHardwarePropertyDefaultInputDevice, default: AudioDeviceID(0))
        let output = DeviceRegistry.value(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(0))
        let devices = Set([input, output].filter { $0 != 0 })
        if devices != watchedDevices {
            removeObservers(includeSystem: false)
            watchedDevices = devices
            for id in devices { observe(id, kAudioObjectPropertyName) }
        }
        func name(_ id: AudioDeviceID) -> String? {
            guard id != 0 else { return nil }
            let value = DeviceRegistry.string(id, kAudioObjectPropertyName)
            return value.isEmpty ? nil : value
        }
        changed(AudioDeviceNames(input: name(input), output: name(output)))
    }
}
