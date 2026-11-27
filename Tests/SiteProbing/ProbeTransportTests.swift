import Network
import dnssd
import XCTest
@testable import StatusBarCore

final class ProbeTransportTests: XCTestCase {
    @MainActor
    func testTCPConnectionsCloseAndPublishRefusalAndSuccess() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        var closed = 0
        listener.newConnectionHandler = { peer in
            peer.start(queue: .main)
            peer.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, ended, _ in
                MainActor.assumeIsolated {
                    XCTAssertTrue(data?.isEmpty ?? true)
                    if ended { closed += 1 }
                    peer.cancel()
                }
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel() }
        try await waitUntil { listener.state == .ready }
        let port = try XCTUnwrap(listener.port).rawValue
        var site = ProbeSite(id: "tcp", name: "NAS", endpoint: .tcp(host: "127.0.0.1", port: port), enabled: false)
        let clock = NetworkDelay()
        let monitor = ConnectivityMonitor(sites: [site], now: { clock.time }, automaticTimer: false) {}
        monitor.start()
        defer { monitor.stop() }
        clock.time = 10
        monitor.pump()
        XCTAssertEqual(monitor.state.color, .normal)
        site.enabled = true
        monitor.apply([site])
        try await waitUntil { closed == 1 && monitor.state.color == .green }
        XCTAssertEqual(monitor.state.rows[0].percentages, "—/100")
        XCTAssertEqual(monitor.state.rate, "0 B/h")
        XCTAssertTrue(monitor.state.footer.contains("HTTPS"))
        listener.cancel()
        try await waitUntil { listener.state == .cancelled }
        clock.time += 10
        monitor.pump()
        try await waitUntil { monitor.state.rows[0].fresh == .connectionRefused }
        XCTAssertEqual(monitor.state.rows[0].percentages, "—/50")
        XCTAssertEqual(monitor.state.color, .red)
        clock.time += 10
        monitor.pump()
        try await waitUntil { monitor.state.rows[0].freshCount.completed == 3 }
        site.enabled = false
        monitor.apply([site])
        XCTAssertEqual(monitor.state.color, .normal)
        XCTAssertEqual(monitor.state.rows[0].percentages, "—/—")
    }

    @MainActor
    func testTCPCutoffAndCancellationAcrossNetworkChanges() async throws {
        let clock = NetworkDelay()
        var site = ProbeSite(id: "tcp", name: "Local", endpoint: .tcp(host: "127.0.0.1", port: 445), enabled: true)
        let monitor = ConnectivityMonitor(sites: [site], now: { clock.time },
            waitForNetwork: { await clock.wait() }, automaticTimer: false) {}
        monitor.start()
        defer { monitor.stop() }
        // Advance the deadline before the main queue receives any native connection events.
        clock.time = 10
        monitor.pump()
        XCTAssertEqual(monitor.state.rows[0].fresh, .timedOut)
        XCTAssertEqual(monitor.state.rows[0].freshCount.completed, 1)
        monitor.networkDidChange()
        try await waitUntil { !clock.completions.isEmpty }
        XCTAssertEqual(monitor.state.rows[0].freshCount.completed, 0)
        site.enabled = false
        monitor.apply([site])
        clock.releaseFirst()
        await Task.yield()
        XCTAssertEqual(monitor.state.color, .normal)
        XCTAssertEqual(monitor.state.rows[0].freshCount.completed, 0)
        XCTAssertEqual(ProbeResult(tcpError: .dns(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord))), .dnsFailed)
        XCTAssertEqual(ProbeResult(tcpError: .posix(.ETIMEDOUT)), .timedOut)
        XCTAssertEqual(ProbeResult(tcpError: .posix(.ENETUNREACH)), .connectionFailed)
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
        var site = ProbeSite(id: "local", name: "Local", endpoint: .https(URL(string: base + "/empty")!), enabled: true, method: .get)
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
        site.endpoint = .https(URL(string: base + "/stream")!)
        monitor.apply([site])
        try await waitUntil { monitor.state.rows[0].percentages == "100/—" }
        site.endpoint = .https(URL(string: base + "/redirect")!)
        monitor.apply([site])
        try await waitUntil { monitor.state.rows[0].daily == .wrongStatus(302) }
        XCTAssertEqual(server.paths, ["/empty", "/empty", "/stream", "/redirect"])
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
