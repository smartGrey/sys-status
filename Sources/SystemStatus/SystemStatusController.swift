import AppKit
import SwiftUI
import IOKit.ps
import notify

@MainActor
final class SystemStatusController: NSObject, ObservableObject {
    @Published private(set) var settings = SystemStatusSettings()
    @Published private(set) var reading = SystemReading()
    @Published private(set) var thermalState: ProcessInfo.ThermalState?
    @Published private(set) var audioNames = AudioDeviceNames()
    private var audioObserver: DefaultAudioDevices?
    @Published var editing = false {
        didSet {
            if visible, oldValue != editing { presentation?.resizeToSettings() }
        }
    }
    @Published var choosingMetrics = false
    @Published var details = false { didSet { refreshDemand() } }
    private let url: URL
    private var loadError: Error?
    private var reader: SystemResourceReader?
    private var sampling: Task<Void, Never>?
    private var demand: ResourceDemand?
    private var source: CFRunLoopSource?
    private var powerPreferencesToken: Int32?
    private var powerPreferencesRevision: UInt64 = 0
    private var awake = false
    private var visible = false
    private var presentation: SystemStatusPanel?
    var didUpdate: ((SystemStatusFace?) -> Void)?
    lazy var menuItem: StatusMenuToggleItem = {
        let item = StatusMenuToggleItem.make(title: "系统状态", action: #selector(toggle))
        item.target = self
        return item
    }()

    init(url: URL) { self.url = url }

    isolated deinit {
        sampling?.cancel()
        stopObservingPowerPreferences()
        if let source { CFRunLoopSourceInvalidate(source) }
    }

    func restore() {
        do {
            var next = try JSONDecoder().decode(SystemStatusSettings.self, from: Data(contentsOf: url))
            guard next.version == 1 else { throw CocoaError(.coderReadCorrupt) }
            next.normalize()
            settings = next
            loadError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            loadError = nil
        } catch { loadError = error }
        updateMenu()
    }
    @objc private func toggle() {
        if loadError != nil { restore() }
        if let loadError { menuItem.afterClosingMenu { NSAlert(error: loadError).runModal() }; return }
        if change({ $0.enabled.toggle() }) {
            OperationFeedback.menu.show(settings.enabled ? "系统状态入口已开启" : "系统状态入口已关闭")
        }
    }
    @discardableResult
    func change(_ apply: (inout SystemStatusSettings) -> Void) -> Bool {
        var next = settings
        apply(&next)
        next.normalize()
        guard settings != next else { return true }
        do {
            if let loadError { throw loadError }
            try AppDataFile.write(next, to: url)
        } catch {
            menuItem.afterClosingMenu { NSAlert(error: error).runModal() }
            return false
        }
        let enabledChanged = next.enabled != settings.enabled
        settings = next
        if enabledChanged { updateMenu() }
        refreshDemand()
        publishFace()
        return true
    }
    func restoreLayout() {
        let width = min(SystemPanelLayout.defaultWidth, presentation?.availableWidth ?? SystemPanelLayout.defaultWidth)
        if change({
            $0.modules = ResourceModule.allCases
            $0.hidden.removeAll()
            $0.width = width
            $0.height = SystemPanelLayout.heightToFit(width: width)
        }) { presentation?.resizeToSettings() }
    }

    private func updateMenu() {
        menuItem.state = settings.enabled ? .on : .off
        menuItem.refreshRow()
    }
    func setAwake(_ value: Bool) { awake = value; refreshDemand() }
    func setVisible(_ value: Bool) {
        visible = value
        if !value { choosingMetrics = false; editing = false; details = false }
        refreshDemand()
    }

    var panelContent: PanelContent {
        PanelContent(show: { [weak self] anchor, screen, focus in
            guard let self, settings.enabled else { return nil }
            let panel = presentation ?? SystemStatusPanel(controller: self)
            presentation = panel
            return panel.show(under: anchor, on: screen, focus: focus)
        }, close: { [weak self] in
            self?.presentation?.close()
            self?.presentation = nil
        }, follow: { [weak self] anchor, screen in self?.presentation?.follow(anchor, on: screen) },
        isEditing: { [weak self] in self?.choosingMetrics == true || self?.editing == true || self?.details == true })
    }

    private func publishFace() {
        didUpdate?(settings.enabled ? SystemStatusFace(reading: reading, metrics: settings.metrics, colors: settings.metricColors ?? [:]) : nil)
    }
    private func powerModeChanged() {
        guard let demand, demand.needsBattery else { return }
        if demand.batteryInStatusBar { powerPreferencesRevision &+= 1 }
        sample(powerChanged: true)
    }

    @objc private func thermalChanged() {
        let state = ProcessInfo.processInfo.thermalState
        if state != thermalState { thermalState = state }
    }

    private func stopObservingPowerPreferences() {
        if let powerPreferencesToken { notify_cancel(powerPreferencesToken) }
        powerPreferencesToken = nil
    }

    private func observeChanges(for next: ResourceDemand?) {
        if (demand?.batteryInStatusBar == true) != (next?.batteryInStatusBar == true) {
            if next?.batteryInStatusBar == true {
                // The preference event also covers Automatic ↔ High, where the public
                // low-power flag does not change. Read the live profile after this event.
                var token: Int32 = 0
                if notify_register_dispatch("com.apple.system.powermanagement.prefschange", &token, .main, { [weak self] _ in
                    MainActor.assumeIsolated {
                        if self?.demand?.batteryInStatusBar == true { self?.powerModeChanged() }
                    }
                }) == NOTIFY_STATUS_OK { powerPreferencesToken = token }
            } else { stopObservingPowerPreferences() }
        }
        let center = NotificationCenter.default
        if (demand?.needsBattery == true) != (next?.needsBattery == true) {
            center.removeObserver(self, name: .NSProcessInfoPowerStateDidChange, object: nil)
            if next?.needsBattery == true {
                center.addObserver(self, selector: #selector(receivedPowerChange),
                                   name: .NSProcessInfoPowerStateDidChange, object: nil)
            }
        }
        if (demand?.thermalPanel == true) != (next?.thermalPanel == true) {
            center.removeObserver(self, name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            if next?.thermalPanel == true {
                thermalChanged()
                center.addObserver(self, selector: #selector(receivedThermalChange),
                                   name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
                thermalChanged()
            } else { thermalState = nil }
        }
        if next?.audioPanel == true {
            if audioObserver == nil {
                audioObserver = DefaultAudioDevices { [weak self] names in
                    if self?.audioNames != names { self?.audioNames = names }
                }
            }
        } else if audioObserver != nil { audioObserver = nil; audioNames = AudioDeviceNames() }
    }

    @objc nonisolated private func receivedPowerChange() {
        Task { @MainActor [weak self] in self?.powerModeChanged() }
    }

    @objc nonisolated private func receivedThermalChange() {
        Task { @MainActor [weak self] in
            if self?.demand?.thermalPanel == true { self?.thermalChanged() }
        }
    }

    private func refreshDemand() {
        guard awake, settings.enabled else {
            if source != nil || demand != nil {
                observeChanges(for: nil)
                sampling?.cancel()
                sampling = nil
                demand = nil
                if let source { CFRunLoopSourceInvalidate(source) }
                source = nil
                reader = nil
                reading = SystemReading()
            }
            return
        }
        let next = ResourceDemand(settings, panelVisible: visible, details: details)
        if next != demand { observeChanges(for: next) }
        if next.needsBattery && source == nil {
            source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<SystemStatusController>.fromOpaque(context).takeUnretainedValue().sample(powerChanged: true)
                }
            }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        } else if !next.needsBattery, let source {
            CFRunLoopSourceInvalidate(source)
            self.source = nil
        }
        if demand != next { demand = next; sample(powerChanged: true) }
    }
    private func sample(powerChanged: Bool) {
        guard let demand else { return }
        sampling?.cancel()
        let reader = self.reader ?? SystemResourceReader()
        self.reader = reader
        sampling = Task { [weak self] in
            var changed = powerChanged
            while !Task.isCancelled {
                guard let revision = self?.powerPreferencesRevision else { return }
                let snapshot = await reader.sample(demand, powerChanged: changed, powerPreferencesRevision: revision)
                guard !Task.isCancelled else { return }
                if let self {
                    if reading != snapshot { reading = snapshot }
                    publishFace()
                } else { return }
                guard let delay = demand.interval(charging: snapshot.battery?.charging == true) else { return }
                changed = false
                do { try await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(100)) }
                catch { return }
            }
        }
    }
}

@MainActor
final class SystemStatusPanel: NSObject, NSWindowDelegate {
    private unowned let controller: SystemStatusController
    private let window: StatusPanelWindow
    private var anchor = NSRect.zero
    private weak var anchorScreen: NSScreen?
    // Only the browsing size is persisted. Editing temporarily adds its footer.
    private var footerHeight: CGFloat { controller.editing ? SystemPanelLayout.editingFooterHeight : 0 }
    var availableWidth: CGFloat? { (window.screen ?? anchorScreen).map { $0.visibleFrame.width - 16 } }
    func resizeToSettings() { if let screen = window.screen ?? anchorScreen { position(in: screen) } }

    init(controller: SystemStatusController) {
        self.controller = controller
        window = StatusPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "系统状态"
        window.setAccessibilityLabel("系统状态")
        window.isMovable = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.delegate = self
        window.protectsInteraction = { [weak controller] in controller?.choosingMetrics == true || controller?.details == true }
        let body = NSHostingView(rootView: SystemStatusView(model: controller))
        body.sizingOptions = []
        let toolbar = NSHostingView(rootView: SystemStatusToolbar(model: controller))
        _ = PanelChrome(title: "系统状态", body: body, window: window, accessory: toolbar)
    }
    func show(under anchor: NSRect, on screen: NSScreen, focus: Bool) -> StatusPanelWindow {
        self.anchor = anchor
        self.anchorScreen = screen
        position(in: screen)
        controller.setVisible(true)
        if focus { window.makeKeyAndOrderFront(nil) }
        return window
    }
    func follow(_ anchor: NSRect, on screen: NSScreen) {
        self.anchor = anchor
        self.anchorScreen = screen
        position(in: screen)
    }
    private func position(in screen: NSScreen) {
        var minimum = SystemStatusSettings.minimum
        minimum.height += footerHeight
        if window.contentMinSize != minimum { window.contentMinSize = minimum }
        window.place(size: CGSize(width: controller.settings.width, height: controller.settings.height + footerHeight),
                     under: anchor, on: screen, trailing: true)
    }
    func windowWillStartLiveResize(_ notification: Notification) { window.beginPinning?() }
    func windowDidEndLiveResize(_ notification: Notification) {
        controller.change {
            $0.width = window.frame.width.rounded()
            $0.height = (window.frame.height - footerHeight).rounded()
        }
    }
    func close() { controller.setVisible(false); window.orderOut(nil) }
}
