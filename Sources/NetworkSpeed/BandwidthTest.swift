import Foundation

enum BandwidthDirection: Equatable, Sendable {
    case download, upload

    var title: String { self == .download ? "下载" : "上传" }
    var arrow: String { self == .download ? "↓" : "↑" }
    var argument: String { self == .download ? "-u" : "-d" }
}

enum BandwidthFailure: Equatable, Sendable {
    case offline, timedOut, dns, connection, tls, http(Int)
    case unavailable, noMeasurement, tool(domain: String?, code: Int)

    var description: String {
        switch self {
        case .offline: "网络未连接"
        case .timedOut: "超时"
        case .dns: "域名解析失败"
        case .connection: "无法连接测速服务"
        case .tls: "安全连接失败"
        case .http(let status): "HTTP \(status)"
        case .unavailable: "无法启动系统测速"
        case .noMeasurement: "系统未返回有效速率"
        case .tool(let domain, let code):
            domain.map { "\($0) \(code)" } ?? "系统测速错误 \(code)"
        }
    }

    var summary: String {
        switch self {
        case .http(413): "请求被拒（HTTP 413）"
        case .noMeasurement, .tool: "未测得"
        default: description
        }
    }
}

enum BandwidthOutcome: Equatable, Sendable {
    case measured(Double)
    case failed(BandwidthFailure)
    case skipped

    static func decode(_ data: Data, exitCode: Int32, direction: BandwidthDirection) -> Self {
        struct Output: Decodable {
            let dl_throughput, ul_throughput: Double?
            let error_domain: String?
            let error_code, status_code: Int?
        }
        guard let output = try? JSONDecoder().decode(Output.self, from: data) else {
            return .failed(exitCode == 0 ? .noMeasurement : .tool(domain: nil, code: Int(exitCode)))
        }
        if let status = output.status_code, (400..<600).contains(status) {
            return .failed(.http(status))
        }
        if let code = output.error_code, code != 0 {
            if output.error_domain == NSURLErrorDomain || output.error_domain == "kCFErrorDomainCFNetwork" {
                switch code {
                case NSURLErrorNotConnectedToInternet: return .failed(.offline)
                case NSURLErrorTimedOut: return .failed(.timedOut)
                case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .failed(.dns)
                case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost: return .failed(.connection)
                case -1206 ... -1200: return .failed(.tls)
                default: break
                }
            }
            return .failed(.tool(domain: output.error_domain, code: code))
        }
        guard exitCode == 0 else { return .failed(.tool(domain: nil, code: Int(exitCode))) }
        let throughput = direction == .download ? output.dl_throughput : output.ul_throughput
        guard let throughput, throughput.isFinite, throughput > 0 else { return .failed(.noMeasurement) }
        return .measured(throughput / 8_000_000)
    }
}

struct BandwidthResult: Equatable, Sendable {
    let download: BandwidthOutcome
    let upload: BandwidthOutcome
    let date: Date

    var hasFailures: Bool {
        if case .measured = download, case .measured = upload { return false }
        return true
    }

    static func rate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 1 ? 0...2 : 0...1)))
    }
}

@MainActor
final class BandwidthTest {
    enum State: Equatable {
        case idle
        case running(BandwidthDirection, download: BandwidthOutcome?)
        case cancelling
        case complete(BandwidthResult)
    }

    private enum StopReason { case timedOut, discard }

    private(set) var state: State = .idle
    private var process: Process?
    private var timeout: Task<Void, Never>?
    private var forceStop: Task<Void, Never>?
    private var stopReason: StopReason?
    private let phaseTimeout: Duration
    private let makeProcess: (BandwidthDirection) -> Process
    var changed: (() -> Void)?
    var busy: Bool { process != nil }

    init(phaseTimeout: Duration = .seconds(10), makeProcess: @escaping (BandwidthDirection) -> Process = { direction in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        process.arguments = [direction.argument, "-c", "-M", "8"]
        return process
    }) {
        self.phaseTimeout = phaseTimeout
        self.makeProcess = makeProcess
    }

    isolated deinit {
        timeout?.cancel()
        forceStop?.cancel()
        if let process, process.isRunning { process.terminate() }
    }

    func start() {
        guard !busy else { return }
        run(.download, download: nil)
    }

    private func run(_ direction: BandwidthDirection, download: BandwidthOutcome?) {
        let child = makeProcess(direction)
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            finishPhase(direction, download: download, outcome: .failed(.unavailable))
            return
        }
        process = child
        state = .running(direction, download: download)
        timeout = Task { [weak self, phaseTimeout] in
            do { try await Task.sleep(for: phaseTimeout) } catch { return }
            self?.stop(.timedOut)
        }
        Task.detached(priority: .utility) { [weak self] in
            // Drain concurrently so even verbose failures cannot fill the child's pipe.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            let outcome = BandwidthOutcome.decode(data, exitCode: child.terminationStatus, direction: direction)
            await self?.finished(child, direction: direction, download: download, outcome: outcome)
        }
        changed?()
    }

    func cancel() { stop(.discard) }

    func invalidate() {
        if busy { stop(.discard) }
        else if state != .idle { state = .idle; changed?() }
    }

    private func stop(_ reason: StopReason) {
        guard let child = process else { return }
        if stopReason == nil {
            timeout?.cancel()
            if child.isRunning { child.terminate() }
            forceStop = Task {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        stopReason = reason
        if reason == .discard, state != .cancelling {
            state = .cancelling
            changed?()
        }
    }

    private func finished(_ child: Process, direction: BandwidthDirection, download: BandwidthOutcome?,
                          outcome: BandwidthOutcome) {
        guard process === child else { return }
        timeout?.cancel()
        timeout = nil
        forceStop?.cancel()
        forceStop = nil
        process = nil
        let reason = stopReason
        stopReason = nil
        if reason == .discard {
            state = .idle
            changed?()
            return
        }
        finishPhase(direction, download: download, outcome: reason == .timedOut ? .failed(.timedOut) : outcome)
    }

    private func finishPhase(_ direction: BandwidthDirection, download: BandwidthOutcome?, outcome: BandwidthOutcome) {
        switch direction {
        case .download where outcome != .failed(.offline):
            run(.upload, download: outcome)
            return
        case .download:
            state = .complete(BandwidthResult(download: outcome, upload: .skipped, date: Date()))
        case .upload:
            state = .complete(BandwidthResult(download: download ?? .skipped, upload: outcome, date: Date()))
        }
        changed?()
    }
}
