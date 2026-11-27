import AppKit
import AVFoundation
import Combine
import OSLog

@MainActor
final class HearingModel: ObservableObject {
    let shortcuts: HearingShortcutController
    let meter = PanelMeter()
    @Published private(set) var preferences = HearingPreferences()
    @Published private(set) var catalog = DeviceCatalog()
    @Published private(set) var permission: AVAuthorizationStatus
    private(set) var prominenceDB: Double = 0
    @Published private(set) var environmentReady = false
    private(set) var envelope: Float = 0
    @Published private(set) var starting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var calibrating = false
    private(set) var calibrationProgress = 0.0
    @Published private(set) var recommendations: [ThresholdRecommendation] = []
    @Published private(set) var sleeping = false
    let handle: AudioHandle
    private let backend: AudioBackend
    private let registry = DeviceRegistry()
    private let logger = Logger(subsystem: "com.smartgrey.netrate.hearing", category: "Lifecycle")
    private let store: HearingStore
    private let authorization: () -> AVAuthorizationStatus
    private let requestAccess: () async -> Bool
    private var revision: UInt64 = 0
    private var needsForceRestart = false
    private var timer: Timer?
    private var pollingInterval: TimeInterval?
    private var lastStatus: HearingPresentation?
    private var notifications: [NSObjectProtocol] = []
    private var retryTask: Task<Void, Never>?
    private var retryCount = 0
    private var healthySince: Date?
    private var calibrationRequested: Date?
    private var calibrationSequence: UInt64 = 0
    private var activeCalibration: UInt64 = 0
    private var shuttingDown = false
    private var requestedPermission = false
    private var previousInputFrames: UInt64 = 0
    private var previousOutputFrames: UInt64 = 0
    private var inputAliveAt = Date()
    private var outputAliveAt = Date()
    var onStatusChange: (() -> Void)?

    init(store: HearingStore, shortcuts: HearingShortcutController,
         authorization: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
         requestAccess: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.store = store
        self.shortcuts = shortcuts
        self.authorization = authorization
        self.requestAccess = requestAccess
        preferences = store.settings.audio
        permission = authorization()
        let handle = AudioHandle()
        self.handle = handle
        self.backend = AudioBackend(handle: handle)
        shortcuts.onToggle = { [weak self] in
            guard let self else { return }
            self.setEnabled(!self.preferences.enabled)
        }
    }

    func start() {
        guard !shuttingDown else { return }
        handle.configure(preferences)
        registry.emergencyMute = { [handle] in handle.mute() }
        registry.onInvalidation = { [weak self] in
            guard let self, !self.shuttingDown else { return }
            if self.activeCalibration != 0 { self.cancelCalibration(restore: false) }
            self.revision &+= 1
            self.needsForceRestart = true
            self.starting = true
        }
        registry.onChange = { [weak self] catalog in
            guard let self, !self.shuttingDown else { return }
            if self.activeCalibration != 0 && self.catalog != catalog { self.cancelCalibration(restore: false) }
            self.catalog = catalog
            self.updateRememberedNames()
            let force = self.needsForceRestart
            self.needsForceRestart = false
            self.retryCount = 0
            self.reconcile(force: force)
        }
        registry.start()
        let center = NSWorkspace.shared.notificationCenter
        notifications.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setSleeping(true) }
        })
        notifications.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.shuttingDown else { return }
                self.setSleeping(false)
                self.registry.refresh(force: true)
            }
        })
        reconcile()
    }
    var statusPresentation: HearingPresentation {
        .init(icon: .init(enabled: isListening || calibrating,
                          passing: isListening && !calibrating && envelope > 0.001,
                          level: prominenceDB), title: statusTitle)
    }
    func setPanelVisible(_ visible: Bool) {
        // Refresh before exposing the meter, including changes made while hidden.
        if visible { tick() }
        meter.setVisible(visible)
    }
    private func synchronizePresentation() {
        meter.accept(.init(level: prominenceDB, active: (isListening && environmentReady) || calibrating,
                           passing: envelope > 0.001, calibrationProgress: calibrationProgress))
        let status = statusPresentation
        if lastStatus != status { lastStatus = status; onStatusChange?() }
    }
    private func updatePolling() {
        guard !shuttingDown else { return }
        let interval = RuntimePolling.interval(active: isListening || starting || calibrating, sleeping: sleeping)
        guard interval != pollingInterval else { return }
        timer?.invalidate(); timer = nil; pollingInterval = interval
        guard let interval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = interval * 0.1
    }
    var decision: RouteDecision {
        RoutePolicy.decide(preferences, catalog: catalog, authorized: permission == .authorized,
                           sleeping: sleeping, calibrating: calibrating)
    }
    var statusTitle: String {
        if calibrating { return "测量背景音" }
        if errorMessage != nil { return "音频暂不可用" }
        if case .stopped(let reason) = decision { return reason.title }
        if starting { return "正在连接" }
        if !environmentReady { return "适应环境…" }
        return envelope > 0.001 ? "环境声透传中" : "正在聆听"
    }
    var isListening: Bool {
        guard !starting, errorMessage == nil else { return false }
        if case .run = decision { return true }
        return false
    }
    var allowedRows: [AllowedDevice] {
        var rows = catalog.outputs.filter(\.supported).map { AllowedDevice(key: $0.key, name: $0.name, kind: $0.kind) }
        let connected = Set(catalog.outputs.map(\.key))
        rows += preferences.allowed.filter { !connected.contains($0.key) }
        return rows
    }
    func setEnabled(_ enabled: Bool) {
        guard !shuttingDown else { return }
        preferences.enabled = enabled
        cancelCalibration(restore: false)
        persist()
        retryCount = 0
        if enabled {
            Task { @MainActor in
                await ensurePermission()
                reconcile()
            }
        }
        reconcile()
    }
    func setThreshold(_ value: Double) { preferences.thresholdDB = value.rounded(); parametersChanged() }
    func setReduction(_ value: Double) { preferences.noiseReductionDB = value.rounded(); parametersChanged() }
    func setGain(_ value: Double) { preferences.gainDB = value.rounded(); parametersChanged() }
    func setHold(_ value: Double) { preferences.holdSeconds = (value * 10).rounded() / 10; parametersChanged() }
    private func parametersChanged() {
        preferences.normalize()
        handle.configure(preferences)
        persist()
    }
    func setAllowed(_ row: AllowedDevice, allowed: Bool) {
        handle.mute()
        preferences.allowed.removeAll { $0.key == row.key }
        if allowed, catalog.outputs.contains(where: { $0.key == row.key && $0.supported }) {
            preferences.allowed.append(row)
        }
        persist(); retryCount = 0; reconcile()
    }
    func refresh() {
        guard !shuttingDown else { return }
        permission = authorization()
        registry.refresh()
    }
    func retry() {
        errorMessage = nil; retryCount = 0
        registry.refresh()
        reconcile(force: true)
    }
    func requestMicrophone() {
        Task { @MainActor in
            if permission == .notDetermined { await ensurePermission(); reconcile() }
            else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }
    private func ensurePermission() async {
        guard !shuttingDown else { return }
        permission = authorization()
        if permission == .notDetermined && !requestedPermission {
            requestedPermission = true
            _ = await requestAccess()
            guard !shuttingDown else { return }
            requestedPermission = false
            permission = authorization()
        }
    }
    func measureBackground() {
        guard !shuttingDown else { return }
        guard !calibrating && !starting else { return }
        notice = nil
        Task { @MainActor in
            await ensurePermission()
            guard !shuttingDown, !calibrating, !sleeping, permission == .authorized else { return }
            guard catalog.input != nil else { notice = "找不到可用的 MacBook 内置麦克风。"; return }
            handle.mute()
            calibrationSequence &+= 1; activeCalibration = calibrationSequence
            HearingRequestCalibration(handle.pointer, activeCalibration)
            calibrationRequested = Date(); calibrationProgress = 0; calibrating = true
            retryCount = 0
            reconcile(force: true)
        }
    }
    func cancelCalibration(restore: Bool = true) {
        let wasCalibrating = calibrating
        HearingRequestCalibration(handle.pointer, 0)
        activeCalibration = 0; calibrating = false; calibrationRequested = nil; calibrationProgress = 0
        if restore && wasCalibrating { reconcile(force: true) }
    }
    func applySuggestion(_ suggestion: ThresholdRecommendation) { setThreshold(suggestion.value) }
    private func finishCalibration(normal: Double) {
        let request = activeCalibration
        calibrating = false; calibrationRequested = nil; calibrationProgress = 0
        handle.mute(); revision &+= 1; starting = true
        let token = revision
        Task { @MainActor [weak self, backend] in
            let accepted = await backend.completeCalibration(request: request, generation: token)
            guard let self, !self.shuttingDown, token == self.revision, self.activeCalibration == request else { return }
            self.activeCalibration = 0
            if accepted { self.recommendations = Calibration.recommendations(normal: normal) }
            else { self.notice = "测量结果已失效，请重新测量。" }
            self.reconcile(force: true)
        }
    }
    func dismissNotice() { notice = nil }
    private func persist() {
        guard !shuttingDown else { return }
        do { try store.update { $0.audio = preferences } }
        catch { notice = "环境音设置未能保存。" }
    }
    private func updateRememberedNames() {
        let previous = preferences.allowed
        for i in preferences.allowed.indices {
            if let device = catalog.outputs.first(where: { $0.key == preferences.allowed[i].key }) {
                preferences.allowed[i].name = device.name
                preferences.allowed[i].kind = device.kind
            }
        }
        if previous != preferences.allowed { persist() }
    }
    private func setSleeping(_ value: Bool) {
        guard !shuttingDown else { return }
        sleeping = value
        shortcuts.setSleeping(value)
        if value { cancelCalibration(restore: false); HearingInvalidateEnvironment(handle.pointer) }
        reconcile(force: true)
    }
    private func reconcile(force: Bool = false) {
        guard !shuttingDown else { return }
        retryTask?.cancel()
        handle.mute(); revision &+= 1
        let token = revision, expected = decision
        errorMessage = nil; healthySince = nil
        let route: EngineRoute?
        switch expected {
        case .run(let value): route = value; starting = true
        case .stopped: route = nil; starting = false; prominenceDB = 0; envelope = 0; environmentReady = false
        }
        updatePolling()
        synchronizePresentation()
        handle.configure(preferences)
        Task { @MainActor [weak self, backend] in
            let result = await backend.apply(route, generation: token, force: force)
            guard let self, !self.shuttingDown, token == self.revision else { return }
            self.starting = false
            if result != 0 { self.failed(result); return }
            // Read the default route again after asynchronous hardware startup.
            self.registry.refresh()
            guard token == self.revision, self.decision == expected else { return }
            if route?.output != nil { self.handle.allowOutput() }
            self.healthySince = route == nil ? nil : Date()
            self.previousInputFrames = 0; self.previousOutputFrames = 0
            self.inputAliveAt = Date(); self.outputAliveAt = Date()
            self.updatePolling()
            self.synchronizePresentation()
        }
    }
    private func failed(_ code: Int32) {
        handle.mute()
        logger.error("Audio failure \(code), attempt \(self.retryCount)")
        if calibrating {
            cancelCalibration(restore: false)
            notice = "背景音测量失败，原阈值保持不变。"
        }
        errorMessage = "设备暂时无法使用（\(code)）。请检查连接后重试。"
        starting = false
        updatePolling()
        synchronizePresentation()
        revision &+= 1
        let token = revision
        Task { [backend] in await backend.stop(generation: token) }
        guard retryCount < 3 else { return }
        retryCount += 1
        let delay = UInt64(1 << (retryCount - 1))
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.shuttingDown, self.revision == token else { return }
            self.reconcile(force: true)
        }
    }
    private func tick() {
        guard !shuttingDown else { return }
        let currentPermission = authorization()
        if currentPermission != permission {
            permission = currentPermission
            if permission != .authorized { cancelCalibration(restore: false) }
            reconcile(force: true)
        }
        let snapshot = handle.snapshot()
        if !starting && snapshot.running != 0 {
            prominenceDB = Double(snapshot.prominenceDB); envelope = snapshot.envelope
            let ready = snapshot.environmentReady != 0
            if environmentReady != ready { environmentReady = ready }
            if snapshot.inputFrames != previousInputFrames {
                previousInputFrames = snapshot.inputFrames; inputAliveAt = Date()
            }
            if snapshot.outputFrames != previousOutputFrames {
                previousOutputFrames = snapshot.outputFrames; outputAliveAt = Date()
            }
            if snapshot.callbackErrors > 0 && errorMessage == nil { failed(snapshot.lastError) }
            if errorMessage == nil && (Date().timeIntervalSince(inputAliveAt) > 3
                || (!calibrating && snapshot.outputRate > 0 && Date().timeIntervalSince(outputAliveAt) > 3)) {
                failed(-70001)
            }
            if let healthySince, Date().timeIntervalSince(healthySince) > 30 { retryCount = 0 }
        } else {
            prominenceDB = 0; envelope = 0
            if environmentReady { environmentReady = false }
        }
        if calibrating && !starting && snapshot.running != 0 {
            calibrationProgress = Double(snapshot.calibrationProgress)
            if snapshot.calibrationRequest == activeCalibration && snapshot.calibrationStatus != 0 {
                if snapshot.calibrationStatus == 1 { finishCalibration(normal: Double(snapshot.calibrationNormalDB)) }
                else {
                    cancelCalibration(restore: false)
                    notice = "背景波动较大或有效声音不足，请保持安静后重测。原设置未改变。"
                    reconcile(force: true)
                }
            }
        }
        if calibrating, let requested = calibrationRequested, Date().timeIntervalSince(requested) > 9 {
            cancelCalibration(restore: false)
            notice = "麦克风没有持续提供声音，测量已取消。原阈值未改变。"
            reconcile(force: true)
        }
        updatePolling()
        synchronizePresentation()
    }
    func shutdown() -> Task<Void, Never> {
        // Mute and detach synchronously before another feature can own the hardware.
        shuttingDown = true; revision &+= 1
        HearingRequestCalibration(handle.pointer, 0)
        shortcuts.shutdown()
        handle.mute(); retryTask?.cancel(); timer?.invalidate(); timer = nil
        registry.stop()
        for token in notifications { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        notifications.removeAll()
        let token = revision
        return Task.detached { [backend] in await backend.stop(generation: token) }
    }
}
