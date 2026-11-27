import Foundation

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
                guard case let .https(url) = stored.endpoint,
                      var custom = try? ProbeSite.custom(id: stored.id, name: stored.name, address: url.absoluteString,
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
    static let version = 3
    var schemaVersion = Self.version
    var probingEnabled: Bool
    var sites: [ProbeSite]

    private struct Version: Decodable { let schemaVersion: Int }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        do {
            let version = try decoder.decode(Version.self, from: data).schemaVersion
            guard (1...Self.version).contains(version) else { throw ConfigurationFileError.unsupportedVersion(version) }
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
                    guard site.name == builtIn.name, site.endpoint == builtIn.endpoint, site.method == builtIn.method, codesMatch else {
                        throw ConfigurationFileError.invalid("内置站点的名称、地址、方法和成功状态码是固定的。")
                    }
                } else {
                    if case let .https(url) = site.endpoint {
                        _ = try ProbeSite.custom(id: site.id, name: site.name, address: url.absoluteString)
                    }
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
