import AppKit

@MainActor
struct StopwatchStatusFace {
    static let leadingGap: CGFloat = 8
    private static let gap: CGFloat = 3
    private static let padding: CGFloat = 5
    private static let height: CGFloat = 19
    private static let focusMarkerSize = NSSize(width: 3, height: 11)
    private static let nameFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    private struct Label: Equatable {
        let id: UUID
        let name: String
        let time: String
        let state: State
        let focused: Bool
        let width: CGFloat
    }

    private enum State {
        case ready, running, paused

        init(_ reading: StopwatchReading) {
            self = reading.isRunning ? .running : reading.canReset ? .paused : .ready
        }

        var description: String {
            switch self {
            case .ready: "待开始"
            case .running: "计时中"
            case .paused: "已暂停"
            }
        }
    }

    struct FocusTransition {
        let from: [CGFloat]
        let to: [CGFloat]
        let start: TimeInterval

        func amounts(at time: TimeInterval) -> [CGFloat]? {
            let progress = CGFloat(max(0, time - start) / 0.14)
            guard progress < 1 else { return nil }
            let eased = progress * progress * (3 - 2 * progress)
            return zip(from, to).map { old, new in old + (new - old) * eased }
        }
    }

    private let labels: [Label]
    var focusAmounts: [CGFloat] { labels.map { $0.focused ? 1 : 0 } }
    let width: CGFloat
    let accessibilityValue: String

    init(_ presentation: StopwatchPresentation) {
        let multiple = presentation.readings.count > 1
        labels = presentation.readings.map { reading in
            let name = multiple && !reading.name.isEmpty ? reading.name + ":" : ""
            let nameWidth = (name as NSString).size(withAttributes: [.font: Self.nameFont]).width
            let timeWidth = (reading.time.compact as NSString).size(withAttributes: [.font: Self.timeFont]).width
            return Label(id: reading.id, name: name, time: reading.time.compact, state: State(reading),
                         focused: multiple && reading.id == presentation.focus,
                         width: ceil(nameWidth + timeWidth) + 2 * Self.padding)
        }
        let markerWidth = multiple ? Self.focusMarkerSize.width : 0
        width = labels.map(\.width).reduce(0, +) + CGFloat(max(0, labels.count - 1)) * Self.gap + markerWidth
        accessibilityValue = presentation.readings.enumerated().map { index, reading in
            let name = reading.name.isEmpty ? "秒表\(index + 1)" : reading.name
            let focus = multiple && reading.id == presentation.focus ? "，快捷键焦点" : ""
            return "\(name)，\(reading.seconds) 秒，\(State(reading).description)\(focus)"
        }.joined(separator: "；")
    }

    func hasSameLabels(as other: StopwatchStatusFace?) -> Bool { labels == other?.labels }

    func sharesTimerOrder(with other: StopwatchStatusFace) -> Bool {
        labels.map(\.id) == other.labels.map(\.id)
    }

    func combinedImage(with network: NSImage, focusAmounts: [CGFloat]? = nil) -> NSImage {
        let size = NSSize(width: network.size.width + Self.leadingGap + width, height: network.size.height)
        let amounts = focusAmounts ?? self.focusAmounts
        return NSImage(size: size, flipped: false) { bounds in
            let networkBounds = NSRect(x: bounds.minX, y: bounds.minY, width: network.size.width, height: bounds.height)
            network.draw(in: networkBounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            drawLabels(at: networkBounds.maxX + Self.leadingGap, midY: bounds.midY, focusAmounts: amounts)
            return true
        }
    }

    private func drawLabels(at origin: CGFloat, midY: CGFloat, focusAmounts: [CGFloat]) {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var x = origin
        for (label, amount) in zip(labels, focusAmounts) {
            let extra = Self.focusMarkerSize.width * amount
            let box = NSRect(x: x, y: midY - Self.height / 2, width: label.width + extra, height: Self.height)
            let shape = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            let fill: NSColor
            let foreground: NSColor
            switch label.state {
            case .ready:
                foreground = .labelColor
                fill = foreground.withAlphaComponent(dark ? 0.19 : 0.13)
            case .running:
                fill = NSColor(srgbRed: 0.29, green: 0.85, blue: 0.48, alpha: 0.96)
                foreground = NSColor(srgbRed: 0.04, green: 0.17, blue: 0.09, alpha: 1)
            case .paused:
                fill = NSColor(srgbRed: 1, green: 0.79, blue: 0.28, alpha: 0.96)
                foreground = NSColor(srgbRed: 0.20, green: 0.13, blue: 0.02, alpha: 1)
            }
            fill.setFill()
            shape.fill()
            if amount > 0 {
                let size = Self.focusMarkerSize
                let marker = NSRect(x: box.minX + Self.padding - 2, y: midY - size.height / 2,
                                    width: size.width, height: size.height)
                foreground.withAlphaComponent(amount).setFill()
                NSBezierPath(roundedRect: marker, xRadius: size.width / 2, yRadius: size.width / 2).fill()
            }
            let text = NSMutableAttributedString(string: label.name, attributes: [.font: Self.nameFont, .foregroundColor: foreground])
            text.append(NSAttributedString(string: label.time, attributes: [.font: Self.timeFont, .foregroundColor: foreground]))
            let textHeight = text.size().height
            text.draw(at: NSPoint(x: x + Self.padding + extra, y: midY - textHeight / 2))
            x = box.maxX + Self.gap
        }
    }
}
