import AppKit

@MainActor
final class NetworkPanel {
    private var connectivity = ConnectivityState()
    private var anchor: NSRect?
    private weak var screen: NSScreen?
    private var window: StatusPanelWindow?
    private lazy var card: HoverCard = {
        let card = HoverCard()
        card.probeNow = { [weak self] in self?.probeNow?() }
        card.togglePin = { [weak self] in self?.window?.togglePinned?() }
        return card
    }()
    var readTimeline: () -> ProbeTimeline = { ProbeTimeline() }
    var probeNow: (() -> Void)?
    var setTooltip: ((String?) -> Void)?

    var panelContent: PanelContent {
        PanelContent(show: { [weak self] anchor, screen, _ in self?.show(under: anchor, on: screen) },
                     close: { [weak self] in self?.close() }, follow: { [weak self] rect, screen in
            self?.anchor = rect
            self?.screen = screen
            self?.layout()
        })
    }
    func refreshTiming() {
        if anchor != nil { card.setTimeline(readTimeline()) }
    }
    func update(_ state: ConnectivityState) {
        guard connectivity != state else { return }
        connectivity = state
        if anchor != nil { layout() } else { setTooltip?(state.hoverTooltip) }
    }
    private func show(under rect: NSRect, on screen: NSScreen) -> StatusPanelWindow {
        self.screen = screen
        anchor = rect
        let window = window ?? makePanel()
        self.window = window
        layout()
        card.setTimeline(readTimeline())
        card.setVisible(true)
        setTooltip?(nil)
        return window
    }
    private func close() {
        card.setVisible(false)
        window?.orderOut(nil)
        anchor = nil
        setTooltip?(connectivity.hoverTooltip)
    }
    private func layout() {
        guard let window, let anchor, let screen = (window.isMovable ? window.screen : nil) ?? screen else { return }
        let bounds = screen.visibleFrame
        let height = window.isMovable ? bounds.height : StatusPanelGeometry.top(under: anchor, within: bounds) - bounds.minY
        let size = card.update(connectivity, availableHeight: height, availableWidth: bounds.width)
        let frame = window.isMovable ? StatusPanelGeometry.pinnedFrame(size: size, previous: window.frame, within: bounds)
            : StatusPanelGeometry.frame(size: size, under: anchor, within: bounds)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }
    private func makePanel() -> StatusPanelWindow {
        let window = StatusPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        window.title = "网络状况"
        window.isMovable = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.acceptsMouseMovedEvents = true
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentView = card
        window.pinChanged = { [weak card] in card?.setPinned($0) }
        return window
    }
}
