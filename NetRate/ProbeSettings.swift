import Foundation

private extension CodingUserInfoKey {
    static let configurationVersion = CodingUserInfoKey(rawValue: "configurationVersion")!
    static let legacyProbeSites = CodingUserInfoKey(rawValue: "legacyProbeSites")!
}

struct StatusCodes: Equatable {
    private var codes: [Int] = []
    init() {}

    init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return }
        for part in text.replacingOccurrences(of: "，", with: ",").components(separatedBy: ",") {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.utf8.count == 3 else { throw SiteConfigurationError.invalidStatusCode }
            if let number = Int(token), (200...599).contains(number) {
                codes.append(number)
            } else if token.hasSuffix("xx"), let family = Int(token.prefix(1)), (2...5).contains(family) {
                codes.append(family)
            } else {
                throw SiteConfigurationError.invalidStatusCode
            }
        }
        let unique = Set(codes)
        codes = unique.filter { !unique.contains($0 / 100) }.sorted()
    }

    var text: String { codes.map { $0 < 10 ? "\($0)xx" : String($0) }.joined(separator: ", ") }
    func accepts(_ status: Int) -> Bool {
        codes.isEmpty ? (200..<300).contains(status) : codes.contains(status) || codes.contains(status / 100)
    }
}

enum ProbeLane: CaseIterable {
    case daily, fresh

    var title: String { self == .daily ? "复用" : "新建" }
    var defaults: ProbeParameters { strengths[0].values.parameters() }
    var legacyDefaults: ProbeParameters {
        self == .daily ? .init(interval: 2, warning: 5, cutoff: 5, capacity: 1)
                       : .init(interval: 6, warning: 5, cutoff: 10, capacity: 2)
    }
}

struct ProbeParameters: Codable, Equatable {
    var enabled = true
    var interval: Int
    var warning: Int
    var cutoff: Int
    var capacity: Int

    func validate() throws {
        guard interval > 0, warning > 0, cutoff > 0, capacity > 0 else {
            throw SiteConfigurationError.invalidNumber
        }
        guard cutoff >= warning else { throw SiteConfigurationError.shortDeadline }
    }

    var requiredCapacity: Int? {
        guard interval > 0, cutoff > 0 else { return nil }
        return 1 + (cutoff - 1) / interval
    }

    var capacityHint: String? {
        guard enabled, let required = requiredCapacity else { return nil }
        return capacity < required ? "持续无响应时部分轮次会延后，维持节奏需要 \(required) 个名额。" : nil
    }
}

struct StrengthValues: Codable, Equatable {
    var interval: Int
    var warning: Int
    var cutoff: Int
    var capacity: Int

    func parameters(enabled: Bool = true) -> ProbeParameters {
        ProbeParameters(enabled: enabled, interval: interval, warning: warning, cutoff: cutoff, capacity: capacity)
    }
}

struct ProbeStrength: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var values: StrengthValues
}

extension ProbeLane {
    private static func builtIns(_ lane: Self, intervals: [Int]) -> [ProbeStrength] {
        let names = [("fast", "快速"), ("balanced", "均衡"), ("gentle", "温和"), ("low", "低频")]
        return zip(names, intervals).map { entry, interval in
            ProbeStrength(id: entry.0, name: entry.1, values: .init(interval: interval, warning: 5,
                cutoff: lane == .daily ? 8 : 10, capacity: lane == .fresh && entry.0 == "fast" ? 2 : 1))
        }
    }
    private static let reuseStrengths = builtIns(.daily, intervals: [2, 5, 10, 20])
    private static let freshStrengths = builtIns(.fresh, intervals: [6, 10, 15, 30])
    var strengths: [ProbeStrength] { self == .daily ? Self.reuseStrengths : Self.freshStrengths }
}

struct InvalidStrengthIdentity: LocalizedError {
    let id: String
    var errorDescription: String? { "个人强度的名称和 ID 需非空，且在本站同一种方式内唯一。" }
}

struct LaneStrength: Codable, Equatable {
    var enabled = true
    var selectedID = "fast"
    var personal: [ProbeStrength] = []

    init(enabled: Bool = true, selectedID: String = "fast", personal: [ProbeStrength] = []) {
        self.enabled = enabled
        self.selectedID = selectedID
        self.personal = personal
    }

    init(migrating p: ProbeParameters, lane: ProbeLane) {
        let values = StrengthValues(interval: p.interval, warning: p.warning, cutoff: p.cutoff, capacity: p.capacity)
        if let match = lane.strengths.first(where: { $0.values == values }) {
            self.init(enabled: p.enabled, selectedID: match.id)
        } else {
            let original = ProbeStrength(id: "original", name: "原有配置", values: values)
            self.init(enabled: p.enabled, selectedID: original.id, personal: [original])
        }
    }

    func selected(in lane: ProbeLane) -> ProbeStrength? {
        lane.strengths.first { $0.id == selectedID } ?? personal.first { $0.id == selectedID }
    }

    func validate(for lane: ProbeLane) throws {
        var ids = Set(lane.strengths.map(\.id))
        var names = Set(lane.strengths.map(\.name))
        for item in personal {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.id.isEmpty, ids.insert(item.id).inserted, !name.isEmpty,
                  names.insert(name.lowercased()).inserted else {
                throw InvalidStrengthIdentity(id: item.id)
            }
            try item.values.parameters().validate()
        }
        guard ids.contains(selectedID) else {
            throw ConfigurationFileError.invalid("选中的探测强度不存在，请先在菜单中切换强度。")
        }
    }
}

enum ProbeMethod: String, Codable, CaseIterable {
    case head = "HEAD", get = "GET"
}

struct ProbeSite: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var url: URL
    var enabled: Bool
    var statusCodes = StatusCodes()

    var method: ProbeMethod = .head
    private var dailyStrength = LaneStrength()
    private var freshStrength = LaneStrength()

    subscript(strength kind: ProbeLane) -> LaneStrength {
        get { kind == .daily ? dailyStrength : freshStrength }
        set { if kind == .daily { dailyStrength = newValue } else { freshStrength = newValue } }
    }

    subscript(_ kind: ProbeLane) -> ProbeParameters {
        let selection = self[strength: kind]
        // Decoding and editor saves both validate references before the monitor receives them.
        return selection.selected(in: kind)!.values.parameters(enabled: selection.enabled)
    }

    var hasEnabledLane: Bool { dailyStrength.enabled || freshStrength.enabled }

    func validate() throws {
        for lane in ProbeLane.allCases { try self[strength: lane].validate(for: lane) }
        guard !enabled || hasEnabledLane else { throw SiteConfigurationError.noLane }
    }

    func sharesRequest(with other: Self) -> Bool {
        url == other.url && method == other.method && statusCodes == other.statusCodes
    }

    private enum CodingKeys: String, CodingKey { case id, name, url, enabled, statusCodes, method, daily, fresh }
    private enum LegacyKey: String, CodingKey { case expectedStatusCode }

    init(id: String, name: String, url: URL, enabled: Bool, method: ProbeMethod = .head, statusCodes: StatusCodes = StatusCodes()) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
        self.method = method
        self.statusCodes = statusCodes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let migrating = decoder.userInfo[.legacyProbeSites] as? Bool == true
        let rules: String
        if migrating {
            let legacy = try decoder.container(keyedBy: LegacyKey.self)
            rules = try values.decodeIfPresent(String.self, forKey: .statusCodes)
                ?? legacy.decodeIfPresent(Int.self, forKey: .expectedStatusCode).map(String.init) ?? ""
        } else {
            rules = try values.decode(String.self, forKey: .statusCodes)
        }
        let codes: StatusCodes
        do {
            codes = try StatusCodes(rules)
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .statusCodes, in: values, debugDescription: error.localizedDescription)
        }
        try self.init(id: values.decode(String.self, forKey: .id),
                      name: values.decode(String.self, forKey: .name),
                      url: values.decode(URL.self, forKey: .url),
                      enabled: values.decode(Bool.self, forKey: .enabled), statusCodes: codes)
        method = try migrating ? values.decodeIfPresent(ProbeMethod.self, forKey: .method) ?? (isBuiltIn ? .get : .head)
                               : values.decode(ProbeMethod.self, forKey: .method)
        for lane in ProbeLane.allCases {
            let key: CodingKeys = lane == .daily ? .daily : .fresh
            if migrating || decoder.userInfo[.configurationVersion] as? Int == 1 {
                let p = try migrating ? values.decodeIfPresent(ProbeParameters.self, forKey: key) ?? lane.legacyDefaults
                                      : values.decode(ProbeParameters.self, forKey: key)
                self[strength: lane] = LaneStrength(migrating: p, lane: lane)
            } else {
                self[strength: lane] = try values.decode(LaneStrength.self, forKey: key)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(url, forKey: .url)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(statusCodes.text, forKey: .statusCodes)
        try values.encode(method, forKey: .method)
        try values.encode(dailyStrength, forKey: .daily)
        try values.encode(freshStrength, forKey: .fresh)
    }

    static let builtIns = [
        ProbeSite(id: "google", name: "Google", url: URL(string: "https://www.google.com/generate_204")!, enabled: true, method: .get),
        ProbeSite(id: "cloudflare", name: "Cloudflare", url: URL(string: "https://cp.cloudflare.com/generate_204")!, enabled: true, method: .get)
    ]

    var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }

    static func custom(id: String = UUID().uuidString, name: String, address: String, enabled: Bool = true,
                       statusCodes: StatusCodes = StatusCodes()) throws -> Self {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil, let url = parts.url else {
            throw SiteConfigurationError.invalidAddress
        }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(id: id, name: label.isEmpty ? host : label, url: url, enabled: enabled,
                    statusCodes: statusCodes)
    }

    func accepts(statusCode: Int) -> Bool {
        if isBuiltIn { return statusCode == 204 }
        return statusCodes.accepts(statusCode)
    }
}

enum SiteConfigurationError: LocalizedError {
    case invalidAddress
    case invalidStatusCode, invalidNumber, shortDeadline, noLane

    var errorDescription: String? {
        switch self {
        case .invalidNumber: "间隔、告警、截止和并发均须为正整数。"
        case .shortDeadline: "截止时间须大于或等于告警时间。"
        case .noLane: "已启用的站点至少需要开启一类探测。"
        case .invalidAddress: "请输入完整的 HTTPS 地址，地址中不能包含账号、密码或页面锚点。"
        case .invalidStatusCode: "请输入 200–599 或 2xx–5xx，多项用逗号分隔。"
        }
    }
}

struct LegacySiteSettings {
    let defaults: UserDefaults
    private let key = "NetRate.ProbeSites.v1"

    var probingEnabled: Bool {
        defaults.object(forKey: "NetRate.ProbingEnabled") as? Bool ?? true
    }

    private struct StoredSite: Decodable {
        let site: ProbeSite?
        init(from decoder: Decoder) {
            site = try? {
                let site = try ProbeSite(from: decoder)
                try site.validate()
                return site
            }()
        }
    }

    func load() -> [ProbeSite] {
        let decoder = JSONDecoder()
        decoder.userInfo[.legacyProbeSites] = true
        let previousBuiltIns = ProbeSite.builtIns.map { site in
            var old = site
            for lane in ProbeLane.allCases { old[strength: lane] = LaneStrength(migrating: lane.legacyDefaults, lane: lane) }
            return old
        }
        guard let data = defaults.data(forKey: key),
              let records = try? decoder.decode([StoredSite].self, from: data) else {
            return defaults.object(forKey: key) == nil && defaults.object(forKey: "NetRate.ProbingEnabled") == nil
                ? ProbeSite.builtIns : previousBuiltIns
        }
        var sites: [ProbeSite] = []
        var ids = Set<String>()
        for stored in records.compactMap(\.site) where !ids.contains(stored.id) {
            let site: ProbeSite
            if var builtIn = ProbeSite.builtIns.first(where: { $0.id == stored.id }) {
                builtIn.enabled = stored.enabled
                for lane in ProbeLane.allCases { builtIn[strength: lane] = stored[strength: lane] }
                site = builtIn
            } else {
                guard var custom = try? ProbeSite.custom(id: stored.id, name: stored.name, address: stored.url.absoluteString,
                                                         enabled: stored.enabled, statusCodes: stored.statusCodes) else { continue }
                custom.method = stored.method
                for lane in ProbeLane.allCases { custom[strength: lane] = stored[strength: lane] }
                site = custom
            }
            sites.append(site)
            ids.insert(site.id)
        }
        // Older records can omit built-ins. Only insert those missing from the saved order.
        return previousBuiltIns.filter { !ids.contains($0.id) } + sites
    }

}

struct ProbeConfiguration: Codable, Equatable {
    static let version = 2
    var schemaVersion = Self.version
    var probingEnabled: Bool
    var sites: [ProbeSite]

    private struct Version: Decodable { let schemaVersion: Int }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        do {
            let version = try decoder.decode(Version.self, from: data).schemaVersion
            guard version == 1 || version == Self.version else { throw ConfigurationFileError.unsupportedVersion(version) }
            decoder.userInfo[.configurationVersion] = version
            var configuration = try decoder.decode(Self.self, from: data)
            configuration.schemaVersion = Self.version
            try configuration.validate()
            return configuration
        } catch DecodingError.keyNotFound(let key, let context) {
            throw ConfigurationFileError.invalid("缺少字段 " + fieldPath(context.codingPath + [key]) + "。")
        } catch DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context) {
            throw ConfigurationFileError.invalid("字段 " + fieldPath(context.codingPath) + " 的值无效。")
        } catch DecodingError.dataCorrupted(let context) {
            let field = context.codingPath.isEmpty ? "JSON 格式错误" : fieldPath(context.codingPath)
            throw ConfigurationFileError.invalid(field + "：" + context.debugDescription)
        }
    }

    private static func fieldPath(_ keys: [any CodingKey]) -> String {
        keys.map { key in key.intValue.map { "[\($0)]" } ?? key.stringValue }.joined(separator: ".")
            .replacingOccurrences(of: ".[", with: "[")
    }

    func validate() throws {
        guard schemaVersion == Self.version else { throw ConfigurationFileError.unsupportedVersion(schemaVersion) }
        var ids = Set<String>()
        for (index, site) in sites.enumerated() {
            let field = "sites[\(index)]"
            guard !site.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ids.insert(site.id).inserted else {
                throw ConfigurationFileError.invalid(field + " 的站点 ID 为空或重复。")
            }
            do {
                try site.validate()
                if let builtIn = ProbeSite.builtIns.first(where: { $0.id == site.id }) {
                    let codesMatch = site.statusCodes == builtIn.statusCodes || site.statusCodes.text == "204"
                    guard site.name == builtIn.name, site.url == builtIn.url, site.method == builtIn.method, codesMatch else {
                        throw ConfigurationFileError.invalid("内置站点的名称、地址、方法和成功状态码是固定的。")
                    }
                } else {
                    _ = try ProbeSite.custom(id: site.id, name: site.name, address: site.url.absoluteString)
                    guard !site.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ConfigurationFileError.invalid("站点名称不能为空。")
                    }
                }
            } catch {
                throw ConfigurationFileError.invalid(field + "（" + site.name + "）" + error.localizedDescription)
            }
        }
        for builtIn in ProbeSite.builtIns where !ids.contains(builtIn.id) {
            throw ConfigurationFileError.invalid("缺少内置站点 " + builtIn.name + "。可用 enabled 关闭该站点。")
        }
    }
}

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

    init(url: URL = URL.applicationSupportDirectory.appending(path: "NetRate/config.json"),
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration) + Data([0x0A])
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ConfigurationFileError.write(error)
        }
        snapshot = Snapshot(configuration: configuration, data: data)
        defaults.set(true, forKey: migrationKey)
    }
}
