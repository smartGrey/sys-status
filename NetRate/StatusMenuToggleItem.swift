import AppKit
import Carbon

/// Runs a menu command from an embedded control, which leaves native menu tracking active.
@MainActor
final class StatusMenuToggleItem: NSMenuItem {
    static func make(title: String, action: Selector?) -> StatusMenuToggleItem {
        let item = StatusMenuToggleItem(title: title, action: action, keyEquivalent: "")
        item.view = StatusMenuToggleRow(item: item)
        item.refreshRow()
        return item
    }

    func refreshRow() { (view as? StatusMenuToggleRow)?.refresh() }

    @discardableResult
    fileprivate func activate() -> Bool {
        guard isEnabled, let action, let target else { return false }
        return NSApp.sendAction(action, to: target, from: self)
    }

    func afterClosingMenu(_ present: @escaping @MainActor () -> Void) {
        guard view?.window != nil, var root = menu else {
            present()
            return
        }
        while let parent = root.supermenu { root = parent }
        root.cancelTrackingWithoutAnimation()
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { present() }
        }
    }
}

@MainActor
private final class StatusMenuToggleRow: NSView {
    private weak var item: StatusMenuToggleItem?
    private let font = NSFont.menuFont(ofSize: 0)
    private var tracking: NSTrackingArea?
    private var pointerInside = false
    private var pressed = false

    init(item: StatusMenuToggleItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
    }

    required init?(coder: NSCoder) { fatalError("Menu toggle rows are created in code") }

    func refresh() {
        guard let item else { return }
        let label = item.accessibilityLabel() ?? item.title
        let previousValue = accessibilityValue() as? Int
        setAccessibilityLabel(label)
        setAccessibilityEnabled(item.isEnabled)
        setAccessibilityHelp(item.toolTip)
        toolTip = item.toolTip
        let value = item.state == .mixed ? 2 : item.state.rawValue
        setAccessibilityValue(value)
        if previousValue != value, window != nil {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        let requiredWidth = ceil((item.title as NSString).size(withAttributes: [.font: font]).width) + 43
        if requiredWidth > frame.width || window == nil {
            setFrameSize(NSSize(width: requiredWidth, height: frame.height))
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let highlighted = item.isEnabled && (pointerInside || item.isHighlighted)
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = if !item.isEnabled { .disabledControlTextColor }
            else if highlighted { .alternateSelectedControlTextColor }
            else { .labelColor }
        draw(item.title, at: 31, font: font, color: color)
        if item.state != .off {
            draw(item.state == .on ? "✓" : "−", at: 13, font: .systemFont(ofSize: 13, weight: .medium), color: color)
        }
    }

    private func draw(_ label: String, at x: CGFloat, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = label as NSString
        let height = text.size(withAttributes: attributes).height
        text.draw(at: NSPoint(x: x, y: floor(bounds.midY - height / 2)), withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointerInside = false
        pressed = false
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = item?.isEnabled == true }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        if pressed && bounds.contains(convert(event.locationInWindow, from: nil)) { item?.activate() }
    }

    override var acceptsFirstResponder: Bool { item?.isEnabled == true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let activationKeys = [kVK_Return, kVK_Space, kVK_ANSI_KeypadEnter]
        guard modifiers.isEmpty, activationKeys.contains(Int(event.keyCode)),
              let highlighted = highlightedToggle() else {
            super.keyDown(with: event)
            return
        }
        if !event.isARepeat { highlighted.activate() }
    }

    private func highlightedToggle() -> StatusMenuToggleItem? {
        guard let source = item?.menu else { return nil }
        var menu = source
        while let parent = menu.supermenu { menu = parent }
        // AppKit can keep the last clicked view as first responder when another
        // menu row is highlighted. Activate the highlighted row in the open branch.
        while let submenu = menu.highlightedItem?.submenu, submenu.highlightedItem != nil { menu = submenu }
        if let highlighted = menu.highlightedItem, !highlighted.hasSubmenu {
            return highlighted as? StatusMenuToggleItem
        }
        // Mouse tracking can temporarily clear the highlight while a custom row
        // retains keyboard focus. Use the visible row under the pointer then.
        let point = NSEvent.mouseLocation
        return source.items.lazy.compactMap { $0 as? StatusMenuToggleItem }.first { row in
            guard let view = row.view, let window = view.window, window.isVisible else { return false }
            let bounds = window.convertToScreen(view.convert(view.bounds, to: nil))
            return bounds.contains(point)
        }
    }

    override func accessibilityPerformPress() -> Bool { item?.activate() == true }
}
