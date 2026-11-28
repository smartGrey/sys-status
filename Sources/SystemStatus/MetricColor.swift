import AppKit

enum MetricColor: String, CaseIterable, Codable {
    case graphite, slate, blue, cyan, teal, jade, olive, amber, copper, rose, violet, indigo

    private var swatch: (name: String, light: Int, dark: Int) {
        switch self {
        case .graphite: ("石墨", 0x33363A, 0xEDF0F2)
        case .slate:    ("岩灰", 0x4A5569, 0xC8D1E4)
        case .blue:     ("湖蓝", 0x14569A, 0x93C8FF)
        case .cyan:     ("海青", 0x006078, 0x84E2F9)
        case .teal:     ("松石", 0x00634F, 0x7BE3C9)
        case .jade:     ("翡翠", 0x236341, 0xA1E1B1)
        case .olive:    ("青橄榄", 0x556214, 0xD7E590)
        case .amber:    ("琥珀", 0x785400, 0xF1D18B)
        case .copper:   ("赤陶", 0x91441F, 0xFFB287)
        case .rose:     ("玫瑰", 0x893A59, 0xFFB5D0)
        case .violet:   ("紫藤", 0x694287, 0xE4B4F7)
        case .indigo:   ("靛蓝", 0x454F92, 0xB9BEFF)
        }
    }

    var name: String { swatch.name }
    var color: NSColor {
        let swatch = self.swatch
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = dark ? swatch.dark : swatch.light
            return NSColor(srgbRed: CGFloat(rgb >> 16) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }

    static func standard(for metric: StatusMetric) -> Self {
        switch metric {
        case .cpu: .blue
        case .memory: .teal
        case .disk: .slate
        case .cpuTemperature: .copper
        case .gpuTemperature: .violet
        case .batteryTemperature: .olive
        }
    }
}
