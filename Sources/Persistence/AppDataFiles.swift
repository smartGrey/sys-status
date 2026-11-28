import Foundation

enum AppDataFile: String {
    case preferences = "status-bar.json"
    case probes = "config.json"
    case stopwatch = "stopwatch.json"
    case hearing = "hearing.json"
    case volumeKeys = "volume-keys.json"
    case systemStatus = "system-status.json"

    static let directory = URL.applicationSupportDirectory.appending(path: "NetRate", directoryHint: .isDirectory)

    func url(in directory: URL = directory) -> URL {
        directory.appending(path: rawValue)
    }

    @discardableResult
    static func write(_ value: some Encodable, to url: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data
    }
}
