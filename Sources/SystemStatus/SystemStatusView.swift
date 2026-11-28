import SwiftUI

enum SystemPanelLayout {
    static let defaultWidth: CGFloat = 580
    static let gridBreakpoint: CGFloat = 532
    static let cellHeight: CGFloat = 110
    static let gap: CGFloat = 10
    static let sideInset: CGFloat = 12
    static let bottomInset: CGFloat = 8
    static let resetSpacing: CGFloat = 6
    static let resetButtonHeight: CGFloat = 20
    static var editingFooterHeight: CGFloat { resetSpacing + resetButtonHeight }

    static func columns(for width: CGFloat) -> Int { width >= gridBreakpoint ? 2 : 1 }

    static func heightToFit(width: CGFloat) -> CGFloat {
        let grid = BoardGeometry(counts: [ResourceModule.allCases.count], width: width - 2 * sideInset,
                                 columns: columns(for: width), cellHeight: cellHeight, gap: gap, header: 0)
        return PanelChrome.headerHeight + grid.height + bottomInset
    }
}

@MainActor
struct SystemStatusView: View {
    @ObservedObject var model: SystemStatusController

    private var modules: [ResourceModule] {
        model.settings.modules.filter { model.editing || !model.settings.hidden.contains($0) }
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    if !modules.isEmpty {
                        ReorderBoard(groups: [modules], columns: SystemPanelLayout.columns(for: geometry.size.width),
                                     cellHeight: SystemPanelLayout.cellHeight, gap: SystemPanelLayout.gap, editable: model.editing, commit: { groups in
                            model.change { $0.modules = groups[0] }
                        }, row: tile)
                        .padding(.horizontal, SystemPanelLayout.sideInset)
                    }
                    if model.editing {
                        Button("恢复默认布局") {
                            model.restoreLayout()
                        }.buttonStyle(.borderless)
                            .frame(height: SystemPanelLayout.resetButtonHeight)
                            .padding(.top, SystemPanelLayout.resetSpacing)
                    } else if modules.isEmpty {
                        Button("选择显示模块") { model.editing = true }
                            .padding()
                    }
                }.padding(.bottom, SystemPanelLayout.bottomInset)
            }.background { if !model.editing { PanelDragBackground() } }
        }
        .allowsWindowActivationEvents()
    }

    private func tile(_ module: ResourceModule) -> some View {
        VStack(alignment: .leading, spacing: module == .compute ? 10 : 13) {
            HStack {
                Text(module.title).font(.system(size: 13, weight: .semibold))
                if module == .battery && !model.editing { BatteryInfoButton(model: model) }
                Spacer()
                if module == .compute && !model.editing {
                    Text(ComputeCard.chip).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if model.editing {
                    Button { model.change {
                        if $0.hidden.contains(module) { $0.hidden.remove(module) } else { $0.hidden.insert(module) }
                    } } label: {
                        Image(systemName: model.settings.hidden.contains(module) ? "eye.slash" : "eye")
                    }.reorderControl().accessibilityLabel((model.settings.hidden.contains(module) ? "显示" : "隐藏") + module.title)
                }
            }.buttonStyle(.borderless)
            Group {
                switch module {
                case .battery: battery
                case .compute: ComputeCard(reading: model.reading)
                case .memory: memory
                case .disk: disk
                case .temperature: temperature
                }
            }.opacity(model.editing && model.settings.hidden.contains(module) ? 0.4 : 1)
        }
        .padding(EdgeInsets(top: 13, leading: 13, bottom: 12, trailing: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.opacity(0.58), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.08)).allowsHitTesting(false) }
        .background { if !model.editing { PanelDragBackground() } }
    }

    private var battery: some View {
        let b = model.reading.battery
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                number(b?.percent.map { "\($0)%" } ?? "—")
                Spacer()
                Text(b?.source ?? (model.reading.hasBattery == false ? "无内置电池" : "—")).font(.caption).foregroundStyle(.secondary)
            }
            gauge(b?.percent.map { Double($0) / 100 }, color: b?.charging == true ? .green : .accentColor)
            if let b {
                HStack(spacing: 8) {
                    if let w = b.watts {
                        Text(String(format: w < 0 ? "放电 %.1f W" : w > 0 ? "充电 %.1f W" : "%.1f W", abs(w)))
                    }
                    if !b.connected || b.isActivelyCharging {
                        Text((b.charging ? "距充满 " : "可用 ") + b.timeLabel)
                    }
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var memory: some View {
        let m = model.reading.memory
        return VStack(alignment: .leading, spacing: 6) {
            number(m.map { String(format: "%.1f / %.0f GB", Double($0.used)/1_073_741_824, Double($0.total)/1_073_741_824) } ?? "—")
            gauge(m.flatMap { $0.total > 0 ? Double($0.used)/Double($0.total) : nil }, color: m?.pressure == 4 ? .red : m?.pressure == 2 ? .orange : .teal)
            HStack {
                Text("压力 " + (m?.pressureText ?? "—"))
                Spacer()
                Text("交换 " + (m?.swap.map(Self.swapText) ?? "—"))
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
    private var disk: some View {
        let d = model.reading.disk
        return VStack(alignment: .leading, spacing: 6) {
            number(d.map { String(format: "%.1f GB 可用", Double($0.available)/1e9) } ?? "—")
            gauge(d.flatMap { $0.total > 0 ? 1 - Double($0.available)/Double($0.total) : nil }, color: .secondary)
            Text(d.map { String(format: "总容量 %.1f GB", Double($0.total)/1e9) } ?? "总容量 —")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var temperature: some View {
        HStack(spacing: 8) {
            ForEach([StatusMetric.cpuTemperature, .gpuTemperature, .batteryTemperature]) { metric in
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(metric.title.dropLast(2))).font(.caption).foregroundStyle(.secondary)
                    number(model.reading.temperatures[metric].map { String(format: "%.0f°C", $0) } ?? "—")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func number(_ text: String) -> some View {
        Text(text).font(.system(size: 19, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.82)
    }
    private func gauge(_ ratio: Double?, color: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: proxy.size.width * max(0,min(1,ratio ?? 0)))
            }
        }.frame(height: 4).accessibilityHidden(true)
    }
    private static func swapText(_ bytes: UInt64) -> String {
        if bytes == 0 { return "0 B" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.0f KiB", Double(bytes)/1024) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MiB", Double(bytes)/1_048_576) }
        return String(format: "%.1f GiB", Double(bytes)/1_073_741_824)
    }
}

@MainActor
struct SystemStatusToolbar: View {
    @ObservedObject var model: SystemStatusController

    var body: some View {
        HStack(spacing: 12) {
            Button { model.choosingMetrics.toggle() } label: {
                Label("状态栏指标", systemImage: "menubar.rectangle")
            }
            .popover(isPresented: $model.choosingMetrics, arrowEdge: .bottom) { MetricPicker(model: model) }
            Button {
                model.editing.toggle()
            } label: {
                Label(model.editing ? "完成" : "编辑布局", systemImage: model.editing ? "checkmark" : "square.grid.2x2")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .labelStyle(SystemToolbarLabelStyle())
        .allowsWindowActivationEvents()
    }
}

private struct SystemToolbarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        ViewThatFits(in: .horizontal) {
            Label(configuration).labelStyle(.titleAndIcon).fixedSize()
            configuration.title.fixedSize()
        }
    }
}
