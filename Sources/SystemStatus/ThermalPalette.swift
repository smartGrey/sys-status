import SwiftUI

enum ThermalPalette {
    static func title(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "正常"
        case .fair: "略高"
        case .serious: "高"
        case .critical: "临界"
        @unknown default: "未知"
        }
    }

    static func tint(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: .secondary
        case .fair: Color(nsColor: .init(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .systemYellow : NSColor(srgbRed: 0.60, green: 0.39, blue: 0.02, alpha: 1)
        })
        case .serious: .orange
        case .critical: .red
        @unknown default: .secondary
        }
    }

    static func temperature(_ value: Double?, battery: Bool, dark: Bool) -> Color {
        guard let value else { return .secondary }
        let (low, middle, high) = battery ? (32.0, 37.0, 42.0) : (55.0, 70.0, 85.0)
        guard value > low else { return .primary }
        let amber = dark ? Color(red: 1, green: 0.81, blue: 0.37) : Color(red: 0.59, green: 0.39, blue: 0.05)
        let orange = dark ? Color(red: 1, green: 0.52, blue: 0.29) : Color(red: 0.74, green: 0.25, blue: 0.07)
        if value < middle { return Color.primary.mix(with: amber, by: (value-low)/(middle-low)) }
        return amber.mix(with: orange, by: min(1, (value-middle)/(high-middle)))
    }

    static func fanLabel(_ speeds: [Int?]) -> String? {
        guard !speeds.isEmpty else { return nil }
        if speeds.allSatisfy({ $0 == 0 }) { return "风扇停转" }
        let values = speeds.map { $0.map(String.init) ?? "—" }.joined(separator: " / ")
        return "风扇 " + values + (speeds.contains(where: { $0 != nil }) ? " RPM" : "")
    }
}
