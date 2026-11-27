import AppKit
import Combine

struct MeterState: Equatable {
    var level: Double = 0
    var active = false
    var passing = false
    var calibrationProgress: Double = 0
}

/// Only the live track/progress view observes this object, never the whole panel.
@MainActor
final class PanelMeter: ObservableObject {
    @Published private(set) var state = MeterState()
    private var latest = MeterState()
    private(set) var isVisible = false

    func accept(_ value: MeterState) {
        latest = value
        if isVisible && state != value { state = value }
    }
    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible && state != latest { state = latest }
    }
}

struct StatusIconState: Hashable {
    let enabled: Bool
    let passing: Bool
    let bars: Int

    init(enabled: Bool, passing: Bool, level: Double) {
        self.enabled = enabled
        self.passing = enabled && passing
        let fraction = level.isFinite ? max(0, min(1, (level - 3) / 27)) : 0
        bars = enabled ? Int(ceil(fraction * 4)) : 0
    }
}

struct HearingPresentation: Equatable {
    let icon: StatusIconState
    let title: String
}

enum RuntimePolling {
    static func interval(active: Bool, sleeping: Bool) -> TimeInterval? {
        sleeping ? nil : active ? 0.125 : 1
    }
}

extension StatusIconState {
    static let size = NSSize(width: 16, height: 18)

    func image() -> NSImage {
        let bars = bars, enabled = enabled, passing = passing
        let image = NSImage(size: Self.size, flipped: false) { rect in
            let heights: [CGFloat] = [6, 11, 16, 9]
            for (index, height) in heights.enumerated() {
                let illuminated = index < bars
                let color = passing ? NSColor.systemGreen : NSColor.labelColor
                color.withAlphaComponent(illuminated ? 1 : passing ? 0.65 : enabled ? 0.35 : 0.5).setFill()
                NSBezierPath(roundedRect: NSRect(x: CGFloat(index)*4.0 + 0.75, y: (rect.height-height)/2,
                                                width: 2.5, height: height), xRadius: 1.2, yRadius: 1.2).fill()
            }
            if !enabled {
                NSColor.labelColor.setStroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 1, y: 2)); slash.line(to: NSPoint(x: 15, y: 16))
                slash.lineWidth = 1.3; slash.stroke()
            }
            return true
        }
        image.isTemplate = !passing
        return image
    }
}
