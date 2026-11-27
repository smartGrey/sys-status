import AppKit
import XCTest
@testable import StatusBarCore

final class ProbeScheduleTests: XCTestCase {
    @MainActor
    func testManualRefreshSharesScheduleAndCooldown() async throws {
        var site = ProbeSite.builtIns[0]
        site.daily = .init(interval: 10, warning: 5, cutoff: 10, capacity: 1)
        site.fresh = .init(interval: 6, warning: 5, cutoff: 10, capacity: 2)
        let h = ProbeHarness(sites: [site])
        defer { h.stop() }
        try await waitUntil { h.daily.count == 1 && h.fresh.count == 1 }
        h.daily[0].reply(204)
        try await waitUntil { h.monitor.timeline.lanes[site.id]?[.daily]?.full == false }
        h.delay.time = 4
        XCTAssertTrue(h.monitor.probeNow())
        XCTAssertFalse(h.monitor.probeNow())
        try await waitUntil { h.daily.count == 2 }
        XCTAssertEqual(h.monitor.timeline.lanes[site.id]?[.daily]?.next, 14)
        XCTAssertEqual(h.monitor.timeline.lanes[site.id]?[.fresh]?.next, 6)
        h.advance(6)
        try await waitUntil { h.fresh.count == 2 }
        XCTAssertEqual(h.monitor.timeline.lanes[site.id]?[.fresh]?.starts, [0, 6])
        h.delay.time = 6.25
        h.fresh[1].reply(204)
        try await waitUntil { h.monitor.timeline.lanes[site.id]?[.fresh]?.result == .success(0.25) }
        XCTAssertEqual(h.monitor.timeline.lanes[site.id]?[.fresh]?.starts, [0])
        h.advance(10)
        XCTAssertEqual(h.monitor.timeline.lanes[site.id]?[.fresh]?.result, .success(0.25))
        XCTAssertEqual(h.monitor.state.rows[0].freshCount, .init(successes: 1, completed: 2))
        h.delay.time = 12
        XCTAssertTrue(h.monitor.probeNow())
        h.monitor.pump()
        try await waitUntil { h.fresh.count == 3 }
        XCTAssertEqual(h.monitor.timeline.lanes[site.id]?[.fresh]?.starts, [12])
        h.monitor.setEnabled(false)
        XCTAssertFalse(h.monitor.probeNow())
        XCTAssertTrue(h.monitor.timeline.lanes.isEmpty)
    }

    @MainActor
    func testManualRefreshHonorsCapacitySleepAndNetworkChanges() async throws {
        var site = ProbeSite.builtIns[0]
        site.daily.enabled = false
        site.fresh = .init(interval: 2, warning: 5, cutoff: 8, capacity: 1)
        let h = ProbeHarness(sites: [site])
        defer { h.stop() }
        h.advance(3)
        XCTAssertTrue(h.monitor.probeNow())
        let fresh = try XCTUnwrap(h.monitor.timeline.lanes[site.id]?[.fresh])
        XCTAssertTrue(fresh.waitingForSlot(at: 3))
        XCTAssertNil(h.monitor.timeline.lanes[site.id]?[.daily])
        XCTAssertEqual(fresh.starts, [0])
        h.monitor.networkDidChange()
        XCTAssertFalse(h.monitor.probeNow())
        try await waitUntil { !h.delay.completions.isEmpty }
        h.delay.releaseFirst()
        try await waitUntil { !h.monitor.timeline.lanes.isEmpty }
        site.enabled = false
        h.monitor.apply([site])
        XCTAssertFalse(h.monitor.probeNow())
        h.monitor.stop()
        XCTAssertFalse(h.monitor.probeNow())
    }

    @MainActor
    func testFreshSoftDeadlineLateSuccessAndRecovery() async throws {
        let h = ProbeHarness()
        defer { h.stop() }
        try await waitUntil { h.daily.count == 1 && h.fresh.count == 1 }
        h.daily[0].reply(204)
        try await waitUntil { h.monitor.state.rows[0].daily == .success(0) }
        h.advance(2)
        try await waitUntil { h.daily.count == 2 }
        h.daily[1].reply(204)
        try await Task.sleep(for: .milliseconds(25))
        h.advance(5)
        try await waitUntil { h.fresh.count == 1 && h.daily.count == 3 }
        XCTAssertEqual(h.monitor.state.color, .red)
        h.daily[2].reply(204)
        try await Task.sleep(for: .milliseconds(25))
        h.advance(6)
        try await waitUntil { h.fresh.count == 2 }
        h.advance(7)
        h.fresh[0].reply(204)
        try await waitUntil { h.monitor.state.rows[0].fresh == .success(7) }
        XCTAssertEqual(h.monitor.state.color, .orange)
        h.fresh[1].reply(204)
        try await waitUntil { h.monitor.state.color == .green }
        XCTAssertEqual(h.monitor.state.rows[0].fresh.text, "1.0 s")
        XCTAssertEqual(h.sessions.filter { $0 == .daily }.count, 1)
    }

    @MainActor
    func testNewerEvidenceSurvivesOlderLateResponse() async throws {
        let h = ProbeHarness()
        defer { h.stop() }
        try await waitUntil { h.fresh.count == 1 }
        h.advance(6)
        try await waitUntil { h.fresh.count == 2 }
        h.delay.time = 6.25
        h.fresh[1].reply(204)
        try await waitUntil { h.monitor.state.rows[0].fresh == .success(0.25) }
        h.advance(7)
        h.fresh[0].reply(403)
        try await waitUntil { h.monitor.state.rows[0].freshCount == SuccessCount(successes: 1, completed: 2) }
        XCTAssertEqual(h.monitor.state.rows[0].fresh.text, "250 ms")
    }

    @MainActor
    func testHardDeadlinesBoundOverlapAndCancelOldRequests() async throws {
        let h = ProbeHarness()
        defer { h.stop() }
        for round in 0...4 {
            h.advance(Double(round * 6))
            try await waitUntil { h.fresh.count == round + 1 && h.daily.count == round + 1 }
            if round > 0 {
                XCTAssertTrue(h.daily[round - 1].stopped)
                XCTAssertEqual(h.monitor.state.rows[0].fresh, .waiting)
            }
            if round > 1 { XCTAssertTrue(h.fresh[round - 2].stopped) }
            XCTAssertLessThanOrEqual(h.fresh.filter { !$0.stopped }.count, 2)
            h.monitor.pump()
            XCTAssertEqual(h.fresh.count, round + 1)
        }
    }

    @MainActor
    func testFastFailuresRetryAtTwoSecondsAndOnlyResetDailyConnection() async throws {
        let h = ProbeHarness()
        defer { h.stop() }
        try await waitUntil { h.fresh.count == 1 && h.daily.count == 1 }
        h.delay.time = 0.1
        h.fresh[0].reply(204)
        h.daily[0].fail(.networkConnectionLost)
        try await waitUntil { h.monitor.state.color == .orange }
        h.advance(1.99)
        XCTAssertEqual(h.daily.count, 1)
        h.advance(2)
        try await waitUntil { h.daily.count == 2 }
        h.daily[1].reply(204)
        try await waitUntil { h.monitor.state.color == .green }
        XCTAssertEqual(h.sessions.filter { $0 == .daily }.count, 2)
        h.advance(6)
        try await waitUntil { h.fresh.count == 2 }
        h.fresh[1].reply(403)
        try await waitUntil { h.monitor.state.color == .red }
        XCTAssertEqual(h.monitor.state.rows[0].fresh.text, "403")
        h.advance(7.9)
        XCTAssertEqual(h.fresh.count, 2)
        h.advance(11.99)
        XCTAssertEqual(h.sessions.filter { $0 == .fresh }.count, 2)
        h.advance(12)
        try await waitUntil { h.fresh.count == 3 }
    }

    @MainActor
    func testResetSwitchAndSleepInvalidateCallbacksAndDebounce() async throws {
        let h = ProbeHarness(sites: ProbeSite.builtIns)
        defer {
            h.stop()
            while !h.delay.completions.isEmpty { h.delay.releaseFirst() }
        }
        try await waitUntil { h.fresh.count == 2 && h.daily.count == 2 }
        h.monitor.networkDidChange()
        try await waitUntil { h.delay.completions.count == 1 }
        h.monitor.networkDidChange()
        try await waitUntil { h.delay.completions.count == 2 }
        h.delay.releaseFirst()
        h.advance(1)
        XCTAssertEqual(h.sessions.count, 4)
        h.delay.time = 1.25
        h.delay.releaseFirst()
        try await waitUntil { h.fresh.count == 4 && h.daily.count == 4 }
        h.advance(7.25)
        try await waitUntil { h.fresh.count == 6 }
        h.monitor.setEnabled(false)
        try await waitUntil { h.fresh.allSatisfy(\.stopped) && h.daily.allSatisfy(\.stopped) }
        h.monitor.networkDidChange()
        h.monitor.stop()
        h.monitor.start()
        h.monitor.apply([ProbeSite.builtIns[1]])
        h.advance(60)
        XCTAssertEqual(h.fresh.count, 6)
        XCTAssertEqual(h.monitor.state.title, "站点探测已关闭")
        XCTAssertEqual(h.monitor.state.rate, "0 B/h")
        XCTAssertTrue(h.monitor.estimate(for: ProbeSite.builtIns).footer.hasPrefix("全部站点合计 · 开启后预计"))
        h.monitor.setEnabled(true)
        try await waitUntil { h.fresh.count == 7 }
        XCTAssertEqual(h.monitor.state.color, .normal)
        XCTAssertEqual(h.fresh.last?.request.url, ProbeSite.builtIns[1].endpoint.httpsURL)
        h.monitor.networkDidChange()
        try await waitUntil { h.delay.completions.count == 1 }
        h.monitor.stop()
        h.delay.releaseFirst()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(h.fresh.count, 7)
    }

    @MainActor
    func testCustomRulesAndSelectiveReconfiguration() async throws {
        var custom = try ProbeSite.custom(name: "Codex", address: "https://example.com/",
                                          statusCodes: StatusCodes("2xx, 405"))
        let h = ProbeHarness(sites: ProbeSite.builtIns + [custom])
        defer { h.stop() }
        try await waitUntil { h.fresh.count == 3 && h.daily.count == 3 }
        for p in h.daily + h.fresh {
            let isCustom = p.request.url == custom.endpoint.httpsURL
            XCTAssertEqual(p.request.httpMethod, isCustom ? "HEAD" : "GET")
            p.reply(isCustom ? 405 : 204)
        }
        try await waitUntil { h.monitor.state.color == .green }
        custom.name = "Renamed"
        h.monitor.apply(ProbeSite.builtIns + [custom])
        XCTAssertEqual(h.monitor.state.rows.last?.name, "Renamed")
        XCTAssertEqual(h.sessions.count, 6)
        custom.statusCodes = try StatusCodes("3xx")
        h.monitor.apply(ProbeSite.builtIns + [custom])
        try await waitUntil { h.fresh.count == 4 && h.daily.count == 4 }
        let destination = URL(string: "https://other.example/")!
        h.fresh[3].redirect(to: destination)
        h.daily[3].reply(302)
        try await waitUntil { h.monitor.state.color == .green }
        XCTAssertFalse(h.fresh.contains { $0.request.url == destination })
        custom.endpoint = .https(URL(string: "https://example.com/new")!)
        h.monitor.apply(ProbeSite.builtIns + [custom])
        try await waitUntil { h.fresh.count == 5 }
        h.fresh[4].reply(302, url: destination)
        try await waitUntil { h.monitor.state.rows.last?.fresh == .failed }
        h.monitor.apply([])
        h.advance(50)
        XCTAssertEqual(h.monitor.state.title, "未启用探测")
        XCTAssertEqual(h.monitor.state.rate, "0 B/h")
    }

    @MainActor
    func testRetiringRequestsOccupyTheirLaneAcrossReconfiguration() async throws {
        var custom = try ProbeSite.custom(id: "google", name: "new", address: "https://example.com/")
        custom.fresh.capacity = 1
        let h = ProbeHarness(sites: ProbeSite.builtIns)
        defer { h.stop() }
        try await waitUntil { h.daily.count == 2 && h.fresh.count == 2 }
        h.advance(8)
        try await waitUntil { h.daily.count == 4 && h.fresh.count == 4 }
        let sessionsBeforeChange = h.sessions.count
        h.monitor.apply([custom])
        XCTAssertEqual(h.sessions.count, sessionsBeforeChange, "Retiring tasks occupy slots for this site and lane")
        try await waitUntil { h.fresh.count == 5 && h.daily.count == 5 }
        XCTAssertEqual(h.fresh[4].request.url, custom.endpoint.httpsURL)
        XCTAssertEqual(h.daily[4].request.url, custom.endpoint.httpsURL)
        XCTAssertEqual(h.monitor.state.rows[0].fresh, .checking)
        h.daily[4].reply(204)
        h.fresh[4].reply(204)
        try await waitUntil { h.monitor.state.color == .green }
    }

    @MainActor
    func testHealthyLanesHaveIndependentSchedules() async throws {
        let h = ProbeHarness()
        defer { h.stop() }
        for second in 0...12 {
            h.advance(Double(second))
            h.monitor.pump()
            let daily = second / 2 + 1
            let fresh = second / 6 + 1
            try await waitUntil { h.daily.count == daily && h.fresh.count == fresh }
            h.delay.time += 0.05
            if second.isMultiple(of: 2) { h.daily[daily - 1].reply(204) }
            if second.isMultiple(of: 6) { h.fresh[fresh - 1].reply(204) }
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(h.monitor.state.color, .green)
            XCTAssertEqual(h.sessions.filter { $0 == .daily }.count, 1)
            XCTAssertEqual(h.sessions.filter { $0 == .fresh }.count, fresh)
        }
    }

    @MainActor
    func testDailyWarningsRotateOnlyTheSessionThatWasSlow() async throws {
        var site = ProbeSite.builtIns[0]
        site.fresh.enabled = false
        site.daily = .init(interval: 1, warning: 4, cutoff: 9, capacity: 5)
        let h = ProbeHarness(sites: [site])
        defer { h.stop() }
        for second in 0...4 {
            h.advance(Double(second))
            try await waitUntil { h.daily.count == second + 1 }
        }
        XCTAssertEqual(h.sessions.count, 2)
        XCTAssertEqual(h.monitor.state.color, .orange)
        XCTAssertFalse(h.daily[0].stopped)
        XCTAssertEqual(h.monitor.state.rows[0].dailyCount.completed, 0)
        h.delay.time = 4.25
        h.daily[4].reply(204)
        try await waitUntil { h.monitor.state.color == .green }
        h.daily[0].reply(403)
        try await waitUntil { h.monitor.state.rows[0].dailyCount.completed == 2 }
        XCTAssertEqual(h.monitor.state.rows[0].daily, .success(0.25))
        h.advance(5)
        try await waitUntil { h.daily.count == 6 }
        XCTAssertEqual(h.sessions.count, 2, "Old warnings and failures must keep the replacement session")
        h.daily[5].fail(.cannotConnectToHost)
        try await waitUntil { h.monitor.state.color == .red }
        h.advance(6)
        try await waitUntil { h.sessions.count == 3 && h.daily.count == 7 }
    }

    @MainActor
    func testFullLaneCoalescesMissedIntervalsAndChargesDailyHandshakesToDaily() async throws {
        var site = ProbeSite.builtIns[0]
        site.fresh.enabled = false
        site.daily = .init(interval: 2, warning: 8, cutoff: 8, capacity: 1)
        let h = ProbeHarness(sites: [site])
        defer { h.stop() }
        try await waitUntil { h.daily.count == 1 }
        for tick in [2.0, 4, 6, 7.99] { h.advance(tick) }
        XCTAssertEqual(h.sessions.count, 1)
        h.advance(8)
        XCTAssertEqual(h.monitor.state.rows[0].daily, .timedOut)
        XCTAssertEqual(h.monitor.state.color, .red)
        XCTAssertEqual(h.monitor.state.rows[0].percentages, "0/—")
        try await waitUntil { h.daily[0].stopped && h.daily.count == 2 }
        h.daily[1].reply(403)
        try await waitUntil { h.monitor.state.rows[0].dailyCount.completed == 2 }
        h.advance(9.99)
        XCTAssertEqual(h.daily.count, 2)
        h.advance(10)
        try await waitUntil { h.daily.count == 3 }
        h.daily[2].reply(204)
        try await waitUntil { h.monitor.state.rows[0].dailyCount.completed == 3 }
        h.delay.time = 60
        let expected = Double(3 * ProbeUsage.freshBytes) * 60
        try await waitUntil { h.monitor.estimate(for: [site]).total == expected }
        XCTAssertEqual(h.monitor.estimate(for: [site]).sites[site.id], SiteTraffic(daily: expected, fresh: 0))
    }

    @MainActor
    func testGetSettlesAtHeadersAndOnlyEditedLanesLoseHistory() async throws {
        var site = try ProbeSite.custom(name: "Large response", address: "https://example.com/stream")
        site.method = .get
        let h = ProbeHarness(sites: [site])
        defer {
            h.stop()
            while !h.delay.completions.isEmpty { h.delay.releaseFirst() }
        }
        try await waitUntil { h.daily.count == 1 && h.fresh.count == 1 }
        for probe in [h.daily[0], h.fresh[0]] {
            XCTAssertEqual(probe.request.httpMethod, "GET")
            probe.headers(200)
        }
        try await waitUntil { h.monitor.state.rows[0].percentages == "100/100" }
        try await waitUntil { h.daily[0].stopped && h.fresh[0].stopped }
        h.advance(2)
        try await waitUntil { h.daily.count == 2 }
        site.name = "New name"
        h.monitor.apply([site])
        XCTAssertEqual(h.monitor.state.rows[0].percentages, "100/100")
        site.daily.capacity = 3
        h.monitor.apply([site])
        XCTAssertEqual(h.monitor.state.rows[0].percentages, "—/100")
        try await waitUntil { h.daily[1].stopped && h.daily.count == 3 }
        XCTAssertEqual(h.fresh.count, 1)
        site.daily.enabled = false
        h.monitor.apply([site])
        try await waitUntil { h.daily[2].stopped }
        XCTAssertEqual(h.monitor.state.rows[0].percentages, "—/100")
        site.method = .head
        h.monitor.apply([site])
        XCTAssertEqual(h.monitor.state.rows[0].percentages, "—/—")
        try await waitUntil { h.fresh.count == 2 }
        XCTAssertEqual(h.fresh[1].request.httpMethod, "HEAD")
        h.fresh[1].reply(500)
        try await waitUntil { h.monitor.state.rows[0].percentages == "—/0" }
        h.monitor.networkDidChange()
        XCTAssertEqual(h.monitor.state.rows[0].percentages, "—/—")
        try await waitUntil { h.delay.completions.count == 1 }
        h.delay.releaseFirst()
        try await waitUntil { h.fresh.count == 3 }
        h.fresh[2].reply(200)
        try await waitUntil { h.monitor.state.rows[0].percentages == "—/100" }
        h.monitor.stop()
        h.monitor.start()
        XCTAssertEqual(h.monitor.state.rows[0].percentages, "—/—")
    }

    @MainActor
    func testOnlyEffectiveStrengthChangesResetProbeHistory() async throws {
        var site = ProbeSite.builtIns[0]
        let h = ProbeHarness(sites: [site])
        defer { h.stop() }
        try await waitUntil { h.daily.count == 1 && h.fresh.count == 1 }
        h.advance(5)
        XCTAssertEqual(h.monitor.state.rows[0].daily, .waiting)
        h.delay.time = 7
        h.daily[0].reply(204)
        h.fresh[0].reply(204)
        try await waitUntil { h.monitor.state.rows[0].dailyCount.successes == 1 && h.monitor.state.rows[0].freshCount.successes == 1 }
        let personal = ProbeStrength(id: "mine", name: "工作", values: ProbeLane.fresh.strengths[0].values)
        site[strength: .fresh].personal = [personal]
        site[strength: .fresh].selectedID = personal.id
        h.monitor.apply([site])
        XCTAssertEqual(h.monitor.state.rows[0].freshCount.successes, 1)
        site[strength: .fresh].personal[0].name = "办公"
        h.monitor.apply([site])
        XCTAssertEqual(h.monitor.state.rows[0].freshCount.successes, 1)
        site[strength: .fresh].personal[0].values.interval = 13
        h.monitor.apply([site])
        XCTAssertEqual(h.monitor.state.rows[0].freshCount.completed, 0)
        XCTAssertEqual(h.monitor.state.rows[0].dailyCount.successes, 1)
    }

    @MainActor
    func testApplyingPausedConfigurationDoesNotLaunchItsNewSites() async throws {
        let h = ProbeHarness()
        defer { h.stop() }
        try await waitUntil { h.daily.count == 1 && h.fresh.count == 1 }
        h.monitor.apply(ProbeConfiguration(probingEnabled: false, sites: ProbeSite.builtIns))
        h.advance(40)
        try await waitUntil { h.daily[0].stopped && h.fresh[0].stopped }
        XCTAssertEqual(h.sessions, [.daily, .fresh])
        XCTAssertFalse(h.monitor.state.enabled)
        XCTAssertTrue(h.monitor.state.rows.contains { $0.name == "Cloudflare" })
    }
}
