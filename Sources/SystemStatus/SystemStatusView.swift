import SwiftUI

@MainActor
struct SystemStatusView: View {
    @ObservedObject var model: SystemStatusController

    private var modules: [ResourceModule] {
        model.settings.modules.filter { model.editing || !model.settings.hidden.contains($0) }
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                let pairs = geometry.size.width >= 532 ? modules.count / 2 * 2 : 0
                VStack(spacing: 10) {
                    if pairs > 0 {
                        let column = GridItem(.flexible(minimum: 0), spacing: 10, alignment: .top)
                        LazyVGrid(columns: [column, column], spacing: 10) {
                            ForEach(modules.prefix(pairs)) { moduleTile($0) }
                        }
                    }
                    ForEach(modules.dropFirst(pairs)) { moduleTile($0) }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
                if model.editing {
                    Button("恢复默认布局") {
                        model.change { $0.modules = ResourceModule.allCases; $0.hidden.removeAll() }
                    }.buttonStyle(.borderless).padding(.bottom, 12)
                } else if modules.isEmpty {
                    Button("选择显示模块") { model.editing = true }
                        .padding()
                }
            }.background { if !model.editing { PanelDragBackground() } }
        }
        .allowsWindowActivationEvents()
    }

    @ViewBuilder
    private func moduleTile(_ module: ResourceModule) -> some View {
        if model.editing {
            tile(module)
                .draggable("module." + module.rawValue)
                .dropDestination(for: String.self) { values, _ in
                    guard let raw = values.first, raw.hasPrefix("module."),
                          let source = ResourceModule(rawValue: String(raw.dropFirst(7))) else { return false }
                    return model.change { Self.move(source, to: module, in: &$0.modules) }
                }
        } else {
            tile(module)
        }
    }

    private func tile(_ module: ResourceModule) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(module.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.editing {
                    Button { model.change {
                        if $0.hidden.contains(module) { $0.hidden.remove(module) } else { $0.hidden.insert(module) }
                    } } label: {
                        Image(systemName: model.settings.hidden.contains(module) ? "eye.slash" : "eye")
                    }.accessibilityLabel((model.settings.hidden.contains(module) ? "显示" : "隐藏") + module.title)
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("拖动调整顺序")
                } else if module == .battery {
                    Button { model.details.toggle() } label: {
                        Image(systemName: model.details ? "chevron.up" : "chevron.down")
                            .frame(width: 24, height: 18)
                    }.accessibilityLabel(model.details ? "收起电池详情" : "展开电池详情")
                }
            }.buttonStyle(.borderless)
            Group {
                switch module {
                case .battery: battery
                case .cpu: cpu
                case .memory: memory
                case .disk: disk
                case .temperature: temperature
                }
            }.opacity(model.editing && model.settings.hidden.contains(module) ? 0.4 : 1)
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.58), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.08)).allowsHitTesting(false) }
        .background { if !model.editing { PanelDragBackground() } }
        .accessibilityAction(named: "向前移动") { shiftModule(module, delta: -1) }
        .accessibilityAction(named: "向后移动") { shiftModule(module, delta: 1) }
    }

    private func shiftModule(_ module: ResourceModule, delta: Int) {
        guard model.editing, let index = model.settings.modules.firstIndex(of: module),
              model.settings.modules.indices.contains(index + delta) else { return }
        model.change { $0.modules.swapAt(index, index + delta) }
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
                    if !b.connected || b.charging {
                        Text((b.charging ? "距充满 " : "可用 ") + b.timeLabel)
                    }
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if model.details {
                Divider()
                detail("电池健康", b?.health.map { "\($0)%" })
                detail("循环次数", b?.cycles.map(String.init))
                detail("当前容量", b?.currentCapacity.map { "\($0) mAh" })
                detail("满充容量", b?.fullCapacity.map { "\($0) mAh" })
                detail("设计容量", b?.designCapacity.map { "\($0) mAh" })
            }
        }
    }

    private var cpu: some View {
        VStack(alignment: .leading, spacing: 8) {
            number(model.reading.statusValue(.cpu))
            HStack(alignment: .bottom, spacing: 10) {
                ForEach([CoreLoad.Kind.performance, .efficiency, .unknown], id: \.self) { kind in
                    let cores = model.reading.cores.filter { $0.kind == kind }
                    if !cores.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .bottom, spacing: 2) {
                                ForEach(cores) { core in
                                    ZStack(alignment: .bottom) {
                                        Capsule().fill(.quaternary)
                                        Capsule().fill(kind == .performance ? Color.accentColor : Color.teal)
                                            .frame(height: max(1, 19 * core.usage / 100))
                                    }
                                    .frame(maxWidth: 17).frame(height: 19)
                                    .help("\(kind.rawValue) · 核心 \(core.id + 1) · \(Int(core.usage.rounded()))%")
                                    .accessibilityLabel("核心 \(core.id + 1)，\(kind.rawValue)，\(Int(core.usage.rounded()))%")
                                }
                            }
                            Text(kind.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }.frame(height: 35, alignment: .bottom)
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
    private func detail(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—").monospacedDigit()
        }.font(.caption)
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
    static func move<T: Equatable>(_ source: T, to target: T, in items: inout [T]) {
        guard let from = items.firstIndex(of: source), let to = items.firstIndex(of: target), from != to else { return }
        items.insert(items.remove(at: from), at: to)
    }
}

@MainActor
struct SystemStatusToolbar: View {
    @ObservedObject var model: SystemStatusController

    var body: some View {
        HStack(spacing: 12) {
            Button { model.choosingMetrics.toggle() } label: {
                Label("状态栏显示", systemImage: "menubar.rectangle")
            }
            .popover(isPresented: $model.choosingMetrics, arrowEdge: .bottom) { metricPicker }
            Button {
                model.editing.toggle()
            } label: {
                Label(model.editing ? "完成" : "编辑布局", systemImage: model.editing ? "checkmark" : "square.grid.2x2")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .fixedSize()
        .allowsWindowActivationEvents()
    }

    private var metricPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("状态栏显示").font(.headline)
            let selected = model.settings.metrics
            ForEach(selected + StatusMetric.allCases.filter { !selected.contains($0) }) { metric in
                HStack {
                    Toggle(metric.title, isOn: Binding(get: { model.settings.metrics.contains(metric) }, set: { enabled in
                        model.change { $0.metrics.removeAll { $0 == metric }; if enabled { $0.metrics.append(metric) } }
                    }))
                    Spacer()
                    if let index = selected.firstIndex(of: metric) {
                        Button { model.change { $0.metrics.swapAt(index, index-1) } } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).accessibilityLabel("向前移动" + metric.title)
                        Button { model.change { $0.metrics.swapAt(index, index+1) } } label: { Image(systemName: "chevron.down") }
                            .disabled(index + 1 == selected.count).accessibilityLabel("向后移动" + metric.title)
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            .draggable("metric." + metric.rawValue)
                    }
                }.buttonStyle(.borderless).frame(minHeight: 22)
                .dropDestination(for: String.self) { values, _ in
                    guard selected.contains(metric), let raw = values.first, raw.hasPrefix("metric."),
                          let source = StatusMetric(rawValue: String(raw.dropFirst(7))) else { return false }
                    return model.change { SystemStatusView.move(source, to: metric, in: &$0.metrics) }
                }
            }
        }.padding(14).frame(width: 238)
    }
}
