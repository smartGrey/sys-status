import AppKit

enum StatusModule: String, CaseIterable, Codable, Identifiable {
    case hearing, network, stopwatch, system
    var id: Self { self }
    var title: String {
        switch self {
        case .hearing: "监听环境音"
        case .network: "网络状况"
        case .stopwatch: "秒表"
        case .system: "系统状态"
        }
    }

    static func ordered(_ saved: [Self]) -> [Self] {
        var seen: Set<Self> = []
        return (saved + allCases).filter { seen.insert($0).inserted }
    }
}

/// The content frames and the halfway points between them define both drawing and input.
struct StatusStripLayout {
    struct Slot {
        let module: StatusModule
        let x: CGFloat
        let width: CGFloat
    }
    static let moduleGap: CGFloat = 8
    static let inset: CGFloat = 6
    let slots: [Slot]
    let width: CGFloat

    init(order: [StatusModule], widths: [StatusModule: CGFloat]) {
        var next: [Slot] = []
        var x = Self.inset
        for module in order {
            guard let width = widths[module] else { continue }
            if let previous = next.last {
                x += Self.moduleGap
                if [previous.module, module].contains(.hearing) { x += 1 }
            }
            next.append(Slot(module: module, x: x, width: width))
            x += width
        }
        slots = next
        width = next.isEmpty ? 22 : x + Self.inset
    }

    func region(_ part: StatusModule, in frame: CGRect) -> CGRect? {
        guard let i = slots.firstIndex(where: { $0.module == part }) else { return nil }
        let origin = frame.midX - width / 2
        func boundary(before index: Int) -> CGFloat {
            let previous = slots[index - 1]
            return min(frame.maxX, max(frame.minX, origin + (previous.x + previous.width + slots[index].x) / 2))
        }
        let left = i == 0 ? frame.minX : boundary(before: i)
        let right = i == slots.count - 1 ? frame.maxX : boundary(before: i + 1)
        return CGRect(x: left, y: frame.minY, width: right-left, height: frame.height)
    }
}
