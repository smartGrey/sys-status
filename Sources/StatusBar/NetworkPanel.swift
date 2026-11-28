import AppKit

@MainActor
final class NetworkPanel {
    private let wirelessReader = WirelessReader()
    private var wireless = WirelessLink()
    private var wirelessSampling: Task<Void, Never>?
    private var association: WirelessAssociationObserver?
    private let bandwidth: BandwidthTest
    var keepOpen: (() -> Void)?
    var bandwidthBusyChanged: ((Bool) -> Void)?

    init(bandwidth: BandwidthTest = BandwidthTest()) {
        self.bandwidth = bandwidth
        bandwidth.changed = { [weak self] in self?.bandwidthChanged() }
    }

    isolated deinit { wirelessSampling?.cancel() }

    private func bandwidthChanged() {
        if bandwidth.state == .idle { association = nil }
        bandwidthBusyChanged?(bandwidth.busy)
        if anchor != nil { card.showDiagnostics(wireless, bandwidth.state) }
    }

    func networkChanged() {
        wireless = WirelessLink()
        bandwidth.invalidate()
        if anchor != nil {
            card.showDiagnostics(wireless, bandwidth.state)
            observeWireless()
        }
    }

    private func observeWireless() {
        wirelessSampling?.cancel()
        wirelessSampling = Task { [weak self, wirelessReader] in
            while !Task.isCancelled {
                let reading = await wirelessReader.read(previousBars: self?.wireless.bars)
                guard !Task.isCancelled, let self else { return }
                if reading != wireless {
                    wireless = reading
                    card.showDiagnostics(reading, bandwidth.state)
                }
                do { try await Task.sleep(for: .seconds(3), tolerance: .milliseconds(300)) } catch { return }
            }
        }
    }

    private func toggleBandwidthTest() {
        if bandwidth.busy { bandwidth.cancel(); return }
        keepOpen?()
        association = association ?? WirelessAssociationObserver { [weak self] in self?.networkChanged() }
        bandwidth.start()
    }

    private var connectivity = ConnectivityState()
    private var anchor: NSRect?
    private weak var screen: NSScreen?
    private var window: StatusPanelWindow?
    private lazy var card: HoverCard = {
        let card = HoverCard()
        card.measureBandwidth = { [weak self] in self?.toggleBandwidthTest() }
        card.probeNow = { [weak self] in self?.probeNow?() }
        card.togglePin = { [weak self] in self?.window?.togglePinned?() }
        card.openSettings = { [weak self] in self?.configure?() }
        card.toggleSites = { [weak self] value in
            guard let self else { return }
            if setShowAllSites?(value) == true { showAllSites = value }
            layout()
        }
        card.openSite = { [weak self] id, view in self?.presentSite(id, from: view) }
        return card
    }()
    var configure: (() -> Void)?
    var showAllSites = false
    var setShowAllSites: ((Bool) -> Bool)?
    var openSite: ((String, NSView) -> Void)?
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
    private func presentSite(_ id: String, from view: NSView) {
        card.trackingSiteID = id
        defer { card.trackingSiteID = nil; layout() }
        openSite?(id, view)
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
        card.showDiagnostics(wireless, bandwidth.state)
        observeWireless()
        card.setVisible(true)
        setTooltip?(nil)
        return window
    }
    private func close() {
        wirelessSampling?.cancel()
        wirelessSampling = nil
        wireless = WirelessLink()
        card.setVisible(false)
        window?.orderOut(nil)
        anchor = nil
        setTooltip?(connectivity.hoverTooltip)
    }
    private func layout() {
        guard let window, let anchor, let screen = (window.isMovable ? window.screen : nil) ?? screen else { return }
        let bounds = screen.visibleFrame
        let height = window.isMovable ? bounds.height : StatusPanelGeometry.top(under: anchor, within: bounds) - bounds.minY
        card.showAllSites = showAllSites
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
        window.protectsInteraction = { [weak card] in card?.trackingSiteID != nil }
        window.contentView = card
        window.pinChanged = { [weak card] in card?.setPinned($0) }
        return window
    }
}
