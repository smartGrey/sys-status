import AppKit

@MainActor
public enum StatusBarApplication {
    public static func run() {
        let app = NSApplication.shared
        let delegate = ApplicationCoordinator()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
