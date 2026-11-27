import AppKit
import CoreText

// The result, wait track, and next-dispatch clock have identical coordinates in both groups.
@MainActor
final class ProbeTimingView: NSView {
    private static let columnGap: CGFloat = 8
    static let resultRect = NSRect(x: 0, y: 0, width: 90, height: 34)
    static let waitRect = NSRect(x: resultRect.maxX + columnGap, y: 0, width: 86, height: resultRect.height)
    static let nextRect = NSRect(x: waitRect.maxX + columnGap, y: 0, width: 65, height: resultRect.height)
    static let width = nextRect.maxX
    private static let ringRect = NSRect(x: nextRect.minX + 9, y: nextRect.midY - 8, width: 16, height: 16)
    private static let ringStroke: CGFloat = 2
    // At 14 pt, two digits plus the unit occupy just over 28 pt.
    private static let countdownRect = NSRect(x: ringRect.maxX + 6, y: 0, width: 30, height: nextRect.height)
    static let nextContentRect = ringRect.insetBy(dx: -ringStroke / 2, dy: 0).union(countdownRect)
    private let result = NSTextField(labelWithString: "—")
    private var timeline: ProbeLaneTimeline?
    private var laneName = ""
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.resultRect.height))
        result.font = font
        result.alignment = .center
        result.frame = NSRect(x: Self.resultRect.minX, y: 5, width: Self.resultRect.width, height: 24)
        result.lineBreakMode = .byTruncatingTail
        addSubview(result)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        addToolTip(Self.waitRect.union(Self.nextRect), owner: self, userData: nil)
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ timing: ProbeLaneTimeline?, name: String, enabled: Bool) {
        timeline = timing
        laneName = name
        let reading = enabled ? timing?.result : nil
        result.stringValue = reading?.text ?? "—"
        result.textColor = switch reading {
        case .success(let elapsed): elapsed > 0.8 ? HoverPalette.warning : .labelColor
        case .timedOut, .wrongStatus, .failed, .dnsFailed, .connectionRefused, .connectionFailed: HoverPalette.warning
        case .checking, .waiting, nil: .labelColor
        }
        result.toolTip = reading?.spoken
        setAccessibilityLabel(name)
        needsDisplay = true
    }

    func liveWaitDetail(at now: TimeInterval) -> String? {
        guard let timeline, !timeline.starts.isEmpty else { return nil }
        return ([laneName] + timeline.waits(at: now)).joined(separator: "　·　")
    }

    override func accessibilityValue() -> Any? {
        [result.stringValue, timeline?.detail(at: ProcessInfo.processInfo.systemUptime)].compactMap { $0 }.joined(separator: "，")
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                    userData: UnsafeMutableRawPointer?) -> String {
        guard let timeline else { return "" }
        return laneName + "\n" + timeline.detail(at: ProcessInfo.processInfo.systemUptime)
    }

    private func drawText(_ text: String, in rect: NSRect, alignment: NSTextAlignment = .left, compactIfNeeded: Bool = false) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.secondaryLabelColor.cgColor
        ]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        if compactIfNeeded, CTLineGetTypographicBounds(line, nil, nil, nil) > rect.width {
            attributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        if CTLineGetTypographicBounds(line, nil, nil, nil) > rect.width {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(line, Double(rect.width), .end, ellipsis) ?? line
        }
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let x = switch alignment {
        case .center: rect.midX - ink.midX
        case .right: rect.maxX - ink.maxX
        default: rect.minX
        }
        context.saveGState()
        context.clip(to: rect)
        context.textMatrix = .identity
        context.textPosition = NSPoint(x: x, y: rect.midY - ink.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func countdown(_ remaining: TimeInterval) -> String {
        let seconds = ceil(remaining)
        if seconds < 1000 { return String(format: "%.0f s", seconds) }
        if seconds < 3600 { return String(format: "%.0f m", ceil(seconds / 60)) }
        if seconds < 86_400 { return String(format: "%.0f h", ceil(seconds / 3600)) }
        return String(format: "%.0f d", ceil(seconds / 86_400))
    }

    private func fill(_ rect: NSRect, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).fill()
    }

    private func tint(age: Double, warning: Double, cutoff: Double) -> NSColor {
        let cool = NSColor.systemTeal.blended(withFraction: 0.45, of: .secondaryLabelColor) ?? .systemTeal
        if age < warning && warning < cutoff {
            return cool.blended(withFraction: age / warning, of: .systemOrange) ?? cool
        }
        if warning == cutoff {
            return cool.blended(withFraction: age / cutoff, of: .systemRed) ?? cool
        }
        return NSColor.systemOrange.blended(withFraction: (age - warning) / (cutoff - warning), of: .systemRed) ?? .systemRed
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let timeline else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !timeline.starts.isEmpty {
            let track = NSRect(x: Self.waitRect.minX + 3, y: Self.waitRect.midY - 2.5, width: 55, height: 5)
            let cutoff = Double(timeline.settings.cutoff), warning = Double(timeline.settings.warning)
            fill(track, color: .quaternaryLabelColor)
            for start in timeline.starts {
                let age = timeline.elapsed(since: start, at: now)
                let segment = NSRect(x: track.minX, y: track.minY, width: max(1, track.width * age / cutoff), height: track.height)
                fill(segment, color: tint(age: age, warning: warning, cutoff: cutoff))
            }
            NSColor.secondaryLabelColor.setFill()
            NSRect(x: track.minX + (track.width - 1) * warning / cutoff, y: track.midY - 5, width: 1, height: 10).fill()
            if timeline.starts.count > 1 {
                let count = timeline.starts.count > 9 ? "×9+" : "×\(timeline.starts.count)"
                let x = track.maxX + 3
                drawText(count, in: NSRect(x: x, y: 0, width: Self.waitRect.maxX - x, height: Self.waitRect.height))
            }
        }

        if timeline.waitingForSlot(at: now) {
            drawText("等空位", in: Self.nextContentRect, alignment: .center)
            return
        }
        let remaining = timeline.remaining(at: now)
        let circle = Self.ringRect
        let ring = NSBezierPath(ovalIn: circle)
        ring.lineWidth = Self.ringStroke
        NSColor.quaternaryLabelColor.setStroke()
        ring.stroke()
        let fraction = min(1, remaining / Double(timeline.settings.interval))
        if fraction > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2, startAngle: 90,
                          endAngle: 90 - fraction * 360, clockwise: true)
            arc.lineWidth = ring.lineWidth
            NSColor.controlAccentColor.setStroke()
            arc.stroke()
        }
        drawText(countdown(remaining), in: Self.countdownRect, alignment: .right, compactIfNeeded: true)
    }
}
