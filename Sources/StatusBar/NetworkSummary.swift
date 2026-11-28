import AppKit
import CoreText

@MainActor
enum NetworkHeaderLine {
    static let insetFromTop: CGFloat = 33

    static func textOrigin(_ field: NSTextField, height: CGFloat, bottom: CGFloat, reference: String) -> CGFloat {
        let font = field.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let text = NSAttributedString(string: reference, attributes: [.font: font])
        let ink = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(text), .useGlyphPathBounds)
        let baseline = height - field.firstBaselineOffsetFromTop
        return bottom - (baseline + ink.minY)
    }
}

/// The passive header sits beneath the panel's drag surface; the action is a sibling above it.
@MainActor
final class NetworkSummary: NSScrollView {
    private let line = NSView()
    private let signal = NSTextField(labelWithString: "Wi-Fi —")
    private let speed = NSTextField(labelWithString: "无线发送链路 —")
    private let result = NSTextField(labelWithString: "")
    private let bars = SignalBars()
    private var link = WirelessLink()
    private var measurement = BandwidthTest.State.idle
    private var compact = false
    private var fullWidth: CGFloat?
    private static let height: CGFloat = 28
    private static let inkBottom: CGFloat = 8
    private(set) var wirelessTip = ""
    private(set) var resultTip = ""

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        scrollerStyle = .overlay
        autohidesScrollers = true
        documentView = line
        for field in [signal, speed, result] {
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            line.addSubview(field)
        }
        line.addSubview(bars)
        signal.textColor = .labelColor
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let height = contentSize.height
        let barHeight: CGFloat = 12
        bars.frame = NSRect(x: 0, y: Self.inkBottom, width: 18, height: barHeight)

        func place(_ field: NSTextField, at x: CGFloat) -> CGFloat {
            let size = field.intrinsicContentSize
            // Align the body of the text. The slash in MB/s and a lone dash sit
            // outside it and should not move the baseline as the readings change.
            let y = NetworkHeaderLine.textOrigin(field, height: size.height, bottom: Self.inkBottom,
                                                 reference: "状态")
            field.frame = NSRect(x: x, y: y, width: labelWidth(field), height: size.height)
            return field.frame.maxX
        }

        let signalEnd = place(signal, at: 22)
        let speedEnd = place(speed, at: signalEnd + gap)
        let end = result.stringValue.isEmpty ? speedEnd : place(result, at: speedEnd + gap)
        result.isHidden = result.stringValue.isEmpty
        let needsScrolling = end > contentSize.width
        if hasHorizontalScroller != needsScrolling { hasHorizontalScroller = needsScrolling }
        line.frame = NSRect(x: 0, y: 0, width: max(end, contentSize.width), height: height)
        if !needsScrolling && contentView.bounds.minX != 0 {
            contentView.scroll(to: .zero)
            reflectScrolledClipView(contentView)
        }
    }

    private var gap: CGFloat { compact ? 4 : 10 }
    private func labelWidth(_ field: NSTextField) -> CGFloat {
        ceil(field.intrinsicContentSize.width) + (compact ? 4 : 6)
    }

    func frame(at x: CGFloat, bottom: CGFloat, available: CGFloat) -> NSRect {
        let idealWidth: CGFloat
        if let fullWidth {
            idealWidth = fullWidth
        } else {
            compact = false
            updateLabels()
            idealWidth = rowWidth
            fullWidth = idealWidth
        }
        let needsCompact = idealWidth > available
        if needsCompact != compact {
            compact = needsCompact
            updateLabels()
        }
        needsLayout = true
        return NSRect(x: x, y: bottom - Self.inkBottom, width: min(rowWidth, available), height: Self.height)
    }

    private var rowWidth: CGFloat {
        let wirelessWidth = 22 + labelWidth(signal) + gap + labelWidth(speed)
        return result.stringValue.isEmpty ? wirelessWidth : wirelessWidth + gap + labelWidth(result)
    }

    func update(wireless: WirelessLink, state: BandwidthTest.State) {
        guard link != wireless || measurement != state else { return }
        link = wireless
        measurement = state
        fullWidth = nil
        bars.level = wireless.bars
        wirelessTip = [wireless.rssi.map { "信号强度 \($0) dBm" },
                       wireless.transmitMbps.map { "Mac 向接入点发送的链路速率 \(BandwidthResult.rate($0)) Mbps" }]
            .compactMap { $0 }.joined(separator: " · ")
        resultTip = resultText(compact: false, detailed: true)
        needsLayout = true
    }

    private func updateLabels() {
        let signalTitle = compact ? link.signal : "Wi-Fi " + link.signal
        let linkRate = (compact ? "链路 " : "无线发送链路 ")
            + (link.transmitMbps.map { BandwidthResult.rate($0 / 8) + " MB/s" } ?? "—")
        let resultTitle = resultText(compact: compact)
        if signal.stringValue != signalTitle {
            signal.stringValue = signalTitle
            signal.setAccessibilityLabel("Wi-Fi " + link.signal)
        }
        if speed.stringValue != linkRate { speed.stringValue = linkRate }
        if result.stringValue != resultTitle {
            result.stringValue = resultTitle
            result.setAccessibilityLabel(resultText(compact: false))
        }
    }

    private func resultText(compact: Bool, detailed: Bool = false) -> String {
        func line(_ direction: BandwidthDirection, _ outcome: BandwidthOutcome) -> String {
            let name = compact ? direction.arrow : direction.title
            switch outcome {
            case .measured(let value): return name + " " + BandwidthResult.rate(value) + " MB/s"
            case .failed(let failure):
                if detailed { return "\(name)未测得（\(failure.description)）" }
                if case .http(let status) = failure, compact { return "\(name) HTTP \(status)" }
                return name + " " + failure.summary
            case .skipped: return detailed ? name + "未开始" : name + " 未测得"
            }
        }
        switch measurement {
        case .idle: return ""
        case .running(let direction, let download):
            var items = download.map { [line(.download, $0)] } ?? []
            items.append("正在测" + direction.title)
            if detailed { items.append("暂缓新探测") }
            return items.joined(separator: " · ")
        case .cancelling: return "正在结束测速…"
        case .complete(let reading):
            var items = [line(.download, reading.download), line(.upload, reading.upload)]
            if detailed { items.append(reading.date.formatted()) }
            else if !compact && !reading.hasFailures { items.append(reading.date.formatted(date: .omitted, time: .shortened)) }
            return items.joined(separator: " · ")
        }
    }

    private final class SignalBars: NSView {
        var level: Int? { didSet { if level != oldValue { needsDisplay = true } } }
        override func draw(_ rect: NSRect) {
            let palettes: [NSColor] = [.systemRed, .systemOrange, .systemTeal, .systemGreen]
            let active = level.flatMap { (1...palettes.count).contains($0) ? palettes[$0 - 1] : nil }
            for index in 0..<palettes.count {
                let tint = index < (level ?? 0) ? active ?? .quaternaryLabelColor : .quaternaryLabelColor
                tint.setFill()
                NSBezierPath(roundedRect: CGRect(x: CGFloat(index) * 5, y: 0, width: 3, height: bounds.height),
                             xRadius: 1, yRadius: 1).fill()
            }
        }
    }
}
