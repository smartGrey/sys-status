import SwiftUI

/// The two accelerator plots share one measured value across the whole grid.
struct ComputeCard: View {
    let reading: SystemReading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let chip = systemString("machdep.cpu.brand_string").replacingOccurrences(of: "Apple ", with: "")
    @Environment(\.colorScheme) private var scheme
    private func tint(_ light: Int, _ dark: Int) -> Color {
        let rgb = scheme == .dark ? dark : light
        return Color(red: Double(rgb >> 16)/255, green: Double((rgb >> 8) & 255)/255, blue: Double(rgb & 255)/255)
    }

    var body: some View {
        HStack(spacing: 8) {
            column("CPU", reading.cpu, cpuCaption) {
                HStack(spacing: 1.25) {
                    ForEach(orderedCores) { core in
                        GeometryReader { geo in
                            ZStack(alignment: .bottom) {
                                Rectangle().fill(.quaternary)
                                Rectangle().fill(color(for: core.kind))
                                    .frame(height: geo.size.height * (core.usage ?? 0) / 100)
                            }.clipShape(RoundedRectangle(cornerRadius: 1))
                        }.help("\(core.kind.rawValue) · 核心 \(core.id + 1) · " + percent(core.usage))
                    }
                }
            }
            column("GPU", reading.gpuUsage, countText(reading.gpuCores) + " · 利用率") {
                plot(count: reading.gpuCores, value: reading.gpuUsage, color: tint(0x7351A6, 0xBDA1E7), fine: true)
            }.help("核心数由网格表示。颗粒密度对应整块 GPU 的利用率。")
            column("神经引擎", reading.neuralActivity, countText(reading.neuralCores) + " · 活跃时间") {
                plot(count: reading.neuralCores, value: reading.neuralActivity, color: tint(0xA76A20, 0xE8B674), fine: false)
            }.help("上一采样周期中，最活跃的神经引擎簇处于活动电源状态的时间占比。")
        }
    }

    private func column<Plot: View>(_ title: String, _ value: Double?, _ caption: String,
                                    @ViewBuilder plot: () -> Plot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 1) {
                Text(title)
                Spacer(minLength: 0)
                Text(percent(value)).monospacedDigit()
            }.font(.system(size: 10, weight: .semibold))
            plot().frame(height: 29).background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 2))
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .lineLimit(1).minimumScaleFactor(0.72)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var orderedCores: [CoreLoad] {
        [.efficiency, .performance, .unknown].flatMap { kind in reading.cores.filter { $0.kind == kind } }
    }
    private var cpuCaption: String {
        let e = reading.cores.filter { $0.kind == .efficiency }.count
        let p = reading.cores.filter { $0.kind == .performance }.count
        return e + p == reading.cores.count && e + p > 0 ? "\(e) 能效 · \(p) 性能" : countText(reading.cores.isEmpty ? nil : reading.cores.count)
    }
    private func countText(_ count: Int?) -> String { count.map { "\($0) 核" } ?? "— 核" }
    private func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "—" }
    private func color(for kind: CoreLoad.Kind) -> Color {
        switch kind {
        case .efficiency: tint(0x309273, 0x84C9A7)
        case .performance: tint(0x247388, 0x7AC7D9)
        case .unknown: .secondary
        }
    }

    private func plot(count: Int?, value: Double?, color: Color, fine: Bool) -> some View {
        Canvas { context, size in
            guard let count, count > 0, size.width > 0 else { return }
            let columns = Int(ceil(Double(count) / min(4, Double(count))))
            let rows = (count + columns - 1) / columns
            let cell = CGSize(width: size.width / CGFloat(columns), height: size.height / CGFloat(rows))
            let phase = reduceMotion ? 0 : reading.computePhase
            let texture = fine ? Self.gpuTexture : Self.neuralTexture
            let lattice = fine ? 64 : 32
            if let value {
                var fill = Path()
                let n = Int((Double(texture[phase].count) * value / 100).rounded())
                let dx = size.width / CGFloat(lattice), dy = size.height / 16
                for index in texture[phase].prefix(n) {
                    fill.addRect(CGRect(x: CGFloat(index % lattice) * dx, y: CGFloat(index / lattice) * dy,
                                        width: dx, height: dy))
                }
                context.fill(fill, with: .color(color))
            }
            var grid = Path()
            for i in 0..<count {
                grid.addRect(CGRect(origin: CGPoint(x: CGFloat(i % columns) * cell.width,
                                                    y: CGFloat(i / columns) * cell.height), size: cell))
            }
            if count < rows * columns {
                let empty = CGRect(x: CGFloat(count % columns) * cell.width, y: CGFloat(rows-1) * cell.height,
                                   width: CGFloat(rows * columns-count) * cell.width, height: cell.height)
                context.blendMode = .clear
                context.fill(Path(empty), with: .color(.black))
                context.blendMode = .normal
            }
            context.stroke(grid, with: .color(.primary.opacity(0.38)), lineWidth: 0.65)
        }.accessibilityHidden(true)
    }

    // Precompute eight related permutations. Each frame fills exactly the measured
    // fraction and moves only a small share of particles between adjacent samples.
    private static let gpuTexture = texture(columns: 64)
    private static let neuralTexture = texture(columns: 32)
    private static func texture(columns: Int) -> [[Int]] {
        func hash(_ index: Int) -> UInt32 {
            var n = UInt32(truncatingIfNeeded: index) &+ 11
            n = (n ^ (n >> 16)) &* 0x45d9f3b
            n = (n ^ (n >> 16)) &* 0x45d9f3b
            return n ^ (n >> 16)
        }
        return (0..<8).map { phase in
            (0..<columns*16).map { index in
                (index, UInt64(hash(index)) + UInt64(hash(index + phase*1643))/7)
            }.sorted { $0.1 < $1.1 }.map(\.0)
        }
    }
}
