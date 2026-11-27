import Foundation
import Network

extension CodingUserInfoKey {
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

enum ProbeSiteType: String, Codable {
    case https, tcp
}

enum ProbeEndpoint: Equatable {
    case https(URL)
    case tcp(host: String, port: UInt16)

    var type: ProbeSiteType {
        switch self {
        case .https: .https
        case .tcp: .tcp
        }
    }

    var httpsURL: URL? {
        if case let .https(url) = self { return url }
        return nil
    }

    static func tcpHost(_ input: String) throws -> String {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.contains(":") {
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            guard IPv6Address(host) != nil else { throw SiteConfigurationError.invalidHost }
        } else {
            let name = host.hasSuffix(".") ? String(host.dropLast()) : host
            let labels = name.components(separatedBy: ".")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard !name.isEmpty, name.utf8.count <= 253, labels.allSatisfy({
                (1...63).contains($0.utf8.count) && $0.unicodeScalars.allSatisfy(allowed.contains)
            }) else { throw SiteConfigurationError.invalidHost }
        }
        return host
    }
}

struct ProbeSite: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var endpoint: ProbeEndpoint
    var lanes: [ProbeLane] { endpoint.type == .tcp ? [.fresh] : ProbeLane.allCases }
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
        if case let .tcp(host, port) = endpoint {
            guard try ProbeEndpoint.tcpHost(host) == host else { throw SiteConfigurationError.invalidHost }
            guard port > 0 else { throw SiteConfigurationError.invalidPort }
            guard !dailyStrength.enabled, freshStrength.enabled else { throw SiteConfigurationError.invalidTCPLane }
        }
        for lane in lanes { try self[strength: lane].validate(for: lane) }
        guard !enabled || hasEnabledLane else { throw SiteConfigurationError.noLane }
    }

    func sharesRequest(with other: Self) -> Bool {
        endpoint == other.endpoint && method == other.method && statusCodes == other.statusCodes
    }

    private enum CodingKeys: String, CodingKey { case id, name, type, url, host, port, enabled, statusCodes, method, daily, fresh }
    private enum LegacyKey: String, CodingKey { case expectedStatusCode }

    init(id: String, name: String, endpoint: ProbeEndpoint, enabled: Bool, method: ProbeMethod = .head, statusCodes: StatusCodes = StatusCodes()) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        if endpoint.type == .tcp {
            dailyStrength = LaneStrength(enabled: false, selectedID: "balanced")
            freshStrength = LaneStrength(selectedID: "balanced")
        }
        self.enabled = enabled
        self.method = method
        self.statusCodes = statusCodes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let migrating = decoder.userInfo[.legacyProbeSites] as? Bool == true
        let version = decoder.userInfo[.configurationVersion] as? Int
        let type: ProbeSiteType = migrating || (version ?? 3) < 3 ? .https : try values.decode(ProbeSiteType.self, forKey: .type)
        let endpoint: ProbeEndpoint
        switch type {
        case .https: endpoint = .https(try values.decode(URL.self, forKey: .url))
        case .tcp:
            let host = try values.decode(String.self, forKey: .host)
            endpoint = .tcp(host: try ProbeEndpoint.tcpHost(host), port: try values.decode(UInt16.self, forKey: .port))
        }
        try self.init(id: values.decode(String.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      endpoint: endpoint, enabled: values.decode(Bool.self, forKey: .enabled))
        if type == .https {
            let rules: String
            if migrating {
                let legacy = try decoder.container(keyedBy: LegacyKey.self)
                rules = try values.decodeIfPresent(String.self, forKey: .statusCodes)
                    ?? legacy.decodeIfPresent(Int.self, forKey: .expectedStatusCode).map(String.init) ?? ""
            } else {
                rules = try values.decode(String.self, forKey: .statusCodes)
            }
            do { statusCodes = try StatusCodes(rules) }
            catch { throw DecodingError.dataCorruptedError(forKey: .statusCodes, in: values, debugDescription: error.localizedDescription) }
            method = try migrating ? values.decodeIfPresent(ProbeMethod.self, forKey: .method) ?? (isBuiltIn ? .get : .head)
                                   : values.decode(ProbeMethod.self, forKey: .method)
        }
        for lane in lanes {
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
        try values.encode(enabled, forKey: .enabled)
        try values.encode(endpoint.type, forKey: .type)
        switch endpoint {
        case let .https(url):
            try values.encode(url, forKey: .url)
            try values.encode(statusCodes.text, forKey: .statusCodes)
            try values.encode(method, forKey: .method)
            try values.encode(dailyStrength, forKey: .daily)
        case let .tcp(host, port):
            try values.encode(host, forKey: .host)
            try values.encode(port, forKey: .port)
        }
        try values.encode(freshStrength, forKey: .fresh)
    }

    static let builtIns = [
        ProbeSite(id: "google", name: "Google", endpoint: .https(URL(string: "https://www.google.com/generate_204")!), enabled: true, method: .get),
        ProbeSite(id: "cloudflare", name: "Cloudflare", endpoint: .https(URL(string: "https://cp.cloudflare.com/generate_204")!), enabled: true, method: .get)
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
        return Self(id: id, name: label.isEmpty ? host : label, endpoint: .https(url), enabled: enabled,
                    statusCodes: statusCodes)
    }

    func accepts(statusCode: Int) -> Bool {
        if isBuiltIn { return statusCode == 204 }
        return statusCodes.accepts(statusCode)
    }
}

enum SiteConfigurationError: LocalizedError {
    case invalidAddress, invalidHost, invalidPort, invalidTCPLane
    case invalidStatusCode, invalidNumber, shortDeadline, noLane

    var errorDescription: String? {
        switch self {
        case .invalidNumber: "间隔、告警、截止和并发均须为正整数。"
        case .shortDeadline: "截止时间须大于或等于告警时间。"
        case .noLane: "已启用的站点至少需要开启一类探测。"
        case .invalidHost: "请输入主机名或 IP 地址，例如 nas。"
        case .invalidPort: "请输入 1–65535 之间的端口号。"
        case .invalidTCPLane: "TCP 端口只支持新建连接。请通过站点开关控制探测。"
        case .invalidAddress: "请输入完整的 HTTPS 地址，地址中不能包含账号、密码或页面锚点。"
        case .invalidStatusCode: "请输入 200–599 或 2xx–5xx，多项用逗号分隔。"
        }
    }
}
