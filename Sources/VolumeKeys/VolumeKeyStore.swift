import Foundation

struct VolumeKeySettings: Codable, Equatable {
    var version = 1
    var enabled = false
    var failure: VolumeKeyFailure?
}

struct VolumeKeyStore {
    let url: URL
    let defaults: UserDefaults
    private let legacyKey = "volumeKeyAdjustment"

    init(url: URL = AppDataFile.volumeKeys.url(), defaults: UserDefaults = .standard) {
        self.url = url
        self.defaults = defaults
    }

    func load() throws -> VolumeKeySettings {
        do {
            let settings = try JSONDecoder().decode(VolumeKeySettings.self, from: Data(contentsOf: url))
            guard settings.version == 1, !settings.enabled || settings.failure == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return settings
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard let old = defaults.string(forKey: legacyKey) else { return VolumeKeySettings() }
            let settings = VolumeKeySettings(enabled: old == "enabled", failure: VolumeKeyFailure(rawValue: old))
            try save(settings)
            defaults.removeObject(forKey: legacyKey)
            return settings
        }
    }

    func save(_ settings: VolumeKeySettings) throws {
        try AppDataFile.write(settings, to: url)
    }
}
