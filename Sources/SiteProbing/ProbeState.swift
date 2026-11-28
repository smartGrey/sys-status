import Foundation
import Network
import dnssd

enum ArrowColor { case normal, green, orange, red }
enum ProbeResult: Equatable {
    case checking, waiting, success(TimeInterval), timedOut, wrongStatus(Int), failed
    case dnsFailed, connectionRefused, connectionFailed

    init(tcpError: NWError) {
        switch tcpError {
        case .posix(.ECONNREFUSED): self = .connectionRefused
        case .posix(.ETIMEDOUT), .dns(DNSServiceErrorType(kDNSServiceErr_Timeout)): self = .timedOut
        case .dns: self = .dnsFailed
        default: self = .connectionFailed
        }
    }

    var text: String {
        switch self {
        case .checking: "…"
        case .waiting: "等待中"
        case .timedOut: "超时"
        case .failed: "失败"
        case .dnsFailed: "域名解析失败"
        case .connectionRefused: "连接被拒绝"
        case .connectionFailed: "连接失败"
        case .wrongStatus(let code): String(code)
        case .success(let seconds):
            seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.1f s", seconds)
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var spoken: String {
        switch self {
        case .checking: "检测中"
        case .wrongStatus(let code): "非预期状态码 \(code)"
        default: text
        }
    }

    func color(for lane: ProbeLane, warning: Int, freshEnabled: Bool) -> ArrowColor {
        switch self {
        case .checking: .normal
        case .waiting: lane == .fresh ? .red : .orange
        case .success(let elapsed): elapsed >= Double(warning) ? .orange : .green
        default: lane == .daily && freshEnabled ? .orange : .red
        }
    }
}

struct SuccessCount: Equatable {
    var successes = 0
    var completed = 0

    var percent: String {
        guard completed > 0 else { return "—" }
        if successes == 0 { return "0" }
        if successes == completed { return "100" }
        let rounded = Int((100 * Double(successes) / Double(completed)).rounded())
        return String(min(99, max(1, rounded)))
    }

    var spoken: String {
        completed == 0 ? "暂无样本，成功 0 次，完成 0 次" : "\(percent)%，成功 \(successes) 次，完成 \(completed) 次"
    }
}

struct ProbeHistory {
    private var samples: [(time: TimeInterval, success: Bool)] = []

    mutating func record(at time: TimeInterval, success: Bool) {
        expire(at: time)
        samples.append((time, success))
    }

    var nextExpiry: TimeInterval? { samples.first.map { $0.time + 300 } }

    @discardableResult
    mutating func expire(at time: TimeInterval) -> Bool {
        guard let nextExpiry, nextExpiry <= time else { return false }
        samples.removeAll { $0.time + 300 <= time }
        return true
    }

    func count(at time: TimeInterval) -> SuccessCount {
        samples.reduce(into: SuccessCount()) { count, sample in
            if sample.time + 300 > time {
                count.completed += 1
                if sample.success { count.successes += 1 }
            }
        }
    }
}

struct ProbeUsage {
    static let reusedBytes = 270
    static let freshBytes = 7014

    static func baseline(_ lane: ProbeLane, interval: Int) -> Double {
        3600 / Double(interval) * Double(lane == .daily ? reusedBytes : freshBytes)
    }
    // Five-second buckets bound storage and exclude expired samples even when no new probes finish.
    private var bins: [Int: Int] = [:]
    let since: TimeInterval

    init(since: TimeInterval) { self.since = since }

    mutating func record(at time: TimeInterval, reused: Bool) {
        let bin = Int(time / 5)
        if bins[bin] == nil { bins = bins.filter { $0.key > bin - 60 } }
        bins[bin, default: 0] += reused ? Self.reusedBytes : Self.freshBytes
    }

    func hourly(at time: TimeInterval, baseline: Double) -> Double {
        let age = time - since
        guard age >= 60 else { return baseline }
        let first = Int(time / 5) - 59
        let bytes = bins.reduce(0) { $0 + ($1.key >= first ? $1.value : 0) }
        return Double(bytes) * 3600 / min(age, time - Double(first * 5))
    }

    static func display(_ bytes: Double, perHour: Bool = true) -> String {
        let unit: (Double, String) = bytes >= 1_000_000 ? (1_000_000, "MB") : bytes >= 1000 || !perHour ? (1000, "KB") : (1, "B")
        let value = (bytes / unit.0).formatted(.number.precision(.significantDigits(1...2)))
        return "\(value) \(unit.1)" + (perHour ? "/h" : "")
    }
}

struct ProbeBudget: Equatable {
    var requests = 0
    var bytes = 0.0
    var includesTCP = false
    private var includesHTTPS = false

    init() {}

    init(lane: ProbeLane, interval: Int, type: ProbeSiteType = .https) {
        requests = 1 + (28_800 - 1) / interval
        includesTCP = type == .tcp
        guard !includesTCP else { return }
        includesHTTPS = true
        bytes = Double(requests) * Double(lane == .daily ? ProbeUsage.reusedBytes : ProbeUsage.freshBytes)
    }

    mutating func add(_ other: Self) {
        requests += other.requests
        bytes += other.bytes
        includesTCP = includesTCP || other.includesTCP
        includesHTTPS = includesHTTPS || other.includesHTTPS
    }

    var trafficDisplay: String {
        if includesTCP && !includesHTTPS { return "—" }
        let unit = bytes >= 1_000_000 ? (1_000_000.0, "MB") : (1_000.0, "KB")
        let amount = (bytes / unit.0).formatted(.number.precision(.significantDigits(1...3)))
        return "\(amount) \(unit.1)"
    }

    var display: String {
        let count = "\(requests.formatted()) 次"
        if includesTCP && !includesHTTPS { return count }
        return count + (includesTCP ? " · HTTPS 流量 " : " · ") + trafficDisplay
    }
}

struct SiteTraffic: Equatable {
    var daily = 0.0
    var fresh = 0.0

    subscript(_ lane: ProbeLane) -> Double {
        get { lane == .daily ? daily : fresh }
        set { if lane == .daily { daily = newValue } else { fresh = newValue } }
    }
}

struct ProbeEstimate {
    var sites: [String: SiteTraffic] = [:]
    var enabled: Bool
    var includesTCP = false

    var total: Double { sites.values.reduce(0) { $0 + $1.daily + $1.fresh } }
    var footer: String {
        "全部站点合计 · " + (includesTCP ? "仅 HTTPS · " : "") + (enabled ? "预计流量 " : "开启后预计 ") + (total > 0 ? "≈ " : "") + ProbeUsage.display(total)
    }
}

struct ConnectivityState: Equatable {
    struct Row: Equatable {
        let id: String
        let name: String
        let enabled: Bool
        var isTCP = false
        var daily = ProbeResult.checking
        var fresh = ProbeResult.checking

        var dailySettings = ProbeLane.daily.defaults
        var freshSettings = ProbeLane.fresh.defaults
        var dailyCount = SuccessCount()
        var freshCount = SuccessCount()

        var percentages: String {
            "\(percentage(for: .daily))/\(percentage(for: .fresh))"
        }

        func percentage(for lane: ProbeLane) -> String {
            let settings = lane == .daily ? dailySettings : freshSettings
            guard enabled, settings.enabled else { return "—" }
            return (lane == .daily ? dailyCount : freshCount).percent
        }

        func text(for lane: ProbeLane) -> String {
            let settings = lane == .daily ? dailySettings : freshSettings
            return enabled && settings.enabled ? (lane == .daily ? daily : fresh).text : "—"
        }

        var color: ArrowColor {
            guard enabled else { return .normal }
            var colors: [ArrowColor] = []
            if dailySettings.enabled {
                colors.append(daily.color(for: .daily, warning: dailySettings.warning, freshEnabled: freshSettings.enabled))
            }
            if freshSettings.enabled {
                colors.append(fresh.color(for: .fresh, warning: freshSettings.warning, freshEnabled: true))
            }
            if colors.contains(.red) { return .red }
            if colors.contains(.orange) { return .orange }
            return colors.contains(.normal) ? .normal : .green
        }

        var spoken: String {
            guard enabled else { return "\(name)，已停用" }
            if isTCP { return "\(name)，TCP 新建连接 \(fresh.spoken)，近 5 分钟成功率 \(freshCount.spoken)" }
            let results = "复用 " + (dailySettings.enabled ? daily.spoken : "已关闭") +
                "，新建 " + (freshSettings.enabled ? fresh.spoken : "已关闭")
            return "\(name)，\(results)，近 5 分钟复用成功率 " + (dailySettings.enabled ? dailyCount.spoken : "已关闭") +
                "，新建成功率 " + (freshSettings.enabled ? freshCount.spoken : "已关闭")
        }

        var detail: String {
            enabled ? "\(name)，复用 \(text(for: .daily))，新建 \(text(for: .fresh))，近 5 分钟成功率（复用/新建，%）\(percentages)" : "\(name)，已停用"
        }
    }

    var rows: [Row] = []
    var enabled = true
    var rate = "0 B/h"
    var configurationUnavailable = false

    var color: ArrowColor {
        guard enabled else { return .normal }
        let colors = rows.filter(\.enabled).map(\.color)
        if colors.contains(.red) { return .red }
        if colors.contains(.orange) { return .orange }
        return !colors.isEmpty && !colors.contains(.normal) ? .green : .normal
    }

    var title: String {
        if configurationUnavailable { return "配置文件异常，探测已暂停" }
        if !enabled { return "站点探测已关闭" }
        if !rows.contains(where: \.enabled) { return "未启用探测" }
        switch color {
        case .green: return "正常"
        case .orange: return "连接不稳"
        case .red: return "连接异常"
        case .normal: return "检测中"
        }
    }

    var footer: String {
        let label = rows.contains(where: \.isTCP) ? "预计 HTTPS 探测流量 " : "预计探测流量 "
        return label + (rate == "0 B/h" ? "" : "≈ ") + rate
    }
    var summary: String { ([title] + (enabled ? rows.map(\.spoken) : []) + [footer]).joined(separator: " · ") }
    var hoverTooltip: String { ([title] + (enabled ? rows.map(\.detail) : []) + [footer]).joined(separator: "\n") }
}
