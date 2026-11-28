import AppKit
import SwiftUI

/// Each status region owns one copy of its content. StatusPanelShell owns its presentation lifetime.
@MainActor
struct PanelContent {
    var show: (NSRect, NSScreen, Bool) -> StatusPanelWindow?
    var close: () -> Void
    var follow: (NSRect, NSScreen) -> Void
    var isEditing: () -> Bool = { false }
}

@MainActor
class StatusPanelWindow: NSPanel {
    var togglePinned: (() -> Void)?
    var beginPinning: (() -> Void)?
    var dismissPanel: (() -> Void)?
    var pinChanged: ((Bool) -> Void)?
    var protectsInteraction: () -> Bool = { false }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismissPanel?() }

    func place(size: NSSize, under anchor: NSRect, on screen: NSScreen, trailing: Bool = false) {
        let bounds = (isMovable ? self.screen ?? screen : screen).visibleFrame.insetBy(dx: 8, dy: 0)
        let rect = isMovable ? StatusPanelGeometry.pinnedFrame(size: size, previous: frame, within: bounds)
            : StatusPanelGeometry.frame(size: size, under: anchor, within: bounds, trailing: trailing)
        if frame != rect { setFrame(rect, display: true) }
    }
}

@MainActor
final class PanelPinButton: NSButton {
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        imagePosition = .imageOnly
        target = self
        action = #selector(pin)
        update(false)
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func pin() { (window as? StatusPanelWindow)?.togglePinned?() }
    func update(_ pinned: Bool) {
        state = pinned ? .on : .off
        isBordered = pinned
        image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
        toolTip = pinned ? "取消固定" : "固定在最前"
        setAccessibilityLabel(toolTip)
    }
}

@MainActor
class PanelDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var start: (point: NSPoint, origin: NSPoint)?
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        start = (Self.screenPoint(event, in: window), window.frame.origin)
    }
    override func mouseUp(with event: NSEvent) { start = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let panel = window as? StatusPanelWindow else { return }
        let point = Self.screenPoint(event, in: panel)
        let dx = point.x - start.point.x
        let dy = point.y - start.point.y
        guard abs(dx) + abs(dy) >= 3 || panel.isMovable else { return }
        panel.beginPinning?()
        panel.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }
    static func screenPoint(_ event: NSEvent, in window: NSWindow) -> NSPoint {
        guard let point = event.cgEvent?.location, let primary = NSScreen.screens.first else {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSPoint(x: point.x, y: primary.frame.maxY - point.y)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

struct PanelDragBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> PanelDragView { PanelDragView() }
    func updateNSView(_ nsView: PanelDragView, context: Context) {}
}

/// A purely SwiftUI gesture (for example the custom threshold slider) has no NSControl.
struct PanelControlRegion: NSViewRepresentable {
    final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ nsView: Marker, context: Context) {}
}

/// A shared draggable header leaves controls, text editors and scroll views in their native responder chains.
@MainActor
final class PanelChrome: NSView {
    static let headerHeight: CGFloat = 36
    let body: NSView
    private let header = PanelDragView()
    let pin = PanelPinButton()
    private let title: NSTextField
    private let accessory: NSView?
    private let leadingControl: NSView?
    init(title: String, body: NSView, window: StatusPanelWindow, accessory: NSView? = nil, leadingControl: NSView? = nil) {
        self.leadingControl = leadingControl
        self.accessory = accessory
        self.body = body
        self.title = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        let material = NSVisualEffectView()
        material.material = .popover
        material.state = .active
        material.frame = bounds
        material.autoresizingMask = [.width, .height]
        addSubview(material)
        self.title.font = .systemFont(ofSize: 14, weight: .semibold)
        for view in [body, self.title, header, pin] { addSubview(view) }
        if let accessory { addSubview(accessory) }
        if let leadingControl { addSubview(leadingControl) }
        self.title.isHidden = title.isEmpty
        window.pinChanged = { [weak pin] in pin?.update($0) }
        window.contentView = self
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTest(point, primaryClick: NSApp.currentEvent?.type == .leftMouseDown)
    }

    func hitTest(_ point: NSPoint, primaryClick: Bool) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard primaryClick, hit.isDescendant(of: body),
              !(hit is PanelDragView), !(hit is NSControl), !(hit is NSTextView) else { return hit }
        // Hosting/scroll views can return their container for a click on an embedded
        // background. Resolve only explicitly marked surfaces. Keep native controls,
        // custom gestures, scroll events and tooltip tracking on their original path.
        let local = body.convert(point, from: superview)
        var background: PanelDragView?
        func locate(in view: NSView) -> Bool {
            let point = view.convert(local, from: body)
            guard !view.isHidden, view.visibleRect.contains(point) else { return false }
            // Hosting views can report a visible rect larger than their bounds.
            // Only the actual control or drag surface should claim this point.
            if !view.bounds.contains(point), view is PanelControlRegion.Marker || view is PanelDragView {
                return false
            }
            if view is PanelControlRegion.Marker { return true }
            if let drag = view as? PanelDragView { background = drag; return false }
            return view.subviews.reversed().contains(where: locate)
        }
        return locate(in: body) ? hit : background ?? hit
    }

    override func layout() {
        super.layout()
        let h = Self.headerHeight
        header.frame = NSRect(x: 0, y: bounds.height-h, width: bounds.width, height: h)
        pin.frame = NSRect(x: bounds.width-44, y: bounds.height-h+4, width: 30, height: 28)
        var titleRight = pin.frame.minX
        if let accessory {
            let size = accessory.fittingSize
            accessory.frame = NSRect(x: pin.frame.minX - 8 - size.width, y: header.frame.midY - size.height / 2,
                                     width: size.width, height: size.height)
            titleRight = accessory.frame.minX
        }
        title.frame = NSRect(x: 16, y: header.frame.midY - 10, width: max(0, titleRight - 22), height: 20)
        if let leadingControl {
            let size = leadingControl.intrinsicContentSize
            leadingControl.frame = NSRect(x: 16, y: header.frame.midY - size.height/2, width: size.width, height: size.height)
        }
        body.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0,bounds.height-h))
    }
}
