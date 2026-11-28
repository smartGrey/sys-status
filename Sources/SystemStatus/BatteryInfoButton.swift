import SwiftUI

struct BatteryInfoButton: View {
    @ObservedObject var model: SystemStatusController
    @State private var overButton = false
    @State private var overBubble = false
    @State private var heldOpen = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        Button {
            pending?.cancel()
            if heldOpen { model.details = false }
            else { heldOpen = true; model.details = true }
        } label: {
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 18, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("电池详情")
        .background(PanelControlRegion())
        .onHover { overButton = $0; schedule() }
        .popover(isPresented: $model.details, arrowEdge: .bottom) {
            let battery = model.reading.battery
            VStack(alignment: .leading, spacing: 7) {
                Text("电池详情").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    if let battery {
                        GridRow {
                            Text("低电量模式").foregroundStyle(.secondary)
                            Text(battery.lowPower ? "已开启" : "已关闭").gridColumnAlignment(.trailing)
                        }
                    }
                    detail("电池健康", battery?.health, "%")
                    detail("循环次数", battery?.cycles, "")
                    detail("当前容量", battery?.currentCapacity, " mAh")
                    detail("满充容量", battery?.fullCapacity, " mAh")
                    detail("设计容量", battery?.designCapacity, " mAh")
                }
            }.fixedSize().padding(12).contentShape(Rectangle())
            .onHover { overBubble = $0; schedule() }
        }
        .onChange(of: model.details) { _, open in
            if !open { pending?.cancel(); heldOpen = false; overBubble = false }
        }
        .onDisappear { pending?.cancel(); model.details = false }
    }

    private func detail(_ title: String, _ value: Int?, _ unit: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value.map { String($0) + unit } ?? "—").monospacedDigit().gridColumnAlignment(.trailing)
        }
    }

    private func schedule() {
        pending?.cancel()
        guard !heldOpen, !overBubble else { return }
        let show = overButton
        guard show != model.details else { return }
        pending = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(show ? 300 : 220)) } catch { return }
            model.details = show
        }
    }
}
