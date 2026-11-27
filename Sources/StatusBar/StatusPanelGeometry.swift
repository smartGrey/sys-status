import Foundation

enum StatusPanelGeometry {
    static func menuAnchor(at point: CGPoint, replica: CGRect?, visibleFrame: CGRect) -> CGRect {
        if let replica, replica.contains(point) { return replica }
        return CGRect(x: point.x, y: visibleFrame.maxY, width: 0, height: 0)
    }

    static func top(under anchor: CGRect, within screen: CGRect) -> CGFloat {
        min(anchor.minY, screen.maxY) - 4
    }

    static func frame(size: CGSize, under anchor: CGRect, within screen: CGRect, trailing: Bool = false) -> CGRect {
        let top = top(under: anchor, within: screen)
        let width = min(size.width, screen.width)
        let height = min(size.height, max(0, top - screen.minY))
        let origin = trailing ? anchor.maxX - width : anchor.midX - width / 2
        return CGRect(x: min(max(origin, screen.minX), screen.maxX - width),
                      y: top - height, width: width, height: height)
    }

    static func pinnedFrame(size: CGSize, previous: CGRect, within screen: CGRect) -> CGRect {
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        return CGRect(x: min(max(previous.minX, screen.minX), screen.maxX - width),
                      y: min(max(previous.maxY - height, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }
}
