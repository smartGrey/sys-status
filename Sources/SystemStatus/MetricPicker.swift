import SwiftUI

struct MetricPicker: View {
    @ObservedObject var model: SystemStatusController
    @State private var choosing: StatusMetric?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("状态栏指标").font(.headline)
            ReorderBoard(groups: [model.settings.metrics, model.settings.inactiveMetrics], headings: ["已显示", "未显示"],
                         commit: { groups in
                model.change { $0.metrics = groups[0]; $0.inactiveMetricOrder = groups[1] }
            }) { metric in
                HStack {
                    Text(metric.title)
                    Spacer()
                    let shade = model.settings.color(for: metric)
                    Button {
                        choosing = metric
                    } label: {
                        RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: shade.color))
                            .frame(width: 20, height: 13).padding(5).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).reorderControl()
                    .accessibilityLabel(metric.title + "颜色，" + shade.name)
                    .popover(isPresented: Binding(get: { choosing == metric }, set: { if !$0 { choosing = nil } })) {
                        palette(for: metric)
                    }
                }
                .padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
        }.padding(14).frame(width: 254)
    }

    private func palette(for metric: StatusMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metric.title).font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 3) {
                ForEach(MetricColor.allCases, id: \.self) { shade in
                    let selected = model.settings.color(for: metric) == shade
                    Button { choose(shade, for: metric) } label: {
                        HStack(spacing: 4) {
                            Circle().fill(Color(nsColor: shade.color)).frame(width: 10, height: 10)
                            Text(shade.name)
                            if selected { Image(systemName: "checkmark").imageScale(.small) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Divider()
            Button("恢复默认色") { choose(nil, for: metric) }.buttonStyle(.borderless)
        }.padding(12).frame(width: 250)
    }

    private func choose(_ color: MetricColor?, for metric: StatusMetric) {
        if model.change({ settings in
            var colors = settings.metricColors ?? [:]
            colors[metric.rawValue] = color
            settings.metricColors = colors.isEmpty ? nil : colors
        }) { choosing = nil }
    }
}
