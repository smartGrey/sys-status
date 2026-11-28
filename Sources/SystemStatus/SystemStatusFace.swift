import AppKit

@MainActor
struct SystemStatusFace: Equatable {
    private struct MetricText: Equatable {
        let metric: StatusMetric
        let value: String
        let color: MetricColor
        let labelWidth: CGFloat
        let valueWidth: CGFloat
    }
    private let percent: Int?
    private let desktop: Bool
    private let watts: String?
    private let plugged: Bool
    private let metrics: [MetricText]
    private let number: String
    private let bodyWidth: CGFloat
    let width: CGFloat
    private static let batteryFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let labelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let batteryInset: CGFloat = 3
    private static let dotSpace: CGFloat = 6
    private static let labelGap: CGFloat = 1.5

    init(reading: SystemReading, metrics: [StatusMetric], colors: [String: MetricColor] = [:]) {
        let battery = reading.battery
        percent = battery?.percent
        number = percent.map(String.init) ?? "—"
        desktop = reading.hasBattery == false
        watts = battery?.isActivelyCharging == true ?
            (battery?.watts.flatMap { $0 >= 0 ? "\(Int($0.rounded()))W" : nil } ?? "—W") : nil
        plugged = battery?.connected == true && watts == nil
        let extra = watts.map { Self.dotSpace + Self.measure($0, Self.batteryFont) } ?? (plugged ? 11 : 0)
        bodyWidth = desktop ? 18 : 2 * Self.batteryInset + Self.measure(number, Self.batteryFont) + extra
        self.metrics = metrics.map {
            let value = reading.statusValue($0)
            return MetricText(metric: $0, value: value, color: colors[$0.rawValue] ?? .standard(for: $0),
                              labelWidth: Self.measure($0.abbreviation, Self.labelFont), valueWidth: Self.measure(value, Self.valueFont))
        }
        width = self.metrics.enumerated().reduce(bodyWidth + (desktop ? 0 : 3)) {
            $0 + ($1.offset == 0 ? 3 : 4) + $1.element.labelWidth + Self.labelGap + $1.element.valueWidth
        }
    }
    private static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    var spoken: String {
        var parts = [desktop ? "系统状态" : "电池 " + (percent.map { "\($0)%" } ?? "未知")]
        if let watts { parts.append("充电 " + watts) } else if plugged { parts.append("已接电") }
        parts += metrics.map { $0.metric.title + " " + $0.value }
        return parts.joined(separator: "，")
    }

    private static func batteryTint(_ percent: Int) -> NSColor {
        let t = CGFloat(max(0, min(100, percent))) / 100
        let red = NSColor(srgbRed: 0.96, green: 0.23, blue: 0.27, alpha: 1)
        let amber = NSColor(srgbRed: 0.97, green: 0.69, blue: 0.18, alpha: 1)
        let green = NSColor(srgbRed: 0.18, green: 0.85, blue: 0.42, alpha: 1)
        return t <= 0.5 ? red.blended(withFraction: 2*t, of: amber) ?? red
                        : amber.blended(withFraction: 2*t-1, of: green) ?? green
    }

    func image() -> NSImage {
        NSImage(size: NSSize(width: width, height: 20), flipped: false) { bounds in
            func text(_ value: String, font: NSFont, color: NSColor, x: CGFloat) {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let string = value as NSString
                string.draw(at: NSPoint(x: x, y: (bounds.height-string.size(withAttributes: attrs).height)/2), withAttributes: attrs)
            }
            func symbol(_ name: String, in rect: NSRect) {
                let color = NSImage.SymbolConfiguration(paletteColors: [.labelColor])
                NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(color)?.draw(in: rect)
            }
            if desktop {
                symbol("cpu", in: NSRect(x: 0, y: 1, width: 18, height: 18))
            } else {
                let box = NSRect(x: 0.5, y: 1, width: bodyWidth-1, height: 18)
                let outline = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
                NSColor.labelColor.withAlphaComponent(0.72).setStroke()
                outline.stroke()
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: bodyWidth+0.5, y: 7, width: 2, height: 6), xRadius: 1, yRadius: 1).fill()
                if let percent {
                    let track = box.insetBy(dx: 1.3, dy: 1.3)
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: track, xRadius: 2.8, yRadius: 2.8).addClip()
                    let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    Self.batteryTint(percent).withAlphaComponent(dark ? 0.40 : 0.67).setFill()
                    NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(percent)/100, height: track.height).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                let start = Self.batteryInset
                text(number, font: Self.batteryFont, color: .labelColor, x: start)
                let end = start + Self.measure(number, Self.batteryFont)
                if let watts {
                    NSColor.labelColor.setFill()
                    NSBezierPath(ovalIn: NSRect(x: end + 2, y: 9, width: 2, height: 2)).fill()
                    text(watts, font: Self.batteryFont, color: .labelColor, x: end + Self.dotSpace)
                } else if plugged {
                    symbol("powerplug.fill", in: NSRect(x: end + 2, y: 4.5, width: 9, height: 11))
                }
            }
            var x = bodyWidth + (desktop ? 0 : 3)
            let labelAlpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.94 : 0.84
            for (index, metric) in metrics.enumerated() {
                x += index == 0 ? 3 : 4
                let color = metric.color.color
                text(metric.metric.abbreviation, font: Self.labelFont, color: color.withAlphaComponent(labelAlpha), x: x)
                x += metric.labelWidth + Self.labelGap
                text(metric.value, font: Self.valueFont, color: color, x: x)
                x += metric.valueWidth
            }
            return true
        }
    }
}
