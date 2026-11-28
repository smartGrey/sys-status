import AppKit

@MainActor
struct SystemStatusFace: Equatable {
    private let percent: Int?
    private let charging: Bool
    private let connected: Bool
    private let desktop: Bool
    private let watts: String
    private let metrics: [StatusMetric]
    private let values: [String]
    private static let small = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let normal = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let caption = NSFont.systemFont(ofSize: 8, weight: .medium)

    init(reading: SystemReading, metrics: [StatusMetric]) {
        percent = reading.battery?.percent
        desktop = reading.hasBattery == false
        charging = reading.battery?.charging == true
        connected = reading.battery?.connected == true
        watts = reading.battery?.watts.flatMap { $0 >= 0 ? "\(Int($0.rounded()))W" : nil } ?? "—W"
        self.metrics = metrics
        values = metrics.map(reading.statusValue)
    }
    private var bodyWidth: CGFloat { desktop ? 18 : charging ? 67 : 34 }
    private func metricWidth(_ metric: StatusMetric, value: String) -> CGFloat {
        let sample = metric.isTemperature ? "100°" : metric == .disk ? "D 999G" : metric.abbreviation + " 100%"
        return ceil(max(Self.measure(sample, Self.small), Self.measure(metric.isTemperature ? value : metric.abbreviation + " " + value, Self.small),
                        metric.isTemperature ? Self.measure(metric.abbreviation, Self.caption) : 0))
    }
    private nonisolated static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
    var width: CGFloat {
        zip(metrics, values).reduce(bodyWidth + (desktop ? 0 : 3)) { $0 + 4 + metricWidth($1.0, value: $1.1) }
    }
    var spoken: String {
        var parts = [desktop ? "系统状态" : "电池 " + (percent.map { "\($0)%" } ?? "未知")]
        if charging { parts.append("充电 " + watts) } else if connected { parts.append("已接电") }
        parts += zip(metrics, values).map { $0.title + " " + $1 }
        return parts.joined(separator: "，")
    }

    func image() -> NSImage {
        NSImage(size: NSSize(width: width, height: 20), flipped: false) { _ in
            func text(_ string: String, _ font: NSFont, x: CGFloat, width: CGFloat, y: CGFloat) {
                let origin = NSPoint(x: x + (width - Self.measure(string, font)) / 2, y: y)
                (string as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
            }
            func symbol(_ name: String, in rect: NSRect) {
                let color = NSImage.SymbolConfiguration(paletteColors: [.labelColor])
                NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(color)?.draw(in: rect)
            }
            if desktop {
                symbol("cpu", in: NSRect(x: 0, y: 1, width: 18, height: 18))
            } else {
                let box = NSRect(x: 0.6, y: 2, width: bodyWidth-1, height: 16)
                let outline = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
                NSColor.labelColor.withAlphaComponent(0.72).setStroke()
                outline.lineWidth = 1.1
                outline.stroke()
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: bodyWidth+0.6, y: 7, width: 2, height: 6), xRadius: 1, yRadius: 1).fill()
                if let percent {
                    let track = box.insetBy(dx: 1.5, dy: 1.5)
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: track, xRadius: 2.6, yRadius: 2.6).addClip()
                    let tint: NSColor = charging ? .systemGreen : percent <= 15 ? .systemRed : .labelColor
                    tint.withAlphaComponent(charging || percent <= 15 ? 0.48 : 0.20).setFill()
                    NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(percent)/100, height: track.height).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                let number = percent.map(String.init) ?? "—"
                let value = charging ? number + " · " + watts : number
                text(value, connected ? Self.small : Self.normal, x: connected && !charging ? 1.5 : 0, width: bodyWidth - (connected && !charging ? 12 : 0), y: connected ? 3.5 : 2.2)
                if connected && !charging {
                    symbol("powerplug.fill", in: NSRect(x: bodyWidth - 10, y: 5, width: 8, height: 10))
                }
            }
            var x = bodyWidth + (desktop ? 0 : 3)
            for (metric, value) in zip(metrics, values) {
                let width = metricWidth(metric, value: value)
                x += 4
                if metric.isTemperature {
                    text(metric.abbreviation, Self.caption, x: x, width: width, y: 9.2)
                    text(value, Self.small, x: x, width: width, y: -1.4)
                } else {
                    text(metric.abbreviation + " " + value, Self.small, x: x, width: width, y: 3.5)
                }
                x += width
            }
            return true
        }
    }
}
