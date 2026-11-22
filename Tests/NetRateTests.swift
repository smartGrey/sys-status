import AppKit
import Network
import Security
import Synchronization
import XCTest

private extension ProbeSite {
    // Transport fixtures specify exact schedules independently of the product's built-in catalogue.
    var daily: ProbeParameters {
        get { self[.daily] }
        set { self[strength: .daily] = LaneStrength(migrating: newValue, lane: .daily) }
    }
    var fresh: ProbeParameters {
        get { self[.fresh] }
        set { self[strength: .fresh] = LaneStrength(migrating: newValue, lane: .fresh) }
    }
    static var legacyGoogle: ProbeSite {
        var site = builtIns[0]
        site.daily = ProbeLane.daily.legacyDefaults
        return site
    }
}

private func legacySiteData(_ sites: [ProbeSite]) throws -> Data {
    let objects: [[String: Any]] = try sites.map { site in
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(site)) as? [String: Any])
        for lane in ProbeLane.allCases {
            record[lane == .daily ? "daily" : "fresh"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(site[lane]))
        }
        return record
    }
    return try JSONSerialization.data(withJSONObject: objects)
}

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

    init(sites: [ProbeSite] = [ProbeSite.legacyGoogle]) {
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
    func testSleepSwitchFollowsSystemAndSerializesWrites() async throws {
        var actual: Bool? = false
        var requests: [Bool] = []
        var authorize: CheckedContinuation<Void, Error>?
        var failures: [String] = []
        let control = SystemSleepMenu(read: { actual }, write: { requested in
            requests.append(requested)
            try await withCheckedThrowingContinuation { authorize = $0 }
        }, report: { failures.append($0) })
        XCTAssertEqual(control.item.state, .off)
        control.toggle()
        control.refresh()
        control.toggle()
        XCTAssertFalse(control.item.isEnabled)
        try await waitUntil { authorize != nil }
        XCTAssertEqual(requests, [true])
        authorize?.resume()
        authorize = nil
        // A successful command can return before the kernel has applied it.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(control.item.isEnabled)
        actual = true
        try await waitUntil { control.item.isEnabled }
        XCTAssertEqual(control.item.state, .on)

        control.toggle()
        try await waitUntil { authorize != nil }
        authorize?.resume(throwing: CancellationError())
        authorize = nil
        try await waitUntil { control.item.isEnabled }
        XCTAssertEqual(control.item.state, .on)
        XCTAssertTrue(failures.isEmpty)
        control.toggle()
        try await waitUntil { authorize != nil }
        actual = false
        authorize?.resume()
        try await waitUntil { control.item.isEnabled }
        XCTAssertEqual(control.item.state, .off)
        XCTAssertEqual(requests, [true, false, false])

        actual = true
        control.toggle() // The action shown in the open menu has already taken effect externally.
        XCTAssertEqual(control.item.state, .on)
        XCTAssertTrue(control.item.isEnabled)
        actual = nil
        control.refresh()
        XCTAssertEqual(control.item.state, .mixed)
        XCTAssertTrue(control.item.title.contains("状态待确认"))
        XCTAssertFalse(control.item.isEnabled)
        control.toggle()
        actual = false
        control.refresh()
        XCTAssertTrue(control.item.isEnabled)
        XCTAssertEqual(control.item.state, .off)
        XCTAssertEqual(requests.count, 3)
    }

    @MainActor
    func testSleepSwitchReportsFailedWritesAndReadsBackActualState() async throws {
        var system: Bool? = true
        var reports: [String] = []
        var commandFails = true
        let control = SystemSleepMenu(read: { system }, write: { _ in
            if commandFails { throw CocoaError(.fileWriteNoPermission) }
        }, report: { reports.append($0) })
        control.toggle()
        try await waitUntil { reports.count == 1 }
        XCTAssertEqual(control.item.state, .on)
        commandFails = false
        control.toggle()
        try await waitUntil { reports.count == 2 }
        XCTAssertEqual(control.item.state, .on)
        system = false
        control.refresh()
        XCTAssertEqual(control.item.state, .off)
    }

    func testSleepServiceRequirementsCompile() {
        for identifier in [SleepService.appIdentifier, SleepService.label] {
            let source = SleepService.signingRequirement(for: identifier, team: "ABCDEFGHIJ")
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(source as CFString, [], &requirement), errSecSuccess)
            XCTAssertNotNil(requirement)
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
        h.advance(8)
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

    private func configurationDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "NetRateTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor
    func testSiteWindowStagesChangesAndProtectsBuiltIns() throws {
        let custom = try ProbeSite.custom(name: "Example", address: "https://example.com/status")
        let sites = ProbeSite.builtIns + [custom]
        for shouldSave in [false, true] {
            var commits: [[ProbeSite]] = []
            var closed = false
            let controller = SiteSettingsWindow(sites: sites, probingEnabled: true, didClose: { closed = true }) {
                commits.append($0)
            }
            let root = try XCTUnwrap(controller.window?.contentView)
            root.layoutSubtreeIfNeeded()
            func button(_ title: String) throws -> NSButton { try XCTUnwrap(view(root) { (b: NSButton) in b.title == title }) }
            let table = try XCTUnwrap(view(root) { (_: NSTableView) in true })
            let remove = try button("删除站点")
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            XCTAssertFalse(remove.isEnabled)
            table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            remove.performClick(nil)
            XCTAssertEqual(table.numberOfRows, 2)
            try button(shouldSave ? "保存" : "取消").performClick(nil)
            XCTAssertTrue(closed)
            XCTAssertEqual(commits, shouldSave ? [ProbeSite.builtIns] : [])
        }
    }

    @MainActor
    func testApplyKeepsWindowOpenAndOnlyLaterEditsAreCancelled() throws {
        let custom = try ProbeSite.custom(name: "Example", address: "https://example.com/status")
        let sites = ProbeSite.builtIns + [custom]
        let domain = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let url = try configurationDirectory().appending(path: "config.json")
        let store = ProbeConfigurationStore(url: url, defaults: defaults)
        try store.loadOnLaunch()
        try store.save(.init(probingEnabled: false, sites: sites))
        var closed = false
        let controller = SiteSettingsWindow(sites: sites, probingEnabled: false, didClose: { closed = true }) {
            try store.save(.init(probingEnabled: false, sites: $0))
        }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(window.contentMinSize)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        func button(_ label: String, in area: NSView) throws -> NSButton {
            try XCTUnwrap(view(area) { (button: NSButton) in button.title == label || button.accessibilityLabel() == label })
        }
        let table = try XCTUnwrap(view(root) { (_: NSTableView) in true })
        let row = try XCTUnwrap(table.rowView(atRow: 2, makeIfNecessary: true))
        try button("展开或折叠Example", in: row).performClick(nil)
        let nameCell = try XCTUnwrap(table.view(atColumn: 0, row: 2, makeIfNecessary: true))
        let name = try XCTUnwrap(view(nameCell) { (field: NSTextField) in field.accessibilityLabel() == "名称" })
        func typeName(_ value: String) {
            name.stringValue = value
            name.delegate?.controlTextDidChange?(.init(name: NSControl.textDidChangeNotification, object: name))
        }
        let apply = try button("应用", in: root)
        XCTAssertFalse(apply.isEnabled)
        typeName(" Applied ")
        XCTAssertTrue(apply.isEnabled)
        apply.performClick(nil)
        XCTAssertEqual(try store.read().configuration.sites.last?.name, "Applied")
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(closed)
        XCTAssertFalse(apply.isEnabled)
        XCTAssertEqual(table.numberOfRows, 4)
        XCTAssertEqual(table.selectedRow, 2)
        typeName("Draft")
        XCTAssertTrue(apply.isEnabled)
        try button("取消", in: root).performClick(nil)
        XCTAssertTrue(closed)
        XCTAssertEqual(try store.read().configuration.sites.last?.name, "Applied")
    }

    @MainActor
    func testSiteWindowSavesHoverOrderAndKeepsProbeHistory() async throws {
        let custom = try ProbeSite.custom(name: "Example", address: "https://example.com/status", enabled: false)
        let sites = ProbeSite.builtIns + [custom]
        let expected = [custom, sites[1], sites[0]]
        let domain = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let url = try configurationDirectory().appending(path: "config.json")
        let settings = ProbeConfigurationStore(url: url, defaults: defaults)
        try settings.loadOnLaunch()
        try settings.save(.init(probingEnabled: true, sites: sites))
        let h = ProbeHarness(sites: sites)
        defer { h.stop() }
        try await waitUntil { h.daily.count == 2 && h.fresh.count == 2 }
        for probe in h.daily { probe.reply(204) }
        try await waitUntil { h.monitor.state.rows.prefix(2).allSatisfy { $0.dailyCount.successes == 1 } }
        let originalRows = h.monitor.state.rows
        let originalSessions = h.sessions

        func editOrder(save: Bool) throws {
            let controller = SiteSettingsWindow(sites: try settings.read().configuration.sites,
                                                probingEnabled: true) { updated in
                let configuration = ProbeConfiguration(probingEnabled: true, sites: updated)
                try settings.save(configuration)
                h.monitor.apply(configuration)
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
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
            XCTAssertNotNil(view(cell) { (label: NSTextField) in label.stringValue == custom.name })
            XCTAssertEqual(try settings.read().configuration.sites, sites)
            XCTAssertEqual(h.monitor.state.rows, originalRows)
            let done = try XCTUnwrap(view(content) { (button: NSButton) in button.title == (save ? "保存" : "取消") })
            done.performClick(nil)
        }

        try editOrder(save: false)
        XCTAssertEqual(try settings.read().configuration.sites, sites)
        XCTAssertEqual(h.monitor.state.rows, originalRows)
        try editOrder(save: true)
        XCTAssertEqual(try ProbeConfigurationStore(url: url, defaults: defaults).read().configuration.sites, expected)
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
    func testMenuControlsStrengthWhilePausedAndProtectsLastLane() throws {
        var site = try ProbeSite.custom(name: "Example", address: "https://example.com", enabled: false)
        site[strength: .daily].enabled = false
        site[strength: .fresh].enabled = false
        site[strength: .fresh].personal = [ProbeStrength(id: "work", name: "办公", values: ProbeLane.fresh.strengths[1].values)]
        let selector = NSSelectorFromString("choose:")
        func command(_ item: NSMenuItem) throws -> SiteProbeCommand { try XCTUnwrap(item.representedObject as? SiteProbeCommand) }
        let parent = SiteProbeCommand.menuItem(for: site, target: self, action: selector)
        let children = try XCTUnwrap(parent.submenu)
        XCTAssertEqual(parent.state, .off)
        XCTAssertFalse(try XCTUnwrap(children.item(withTitle: "启用此站点")).isEnabled)
        XCTAssertFalse(children.items.contains(where: \.hasSubmenu))
        let initiallyChecked = children.items.filter { $0.state == .on }
        XCTAssertEqual(initiallyChecked.map(\.title), ["停止探测", "停止探测"])
        let previous = site
        try command(XCTUnwrap(initiallyChecked.first)).apply(to: &site)
        XCTAssertEqual(site, previous)
        XCTAssertNotNil(children.items.first { $0.title.hasPrefix("办公 · 10 秒") })
        let balanced = try XCTUnwrap(children.items.first { $0.title.hasPrefix("均衡 · 10 秒") })
        XCTAssertTrue(balanced.title.contains("20.2 MB"))
        try command(balanced).apply(to: &site)
        XCTAssertTrue(site.fresh.enabled)
        XCTAssertFalse(site.enabled)
        try SiteProbeCommand(siteID: site.id, operation: .toggleSite).apply(to: &site)
        XCTAssertTrue(site.enabled)
        XCTAssertThrowsError(try SiteProbeCommand(siteID: site.id, operation: .disable(.fresh)).apply(to: &site))
        let checked = SiteProbeCommand.menuItem(for: site, target: self, action: selector)
        XCTAssertEqual(checked.state, .on)
        let lastStop = try XCTUnwrap(checked.submenu?.items.first { $0.accessibilityLabel() == "停止本站的新建探测" })
        XCTAssertFalse(lastStop.isEnabled)
        XCTAssertEqual(lastStop.state, .off)
        XCTAssertEqual(lastStop.accessibilityLabel(), "停止本站的新建探测")
        site[strength: .daily].enabled = true
        let both = SiteProbeCommand.menuItem(for: site, target: self, action: selector)
        let stops = try XCTUnwrap(both.submenu).items.filter { $0.title == "停止探测" }
        XCTAssertEqual(stops.count, 2)
        for (lane, stop) in zip(ProbeLane.allCases, stops) {
            var copy = site
            XCTAssertTrue(stop.isEnabled)
            XCTAssertEqual(stop.state, .off)
            XCTAssertTrue(try XCTUnwrap(stop.toolTip).contains(lane.title))
            XCTAssertEqual(stop.accessibilityLabel(), "停止本站的" + lane.title + "探测")
            try command(stop).apply(to: &copy)
            XCTAssertFalse(copy[strength: lane].enabled)
            XCTAssertTrue(copy[strength: lane == .daily ? .fresh : .daily].enabled)
            XCTAssertTrue(copy.enabled)
            let refreshed = SiteProbeCommand.menuItem(for: copy, target: self, action: selector)
            let stopped = try XCTUnwrap(refreshed.submenu?.items.first { $0.accessibilityLabel() == stop.accessibilityLabel() })
            XCTAssertEqual(stopped.state, .on)
        }
        XCTAssertEqual(checked.submenu?.items.first { $0.title == balanced.title }?.state, .on)
    }

    @MainActor
    func testConfigurationWindowReloadProtectsUnsavedDraft() async throws {
        let domain = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let url = try configurationDirectory().appending(path: "config.json")
        let store = ProbeConfigurationStore(url: url, defaults: defaults)
        try store.loadOnLaunch()
        let initial = try XCTUnwrap(store.configuration)
        let monitor = ConnectivityMonitor(sites: initial.sites, automaticTimer: false) {}
        let file = SiteSettingsWindow.ConfigurationFile(store: store, startupError: nil) {
            if let configuration = store.configuration { monitor.apply(configuration) }
        }
        let controller = SiteSettingsWindow(sites: initial.sites, probingEnabled: true, configurationFile: file) { sites in
            try store.save(.init(probingEnabled: true, sites: sites))
        }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(window.contentMinSize)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let fileMenu = try XCTUnwrap(view(content) { (popup: NSPopUpButton) in popup.title == "配置文件" })
        XCTAssertLessThanOrEqual(fileMenu.frame.width, content.bounds.width)
        let menu = try XCTUnwrap(fileMenu.menu)
        XCTAssertNotNil(menu.item(withTitle: "在 Finder 中显示"))
        let reload = try XCTUnwrap(menu.item(withTitle: "重新读取配置"))
        let table = try XCTUnwrap(view(content) { (_: NSTableView) in true })
        let add = try XCTUnwrap(view(content) { (b: NSButton) in b.title == "新增站点" })
        func alertButton(_ title: String) throws -> NSButton {
            let root = try XCTUnwrap(window.attachedSheet?.contentView)
            return try XCTUnwrap(view(root) { (button: NSButton) in button.title == title })
        }
        add.performClick(nil)
        XCTAssertEqual(table.numberOfRows, 3)
        var updated = initial
        updated.probingEnabled = false
        updated.sites[0].fresh.interval = 10
        updated.sites.append(try ProbeSite.custom(name: "Cursor", address: "https://api2.cursor.sh/"))
        let external = try JSONEncoder().encode(updated)
        try external.write(to: url, options: .atomic)
        XCTAssertEqual(monitor.state.rows.count, 2)

        menu.performActionForItem(at: menu.index(of: reload))
        try alertButton("继续编辑").performClick(nil)
        try await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(store.configuration, initial)
        XCTAssertEqual(try Data(contentsOf: url), external)

        menu.performActionForItem(at: menu.index(of: reload))
        try alertButton("丢弃并重新读取").performClick(nil)
        try await waitUntil { window.attachedSheet == nil && store.configuration == updated }
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(monitor.state.rows.map(\.name), ["Google", "Cloudflare", "Cursor"])
        XCTAssertEqual(monitor.state.rows.first?.freshSettings.interval, 10)
        XCTAssertFalse(monitor.state.enabled)
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    @MainActor
    func testInlineEditorsKeepInputsAndFollowMenuSelections() throws {
        var sites = ProbeSite.builtIns
        var personal = ProbeLane.fresh.strengths[1]
        personal = ProbeStrength(id: "personal", name: "办公", values: personal.values)
        sites[0][strength: .fresh] = LaneStrength(selectedID: personal.id, personal: [personal])
        var saved: [ProbeSite]?
        let controller = SiteSettingsWindow(sites: sites, probingEnabled: true) { saved = $0 }
        let window = try XCTUnwrap(controller.window)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(view(root) { (_: NSTableView) in true })
        func row(_ index: Int) throws -> NSView {
            try XCTUnwrap(table.rowView(atRow: index, makeIfNecessary: true))
        }
        func click(_ title: String, in root: NSView) throws {
            let button = try XCTUnwrap(view(root) { (b: NSButton) in b.title == title || b.accessibilityLabel() == title })
            button.performClick(nil)
        }
        XCTAssertEqual(table.numberOfColumns, 4)
        XCTAssertEqual(table.numberOfRows, 2)
        let address = try XCTUnwrap(view(try row(0)) { (f: NSTextField) in f.accessibilityLabel() == "HTTPS 地址" })
        XCTAssertFalse(address.isEditable)
        XCTAssertTrue(try XCTUnwrap(address.toolTip).contains(address.stringValue))
        try click("展开或折叠Google", in: row(0))
        try click("展开或折叠Cloudflare", in: row(2))
        XCTAssertEqual(table.numberOfRows, 4)
        let google = try XCTUnwrap(view(try row(1)) { (_: SiteEditor) in true })
        try click("管理新建探测强度", in: google)
        let field = try XCTUnwrap(view(google) { (f: NSTextField) in f.accessibilityLabel() == "新建发起间隔" })
        func type(_ value: String, into field: NSTextField) {
            field.stringValue = value
            field.delegate?.controlTextDidChange?(.init(name: NSControl.textDidChangeNotification, object: field))
        }
        type("12", into: field)
        XCTAssertNotNil(view(google) { (f: NSTextField) in f.stringValue == "16.8 MB" })
        XCTAssertNotNil(view(google) { (f: NSTextField) in f.stringValue == "个人 · 已选" })
        sites[0][strength: .fresh].selectedID = "low"
        controller.syncMenu(.init(probingEnabled: false, sites: sites))
        XCTAssertEqual(field.stringValue, "12")
        XCTAssertNotNil(view(root) { (f: NSTextField) in f.stringValue.contains("恢复探测后预计") })
        func chooseTemplate(_ title: String) throws {
            let popup = try XCTUnwrap(view(google) { (b: NSPopUpButton) in b.accessibilityLabel() == "新建新增强度" })
            let menu = try XCTUnwrap(popup.menu)
            menu.update()
            XCTAssertEqual(menu.items[1].title, "低频（当前）")
            XCTAssertEqual(menu.items.filter { $0.title.hasPrefix("低频") }.count, 1)
            let index = menu.indexOfItem(withTitle: title)
            XCTAssertGreaterThan(index, 0)
            if index > 0 { menu.performActionForItem(at: index) }
        }
        try chooseTemplate("办公")
        XCTAssertEqual(google.draft.form.personal[.fresh]?.last?.numbers.first, "12")
        let nameEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual((nameEditor.string as NSString).substring(with: nameEditor.selectedRange()), "自定义 1")
        try chooseTemplate("温和")
        XCTAssertEqual(google.draft.form.personal[.fresh]?.last?.numbers.first, "15")
        google.toggle()
        google.toggle()
        XCTAssertEqual(google.draft.form.personal[.fresh]?.first?.numbers.first, "12")
        try click("新增站点", in: root)
        XCTAssertEqual(table.numberOfRows, 5)
        try click("保存", in: root)
        XCTAssertNil(saved)
        XCTAssertNil(window.attachedSheet)
        let newAddress = try XCTUnwrap(view(try row(4)) { (f: NSTextField) in f.accessibilityLabel() == "HTTPS 地址" })
        XCTAssertTrue(newAddress.currentEditor() === window.firstResponder)
        type("https://example.com/ready", into: newAddress)
        try click("保存", in: root)
        let committed = try XCTUnwrap(saved)
        XCTAssertEqual(committed[0].fresh.interval, 30)
        XCTAssertEqual(committed[0][strength: .fresh].personal.first?.values.interval, 12)
        XCTAssertEqual(committed[0][strength: .fresh].personal.count, 3)
        XCTAssertEqual(committed[2].name, "example.com")
        XCTAssertFalse(committed[2].enabled)
        XCTAssertFalse(committed[2].daily.enabled)
        XCTAssertTrue(committed[2].fresh.enabled)
        XCTAssertEqual(committed[2][strength: .fresh].selectedID, "balanced")
    }

    @MainActor
    func testStoppedLaneCanDeleteItsPreviouslySelectedStrength() throws {
        var site = try ProbeSite.custom(name: "Example", address: "https://example.com/")
        let original = ProbeStrength(id: "original", name: "原有配置", values: ProbeLane.daily.strengths[0].values)
        site[strength: .daily] = LaneStrength(enabled: false, selectedID: original.id, personal: [original])
        var config = ProbeConfiguration(probingEnabled: false, sites: [site] + ProbeSite.builtIns)
        var saved: [ProbeSite]?
        let controller = SiteSettingsWindow(sites: config.sites, probingEnabled: config.probingEnabled) { saved = $0 }
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let root = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(view(root) { (_: NSTableView) in true })
        root.layoutSubtreeIfNeeded()
        func button(_ title: String, in area: NSView) throws -> NSButton {
            try XCTUnwrap(view(area) { (button: NSButton) in button.title == title || button.accessibilityLabel() == title })
        }
        let siteRow = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true))
        try button("展开或折叠Example", in: siteRow).performClick(nil)
        let detail = try XCTUnwrap(table.rowView(atRow: 1, makeIfNecessary: true))
        let editor = try XCTUnwrap(view(detail) { (_: SiteEditor) in true })
        try button("管理复用探测强度", in: editor).performClick(nil)
        XCTAssertTrue(try button("删除", in: editor).isEnabled)
        try button("删除", in: editor).performClick(nil)

        controller.syncMenu(config)
        XCTAssertTrue(editor.draft.form.personal[.daily]?.isEmpty == true)
        config.sites[0][strength: .daily].enabled = true
        controller.syncMenu(config)
        XCTAssertEqual(editor.draft.form.personal[.daily]?.first?.id, original.id)
        try button("管理复用探测强度", in: editor).performClick(nil)
        XCTAssertFalse(try button("删除", in: editor).isEnabled)

        config.sites[0][strength: .daily].enabled = false
        controller.syncMenu(config)
        try button("删除", in: editor).performClick(nil)
        try button("保存", in: root).performClick(nil)
        config.sites = try XCTUnwrap(saved)
        let reopened = try ProbeConfiguration.decode(JSONEncoder().encode(config))
        let reuse = reopened.sites[0][strength: .daily]
        XCTAssertFalse(reuse.enabled)
        XCTAssertTrue(reuse.personal.isEmpty)
        XCTAssertEqual(reuse.selectedID, "balanced")
        XCTAssertEqual(reopened.sites[0][strength: .fresh], site[strength: .fresh])
    }

    @MainActor
    func testCompactGridAlignsValuesAndRevealsInvalidFieldAfterReordering() throws {
        var site = try ProbeSite.custom(name: "Work", address: "https://example.com/long/path")
        site[strength: .daily].enabled = false
        site[strength: .daily].personal = [ProbeStrength(id: "night", name: "夜间", values: ProbeLane.daily.strengths[1].values)]
        var saved: [ProbeSite]?
        let controller = SiteSettingsWindow(sites: [ProbeSite.builtIns[0], site], probingEnabled: true) { saved = $0 }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(window.contentMinSize)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(view(root) { (_: NSTableView) in true })
        func row(_ index: Int) throws -> NSView { try XCTUnwrap(table.rowView(atRow: index, makeIfNecessary: true)) }
        func button(_ title: String, in area: NSView) throws -> NSButton {
            try XCTUnwrap(view(area) { (button: NSButton) in button.title == title || button.accessibilityLabel() == title })
        }
        func label(_ title: String, in area: NSView) throws -> NSTextField {
            try XCTUnwrap(view(area) { (field: NSTextField) in field.accessibilityLabel() == title })
        }
        func type(_ value: String, into field: NSTextField) {
            field.stringValue = value
            field.delegate?.controlTextDidChange?(.init(name: NSControl.textDidChangeNotification, object: field))
        }
        try button("展开或折叠Work", in: row(1)).performClick(nil)
        try button("管理复用探测强度", in: row(2)).performClick(nil)
        let detail = try row(2)
        root.layoutSubtreeIfNeeded()
        XCTAssertNil(view(detail) { (field: NSTextField) in field.stringValue == "方式" })
        for title in ["复用", "新建"] {
            XCTAssertNotNil(view(detail) { (field: NSTextField) in field.stringValue == title })
        }
        XCTAssertEqual(try label("复用当前探测强度", in: detail).stringValue, "已停止 · 快速")
        XCTAssertEqual(try label("复用预计 8 小时请求数", in: detail).stringValue, "0")
        XCTAssertEqual(try label("复用预计 8 小时流量", in: detail).stringValue, "0 KB")
        let current = try label("复用当前截止时间", in: detail)
        let edit = try label("复用截止时间", in: detail)
        func textEdge(_ field: NSTextField) throws -> CGFloat {
            field.convert(try XCTUnwrap(field.cell).titleRect(forBounds: field.bounds), to: root).maxX
        }
        XCTAssertEqual(try textEdge(current), try textEdge(edit), accuracy: 1)
        let add = try button("复用新增强度", in: detail)
        XCTAssertGreaterThanOrEqual(add.bounds.width, add.intrinsicContentSize.width)
        XCTAssertLessThanOrEqual(add.convert(add.bounds, to: table).maxX, table.bounds.maxX)
        try button("上移", in: root).performClick(nil)
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertEqual(table.numberOfRows, 3)
        type("2", into: try label("复用截止时间", in: row(1)))
        try button("展开或折叠Work", in: row(0)).performClick(nil)
        XCTAssertEqual(table.numberOfRows, 2)
        try button("保存", in: root).performClick(nil)
        XCTAssertNil(saved)
        XCTAssertEqual(table.numberOfRows, 3)
        let invalid = try label("复用截止时间", in: row(1))
        XCTAssertEqual(invalid.stringValue, "2")
        XCTAssertTrue(invalid.currentEditor() === window.firstResponder)
        type("8", into: invalid)
        let name = try label("复用个人强度名称", in: row(1))
        type("均衡", into: name)
        try button("保存", in: root).performClick(nil)
        XCTAssertNil(saved)
        let duplicate = try label("复用个人强度名称", in: row(1))
        XCTAssertTrue(duplicate.currentEditor() === window.firstResponder)
        type("晚间", into: duplicate)
        try button("保存", in: root).performClick(nil)
        XCTAssertEqual(saved?.first?[strength: .daily].personal.first?.name, "晚间")
        XCTAssertEqual(saved?.first?.id, site.id)
    }

    @MainActor
    func testModelessHelpSharesTopicsWithFieldTipsAndReturnsToDraft() async throws {
        let controller = SiteSettingsWindow(sites: [], probingEnabled: true) { _ in }
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
        XCTAssertNil(window.attachedSheet)
        let root = list
        let address = try XCTUnwrap(view(root) { (f: NSTextField) in f.accessibilityLabel() == "HTTPS 地址" })
        let input = "https://example.com/status"
        address.stringValue = input
        XCTAssertEqual(address.toolTip, HelpField.address.help.tip)
        XCTAssertEqual(address.accessibilityHelp(), address.toolTip)
        try button("配置说明", in: root).performClick(nil)
        XCTAssertEqual(visibleHelp(), [help])
        XCTAssertTrue((help as? NSPanel)?.worksWhenModal == true)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(address))
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
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(address.stringValue, draft)
        if NSApp.isActive { try await waitUntil { window.isKeyWindow } }
        // A background XCTest host can exercise the field editor without becoming the system key window.
        XCTAssertTrue(window.firstResponder === fieldEditor)
        fieldEditor.insertText("2")
        XCTAssertTrue(address.stringValue.hasSuffix("2"))
        try button("取消", in: root).performClick(nil)
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
        let settings = LegacySiteSettings(defaults: defaults)
        func writeLegacy(_ sites: [ProbeSite]) throws {
            defaults.set(try legacySiteData(sites), forKey: "NetRate.ProbeSites.v1")
        }
        XCTAssertEqual(settings.load(), ProbeSite.builtIns)
        var sites = ProbeSite.builtIns
        sites[0].enabled = false
        let custom = try ProbeSite.custom(name: " ", address: " https://example.com/status ")
        XCTAssertEqual(custom.name, "example.com")
        try writeLegacy(sites + [custom])
        XCTAssertEqual(settings.load(), sites + [custom])
        XCTAssertEqual(settings.load().last?.statusCodes.text, "")
        sites[1].fresh = .init(enabled: false, interval: 9, warning: 3, cutoff: 15, capacity: 4)
        var exact = custom
        exact.method = .get
        exact.daily.capacity = 8
        exact.statusCodes = try StatusCodes("2XX, 405")
        try writeLegacy(sites + [exact])
        XCTAssertEqual(settings.load(), sites + [exact])
        XCTAssertTrue(settings.probingEnabled)
        defaults.set(false, forKey: "NetRate.ProbingEnabled")
        XCTAssertFalse(settings.probingEnabled)
        let legacy = Data(#"[{"id":"old","name":"Codex","url":"https://example.com/","enabled":true,"expectedStatusCode":405}]"#.utf8)
        defaults.set(legacy, forKey: "NetRate.ProbeSites.v1")
        XCTAssertEqual(Array(settings.load().dropLast()).map(\.daily), Array(repeating: ProbeLane.daily.legacyDefaults, count: 2))
        XCTAssertEqual(settings.load().last?.statusCodes.text, "405")
        XCTAssertFalse(settings.load().last!.accepts(statusCode: 200))
        XCTAssertEqual(settings.load().last?.method, .head)
        XCTAssertEqual(settings.load().last?.fresh, ProbeLane.fresh.defaults)
        XCTAssertEqual(settings.load().first?.method, .get)
        XCTAssertTrue(ProbeLane.daily.legacyDefaults.capacityHint?.contains("3 个名额") == true)
        XCTAssertNil(ProbeLane.fresh.defaults.capacityHint)
        exact.daily.warning = 9
        XCTAssertThrowsError(try exact.validate())
        exact.daily.warning = 0
        XCTAssertThrowsError(try exact.validate())
        exact.daily = ProbeLane.daily.defaults
        exact.daily.enabled = false
        exact.fresh.enabled = false
        XCTAssertThrowsError(try exact.validate())
        exact.enabled = false
        try writeLegacy([exact])
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

    @MainActor
    func testConfigurationFileMigratesOnceAndDoesNotOverwriteInvalidFiles() throws {
        let domain = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var github = try ProbeSite.custom(name: "GitHub", address: "https://github.com/", statusCodes: StatusCodes("200"))
        github.daily.enabled = false
        github.fresh = .init(interval: 10, warning: 5, cutoff: 8, capacity: 1)
        var google = ProbeSite.builtIns[0]
        google.enabled = false
        let sites = [github, ProbeSite.builtIns[1], google]
        let legacy = try legacySiteData(sites)
        defaults.set(legacy, forKey: "NetRate.ProbeSites.v1")
        defaults.set(false, forKey: "NetRate.ProbingEnabled")
        let url = try configurationDirectory().appending(path: "NetRate/config.json")
        let store = ProbeConfigurationStore(url: url, defaults: defaults)
        try store.loadOnLaunch()
        let expected = ProbeConfiguration(probingEnabled: false, sites: sites)
        XCTAssertEqual(store.configuration, expected)
        let migrated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(migrated.contains("\"schemaVersion\" : 2"))
        XCTAssertTrue(migrated.contains("https://github.com/"))

        let reopened = ProbeConfigurationStore(url: url, defaults: defaults)
        try reopened.loadOnLaunch()
        XCTAssertEqual(reopened.configuration, expected)
        XCTAssertEqual(defaults.data(forKey: "NetRate.ProbeSites.v1"), legacy)
        XCTAssertFalse(defaults.bool(forKey: "NetRate.ProbingEnabled"))

        let invalid = Data(#"{"schemaVersion":99}"#.utf8)
        try invalid.write(to: url, options: .atomic)
        let startup = ProbeConfigurationStore(url: url, defaults: defaults)
        XCTAssertThrowsError(try startup.loadOnLaunch()) { XCTAssertEqual($0.localizedDescription, "当前版本不支持配置文件格式 99。") }
        XCTAssertNil(startup.configuration)
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try startup.loadOnLaunch())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testVersionOneIsReadWithoutOverwritingUntilNextSave() throws {
        var github = try ProbeSite.custom(name: "GitHub", address: "https://github.com/")
        github.daily = .init(enabled: false, interval: 2, warning: 5, cutoff: 5, capacity: 1)
        github.fresh = .init(interval: 10, warning: 5, cutoff: 8, capacity: 1)
        var cursor = try ProbeSite.custom(name: "Cursor", address: "https://example.com/")
        cursor.fresh = .init(interval: 10, warning: 5, cutoff: 10, capacity: 1)
        let sites = [github, ProbeSite.builtIns[1], cursor, ProbeSite.legacyGoogle]
        let v1 = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "probingEnabled": false,
            "sites": JSONSerialization.jsonObject(with: legacySiteData(sites))
        ])
        let url = try configurationDirectory().appending(path: "config.json")
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try v1.write(to: url)
        let store = ProbeConfigurationStore(url: url, defaults: defaults)
        try store.loadOnLaunch()
        var config = try XCTUnwrap(store.configuration)
        XCTAssertEqual(config.sites, sites)
        XCTAssertEqual(try Data(contentsOf: url), v1)
        XCTAssertEqual(config.sites[0][strength: .daily].selectedID, "original")
        XCTAssertFalse(config.sites[0].daily.enabled)
        XCTAssertEqual(config.sites[0][strength: .fresh].personal.first?.name, "原有配置")
        XCTAssertEqual(config.sites[2][strength: .fresh].selectedID, "balanced")
        config.sites[0][strength: .fresh].selectedID = "balanced"
        try store.save(config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
        XCTAssertEqual(try store.read().configuration, config)
        XCTAssertEqual(config.sites[0][strength: .fresh].personal.first?.values.cutoff, 8)

        var invalid = config
        invalid.sites[1][strength: .fresh].selectedID = "original"
        XCTAssertThrowsError(try store.save(invalid))
        invalid = config
        invalid.sites[0][strength: .fresh].personal.append(ProbeLane.fresh.strengths[1])
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.read().configuration, config)
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
    func testConfigurationFileChecksExternalChangesAndPreservesActiveSettings() throws {
        let domain = "NetRateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let directory = try configurationDirectory()
        let url = directory.appending(path: "config.json")
        let store = ProbeConfigurationStore(url: url, defaults: defaults)
        try store.loadOnLaunch()
        let initial = try XCTUnwrap(store.configuration)
        XCTAssertEqual(initial, .init(probingEnabled: true, sites: ProbeSite.builtIns))
        var updated = initial
        updated.probingEnabled = false
        updated.sites[0].fresh.interval = 10
        let edited = try JSONEncoder().encode(updated)
        try edited.write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.save(initial))
        XCTAssertEqual(store.configuration, initial)
        XCTAssertEqual(try Data(contentsOf: url), edited)
        let candidate = try store.read()
        XCTAssertEqual(candidate.configuration, updated)
        XCTAssertEqual(store.configuration, initial)
        let stale = Data("not json".utf8)
        try stale.write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.accept(candidate))
        XCTAssertThrowsError(try store.read())
        XCTAssertEqual(store.configuration, initial)
        XCTAssertEqual(try Data(contentsOf: url), stale)
        try edited.write(to: url, options: .atomic)
        try store.accept(store.read())
        XCTAssertEqual(store.configuration, updated)
        XCTAssertEqual(try Data(contentsOf: url), edited)

        var invalid = updated
        invalid.sites[0].fresh.interval = 0
        XCTAssertThrowsError(try store.save(invalid)) { XCTAssertTrue($0.localizedDescription.contains("sites[0]")) }
        invalid.sites = [updated.sites[0], updated.sites[0]]
        XCTAssertThrowsError(try ProbeConfiguration.decode(JSONEncoder().encode(invalid)))
        invalid.sites = Array(updated.sites.dropFirst())
        XCTAssertThrowsError(try ProbeConfiguration.decode(JSONEncoder().encode(invalid)))
        invalid.sites = updated.sites
        invalid.sites[0].url = URL(string: "https://example.com/")!
        XCTAssertThrowsError(try ProbeConfiguration.decode(JSONEncoder().encode(invalid)))

        if geteuid() != 0 {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            XCTAssertThrowsError(try store.save(initial))
            XCTAssertEqual(store.configuration, updated)
            XCTAssertEqual(try Data(contentsOf: url), edited)
        }
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
