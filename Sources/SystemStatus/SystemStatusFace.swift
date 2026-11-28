import AppKit
import CoreText

@MainActor
struct SystemStatusFace: Equatable {
    private struct MetricText: Equatable {
        let metric: StatusMetric
        let value: String
        let color: MetricColor
        let labelWidth: CGFloat
    }
    private struct BatteryBadge: Equatable {
        let percent: Int?
        let number: String
        let desktop: Bool
        let watts: Int?
        let plugged: Bool
        let powerMode: BatteryPowerMode

        var powerText: String? {
            watts.map { ($0 < 0 ? "−" : "") + String(abs($0)) + "W" }
        }
    }
    private enum Content: Equatable {
        case battery(BatteryBadge)
        case text(MetricText)
    }
    private struct Slot: Equatable {
        let content: Content
        let x: CGFloat
        let width: CGFloat
    }
    private let slots: [Slot]
    let width: CGFloat
    private static let batteryFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let batteryBaselineOffset = NSLayoutManager().defaultBaselineOffset(for: batteryFont)
    private static let labelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let batteryInset: CGFloat = 5
    private static let dotSpace: CGFloat = 6
    private static let labelGap: CGFloat = 1.5
    private static let metricGap: CGFloat = 4

    init(reading: SystemReading, metrics: [StatusIndicator], colors: [String: MetricColor] = [:]) {
        var slots: [Slot] = []
        var edge: CGFloat = 0
        for (index, indicator) in metrics.enumerated() {
            let content: Content
            let itemWidth: CGFloat
            switch indicator {
            case .battery:
                let battery = reading.battery
                let number = battery?.percent.map(String.init) ?? "—"
                let desktop = reading.hasBattery == false
                let watts = battery?.statusBarWatts
                let plugged = battery?.connected == true && watts == nil
                let badge = BatteryBadge(percent: battery?.percent, number: number, desktop: desktop,
                                         watts: watts, plugged: plugged, powerMode: battery?.powerMode ?? .automatic)
                let extra = badge.powerText.map { Self.dotSpace + Self.measure($0, Self.batteryFont) } ?? (plugged ? 11 : 0)
                itemWidth = desktop ? 18 : 2 * Self.batteryInset + Self.measure(number, Self.batteryFont) + extra
                content = .battery(badge)
            case .metric(let metric):
                let value = reading.statusValue(metric)
                let labelWidth = Self.measure(metric.abbreviation, Self.labelFont)
                let valueWidth = Self.measure(value, Self.valueFont)
                content = .text(MetricText(metric: metric, value: value, color: colors[metric.rawValue] ?? .standard(for: metric),
                                           labelWidth: labelWidth))
                itemWidth = labelWidth + Self.labelGap + valueWidth
            }
            if index > 0 {
                // The battery outline reaches its edge. Give it one extra point on either inside boundary.
                let touchesBattery = indicator == .battery || metrics[index - 1] == .battery
                edge += Self.metricGap + (touchesBattery ? 1 : 0)
            }
            slots.append(Slot(content: content, x: edge, width: itemWidth))
            edge += itemWidth
        }
        self.slots = slots
        width = edge
    }
    private static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    var spoken: String {
        slots.map { slot in
            switch slot.content {
            case .battery(let badge):
                if badge.desktop { return "系统状态" }
                let mode = switch badge.powerMode {
                case .automatic: ""
                case .low: "低电量模式，"
                case .high: "高电量模式，"
                }
                let level = mode + "电池 " + (badge.percent.map { "\($0)%" } ?? "未知")
                if let watts = badge.watts {
                    return level + (watts < 0 ? "，已接电，电池放电 " : "，充电 ") + "\(abs(watts))W"
                }
                return badge.plugged ? level + "，已接电" : level
            case .text(let text):
                return text.metric.title + " " + text.value
            }
        }.joined(separator: "，")
    }

    static func batteryTint(_ percent: Int, dark: Bool) -> NSColor {
        let stops = [(12, 0xF53B45), (25, 0xFF9235), (38, 0xFFCA38),
                     (50, 0xC2DE50), (75, 0xB7E449), (100, 0x2ED96B)]
        let level = min(100, max(0, percent))
        let upper = stops.firstIndex { level <= $0.0 } ?? stops.count - 1
        let (low, left) = stops[max(0, upper-1)]
        let (high, right) = stops[upper]
        let fraction = high > low ? CGFloat(level-low)/CGFloat(high-low) : 0
        func channel(_ shift: Int) -> CGFloat {
            let a = CGFloat((left >> shift) & 255), b = CGFloat((right >> shift) & 255)
            return (a + fraction * (b-a)) / 255
        }
        let middle = sin(.pi * CGFloat(level) / 100)
        return NSColor(srgbRed: channel(16), green: channel(8), blue: channel(0),
                       alpha: dark ? 0.40 + 0.34 * middle : 0.67 + 0.09 * middle)
    }

    private static func batteryOutline(_ mode: BatteryPowerMode, dark: Bool) -> NSColor {
        switch mode {
        case .automatic:
            .labelColor.withAlphaComponent(0.72)
        case .low:
            dark ? NSColor(srgbRed: 1, green: 0.78, blue: 0.27, alpha: 1)
                 : NSColor(srgbRed: 0.65, green: 0.39, blue: 0.03, alpha: 1)
        case .high:
            dark ? NSColor(srgbRed: 0.39, green: 0.69, blue: 1, alpha: 1)
                 : NSColor(srgbRed: 0.11, green: 0.40, blue: 0.76, alpha: 1)
        }
    }

    private static func drawBatteryText(_ value: String, atX x: CGFloat, midY: CGFloat,
                                        ink: NSColor, edge: NSColor, in context: CGContext) {
        let font = batteryFont
        let height = (value as NSString).size(withAttributes: [.font: font]).height
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]))
        let baseline = CGPoint(x: x, y: midY + height / 2 - batteryBaselineOffset)
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        // Paint the rounded outline first so the solid fill retains the original weight.
        context.setLineJoin(.round)
        context.setLineWidth(1.9)
        context.setStrokeColor(edge.cgColor)
        context.textPosition = baseline
        context.setTextDrawingMode(.stroke)
        CTLineDraw(line, context)
        context.setFillColor(ink.cgColor)
        context.textPosition = baseline
        context.setTextDrawingMode(.fill)
        CTLineDraw(line, context)
    }

    private static func drawPlug(in rect: NSRect, ink: NSColor, edge: NSColor) {
        guard let plug = NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: nil) else { return }
        let outline = plug.withSymbolConfiguration(.init(paletteColors: [edge]))
        for (dx, dy) in [(-0.85, 0.0), (0.85, 0.0), (0.0, -0.85), (0.0, 0.85)] {
            outline?.draw(in: rect.offsetBy(dx: dx, dy: dy))
        }
        plug.withSymbolConfiguration(.init(paletteColors: [ink]))?.draw(in: rect)
    }

    func image() -> NSImage {
        NSImage(size: NSSize(width: width, height: 20), flipped: false) { bounds in
            func text(_ value: String, font: NSFont, color: NSColor, x: CGFloat) {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let string = value as NSString
                string.draw(at: NSPoint(x: x, y: (bounds.height-string.size(withAttributes: attrs).height)/2), withAttributes: attrs)
            }
            func symbol(_ name: String, in rect: NSRect, ink: NSColor = .labelColor) {
                let color = NSImage.SymbolConfiguration(paletteColors: [ink])
                NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(color)?.draw(in: rect)
            }
            let labelAlpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.94 : 0.84
            for slot in slots {
                switch slot.content {
                case .text(let metric):
                    let color = metric.color.color
                    text(metric.metric.abbreviation, font: Self.labelFont, color: color.withAlphaComponent(labelAlpha), x: slot.x)
                    text(metric.value, font: Self.valueFont, color: color, x: slot.x + metric.labelWidth + Self.labelGap)
                case .battery(let badge):
                    if badge.desktop {
                        symbol("cpu", in: NSRect(x: slot.x, y: 1, width: 18, height: 18))
                        continue
                    }
                    let box = NSRect(x: slot.x + 0.5, y: 1, width: slot.width-1, height: 18)
                    let outline = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
                    let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    Self.batteryOutline(badge.powerMode, dark: dark).setStroke()
                    outline.stroke()
                    if let percent = badge.percent {
                        let track = box.insetBy(dx: 1.3, dy: 1.3)
                        let filled = NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(percent)/100, height: track.height)
                        NSGraphicsContext.saveGraphicsState()
                        NSBezierPath(roundedRect: track, xRadius: 2.8, yRadius: 2.8).addClip()
                        NSBezierPath(rect: filled).addClip()
                        Self.batteryTint(percent, dark: dark).setFill()
                        track.fill()
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    let ink: NSColor = dark ? .white : .black
                    let edge = (dark ? NSColor.black : .white).withAlphaComponent(0.92)
                    guard let context = NSGraphicsContext.current?.cgContext else { continue }
                    let start = slot.x + Self.batteryInset
                    Self.drawBatteryText(badge.number, atX: start, midY: bounds.midY,
                                         ink: ink, edge: edge, in: context)
                    let end = start + Self.measure(badge.number, Self.batteryFont)
                    if let watts = badge.powerText {
                        let dot = NSRect(x: end + 2, y: 9, width: 2, height: 2)
                        edge.setFill()
                        NSBezierPath(ovalIn: dot.insetBy(dx: -0.9, dy: -0.9)).fill()
                        ink.setFill()
                        NSBezierPath(ovalIn: dot).fill()
                        Self.drawBatteryText(watts, atX: end + Self.dotSpace, midY: bounds.midY,
                                             ink: ink, edge: edge, in: context)
                    } else if badge.plugged {
                        Self.drawPlug(in: NSRect(x: end + 2, y: 4.5, width: 9, height: 11),
                                      ink: ink, edge: edge)
                    }
                }
            }
            return true
        }
    }
}
