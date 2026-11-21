import Foundation

private protocol ProbeTask: AnyObject { func cancel() }
extension URLSessionTask: ProbeTask {}
extension HeaderTask: ProbeTask {}

@MainActor
final class ConnectivityMonitor: NSObject, URLSessionDataDelegate {
    private enum Transport {
        case urlSession(URLSession)
        case headers(HeaderSession)

        var identity: ObjectIdentifier {
            switch self {
            case .urlSession(let session): ObjectIdentifier(session)
            case .headers(let session): ObjectIdentifier(session)
            }
        }
    }

    private final class Lane {
        var result = ProbeResult.checking
        var next: TimeInterval = 0
        var issued = 0
        var evidence = 0
        var session: Transport?
        var usage: ProbeUsage
        var history = ProbeHistory()
        var active = true

        init(at time: TimeInterval) { usage = ProbeUsage(since: time) }
    }

    private final class Site {
        var settings: ProbeSite
        var daily: Lane
        var fresh: Lane

        init(_ settings: ProbeSite, at time: TimeInterval) {
            self.settings = settings
            daily = Lane(at: time)
            fresh = Lane(at: time)
        }

        subscript(_ kind: ProbeLane) -> Lane {
            get { kind == .daily ? daily : fresh }
            set { if kind == .daily { daily = newValue } else { fresh = newValue } }
        }
    }

    private final class Attempt {
        var task: (any ProbeTask)!
        let session: Transport
        let site: Site
        let kind: ProbeLane
        let lane: Lane
        let sequence: Int
        let start: TimeInterval
        let warning: TimeInterval
        let cutoff: TimeInterval
        var reused: Bool
        var warned = false
        var settled = false
        var deadline: TimeInterval { warned ? cutoff : warning }

        init(session: Transport, site: Site, kind: ProbeLane,
             at time: TimeInterval, reused: Bool) {
            self.session = session
            self.site = site
            self.kind = kind
            self.lane = site[kind]
            self.sequence = lane.issued
            self.start = time
            self.warning = time + Double(site.settings[kind].warning)
            self.cutoff = time + Double(site.settings[kind].cutoff)
            self.reused = reused
        }
    }

    private var sites: [Site]
    private var requests: [ObjectIdentifier: Attempt] = [:]
    // Retired tasks still occupy a slot until their transport acknowledges cancellation.
    private var occupied: [String: [ProbeLane: Int]] = [:]
    private let configuration: ((ProbeLane) -> URLSessionConfiguration)?
    private let now: () -> TimeInterval
    private let waitForNetwork: () async throws -> Void
    private let onChange: () -> Void
    private var networkDelay: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private var awake = false
    private(set) var enabled: Bool

    init(sites settings: [ProbeSite] = ProbeSite.builtIns, enabled: Bool = true,
         configuration: ((ProbeLane) -> URLSessionConfiguration)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         waitForNetwork: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) },
         automaticTimer: Bool = true, onChange: @escaping () -> Void) {
        self.sites = settings.map { Site($0, at: now()) }
        self.enabled = enabled
        self.configuration = configuration
        self.now = now
        self.waitForNetwork = waitForNetwork
        self.onChange = onChange
        super.init()
        if automaticTimer {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in self?.pump() }
            timer.schedule(deadline: .distantFuture)
            timer.resume()
            self.timer = timer
        }
    }

    var state: ConnectivityState {
        let time = now()
        let rows = sites.map { site in
            ConnectivityState.Row(id: site.settings.id, name: site.settings.name, enabled: site.settings.enabled,
                                  daily: site.daily.result, fresh: site.fresh.result,
                                  dailySettings: site.settings.daily, freshSettings: site.settings.fresh,
                                  dailyCount: site.daily.history.count(at: time), freshCount: site.fresh.history.count(at: time))
        }
        let bytes = enabled ? sites.reduce(0.0) { sum, site in
            let traffic = traffic(for: site.settings, live: site, at: time)
            return sum + traffic.daily + traffic.fresh
        } : 0
        return ConnectivityState(rows: rows, enabled: enabled, rate: ProbeUsage.display(bytes))
    }

    private func traffic(for draft: ProbeSite, live: Site?, at time: TimeInterval) -> SiteTraffic {
        var traffic = SiteTraffic()
        guard draft.enabled else { return traffic }
        for kind in ProbeLane.allCases where draft[kind].enabled {
            let baseline = ProbeUsage.baseline(kind, interval: draft[kind].interval)
            if enabled, let live, live.settings.enabled, draft.sharesRequest(with: live.settings),
               live.settings[kind] == draft[kind] {
                traffic[kind] = live[kind].usage.hourly(at: time, baseline: baseline)
            } else {
                traffic[kind] = baseline
            }
        }
        return traffic
    }

    func estimate(for draft: [ProbeSite]) -> ProbeEstimate {
        let existing = Dictionary(uniqueKeysWithValues: sites.map { ($0.settings.id, $0) })
        let time = now()
        var estimate = ProbeEstimate(enabled: enabled)
        for item in draft { estimate.sites[item.id] = traffic(for: item, live: existing[item.id], at: time) }
        return estimate
    }

    func start() {
        awake = true
        reset()
        pump()
    }

    func stop() {
        awake = false
        reset()
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        reset()
        pump()
    }

    private func retire(_ lane: Lane) {
        lane.active = false
        if case .urlSession(let session) = lane.session { session.invalidateAndCancel() }
        lane.session = nil
        for attempt in requests.values where attempt.lane === lane { attempt.task.cancel() }
    }

    private func reset() {
        networkDelay?.cancel()
        networkDelay = nil
        timer?.schedule(deadline: .distantFuture)
        sites = sites.map { site in
            for kind in ProbeLane.allCases { retire(site[kind]) }
            return Site(site.settings, at: now())
        }
        onChange()
    }

    func networkDidChange() {
        guard awake, enabled, sites.contains(where: { $0.settings.enabled }) else { return }
        reset()
        networkDelay = Task { [weak self] in
            guard let self else { return }
            do { try await waitForNetwork() } catch { return }
            guard !Task.isCancelled else { return }
            networkDelay = nil
            pump()
        }
    }

    func apply(_ settings: [ProbeSite]) {
        var previous = Dictionary(uniqueKeysWithValues: sites.map { ($0.settings.id, $0) })
        sites = settings.map { setting in
            guard let site = previous.removeValue(forKey: setting.id) else { return Site(setting, at: now()) }
            let resetBoth = setting.enabled != site.settings.enabled || !setting.sharesRequest(with: site.settings)
            for kind in ProbeLane.allCases where resetBoth || setting[kind] != site.settings[kind] {
                retire(site[kind])
                site[kind] = Lane(at: now())
            }
            site.settings = setting
            return site
        }
        for site in previous.values {
            for kind in ProbeLane.allCases { retire(site[kind]) }
        }
        onChange()
        pump()
    }

    // One timer covers due probes, soft warnings and hard cancellations at their actual uptime deadlines.
    func pump() {
        guard awake, enabled, networkDelay == nil else { return }
        let time = now()
        var wake = TimeInterval.infinity
        for attempt in requests.values where attempt.lane.active && !attempt.settled {
            if time >= attempt.cutoff {
                settle(.timedOut, for: attempt, at: time)
                attempt.task.cancel()
            } else if !attempt.warned && time >= attempt.warning {
                attempt.warned = true
                retireConnection(of: attempt)
                publish(.waiting, for: attempt)
                onChange()
            }
            if !attempt.settled { wake = min(wake, attempt.deadline) }
        }
        for site in sites where site.settings.enabled {
            for kind in ProbeLane.allCases where site.settings[kind].enabled {
                let capacity = site.settings[kind].capacity
                let lane = site[kind]
                guard (occupied[site.settings.id]?[kind] ?? 0) < capacity else { continue }
                if lane.next <= time {
                    let attempt = launch(site, kind: kind)
                    wake = min(wake, attempt.deadline)
                }
                if (occupied[site.settings.id]?[kind] ?? 0) < capacity { wake = min(wake, lane.next) }
            }
        }
        timer?.schedule(deadline: wake.isFinite ? .now() + max(0, wake - now()) : .distantFuture)
    }

    private func launch(_ site: Site, kind: ProbeLane) -> Attempt {
        let lane = site[kind]
        let reused = lane.session != nil
        let session: Transport
        if let existing = lane.session {
            session = existing
        } else if configuration == nil && site.settings.method == .get {
            session = .headers(HeaderSession())
        } else {
            let config = configuration?(kind) ?? .ephemeral
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpMaximumConnectionsPerHost = site.settings[kind].capacity
            config.timeoutIntervalForRequest = Double(site.settings[kind].cutoff)
            config.timeoutIntervalForResource = config.timeoutIntervalForRequest
            session = .urlSession(URLSession(configuration: config, delegate: self, delegateQueue: .main))
        }
        if kind == .daily { lane.session = session }
        let time = now()
        lane.issued += 1
        lane.next = time + Double(site.settings[kind].interval)
        let attempt = Attempt(session: session, site: site, kind: kind, at: time, reused: reused)
        switch session {
        case .headers(let headers):
            attempt.task = headers.get(site.settings.url, timeout: Double(site.settings[kind].cutoff)) {
                [weak self, weak attempt] status, reusedConnection, timedOut in
                guard let self, let attempt else { return }
                attempt.reused = reusedConnection
                let time = now()
                if status > 0 {
                    settle(status: status, for: attempt, at: time)
                } else {
                    settle(timedOut ? .timedOut : .failed, for: attempt, at: time)
                }
                complete(attempt)
            }
        case .urlSession(let urlSession):
            var request = URLRequest(url: site.settings.url)
            request.httpMethod = site.settings.method.rawValue
            let task = urlSession.dataTask(with: request)
            attempt.task = task
            task.resume()
            if kind == .fresh { urlSession.finishTasksAndInvalidate() }
        }
        requests[ObjectIdentifier(attempt.task)] = attempt
        occupied[site.settings.id, default: [:]][kind, default: 0] += 1
        return attempt
    }

    private func retireConnection(of attempt: Attempt) {
        guard attempt.lane.session?.identity == attempt.session.identity else { return }
        if case .urlSession(let session) = attempt.session { session.finishTasksAndInvalidate() }
        attempt.lane.session = nil
    }

    private func publish(_ result: ProbeResult, for attempt: Attempt) {
        let lane = attempt.lane
        guard attempt.sequence >= lane.evidence else { return }
        lane.evidence = attempt.sequence
        lane.result = result
    }

    private func settle(_ result: ProbeResult, for attempt: Attempt, at time: TimeInterval) {
        guard attempt.lane.active, !attempt.settled else { return }
        attempt.settled = true
        let final: ProbeResult = time >= attempt.cutoff ? .timedOut : result
        if !final.isSuccess || time >= attempt.warning { retireConnection(of: attempt) }
        attempt.lane.history.record(at: time, success: final.isSuccess)
        publish(final, for: attempt)
        onChange()
    }

    private func receive(_ response: URLResponse?, for attempt: Attempt) {
        let time = now()
        guard let http = response as? HTTPURLResponse, http.url == attempt.site.settings.url else {
            settle(.failed, for: attempt, at: time)
            return
        }
        settle(status: http.statusCode, for: attempt, at: time)
    }

    private func settle(status: Int, for attempt: Attempt, at time: TimeInterval) {
        let accepted = attempt.site.settings.accepts(statusCode: status)
        settle(accepted ? .success(max(0, time - attempt.start)) : .wrongStatus(status),
               for: attempt, at: time)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                                completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        MainActor.assumeIsolated {
            if let attempt = requests[ObjectIdentifier(task)] { receive(response, for: attempt) }
            completionHandler(nil)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                                completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        MainActor.assumeIsolated {
            guard let attempt = requests[ObjectIdentifier(dataTask)], attempt.lane.active else {
                completionHandler(.cancel)
                return
            }
            receive(response, for: attempt)
            // Bodyless responses can finish normally and keep a daily connection reusable.
            let status = (response as? HTTPURLResponse)?.statusCode
            let bodyless = dataTask.originalRequest?.httpMethod == "HEAD" || status == 204 || status == 304 ||
                response.expectedContentLength == 0
            completionHandler(bodyless ? .allow : .cancel)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didFinishCollecting metrics: URLSessionTaskMetrics) {
        MainActor.assumeIsolated {
            if let transaction = metrics.transactionMetrics.last {
                requests[ObjectIdentifier(task)]?.reused = transaction.isReusedConnection
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let attempt = requests[ObjectIdentifier(task)] else { return }
            if attempt.lane.active {
                if !attempt.settled, error == nil { receive(task.response, for: attempt) }
                if !attempt.settled {
                    settle((error as? URLError)?.code == .timedOut ? .timedOut : .failed, for: attempt, at: now())
                }
            }
            complete(attempt)
        }
    }

    private func complete(_ attempt: Attempt) {
        requests.removeValue(forKey: ObjectIdentifier(attempt.task))
        let id = attempt.site.settings.id
        occupied[id]?[attempt.kind]? -= 1
        if occupied[id]?.values.allSatisfy({ $0 == 0 }) == true { occupied.removeValue(forKey: id) }
        if attempt.lane.active { attempt.lane.usage.record(at: now(), reused: attempt.reused) }
        pump()
    }
}
