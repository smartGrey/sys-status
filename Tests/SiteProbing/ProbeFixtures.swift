import AppKit
import Synchronization
import XCTest
@testable import StatusBarCore

extension ProbeSite {
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

func legacySiteData(_ sites: [ProbeSite]) throws -> Data {
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
class ProbeProtocol: URLProtocol, @unchecked Sendable {
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

final class FreshProtocol: ProbeProtocol, @unchecked Sendable {}

@MainActor
final class NetworkDelay {
    var completions: [CheckedContinuation<Void, Never>] = []
    var time: TimeInterval = 0

    func wait() async {
        await withCheckedContinuation { completions.append($0) }
    }

    func releaseFirst() { completions.removeFirst().resume() }
}

@MainActor
final class ProbeHarness {
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
