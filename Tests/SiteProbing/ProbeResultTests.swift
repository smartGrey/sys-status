import AppKit
import XCTest
@testable import StatusBarCore

final class ProbeResultTests: XCTestCase {
    func testUsageWindowAndRounding() {
        var usage = ProbeUsage(since: 0)
        usage.record(at: 1, reused: false)
        usage.record(at: 2, reused: true)
        let baseline = ProbeUsage.baseline(.daily, interval: 2)
        XCTAssertEqual(usage.hourly(at: 59, baseline: baseline), baseline)
        XCTAssertEqual(usage.hourly(at: 60, baseline: baseline), Double(ProbeUsage.freshBytes + ProbeUsage.reusedBytes) * 60)
        XCTAssertEqual(usage.hourly(at: 310, baseline: baseline), 0)
        XCTAssertEqual(ProbeUsage.display(0), "0 B/h")
        XCTAssertEqual(ProbeUsage.display(12_340_000), "12 MB/h")
    }

    @MainActor
    func testAccurateWindowCountsOverlapOnceAndPreviewsDraft() async throws {
        let h = ProbeHarness()
        defer { h.stop() }
        try await waitUntil { h.fresh.count == 1 && h.daily.count == 1 }
        h.advance(6)
        try await waitUntil { h.fresh.count == 2 && h.daily.count == 2 }
        h.delay.time = 7
        h.daily[1].reply(204)
        h.fresh[0].reply(204)
        h.fresh[1].reply(204)
        try await waitUntil { h.monitor.state.color == .green }
        try await Task.sleep(for: .milliseconds(50))
        h.delay.time = 60
        let expected = Double(4 * ProbeUsage.freshBytes * 60)
        XCTAssertEqual(h.monitor.state.rate, ProbeUsage.display(expected))
        var draft = h.sites[0]
        draft.fresh.interval = 12
        let estimate = h.monitor.estimate(for: [draft])
        XCTAssertEqual(estimate.sites[draft.id]?.daily, expected / 2)
        XCTAssertEqual(estimate.sites[draft.id]?.fresh, ProbeUsage.baseline(.fresh, interval: 12))
        XCTAssertEqual(estimate.total, expected / 2 + ProbeUsage.baseline(.fresh, interval: 12))
        XCTAssertEqual(h.monitor.state.rate, ProbeUsage.display(expected))
    }

    @MainActor
    func testFinalSuccessWindowIncludesLateSuccessAndExpiresByFinishTime() async throws {
        var site = ProbeSite.builtIns[0]
        site.daily.enabled = false
        site.fresh = .init(interval: 12, warning: 3, cutoff: 9, capacity: 1)
        let h = ProbeHarness(sites: [site])
        defer { h.stop() }
        XCTAssertEqual(h.monitor.state.rows[0].percentages, "—/—")
        for index in 0..<10 {
            let start = Double(index * 12)
            h.advance(start)
            try await waitUntil { h.fresh.count == index + 1 }
            if index == 7 || index == 8 {
                h.advance(start + 3)
                XCTAssertEqual(h.monitor.state.color, .red)
                XCTAssertEqual(h.monitor.state.rows[0].freshCount, .init(successes: index, completed: index))
                h.delay.time = start + 4
            } else {
                h.delay.time = start + 0.5
            }
            h.fresh[index].reply(index == 9 ? 403 : 204)
            try await waitUntil { h.monitor.state.rows[0].freshCount.completed == index + 1 }
            if index == 0 { XCTAssertEqual(h.monitor.state.rows[0].percentages, "—/100") }
            if index == 7 || index == 8 { XCTAssertEqual(h.monitor.state.color, .orange) }
        }
        XCTAssertTrue(h.daily.isEmpty)
        XCTAssertEqual(h.monitor.state.rows[0].percentages, "—/90")
        h.delay.time = 300.5
        XCTAssertEqual(h.monitor.state.rows[0].freshCount, .init(successes: 8, completed: 9))
        h.delay.time = 400
        XCTAssertEqual(h.monitor.state.rows[0].percentages, "—/0")
        h.delay.time = 408.5
        XCTAssertEqual(h.monitor.state.rows[0].percentages, "—/—")
        XCTAssertEqual(SuccessCount(successes: 1, completed: 300).percent, "1")
        XCTAssertEqual(SuccessCount(successes: 299, completed: 300).percent, "99")
    }

    func testAllEightHourBudgetsAndConcurrency() throws {
        let expectations: [(ProbeLane, [Int], [Int], [Int])] = [
            (.daily, [2, 5, 10, 20], [14_400, 5760, 2880, 1440], [1, 1, 1, 1]),
            (.fresh, [6, 10, 15, 30], [4800, 2880, 1920, 960], [2, 1, 1, 1])
        ]
        var total = ProbeBudget()
        for (lane, intervals, counts, capacities) in expectations {
            XCTAssertEqual(lane.strengths.map(\.id), ["fast", "balanced", "gentle", "low"])
            for (index, strength) in lane.strengths.enumerated() {
                XCTAssertEqual(strength.values.interval, intervals[index])
                XCTAssertEqual(strength.values.warning, 5)
                XCTAssertEqual(strength.values.cutoff, lane == .daily ? 8 : 10)
                XCTAssertEqual(strength.values.capacity, capacities[index])
                let budget = ProbeBudget(lane: lane, interval: intervals[index])
                XCTAssertEqual(budget.requests, counts[index])
                XCTAssertEqual(budget.bytes, Double(counts[index] * (lane == .daily ? 270 : 7014)))
                total.add(budget)
            }
        }
        XCTAssertEqual(total.requests, 35040) // Sum budgets before display rounding.
    }
}
