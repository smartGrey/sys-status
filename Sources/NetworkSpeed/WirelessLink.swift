import CoreWLAN
import Foundation

struct WirelessLink: Equatable, Sendable {
    enum Status { case unknown, disconnected, connected }
    var status: Status = .unknown
    var rssi: Int?
    var transmitMbps: Double?
    var bars: Int?

    init(status: Status = .unknown, rssi: Int? = nil, transmitMbps: Double? = nil, previousBars: Int? = nil) {
        self.status = status
        self.rssi = rssi
        self.transmitMbps = transmitMbps
        guard status == .connected, let rssi, rssi < 0 else { return }
        let boundaries = [-75, -65, -55]
        if let previousBars, (1...4).contains(previousBars) {
            var level = previousBars
            while level < 4 && rssi >= boundaries[level-1] + 2 { level += 1 }
            while level > 1 && rssi < boundaries[level-2] - 2 { level -= 1 }
            bars = level
        } else {
            bars = 1 + boundaries.filter { rssi >= $0 }.count
        }
    }

    var signal: String {
        switch status {
        case .unknown: return "—"
        case .disconnected: return "未连接"
        case .connected: return bars.map { ["弱", "一般", "良好", "强"][$0-1] } ?? "—"
        }
    }
}

actor WirelessReader {
    func read(previousBars: Int?) -> WirelessLink {
        guard let wifi = CWWiFiClient.shared().interface() else { return .init(status: .disconnected) }
        guard wifi.powerOn(), wifi.activePHYMode().rawValue != 0 else { return .init(status: .disconnected) }
        let rssi = wifi.rssiValue(), tx = wifi.transmitRate()
        return .init(status: .connected, rssi: rssi < 0 ? rssi : nil,
                     transmitMbps: tx.isFinite && tx > 0 ? tx : nil, previousBars: previousBars)
    }
}

/// Association changes can preserve the default IP route. No network name is required.
@MainActor
final class WirelessAssociationObserver: NSObject, CWEventDelegate {
    private let client = CWWiFiClient.shared()
    private let changed: () -> Void
    init(changed: @escaping () -> Void) {
        self.changed = changed
        super.init()
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
    }
    isolated deinit {
        try? client.stopMonitoringEvent(with: .ssidDidChange)
        client.delegate = nil
    }
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.changed() }
    }
}
