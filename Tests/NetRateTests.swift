import AppKit
import Network
import Synchronization
import XCTest

// Keep transport tests deterministic and independent of the developer's network.
private class ProbeProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var onRequest: ((ProbeProtocol) -> Void)?
    private let didStop = Mutex(false)
    var stopped: Bool { didStop.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in Self.onRequest?(self) }
    }
    override func stopLoading() {
        didStop.withLock { $0 = true }
    }

    func headers(_ status: Int, url: URL? = nil) {
        let response = HTTPURLResponse(url: url ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/octet-stream", "Content-Length": status == 204 ? "0" : "10000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func reply(_ status: Int, url: URL? = nil) {
        headers(status, url: url)
        client?.urlProtocolDidFinishLoading(self)
    }

    func redirect(to url: URL) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": url.absoluteString])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(_ code: URLError.Code) {
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }
}

private final class FreshProtocol: ProbeProtocol, @unchecked Sendable {}

@MainActor
private final class NetworkDelay {
    var completions: [CheckedContinuation<Void, Never>] = []
    var time: TimeInterval = 0

    func wait() async {
        await withCheckedContinuation { completions.append($0) }
    }

    func releaseFirst() { completions.removeFirst().resume() }
}

@MainActor
private final class ProbeHarness {
    var daily: [ProbeProtocol] = []
    var fresh: [ProbeProtocol] = []
    let delay = NetworkDelay()
    var sessions: [ProbeLane] = []
    let sites: [ProbeSite]
    lazy var monitor = ConnectivityMonitor(sites: sites, configuration: { [unowned self] kind in
        sessions.append(kind)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [kind == .fresh ? FreshProtocol.self : ProbeProtocol.self]
        return config
    }, now: { [delay] in delay.time }, waitForNetwork: { [delay] in await delay.wait() },
       automaticTimer: false, onChange: {})

    init(sites: [ProbeSite] = [ProbeSite.builtIns[0]]) {
        self.sites = sites
        ProbeProtocol.onRequest = { [unowned self] probe in
            if probe is FreshProtocol { fresh.append(probe) } else { daily.append(probe) }
        }
        monitor.start()
    }

    func advance(_ time: TimeInterval) {
        delay.time = time
        monitor.pump()
    }

    func stop() {
        monitor.stop()
        ProbeProtocol.onRequest = nil
    }
}

@MainActor
private final class LoopbackServer {
    var peers: [NWConnection] = []
    var paths: [String] = []
    // Read the next request on each persistent connection. The /stream handler
    // sends only headers and holds its declared body open until the client leaves.
    func read(_ peer: NWConnection, partial: Data = Data()) {
        peer.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, ended, error in
            MainActor.assumeIsolated {
                guard let data, !ended, error == nil else { return }
                let request = partial + data
                let text = String(decoding: request, as: UTF8.self)
                guard text.contains("\r\n\r\n") else { self.read(peer, partial: request); return }
                let parts = text.components(separatedBy: " ")
                XCTAssertEqual(parts.first, "GET")
                let path = parts[1]
                self.paths.append(path)
                let response = switch path {
                case "/empty": "204 No Content"
                case "/redirect": "302 Found\r\nLocation: /destination\r\nContent-Length: 0"
                default: "200 OK\r\nContent-Length: 10000000"
                }
                peer.send(content: Data("HTTP/1.1 \(response)\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                self.read(peer)
            }
        }
    }
}

final class NetRateTests: XCTestCase {
    private func counters(
        received: UInt64,
        sent: UInt64,
        receivedPackets: UInt64 = 0,
        sentPackets: UInt64 = 0,
        lastChange: UInt64 = 0,
        bitsPerSecond: UInt64 = 0
    ) -> LinkCounters {
        LinkCounters(
            received: .init(bytes: received, packets: receivedPackets),
            sent: .init(bytes: sent, packets: sentPackets),
            lastChange: lastChange,
            bitsPerSecond: bitsPerSecond
        )
    }

    func testFormatting() {
        for (rate, expected) in [(0.0,"0B"), (36,"36B"), (999.5,"1K"), (2400,"2K"),
                                 (999600,"1M"), (1.4e6,"1.4M"), (2e6,"2M"),
                                 (9.96e6,"10M"), (82.3e6,"82M"), (1.4e9,"1.4G")] {
            let text = RateText(rate)
            XCTAssertEqual(text.value + text.unit, expected)
        }
        XCTAssertEqual(RateText(nil).value, "—")
    }

    func testInterfacesAndBaseline() {
        let wifi = LinkID(index: 1, name: "en0")
        let peer = LinkID(index: 2, name: "awdl0")
        let proxy = LinkID(index: 3, name: "lo0")
        let vpn = LinkID(index: 4, name: "utun0")
        var meter = TrafficMeter()
        func read(_ time: Double, _ totals: [LinkID: UInt64]) -> Speed? {
            meter.measure(Snapshot(time: time, links: totals.mapValues { counters(received: $0, sent: $0*2) }))
        }
        XCTAssertNil(read(0,[wifi:100,proxy:200,vpn:200]))
        XCTAssertEqual(read(2,[wifi:150,peer:5000,proxy:600,vpn:700])?.upload,50)
        XCTAssertEqual(read(3,[wifi:160,peer:5020])?.download,30)
        XCTAssertEqual(read(4,[wifi:1,peer:5022])?.download,2)
        XCTAssertEqual(read(5,[wifi:1])?.download,0)
        XCTAssertNil(read(24,[wifi:5555]))
        XCTAssertNil(meter.measure(nil))
        XCTAssertNil(read(26,[wifi:9999]))
        XCTAssertEqual(read(27,[wifi:9999])?.upload,0)
    }

    func testInterfaceReplacementAnd64BitCounters() {
        let oldID = LinkID(index: 14, name: "en0")
        let newID = LinkID(index: 24, name: "en0")
        let total: UInt64 = 1 << 42
        var meter = TrafficMeter()
        func sample(_ time: Double, _ id: LinkID, _ bytes: UInt64) -> Speed? {
            meter.measure(Snapshot(time: time, links: [id: counters(received: bytes, sent: 0)]))
        }
        XCTAssertNil(sample(0, oldID, total))
        XCTAssertEqual(sample(1.25, oldID, total + 1250)?.download, 1000)
        XCTAssertNil(sample(2.25, newID, total + 8000))
        XCTAssertEqual(sample(3.25, newID, total + 9000)?.download, 1000)
        let reset = sample(4.25, newID, 0)
        XCTAssertNil(reset?.download)
        XCTAssertEqual(reset?.upload, 0)
        XCTAssertEqual(sample(5.25, newID, 12)?.download, 12)
    }

    func testTruncatedDarwinCountersWrapIndependently() {
        let wifi = LinkID(index: 1, name: "en0")
        let modulus: UInt64 = 1 << 32
        var meter = TrafficMeter()
        func sample(_ time: Double, _ counters: LinkCounters) -> Speed? {
            meter.measure(Snapshot(time: time, links: [wifi: counters]))
        }
        XCTAssertNil(sample(0, counters(
            received: modulus - 4096, sent: modulus - 8192,
            receivedPackets: 1 << 32, sentPackets: 100)))
        let receiveWrap = sample(1.25, counters(
            received: 2048, sent: modulus - 4096,
            receivedPackets: (1 << 32) + 8, sentPackets: 105))
        XCTAssertEqual(receiveWrap?.download, 6144 / 1.25)
        XCTAssertEqual(receiveWrap?.upload, 4096 / 1.25)
        let sendWrap = sample(2.25, counters(
            received: 3072, sent: 1024,
            receivedPackets: (1 << 32) + 10, sentPackets: 110))
        XCTAssertEqual(sendWrap?.download, 1024)
        XCTAssertEqual(sendWrap?.upload, 5120)
    }

    func testResetIsNotAnInterfaceRollover() {
        let wifi = LinkID(index: 1, name: "en0")
        let modulus: UInt64 = 1 << 32
        var meter = TrafficMeter()
        func sample(_ time: Double, _ counters: LinkCounters) -> Speed? {
            meter.measure(Snapshot(time: time, links: [wifi: counters]))
        }
        XCTAssertNil(sample(0, counters(
            received: modulus - 1024, sent: modulus - 2048,
            receivedPackets: 100, sentPackets: 100)))
        let packetReset = sample(1, counters(
            received: 1024, sent: 1024, receivedPackets: 2, sentPackets: 103))
        XCTAssertNil(packetReset?.download)
        XCTAssertEqual(packetReset?.upload, 3072)
        XCTAssertNil(sample(2, counters(
            received: 2048, sent: 2048, receivedPackets: 10, sentPackets: 104, lastChange: 1)))
        let rebased = sample(3, counters(
            received: 3072, sent: 4096, receivedPackets: 11, sentPackets: 106, lastChange: 1))
        XCTAssertEqual(rebased?.download, 1024)
        XCTAssertEqual(rebased?.upload, 2048)
    }

    func testImplausiblyLargeRolloverIsDiscarded() {
        let wifi = LinkID(index: 1, name: "en0")
        var meter = TrafficMeter()
        _ = meter.measure(Snapshot(time: 0, links: [
            wifi: counters(received: 3 << 30, sent: 1 << 30, receivedPackets: 100)
        ]))
        let speed = meter.measure(Snapshot(time: 0.5, links: [
            wifi: counters(received: 1024, sent: (1 << 30) + 1024, receivedPackets: 101)
        ]))
        XCTAssertNil(speed?.download)
        XCTAssertEqual(speed?.upload, 2048)
    }

    func testPureLoopbackAndTunnelTraffic() {
        let loopback = LinkID(index: 1, name: "lo0")
        let tunnel = LinkID(index: 12, name: "utun0")
        var meter = TrafficMeter()
        _ = meter.measure(Snapshot(time: 1, links: [:]))
        let bytes = counters(received: 4_000_000, sent: 4_000_000)
        let speed = meter.measure(Snapshot(time: 2, links: [loopback: bytes, tunnel: bytes]))
        XCTAssertEqual(speed?.download, 0)
        XCTAssertEqual(speed?.upload, 0)
    }

    @MainActor
    func testStatusColorsAcrossAppearances() throws {
        let face = StatusFace()
        XCTAssertEqual(face.width, 34)
        for color in [ArrowColor.normal, .green, .orange, .red] {
            let image = face.image(upload: RateText(999000), download: RateText(1.4e6), color: color)
            try checkColors(image, color: color)
        }
    }

    @MainActor
    private func checkColors(_ image: NSImage, color: ArrowColor) throws {
        for (name, expected) in [(NSAppearance.Name.aqua, 0.0), (.darkAqua, 1.0), (.aqua, 0.0)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 40,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            appearance.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                image.draw(in: NSRect(x: 0, y: 0, width: image.size.width * 2, height: 40))
                NSGraphicsContext.restoreGraphicsState()
                var solidPixels = 0
                var arrowPixels = [0, 0]
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              pixel.alphaComponent > 0.95 else { continue }
                        solidPixels += 1
                        if x < 8 {
                            arrowPixels[y / 20] += 1
                            switch color {
                            case .normal: break
                            case .green:
                                XCTAssertGreaterThan(pixel.greenComponent, pixel.redComponent)
                                XCTAssertGreaterThan(pixel.greenComponent, pixel.blueComponent)
                                continue
                            case .red:
                                XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent)
                                XCTAssertGreaterThan(pixel.redComponent, pixel.blueComponent)
                                continue
                            case .orange:
                                XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent)
                                XCTAssertGreaterThan(pixel.greenComponent, pixel.blueComponent)
                                continue
                            }
                        }
                        for component in [pixel.redComponent, pixel.greenComponent, pixel.blueComponent] {
                            XCTAssertEqual(component, expected, accuracy: 0.04)
                        }
                    }
                }
                XCTAssertGreaterThan(solidPixels, 100)
                for count in arrowPixels { XCTAssertGreaterThan(count, 20) }
            }
        }
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(2), file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("Timed out waiting for probe", file: file, line: line)
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    func testHoverPanelStaysOnTheDisplayWithTheButton() {
        let size = NSSize(width: 148, height: 99)
        for screen in [
            NSRect(x: 65, y: 0, width: 1663, height: 1083),
            NSRect(x: -3200, y: -229, width: 1280, height: 1409),
            NSRect(x: -1920, y: 37, width: 1920, height: 1049)
        ] {
            let button = NSRect(x: screen.maxX - 64, y: screen.maxY + 4, width: 34, height: 22)
            let panel = StatusHover.panelFrame(size: size, under: button, within: screen)
            XCTAssertTrue(screen.contains(panel))
            XCTAssertEqual(panel.maxX, screen.maxX)
            XCTAssertEqual(panel.maxY, button.minY - 14)
        }
    }

    @MainActor
    func testInactiveMenuBarUsesItsOwnScreenCoordinates() throws {
        let source = NSRect(x: -1920, y: 37, width: 1920, height: 1080)
        let button = NSRect(x: -548, y: 1090.5, width: 34, height: 22)
        let external = NSRect(x: -3200, y: -229, width: 1280, height: 1440)
        let externalButton = try XCTUnwrap(StatusHover.replicaFrame(of: button, from: source, to: external,
                                                                   topRightArea: nil))
        XCTAssertEqual(externalButton, NSRect(x: -2468, y: 1184.5, width: 34, height: 22))

        let builtIn = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let rightOfNotch = NSRect(x: 956.5, y: 1085, width: 771.5, height: 32)
        let builtInButton = try XCTUnwrap(StatusHover.replicaFrame(of: button, from: source, to: builtIn,
                                                                  topRightArea: rightOfNotch))
        XCTAssertEqual(builtInButton, NSRect(x: 1180, y: 1090.5, width: 34, height: 22))
        XCTAssertNil(StatusHover.replicaFrame(of: button.offsetBy(dx: -250, dy: 0), from: source, to: builtIn,
                                              topRightArea: rightOfNotch))
        XCTAssertNil(StatusHover.replicaFrame(of: button.offsetBy(dx: 0, dy: -60), from: source, to: external,
                                              topRightArea: nil))
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
        XCTAssertEqual(h.fresh.last?.request.url, ProbeSite.builtIns[1].url)
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
            let isCustom = p.request.url == custom.url
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
        custom.url = URL(string: "https://example.com/new")!
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
        h.advance(6)
        try await waitUntil { h.daily.count == 4 && h.fresh.count == 4 }
        let sessionsBeforeChange = h.sessions.count
        h.monitor.apply([custom])
        XCTAssertEqual(h.sessions.count, sessionsBeforeChange, "Retiring tasks occupy slots for this site and lane")
        try await waitUntil { h.fresh.count == 5 && h.daily.count == 5 }
        XCTAssertEqual(h.fresh[4].request.url, custom.url)
        XCTAssertEqual(h.daily[4].request.url, custom.url)
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
    func testCardTruncationAndAccessibleReadings() throws {
        let row = ConnectivityState.Row(id: "c", name: String(repeating: "长站名", count: 12), enabled: true,
                                        daily: .success(0.132), fresh: .wrongStatus(403),
                                        dailyCount: .init(successes: 7, completed: 7),
                                        freshCount: .init(successes: 2, completed: 2))
        let state = ConnectivityState(rows: [row], rate: "5.2 MB/h")
        let card = HoverCard()
        let size = card.update(state, availableHeight: 200)
        let item = NSStatusBar.system.statusItem(withLength: 34)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        var face = StatusFace()
        let hover = StatusHover(item: item)
        face.update(button, speed: nil, connectivity: state)
        hover.update(state)
        XCTAssertEqual(button.toolTip, state.hoverTooltip)
        XCTAssertEqual(button.accessibilityHelp(), state.summary)
        XCTAssertTrue(state.summary.contains(row.name + "，复用 132 ms，新建 非预期状态码 403"))
        XCTAssertTrue(state.summary.contains("复用成功率 100%，成功 7 次，完成 7 次，新建成功率 100%，成功 2 次，完成 2 次"))
        let fields = try XCTUnwrap(card.contentView).subviews.compactMap { $0 as? NSTextField }
        let percentages = try XCTUnwrap(fields.first { $0.stringValue == "100/100" })
        XCTAssertEqual(percentages.alignment, .right)
        XCTAssertGreaterThanOrEqual(percentages.frame.width, percentages.intrinsicContentSize.width)
        XCTAssertEqual(card.update(state, availableHeight: 180, availableWidth: 320).width, 320)
        let header = try XCTUnwrap(fields.first { $0.stringValue == "复用/新建请求成功率(%)" })
        XCTAssertEqual(header.maximumNumberOfLines, 1)
        XCTAssertGreaterThanOrEqual(header.frame.width, header.intrinsicContentSize.width)
        XCTAssertEqual(header.frame.maxX, percentages.frame.maxX)
        let fresh = try XCTUnwrap(fields.first { $0.stringValue == "新建" })
        XCTAssertEqual(header.frame.minY, fresh.frame.minY)
        XCTAssertGreaterThan(header.frame.minX, fresh.frame.maxX)
        let name = try XCTUnwrap(fields.first { $0.stringValue == row.name })
        XCTAssertEqual(name.accessibilityLabel(), row.spoken)
        XCTAssertGreaterThan(size.width, 402)
        let empty = ConnectivityState.Row(id: "c", name: row.name, enabled: true)
        _ = card.update(.init(rows: [empty]), availableHeight: 180, availableWidth: 320)
        XCTAssertEqual(percentages.stringValue, "—/—")
        XCTAssertEqual(state.color, .red)
        let many = ConnectivityState(rows: Array(repeating: row, count: 15))
        XCTAssertLessThanOrEqual(card.update(many, availableHeight: 185).height, 185)
        XCTAssertEqual(size.width, card.update(many, availableHeight: 185).width)
    }

    @MainActor
    private func view<T: NSView>(_ root: NSView, matching predicate: (T) -> Bool) -> T? {
        if let match = root as? T, predicate(match) { return match }
        for child in root.subviews {
            if let match = view(child, matching: predicate) { return match }
        }
        return nil
    }

    @MainActor
    func testSiteWindowStagesChangesAndProtectsBuiltIns() throws {
        let custom = try ProbeSite.custom(name: "Example", address: "https://example.com/status")
        let sites = ProbeSite.builtIns + [custom]
        var commits: [[ProbeSite]?] = []
        func exercise(save: Bool) throws {
            let monitor = ConnectivityMonitor(sites: sites, automaticTimer: false) {}
            let editor = SiteSettingsWindow(sites: sites, estimate: monitor.estimate(for:)) { commits.append($0) }
            let content = try XCTUnwrap(editor.window?.contentView)
            XCTAssertEqual(editor.window?.title, "探测站点配置")
            editor.window?.setContentSize(try XCTUnwrap(editor.window?.contentMinSize))
            content.layoutSubtreeIfNeeded()
            for title in ["新增站点", "编辑站点"] {
                let button = try XCTUnwrap(view(content) { (b: NSButton) in b.title == title })
                XCTAssertGreaterThanOrEqual(button.frame.width, button.intrinsicContentSize.width)
            }
            let table = try XCTUnwrap(view(content) { (_: NSTableView) in true })
            let remove = try XCTUnwrap(view(content) { (button: NSButton) in button.title == "删除" })
            let edit = try XCTUnwrap(view(content) { (button: NSButton) in button.title == "编辑站点" })
            let finish = try XCTUnwrap(view(content) { (button: NSButton) in button.title == (save ? "保存" : "取消") })
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            XCTAssertFalse(remove.isEnabled)
            XCTAssertTrue(edit.isEnabled)
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
            let toggle = try XCTUnwrap(view(cell) { (_: NSButton) in true })
            toggle.performClick(nil)
            XCTAssertNotNil(view(content) { (label: NSTextField) in label.stringValue == monitor.estimate(for: Array(sites.dropFirst())).footer })
            table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            XCTAssertTrue(remove.isEnabled)
            XCTAssertTrue(edit.isEnabled)
            remove.performClick(nil)
            XCTAssertEqual(table.numberOfRows, 2)
            finish.performClick(nil)
        }
        try exercise(save: false)
        XCTAssertEqual(commits.count, 1)
        XCTAssertNil(commits[0])
        try exercise(save: true)
        var expected = ProbeSite.builtIns
        expected[0].enabled = false
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[1], expected)
    }

    @MainActor
    func testSiteWindowSavesHoverOrderAndKeepsProbeHistory() async throws {
        let custom = try ProbeSite.custom(name: "Example", address: "https://example.com/status", enabled: false)
        let sites = ProbeSite.builtIns + [custom]
        let expected = [custom, sites[1], sites[0]]
        let domain = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SiteSettings(defaults: defaults)
        try settings.save(sites)
        let h = ProbeHarness(sites: sites)
        defer { h.stop() }
        try await waitUntil { h.daily.count == 2 && h.fresh.count == 2 }
        for probe in h.daily { probe.reply(204) }
        try await waitUntil { h.monitor.state.rows.prefix(2).allSatisfy { $0.dailyCount.successes == 1 } }
        let originalRows = h.monitor.state.rows
        let originalSessions = h.sessions

        func editOrder(save: Bool) throws {
            let controller = SiteSettingsWindow(sites: settings.load(), estimate: h.monitor.estimate(for:)) { updated in
                if let updated {
                    try settings.save(updated)
                    h.monitor.apply(updated)
                }
            }
            let window = try XCTUnwrap(controller.window)
            let content = try XCTUnwrap(window.contentView)
            window.setContentSize(window.contentMinSize)
            content.layoutSubtreeIfNeeded()
            let table = try XCTUnwrap(view(content) { (_: NSTableView) in true })
            let up = try XCTUnwrap(view(content) { (button: NSButton) in button.title == "上移" })
            let down = try XCTUnwrap(view(content) { (button: NSButton) in button.title == "下移" })
            for button in [up, down] {
                XCTAssertGreaterThanOrEqual(button.frame.width, button.intrinsicContentSize.width)
                XCTAssertFalse(button.isEnabled)
            }
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            XCTAssertFalse(up.isEnabled)
            down.performClick(nil)
            XCTAssertEqual(table.selectedRow, 1)
            XCTAssertTrue(up.isEnabled)
            down.performClick(nil)
            XCTAssertEqual(table.selectedRow, 2)
            XCTAssertFalse(down.isEnabled)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            up.performClick(nil)
            XCTAssertEqual(table.selectedRow, 0)
            XCTAssertFalse(up.isEnabled)
            let cell = try XCTUnwrap(table.view(atColumn: 1, row: 0, makeIfNecessary: true))
            XCTAssertNotNil(view(cell) { (label: NSTextField) in label.stringValue == custom.name })
            XCTAssertEqual(settings.load(), sites)
            XCTAssertEqual(h.monitor.state.rows, originalRows)
            let done = try XCTUnwrap(view(content) { (button: NSButton) in button.title == (save ? "保存" : "取消") })
            done.performClick(nil)
        }

        try editOrder(save: false)
        XCTAssertEqual(settings.load(), sites)
        XCTAssertEqual(h.monitor.state.rows, originalRows)
        try editOrder(save: true)
        XCTAssertEqual(SiteSettings(defaults: defaults).load(), expected)
        XCTAssertEqual(h.monitor.state.rows, Array(originalRows.reversed()))
        XCTAssertEqual(h.sessions, originalSessions)
        XCTAssertFalse(h.fresh.contains(where: \.stopped))

        let hover = HoverCard()
        _ = hover.update(h.monitor.state, availableHeight: 240)
        let hoverContent = try XCTUnwrap(hover.contentView)
        let expectedNames = expected.map(\.name)
        let names = hoverContent.subviews.compactMap { $0 as? NSTextField }
            .filter { expectedNames.contains($0.stringValue) }
            .sorted { $0.frame.minY > $1.frame.minY }
        XCTAssertEqual(names.map(\.stringValue), expectedNames)
    }

    @MainActor
    func testEditorPreviewsPerLaneValidatesAndDiscardsDrafts() async throws {
        let site = ProbeSite.builtIns[0]
        let monitor = ConnectivityMonitor(sites: [site], automaticTimer: false) {}
        var committed: [ProbeSite]?
        let controller = SiteSettingsWindow(sites: [site], estimate: monitor.estimate(for:)) { committed = $0 }
        let window = try XCTUnwrap(controller.window)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let list = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(view(list) { (_: NSTableView) in true })
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        func button(_ text: String, in root: NSView) throws -> NSButton {
            try XCTUnwrap(view(root) { (b: NSButton) in b.title == text })
        }
        func field(_ name: String, in root: NSView) throws -> NSTextField {
            try XCTUnwrap(view(root) { (f: NSTextField) in f.accessibilityLabel() == name })
        }
        for save in [false, true] {
            try button("编辑站点", in: list).performClick(nil)
            let sheet = try XCTUnwrap(window.attachedSheet)
            let root = try XCTUnwrap(sheet.contentView)
            XCTAssertNil(view(root) { (f: NSTextField) in f.stringValue.contains("全部站点合计") })
            XCTAssertEqual(try field("HTTPS 地址", in: root).toolTip, HelpField.address.tip(readOnly: true))
            let interval = try field("新建间隔（秒）", in: root)
            XCTAssertEqual(interval.stringValue, "6")
            XCTAssertFalse(try field("HTTPS 地址", in: root).isEditable)
            XCTAssertEqual(try field("成功状态码", in: root).stringValue, "204")
            let daily = try field("复用每小时预计流量", in: root).stringValue
            interval.stringValue = "12"
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: interval)
            XCTAssertEqual(try field("新建每小时预计流量", in: root).stringValue, "2.1 MB")
            XCTAssertEqual(try field("复用每小时预计流量", in: root).stringValue, daily)
            let toggle = try XCTUnwrap(view(root) { (b: NSButton) in b.accessibilityLabel() == "启用新建" })
            toggle.performClick(nil)
            XCTAssertFalse(interval.isEnabled)
            XCTAssertEqual(interval.toolTip, HelpField.interval.help.tip)
            XCTAssertEqual(interval.accessibilityHelp(), interval.toolTip)
            XCTAssertEqual(try field("新建每小时预计流量", in: root).stringValue, "0 KB")
            toggle.performClick(nil)
            XCTAssertEqual(interval.stringValue, "12")
            let cutoff = try field("新建截止（秒）", in: root)
            cutoff.stringValue = "1"
            try button("确定", in: root).performClick(nil)
            XCTAssertTrue(window.attachedSheet === sheet)
            XCTAssertNotNil(view(root) { (f: NSTextField) in f.stringValue == SiteConfigurationError.shortDeadline.localizedDescription })
            cutoff.stringValue = "10"
            try button(save ? "确定" : "取消", in: root).performClick(nil)
            try await waitUntil { window.attachedSheet == nil }
            XCTAssertNil(committed)
            var expected = site
            if save { expected.fresh.interval = 12 }
            let footer = monitor.estimate(for: [expected]).footer
            XCTAssertTrue(footer.hasPrefix("全部站点合计"))
            XCTAssertNotNil(view(list) { (f: NSTextField) in f.stringValue == footer })
        }
        try button("保存", in: list).performClick(nil)
        XCTAssertEqual(committed?.first?.fresh.interval, 12)
        XCTAssertEqual(committed?.first?.daily, site.daily)
    }

    @MainActor
    func testModelessHelpSharesTopicsWithFieldTipsAndReturnsToDraft() async throws {
        let monitor = ConnectivityMonitor(sites: [], automaticTimer: false) {}
        let controller = SiteSettingsWindow(sites: [], estimate: monitor.estimate(for:)) { _ in }
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { controller.close() }
        let list = try XCTUnwrap(window.contentView)
        func button(_ title: String, in root: NSView) throws -> NSButton {
            try XCTUnwrap(view(root) { (b: NSButton) in b.title == title })
        }
        func visibleHelp() -> [NSWindow] {
            NSApp.windows.filter { $0.isVisible && $0.title == "配置说明" }
        }
        try button("配置说明", in: list).performClick(nil)
        let help = try XCTUnwrap(visibleHelp().first)
        let guide = try XCTUnwrap(help.contentView)
        XCTAssertGreaterThanOrEqual(guide.bounds.height, help.contentMinSize.height)
        let nav = try XCTUnwrap(view(guide) { (_: NSTableView) in true })
        func selectTopic(_ title: String) throws {
            let row = try XCTUnwrap((0..<nav.numberOfRows).first {
                (nav.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == title
            })
            nav.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        try selectTopic(HelpField.codes.rawValue)
        XCTAssertNotNil(view(guide) { (f: NSTextField) in f.stringValue == HelpField.codes.help.tip })
        try button(HelpRule.success.rawValue, in: guide).performClick(nil)
        XCTAssertNotNil(view(guide) { (f: NSTextField) in f.stringValue == "9 ÷ 10 = 90%" })
        for rule in HelpRule.allCases {
            try selectTopic(rule.rawValue)
            XCTAssertNotNil(view(guide) { (f: NSTextField) in f.stringValue == rule.note })
        }
        help.setContentSize(help.contentMinSize)
        try selectTopic(HelpRule.schedule.rawValue)
        guide.layoutSubtreeIfNeeded()
        let lastNote = try XCTUnwrap(view(guide) { (f: NSTextField) in f.stringValue == HelpRule.schedule.note })
        let scroller = try XCTUnwrap(lastNote.enclosingScrollView)
        XCTAssertGreaterThan(try XCTUnwrap(scroller.documentView).frame.height, scroller.contentSize.height)
        lastNote.scrollToVisible(lastNote.bounds)
        XCTAssertGreaterThan(scroller.contentView.bounds.minY, 0)
        try selectTopic(HelpField.codes.rawValue)
        XCTAssertEqual(scroller.contentView.bounds.minY, 0, accuracy: 1)
        try button("新增站点", in: list).performClick(nil)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let root = try XCTUnwrap(sheet.contentView)
        let address = try XCTUnwrap(view(root) { (f: NSTextField) in f.accessibilityLabel() == "HTTPS 地址" })
        let input = "https://example.com/status"
        address.stringValue = input
        XCTAssertEqual(address.toolTip, HelpField.address.help.tip)
        XCTAssertEqual(address.accessibilityHelp(), address.toolTip)
        try button("配置说明", in: root).performClick(nil)
        XCTAssertEqual(visibleHelp(), [help])
        XCTAssertTrue((help as? NSPanel)?.worksWhenModal == true)
        sheet.makeKeyAndOrderFront(nil)
        XCTAssertTrue(sheet.makeFirstResponder(address))
        let fieldEditor = try XCTUnwrap(address.currentEditor())
        fieldEditor.insertText("/ready")
        let draft = address.stringValue
        XCTAssertTrue(draft.contains("/ready"))
        XCTAssertTrue(help.isVisible)
        try button("配置说明", in: root).performClick(nil)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: help.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(help.performKeyEquivalent(with: escape))
        XCTAssertTrue(visibleHelp().isEmpty)
        XCTAssertTrue(window.attachedSheet === sheet)
        XCTAssertEqual(address.stringValue, draft)
        if NSApp.isActive { try await waitUntil { sheet.isKeyWindow } }
        // A background XCTest host can exercise the field editor without becoming the system key window.
        XCTAssertTrue(sheet.firstResponder === fieldEditor)
        fieldEditor.insertText("2")
        XCTAssertTrue(address.stringValue.hasSuffix("2"))
        try button("取消", in: root).performClick(nil)
        try await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(try XCTUnwrap(view(list) { (_: NSTableView) in true }).numberOfRows, 0)
    }

    @MainActor
    func testNativeGetStopsAtHeadersAndReusesBodylessConnections() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let server = LoopbackServer()
        listener.newConnectionHandler = { peer in
            MainActor.assumeIsolated {
                server.peers.append(peer)
                peer.start(queue: .main)
                server.read(peer)
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel(); server.peers.forEach { $0.cancel() } }
        try await waitUntil { listener.state == .ready && (listener.port?.rawValue ?? 0) > 0 }
        let base = "http://127.0.0.1:\(try XCTUnwrap(listener.port).rawValue)"
        var site = ProbeSite(id: "local", name: "Local", url: URL(string: base + "/empty")!, enabled: true, method: .get)
        site.fresh.enabled = false
        let clock = NetworkDelay()
        let monitor = ConnectivityMonitor(sites: [site], now: { clock.time }, automaticTimer: false) {}
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil { monitor.state.rows[0].dailyCount.completed == 1 }
        clock.time = 2
        monitor.pump()
        try await waitUntil { monitor.state.rows[0].dailyCount.completed == 2 }
        XCTAssertEqual(server.peers.count, 1)
        clock.time = 60
        let usage = monitor.estimate(for: [site]).sites[site.id]
        XCTAssertEqual(usage?.daily, Double(ProbeUsage.freshBytes + ProbeUsage.reusedBytes) * 60)
        site.url = URL(string: base + "/stream")!
        monitor.apply([site])
        try await waitUntil { monitor.state.rows[0].percentages == "100/—" }
        site.url = URL(string: base + "/redirect")!
        monitor.apply([site])
        try await waitUntil { monitor.state.rows[0].daily == .wrongStatus(302) }
        XCTAssertEqual(server.paths, ["/empty", "/empty", "/stream", "/redirect"])
    }

    func testStoredSiteSettingsAndValidation() throws {
        let name = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SiteSettings(defaults: defaults)
        XCTAssertEqual(settings.load(), ProbeSite.builtIns)
        var sites = ProbeSite.builtIns
        sites[0].enabled = false
        let custom = try ProbeSite.custom(name: " ", address: " https://example.com/status ")
        XCTAssertEqual(custom.name, "example.com")
        try settings.save(sites + [custom])
        XCTAssertEqual(SiteSettings(defaults: defaults).load(), sites + [custom])
        XCTAssertEqual(settings.load().last?.statusCodes.text, "")
        sites[1].fresh = .init(enabled: false, interval: 9, warning: 3, cutoff: 15, capacity: 4)
        var exact = custom
        exact.method = .get
        exact.daily.capacity = 8
        exact.statusCodes = try StatusCodes("2XX, 405")
        try settings.save(sites + [exact])
        XCTAssertEqual(settings.load(), sites + [exact])
        XCTAssertTrue(settings.probingEnabled)
        settings.probingEnabled = false
        XCTAssertFalse(SiteSettings(defaults: defaults).probingEnabled)
        let legacy = Data(#"[{"id":"old","name":"Codex","url":"https://example.com/","enabled":true,"expectedStatusCode":405}]"#.utf8)
        defaults.set(legacy, forKey: "NetRate.ProbeSites.v1")
        XCTAssertEqual(Array(settings.load().dropLast()), ProbeSite.builtIns)
        XCTAssertEqual(settings.load().last?.statusCodes.text, "405")
        XCTAssertFalse(settings.load().last!.accepts(statusCode: 200))
        XCTAssertEqual(settings.load().last?.method, .head)
        XCTAssertEqual(settings.load().last?.fresh, ProbeLane.fresh.defaults)
        XCTAssertEqual(settings.load().first?.method, .get)
        XCTAssertTrue(ProbeLane.daily.defaults.capacityHint?.contains("3 个名额") == true)
        XCTAssertNil(ProbeLane.fresh.defaults.capacityHint)
        exact.daily.warning = 9
        XCTAssertThrowsError(try settings.save([exact]))
        exact.daily.warning = 0
        XCTAssertThrowsError(try settings.save([exact]))
        exact.daily = ProbeLane.daily.defaults
        exact.daily.enabled = false
        exact.fresh.enabled = false
        XCTAssertThrowsError(try settings.save([exact]))
        exact.enabled = false
        try settings.save([exact])
        XCTAssertEqual(settings.load().last, exact)
        let mixed = try StatusCodes(" 2XX， 204, 405, 405 ")
        XCTAssertEqual(mixed.text, "2xx, 405")
        for code in [200, 204, 299, 405] { XCTAssertTrue(mixed.accepts(code)) }
        for code in [301, 403, 500] { XCTAssertFalse(mixed.accepts(code)) }
        for invalid in ["199", "600", "201,", "2xy", "1xx", "4x5", "200-300"] {
            XCTAssertThrowsError(try StatusCodes(invalid))
        }
        for invalid in ["http://example.com", "https://", "https://user:secret@example.com", "https://example.com/#section"] {
            XCTAssertThrowsError(try ProbeSite.custom(name: "", address: invalid))
        }
    }

    func testNativeReaderAndMalformedInput() throws {
        var reader = InterfaceReader()
        let sample = try XCTUnwrap(reader.sample())
        XCTAssertTrue(sample.links.keys.contains { $0.name == "lo0" })
        XCTAssertTrue(sample.links.keys.contains { $0.isExternal })
        for invalid: [UInt8] in [[0], [0,0,5,18], [100,0,5,18]] {
            invalid.withUnsafeBytes { XCTAssertNil(InterfaceReader.decode($0)) }
        }
    }
}
