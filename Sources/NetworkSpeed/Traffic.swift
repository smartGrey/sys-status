import Foundation

struct LinkID: Hashable {
    let index: UInt16
    let name: String

    // Include physical and peer-to-peer links. Exclude loopback, tunnel and
    // bridge interfaces so their counters are not added on top of the links.
    var isExternal: Bool {
        for prefix in ["en", "awdl", "llw", "nan", "ap"] where name.hasPrefix(prefix) {
            let suffix = name.dropFirst(prefix.count)
            if !suffix.isEmpty && suffix.allSatisfy(\.isNumber) { return true }
        }
        return false
    }
}

struct LinkCounters {
    struct Direction {
        let bytes: UInt64
        let packets: UInt64

        func delta(from old: Self, elapsed: TimeInterval, bitsPerSecond: UInt64) -> UInt64? {
            guard packets >= old.packets else { return nil }
            if bytes >= old.bytes { return bytes - old.bytes }

            // Darwin masks the low ten bits and truncates byte counters to 32
            // bits for non-platform apps. Packet counters retain all 64 bits.
            let modulus: UInt64 = 1 << 32
            let quantum: UInt64 = 1024
            guard old.bytes < modulus, old.bytes.isMultiple(of: quantum),
                  bytes.isMultiple(of: quantum), packets > old.packets else { return nil }
            let wrapped = modulus - old.bytes + bytes

            // Allow fast links even when the driver gives an unknown or low
            // baud rate. Reject ambiguous hops spanning half the counter.
            let plausibleRate = max(bitsPerSecond, 10_000_000_000)
            let limit = Double(plausibleRate) / 8 * elapsed + Double(quantum - 1)
            guard wrapped < modulus / 2, Double(wrapped) <= limit else { return nil }
            return wrapped
        }
    }

    let received: Direction
    let sent: Direction
    let lastChange: UInt64
    let bitsPerSecond: UInt64
}

struct Snapshot {
    let time: TimeInterval
    let links: [LinkID: LinkCounters]
}

struct Speed {
    let upload: Double?
    let download: Double?
}

struct TrafficMeter {
    private var previous: Snapshot?

    mutating func measure(_ sample: Snapshot?) -> Speed? {
        defer { previous = sample }
        guard let sample, let previous else { return nil }
        let elapsed = sample.time - previous.time
        guard elapsed > 0, elapsed <= 5 else { return nil }

        var received: Double?
        var sent: Double?
        var hasExternal = false
        for (link, current) in sample.links where link.isExternal {
            hasExternal = true
            guard let old = previous.links[link], current.lastChange == old.lastChange else { continue }
            let bitsPerSecond = max(current.bitsPerSecond, old.bitsPerSecond)
            if let delta = current.received.delta(from: old.received, elapsed: elapsed, bitsPerSecond: bitsPerSecond) {
                received = (received ?? 0) + Double(delta)
            }
            if let delta = current.sent.delta(from: old.sent, elapsed: elapsed, bitsPerSecond: bitsPerSecond) {
                sent = (sent ?? 0) + Double(delta)
            }
        }
        guard hasExternal else { return Speed(upload: 0, download: 0) }
        guard received != nil || sent != nil else { return nil }
        return Speed(upload: sent.map { $0 / elapsed }, download: received.map { $0 / elapsed })
    }
}
