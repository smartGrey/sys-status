import Foundation

enum ConfigurationFileError: LocalizedError {
    case missing, changed, unsupportedVersion(Int), invalid(String), read(Error), write(Error)

    var errorDescription: String? {
        switch self {
        case .missing: "找不到 config.json。请恢复配置文件后重新读取。"
        case .changed: "配置文件已在外部修改。请先重新读取配置。"
        case .unsupportedVersion(let version): "当前版本不支持配置文件格式 \(version)。"
        case .invalid(let message): message
        case .read(let error): "无法读取配置文件。\(error.localizedDescription)"
        case .write(let error): "无法保存配置文件。\(error.localizedDescription)"
        }
    }
}

@MainActor
final class ProbeConfigurationStore {
    struct Snapshot {
        let configuration: ProbeConfiguration
        fileprivate let data: Data
    }

    let url: URL
    private let defaults: UserDefaults
    private let migrationKey = "NetRate.ConfigFileMigrated.v1"
    private var snapshot: Snapshot?
    var configuration: ProbeConfiguration? { snapshot?.configuration }

    init(url: URL = AppDataFile.probes.url(),
         defaults: UserDefaults = .standard) {
        self.url = url
        self.defaults = defaults
    }

    func loadOnLaunch() throws {
        do {
            try accept(read())
        } catch ConfigurationFileError.missing {
            guard !defaults.bool(forKey: migrationKey) else { throw ConfigurationFileError.missing }
            let legacy = LegacySiteSettings(defaults: defaults)
            let initial = ProbeConfiguration(probingEnabled: legacy.probingEnabled, sites: legacy.load())
            try write(initial)
        }
    }

    func read() throws -> Snapshot {
        let data = try readData()
        return Snapshot(configuration: try ProbeConfiguration.decode(data), data: data)
    }

    func accept(_ candidate: Snapshot) throws {
        guard try readData() == candidate.data else { throw ConfigurationFileError.changed }
        snapshot = candidate
        defaults.set(true, forKey: migrationKey)
    }

    func save(_ configuration: ProbeConfiguration) throws {
        guard let snapshot, try readData() == snapshot.data else { throw ConfigurationFileError.changed }
        try write(configuration)
    }

    private func readData() throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw ConfigurationFileError.missing
        } catch {
            throw ConfigurationFileError.read(error)
        }
    }

    private func write(_ configuration: ProbeConfiguration) throws {
        try configuration.validate()
        let data: Data
        do {
            data = try AppDataFile.write(configuration, to: url)
        } catch {
            throw ConfigurationFileError.write(error)
        }
        snapshot = Snapshot(configuration: configuration, data: data)
        defaults.set(true, forKey: migrationKey)
    }
}
