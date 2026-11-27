import SwiftUI

private enum Palette {
    static let accent = Color(red: 0.08, green: 0.53, blue: 0.55)
}

@MainActor
struct HearingPanelView: View {
    @ObservedObject var model: HearingModel
    let contentWidth: CGFloat
    var onContentSizeChange: (CGSize) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                parameterLabel("触发阈值", value: String(format: "+%.0f dB", model.preferences.thresholdDB))
                LiveThresholdSlider(meter: model.meter,
                                    value: Binding(get: { model.preferences.thresholdDB }, set: { model.setThreshold($0) }),
                                    recommendations: model.recommendations)
                calibration
            }
            parameter("透传音量", value: String(format: "%+.0f dB", model.preferences.gainDB)) {
                Slider(value: Binding(get: { model.preferences.gainDB }, set: { model.setGain($0) }),
                       in: -12 ... 36, step: 1).accessibilityLabel("环境声增益，单位 dB")
            }
            parameter("底噪抑制", value: model.preferences.noiseReductionDB == 0 ? "关闭" : String(format: "%.0f dB", model.preferences.noiseReductionDB)) {
                Slider(value: Binding(get: { model.preferences.noiseReductionDB }, set: { model.setReduction($0) }),
                       in: 0 ... 30, step: 1)
                    .accessibilityLabel("底噪最大衰减，单位 dB，零表示关闭降噪")
                    .help("最多减弱多少底噪；18 dB 以上加强抑制，弱声可能减弱；0 为关闭，不影响触发灵敏度")
            }
            parameter("关闭等待", value: String(format: "%.1f 秒", model.preferences.holdSeconds)) {
                Slider(value: Binding(get: { model.preferences.holdSeconds }, set: { model.setHold($0) }),
                       in: 0.2 ... 3, step: 0.1).accessibilityLabel("关闭等待时间，单位秒")
            }
            Divider()
            devices
            recoveryActions
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 8) {
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.dismissNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭提示")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .top) {
                Toggle("开启环境声透传", isOn: Binding(get: { model.preferences.enabled }, set: { model.setEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel("开启环境声透传")
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    ShortcutView(controller: model.shortcuts)
                    ShortcutMessage(controller: model.shortcuts)
                }
            }
        }
        .padding(20)
        .frame(width: contentWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .tint(Palette.accent)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onContentSizeChange($0) }
    }
    // Routine status lives in the menu bar; retain only actions needed to recover.
    @ViewBuilder
    private var recoveryActions: some View {
        if let error = model.errorMessage {
            VStack(alignment: .leading, spacing: 6) {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("重试连接") { model.retry() }.font(.caption)
            }
        }
        if case .stopped(.permission) = model.decision {
            Button(model.permission == .notDetermined ? "允许麦克风访问" : "打开麦克风权限设置") {
                model.requestMicrophone()
            }.font(.caption)
        }
    }
    private func parameterLabel(_ name: String, value: String) -> some View {
        HStack {
            Text(name).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }
    private func parameter<Content: View>(_ name: String, value: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            parameterLabel(name, value: value)
            content().controlSize(.small)
        }
    }
    private var calibration: some View {
        HStack(spacing: 7) {
            if model.calibrating {
                CalibrationProgress(meter: model.meter)
                Button("取消") { model.cancelCalibration() }
            } else if !model.recommendations.isEmpty {
                ForEach(model.recommendations) { suggestion in
                    Button { model.applySuggestion(suggestion) } label: {
                        Text(suggestion.kind.title)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(model.preferences.thresholdDB == suggestion.value ? Palette.accent.opacity(0.16) : Color.primary.opacity(0.045), in: Capsule())
                            .foregroundStyle(model.preferences.thresholdDB == suggestion.value ? Palette.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("应用\(suggestion.kind.title)阈值，突出程度 \(Int(suggestion.value)) dB")
                    .accessibilityAddTraits(model.preferences.thresholdDB == suggestion.value ? .isSelected : [])
                    .help("应用\(suggestion.kind.title)：+\(Int(suggestion.value)) dB")
                }
                Spacer(minLength: 0)
                Button { model.measureBackground() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("重新测量背景音").help("重新测量")
                    .disabled(model.starting || model.sleeping)
            } else if model.isListening && !model.environmentReady {
                Text("适应环境…").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            } else {
                Button { model.measureBackground() } label: {
                    Label("推荐阈值", systemImage: "waveform.path").font(.system(size: 11))
                }.disabled(model.starting || model.sleeping)
                Spacer()
            }
        }.controlSize(.small).frame(height: 24)
    }
    private var devices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("允许的输出设备").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if model.allowedRows.isEmpty {
                Text("未连接耳机").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(model.allowedRows) { row in
                let connected = model.catalog.outputs.first { $0.key == row.key && $0.supported }
                let current = connected?.id == model.catalog.defaultOutputID
                HStack(spacing: 10) {
                    Image(systemName: "headphones").foregroundStyle(current ? Palette.accent : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name).font(.system(size: 12, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(connected == nil ? "未连接" : current ? "当前输出" : "已连接")
                            .font(.system(size: 10)).foregroundStyle(current ? Palette.accent : .secondary)
                    }
                    Spacer(minLength: 0)
                    Toggle("允许 \(row.name)", isOn: Binding(
                        get: { model.preferences.allows(row.key) },
                        set: { model.setAllowed(row, allowed: $0) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .accessibilityLabel("允许 \(row.name) 播放环境声")
                }
            }
        }
    }
}

private struct ShortcutMessage: View {
    @ObservedObject var controller: HearingShortcutController
    var body: some View {
        if let message = controller.message {
            HStack(alignment: .top, spacing: 6) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.binding != nil && !controller.isRegistered && !controller.isRecording {
                    Button("重试") { controller.retryIfNeeded() }.font(.caption).buttonStyle(.plain)
                }
            }
        }
    }
}

/// One shared scale: the fill is live input; the thumb sets the opening threshold.
private struct LiveThresholdSlider: View {
    @ObservedObject var meter: PanelMeter
    @Binding var value: Double
    let recommendations: [ThresholdRecommendation]
    var body: some View {
        ThresholdSlider(value: $value, level: meter.state.level, active: meter.state.active,
                        passing: meter.state.passing, recommendations: recommendations)
    }
}

private struct CalibrationProgress: View {
    @ObservedObject var meter: PanelMeter
    var body: some View {
        ProgressView(value: meter.state.calibrationProgress)
            .help("测量背景音，请保持安静")
            .accessibilityLabel("测量背景音，请保持安静")
    }
}

private struct ThresholdSlider: View {
    @Binding var value: Double
    let level: Double
    let active: Bool
    let passing: Bool
    let recommendations: [ThresholdRecommendation]
    @FocusState private var focused: Bool
    private let thumbRadius: CGFloat = 9
    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - 2 * thumbRadius)
            let position = thumbRadius + CGFloat(ThresholdScale.fraction(value)) * travel
            let fill = active && level > 3 ? thumbRadius + CGFloat(ThresholdScale.fraction(level)) * travel : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09)).frame(height: 8)
                Capsule().fill(Palette.accent.opacity(passing ? 0.55 : 0.28))
                    .frame(width: fill, height: 8)
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: focused ? Palette.accent.opacity(0.4) : .black.opacity(0.2),
                            radius: focused ? 3 : 1.5, y: 1)
                    .frame(width: 18, height: 18).offset(x: position - thumbRadius)
            }
            .frame(height: 32)
            .overlay(alignment: .topLeading) {
                ForEach(recommendations) { recommendation in
                    Circle()
                        .fill(value == recommendation.value ? Palette.accent : Color(nsColor: .windowBackgroundColor))
                        .overlay(Circle().strokeBorder(value == recommendation.value ? Palette.accent : .secondary.opacity(0.65), lineWidth: 1))
                        .frame(width: 6, height: 6)
                        .offset(x: thumbRadius + CGFloat(ThresholdScale.fraction(recommendation.value)) * travel - 3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                focused = true
                value = ThresholdScale.value(at: Double((event.location.x - thumbRadius) / travel))
            })

        }
        .frame(height: 32)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.leftArrow) { adjust(-1); return .handled }
        .onKeyPress(.downArrow) { adjust(-1); return .handled }
        .onKeyPress(.rightArrow) { adjust(1); return .handled }
        .onKeyPress(.upArrow) { adjust(1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("触发阈值")
        .accessibilityValue("突出程度 \(Int(value)) dB，当前 \(active ? String(Int(level)) : "无")"
                             + recommendations.map { "，\($0.kind.title) \(Int($0.value)) dB" }.joined())
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(1)
            case .decrement: adjust(-1)
            @unknown default: break
            }
        }
    }
    private func adjust(_ delta: Double) { value = min(30, max(3, value + delta)) }
}
