import Foundation

struct HearingSettings: Codable, Equatable {
    var version = 1
    var enabled = false
    var audio = HearingPreferences()
    var shortcut: ShortcutBinding?
}

@MainActor
final class HearingStore {
    let url: URL
    private(set) var settings = HearingSettings()

    init(url: URL = AppDataFile.hearing.url()) {
        self.url = url
    }

    func load() throws {
        do {
            var saved = try JSONDecoder().decode(HearingSettings.self, from: Data(contentsOf: url))
            guard saved.version == 1, saved.shortcut?.hearingValidationError == nil else {
                throw CocoaError(.coderReadCorrupt)
            }
            saved.audio.normalize()
            settings = saved
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            settings = HearingSettings()
        }
    }

    func update(_ change: (inout HearingSettings) -> Void) throws {
        var next = settings
        change(&next)
        guard next != settings else { return }
        try AppDataFile.write(next, to: url)
        settings = next
    }
}
