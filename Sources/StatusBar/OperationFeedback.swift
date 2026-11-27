import AppKit

/// Capture the action's screen before opening system UI or awaiting the result.
@MainActor
struct OperationFeedback {
    static var deliver: ((String, NSScreen) -> Void)?
    static weak var menuScreen: NSScreen?
    let screen: NSScreen?

    static var menu: Self { Self(screen: menuScreen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? .main) }
    static var shortcut: Self { Self(screen: .main) }

    func show(_ message: String) {
        if let destination = screen.flatMap({ NSScreen.screens.contains($0) ? $0 : nil }) ?? .main {
            Self.deliver?(message, destination)
        }
    }
}

@MainActor
final class OperationToast {
    private let text = NSTextField(labelWithString: "")
    private let panel: NSPanel
    private var dismissal: Timer?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "操作提示"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let surface = NSVisualEffectView()
        surface.material = .hudWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 12
        surface.layer?.masksToBounds = true
        panel.contentView = surface
        text.alignment = .center
        text.font = .systemFont(ofSize: 14, weight: .medium)
        text.lineBreakMode = .byTruncatingTail
        surface.addSubview(text)
    }

    func show(_ message: String, on screen: NSScreen) {
        dismissTimer()
        text.stringValue = message
        let bounds = screen.frame
        let width = min(bounds.width - 24, ceil(text.intrinsicContentSize.width) + 44)
        panel.setFrame(NSRect(x: round(bounds.midX - width / 2), y: round(bounds.midY - 22), width: width, height: 44), display: true)
        text.frame = NSRect(x: 16, y: 12, width: width - 32, height: 20)
        panel.orderFrontRegardless()
        NSAccessibility.post(element: text, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        dismissal = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func dismissTimer() { dismissal?.invalidate(); dismissal = nil }
    func hide() { dismissTimer(); panel.orderOut(nil) }
}
