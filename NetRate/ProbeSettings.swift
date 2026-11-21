import Foundation

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
    var defaults: ProbeParameters {
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
    var daily = ProbeLane.daily.defaults
    var fresh = ProbeLane.fresh.defaults

    subscript(_ kind: ProbeLane) -> ProbeParameters {
        get { kind == .daily ? daily : fresh }
        set { if kind == .daily { daily = newValue } else { fresh = newValue } }
    }

    func validate() throws {
        try daily.validate()
        try fresh.validate()
        guard !enabled || daily.enabled || fresh.enabled else { throw SiteConfigurationError.noLane }
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
        let legacy = try decoder.container(keyedBy: LegacyKey.self)
        let rules = try values.decodeIfPresent(String.self, forKey: .statusCodes)
            ?? legacy.decodeIfPresent(Int.self, forKey: .expectedStatusCode).map(String.init) ?? ""
        try self.init(id: values.decode(String.self, forKey: .id),
                      name: values.decode(String.self, forKey: .name),
                      url: values.decode(URL.self, forKey: .url),
                      enabled: values.decode(Bool.self, forKey: .enabled), statusCodes: StatusCodes(rules))
        method = try values.decodeIfPresent(ProbeMethod.self, forKey: .method) ?? (isBuiltIn ? .get : .head)
        daily = try values.decodeIfPresent(ProbeParameters.self, forKey: .daily) ?? ProbeLane.daily.defaults
        fresh = try values.decodeIfPresent(ProbeParameters.self, forKey: .fresh) ?? ProbeLane.fresh.defaults
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(url, forKey: .url)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(statusCodes.text, forKey: .statusCodes)
        try values.encode(method, forKey: .method)
        try values.encode(daily, forKey: .daily)
        try values.encode(fresh, forKey: .fresh)
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

struct SiteSettings {
    var defaults: UserDefaults = .standard
    private let key = "NetRate.ProbeSites.v1"

    var probingEnabled: Bool {
        get { defaults.object(forKey: "NetRate.ProbingEnabled") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "NetRate.ProbingEnabled") }
    }

    private struct StoredSite: Decodable {
        let site: ProbeSite?
        init(from decoder: Decoder) { site = try? ProbeSite(from: decoder) }
    }

    func load() -> [ProbeSite] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([StoredSite].self, from: data) else { return ProbeSite.builtIns }
        let saved = records.compactMap(\.site)
        var sites = ProbeSite.builtIns.map { site in
            var builtIn = site
            if let stored = saved.first(where: { $0.id == site.id }) {
                builtIn.enabled = stored.enabled
                builtIn.daily = stored.daily
                builtIn.fresh = stored.fresh
            }
            return builtIn
        }
        var ids = Set(sites.map(\.id))
        for site in saved where !ids.contains(site.id) {
            if var custom = try? ProbeSite.custom(id: site.id, name: site.name, address: site.url.absoluteString,
                                                  enabled: site.enabled, statusCodes: site.statusCodes) {
                custom.method = site.method
                custom.daily = site.daily
                custom.fresh = site.fresh
                sites.append(custom)
                ids.insert(site.id)
            }
        }
        return sites
    }

    func save(_ sites: [ProbeSite]) throws {
        for site in sites { try site.validate() }
        defaults.set(try JSONEncoder().encode(sites), forKey: key)
    }
}
