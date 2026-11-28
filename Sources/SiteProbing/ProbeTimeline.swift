import Foundation

struct ProbeLaneTimeline: Equatable {
    let result: ProbeResult?
    let next: TimeInterval
    let settings: ProbeParameters
    let full: Bool
    /// Uptime at dispatch, oldest first. All live requests in a lane share its current settings.
    let starts: [TimeInterval]
    var suspended = false

    func remaining(at now: TimeInterval) -> Double { max(0, next - now) }
    func waitingForSlot(at now: TimeInterval) -> Bool { full && next <= now }
    func elapsed(since start: TimeInterval, at now: TimeInterval) -> Double {
        min(Double(settings.cutoff), max(0, now - start))
    }

    func visibleStarts(at now: TimeInterval, minimumAge: TimeInterval) -> ArraySlice<TimeInterval> {
        starts.prefix { $0 + minimumAge <= now }
    }

    func waits(at now: TimeInterval, minimumAge: TimeInterval) -> [String] {
        visibleStarts(at: now, minimumAge: minimumAge).enumerated().map { index, start in
            let age = elapsed(since: start, at: now)
            return String(format: "请求 %d　已等 %.1f 秒，剩余 %.1f 秒", index + 1, age, Double(settings.cutoff) - age)
        }
    }

    func detail(at now: TimeInterval, minimumAge: TimeInterval) -> String {
        let schedule = suspended ? "测速期间暂停发起" : waitingForSlot(at: now) ? "下次探测等待空位" : "下次探测 " + String(format: "%.1f 秒后", remaining(at: now))
        return ([schedule] + waits(at: now, minimumAge: minimumAge) +
                ["\(settings.warning) 秒提醒，\(settings.cutoff) 秒截止"]).joined(separator: "\n")
    }
}

struct ProbeTimeline: Equatable {
    var suspended = false
    var lanes: [String: [ProbeLane: ProbeLaneTimeline]] = [:]
    var manualAvailableAt = TimeInterval.zero
}
