import Foundation
import SystemConfiguration

// Each waking session owns a fresh reader and baseline. Only the serial timer
// queue calls read(); the main actor owns the source and all AppKit objects.
private final class SamplingSession: @unchecked Sendable {
    private var reader = InterfaceReader()
    private var meter = TrafficMeter()
    func read() -> Speed? { meter.measure(reader.sample()) }
}

@MainActor
final class NetworkSampler {
    private let sampled: (Speed?) -> Void
    private let networkChanged: () -> Void
    private let queue = DispatchQueue(label: "netrate.sample", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var networkStore: SCDynamicStore?

    init(sampled: @escaping (Speed?) -> Void, networkChanged: @escaping () -> Void) {
        self.sampled = sampled
        self.networkChanged = networkChanged
    }

    func observeNetworkChanges() {
        // The application stops this registration before releasing the sampler. Callbacks run on the main queue.
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "NetRate" as CFString, { _, _, info in
            guard let info else { return }
            let sampler = Unmanaged<NetworkSampler>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard sampler.timer != nil else { return }
                sampler.networkChanged()
            }
        }, &context) else { return }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6",
                    "State:/Network/Global/DNS", "State:/Network/Global/Proxies"]
        // A tunnel can keep the primary route, and a physical link can cycle without changing its IP.
        let interfaces = ["State:/Network/Interface/[^/]+/IPv[46]",
                          "State:/Network/Interface/en[0-9]+/Link"]
        guard SCDynamicStoreSetNotificationKeys(store, keys as CFArray, interfaces as CFArray),
              SCDynamicStoreSetDispatchQueue(store, .main) else { return }
        networkStore = store
    }

    func start() {
        let token = generation
        let session = SamplingSession()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(80))
        source.setEventHandler { @Sendable [weak self] in
            let speed = session.read()
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.sampled(speed)
            }
        }
        timer = source
        source.resume()
    }

    func stop() {
        generation += 1
        timer?.cancel()
        timer = nil
    }

    func stopObservingNetworkChanges() {
        if let networkStore { SCDynamicStoreSetDispatchQueue(networkStore, nil) }
        networkStore = nil
    }
}
