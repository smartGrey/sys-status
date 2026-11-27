import AppKit
import ApplicationServices

enum VolumeKeyFailure: String {
    case permission, unavailable, recovery

    var help: String {
        switch self {
        case .permission: "请在系统设置的隐私与安全中允许「网速」使用辅助功能，然后再点一次此项。"
        case .unavailable: "系统未能建立或保留音量键监听。请检查「网速」的辅助功能权限，再点一次重试。"
        case .recovery: "系统反复停用了音量键监听。点此重新启用。"
        }
    }
}

enum VolumeKeySessionEvent {
    case ready, unavailable, disabled
}

protocol VolumeKeyListening: AnyObject {
    @MainActor func start(_ notify: @escaping @MainActor @Sendable (VolumeKeySessionEvent) -> Void)
    @MainActor func checkHealth() -> VolumeKeyFailure?
    @MainActor func stop()
}

// One worker per activation. The thread owns the callback context until its run loop exits.
// The lock coordinates publication and synchronous teardown with the main thread.
final class VolumeKeySession: VolumeKeyListening, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    @MainActor private var recoveries: [TimeInterval] = []

    private final class Callback {
        let session: VolumeKeySession
        let notify: @MainActor @Sendable (VolumeKeySessionEvent) -> Void

        init(_ session: VolumeKeySession, _ notify: @escaping @MainActor @Sendable (VolumeKeySessionEvent) -> Void) {
            self.session = session
            self.notify = notify
        }

        func receive(_ type: CGEventType, _ event: CGEvent) {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { [notify] in notify(.disabled) }
            } else {
                session.lock.withLock {
                    if !session.stopped { VolumeEventFilter.transform(event) }
                }
            }
        }
    }

    @MainActor func start(_ notify: @escaping @MainActor @Sendable (VolumeKeySessionEvent) -> Void) {
        let thread = Thread { [self] in
            let context = Callback(self, notify)
            withExtendedLifetime(context) {
                guard let port = CGEvent.tapCreate(
                    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                    eventsOfInterest: VolumeEventFilter.eventMask,
                    callback: { _, type, event, info in
                        if let info {
                            Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().receive(type, event)
                        }
                        return Unmanaged.passUnretained(event)
                    }, userInfo: Unmanaged.passUnretained(context).toOpaque()
                ) else {
                    DispatchQueue.main.async { notify(.unavailable) }
                    return
                }
                defer { CFMachPortInvalidate(port) }
                guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
                    DispatchQueue.main.async { notify(.unavailable) }
                    return
                }
                let workerLoop = CFRunLoopGetCurrent()!
                CFRunLoopAddSource(workerLoop, source, .defaultMode)
                defer { CFRunLoopRemoveSource(workerLoop, source, .defaultMode) }
                let active = lock.withLock {
                    guard !stopped else { return false }
                    tap = port
                    loop = workerLoop
                    return true
                }
                guard active else { return }
                CFRunLoopPerformBlock(workerLoop, CFRunLoopMode.defaultMode.rawValue) { @Sendable in
                    DispatchQueue.main.async { notify(.ready) }
                }
                CFRunLoopRun()
                // Covers unexpected source invalidation as well as a normal stop.
                DispatchQueue.main.async { notify(.unavailable) }
            }
        }
        thread.name = "NetRate.VolumeKeys"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    @MainActor func checkHealth() -> VolumeKeyFailure? {
        guard let current = lock.withLock({ tap }), CFMachPortIsValid(current) else { return .unavailable }
        guard !CGEvent.tapIsEnabled(tap: current) else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        recoveries.removeAll { now - $0 >= 30 }
        guard recoveries.count < 3 else { return .recovery }
        recoveries.append(now)
        CGEvent.tapEnable(tap: current, enable: true)
        return CGEvent.tapIsEnabled(tap: current) ? nil : .unavailable
    }

    @MainActor func stop() {
        let (port, workerLoop) = lock.withLock {
            stopped = true
            defer { tap = nil; loop = nil }
            return (tap, loop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let workerLoop {
            // Also works when stop arrives just before the worker enters CFRunLoopRun.
            CFRunLoopPerformBlock(workerLoop, CFRunLoopMode.defaultMode.rawValue) { @Sendable in
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(workerLoop)
        }
    }
}
