import Foundation

enum ConnectivityState: String {
    case checking = "境外连通性待检测"
    case reachable = "境外检测地址可达"
    case unreachable = "境外检测地址不可达"
}

@MainActor
final class ConnectivityMonitor: NSObject, URLSessionDataDelegate {
    private let endpoint: URL
    private let configuration: URLSessionConfiguration
    private let onChange: () -> Void
    private var session: URLSession?
    private var request: URLSessionDataTask?
    private var probeOnNextTick = true
    private(set) var state = ConnectivityState.checking {
        didSet { if oldValue != state { onChange() } }
    }

    init(endpoint: URL = URL(string: "https://www.google.com/generate_204")!,
         configuration: URLSessionConfiguration = .ephemeral, onChange: @escaping () -> Void) {
        self.endpoint = endpoint
        self.configuration = configuration
        self.onChange = onChange
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 5
    }

    func start() {
        stop()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        probeOnNextTick = true
    }

    func stop() {
        request = nil
        session?.invalidateAndCancel()
        session = nil
        state = .checking
    }

    // Driven by the existing one-second sampling timer, including its first immediate tick.
    func tick() {
        guard let session else { return }
        defer { probeOnNextTick.toggle() }
        guard probeOnNextTick, request == nil else { return }
        let task = session.dataTask(with: endpoint)
        request = task
        task.resume()
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                                didReceive response: URLResponse,
                                completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        // A login/error page may have a large body. Its headers already decide the result.
        completionHandler((response as? HTTPURLResponse)?.statusCode == 204 ? .allow : .cancel)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            // A path change or sleep may have cancelled a task whose callback was already queued.
            guard task === request else { return }
            request = nil
            let response = task.response as? HTTPURLResponse
            state = error == nil && response?.url == endpoint && response?.statusCode == 204 ? .reachable : .unreachable
        }
    }
}
