import AppKit
import CoreText

@MainActor
struct StatusFace {
    private let digits: NSFont
    private let units: NSFont
    private let arrowColumn: CGFloat = 4
    private let numberEnd: CGFloat
    let width: CGFloat

    init() {
        digits = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        units = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        let gap: CGFloat = 1
        numberEnd = arrowColumn + gap + ceil(("999" as NSString).size(withAttributes: [.font: digits]).width)
        width = numberEnd + gap + ceil(("M" as NSString).size(withAttributes: [.font: units]).width)
    }

    func image(upload: RateText, download: RateText, reachable: Bool) -> NSImage {
        let size = NSSize(width: width, height: 20)
        // All three displays use 2x backing. Rasterize once so AppKit can use
        // the same glyph mask for active and inactive menu bar replicas.
        let scale = 2
        let context = CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale,
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        func draw(_ text: String, _ font: NSFont, _ x: CGFloat, _ baseline: CGFloat, right: Bool = false) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.textPosition = CGPoint(x: right ? x - advance : x, y: baseline)
            CTLineDraw(line, context)
        }
        // Keep the round caps within the four-point arrow column.
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        func arrow(tip: CGFloat, direction: CGFloat) {
            context.move(to: CGPoint(x: 0.75, y: tip - direction * 2.5))
            context.addLine(to: CGPoint(x: 3.25, y: tip))
            context.addLine(to: CGPoint(x: 3.25, y: tip - direction * 6.5))
            context.strokePath()
        }
        arrow(tip: 18.5, direction: 1)
        arrow(tip: 1.5, direction: -1)
        for (rate, baseline) in [(upload, 11.5), (download, 1.5)] {
            draw(rate.value, digits, numberEnd, baseline, right: true)
            draw(rate.unit, units, numberEnd + 1, baseline)
        }
        let mask = context.makeImage()!
        // Resolve the foreground in each menu bar's drawing appearance. A
        // template status image receives an additional inactive tint on this Mac.
        return NSImage(size: size, flipped: false) { bounds in
            guard let target = NSGraphicsContext.current?.cgContext else { return false }
            target.saveGState()
            target.clip(to: bounds, mask: mask)
            let (arrows, text) = bounds.divided(atDistance: bounds.width * arrowColumn / size.width, from: .minXEdge)
            let foreground = NSColor.labelColor.withAlphaComponent(1)
            (reachable ? NSColor.systemGreen : foreground).setFill()
            target.fill(arrows)
            foreground.setFill()
            target.fill(text)
            target.restoreGState()
            return true
        }
    }
}
