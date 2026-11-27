import AppKit
import IOKit
import LocalAuthentication
import ServiceManagement

enum SystemSleep {
    static func isDisabled() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(root, &properties, nil, 0) == KERN_SUCCESS,
              let snapshot = properties?.takeRetainedValue() as NSDictionary? else { return nil }
        // On a system where the override was never set, the kernel defaults to allowing sleep.
        guard let value = snapshot["SleepDisabled"] else { return false }
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }

    @MainActor
    static func setDisabled(_ disabled: Bool) async throws {
        guard let requirement = SleepService.signingRequirement(for: SleepService.label) else {
            throw SleepService.error("请使用带开发者签名的状态栏扩展版本。")
        }
        try prepareService()

        let context = LAContext()
        let reason = disabled ? "禁用 Mac 的系统睡眠" : "恢复 Mac 的系统睡眠"
        NSApp.activate()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw SleepService.error("身份验证未通过。")
            }
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            throw CancellationError()
        }

        let connection = NSXPCConnection(machServiceName: SleepService.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SleepServiceProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        let deadline = Task {
            try await Task.sleep(for: .seconds(10))
            connection.invalidate()
        }
        defer {
            deadline.cancel()
            connection.invalidate()
        }
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                result.resume(throwing: SleepService.error("未能连接睡眠控制服务。请确认系统设置中的后台服务已允许，再试一次。"))
            }
            guard let service = proxy as? SleepServiceProtocol else {
                result.resume(throwing: SleepService.error("无法使用睡眠控制服务。"))
                return
            }
            service.setSleepDisabled(disabled) { error in
                if let error { result.resume(throwing: error) }
                else { result.resume() }
            }
        }
    }

    @MainActor
    private static func prepareService() throws {
        let service = SMAppService.daemon(plistName: SleepService.label + ".plist")
        switch service.status {
        case .enabled:
            return
        case .notRegistered, .notFound, .requiresApproval:
            let alert = NSAlert()
            alert.messageText = "允许状态栏扩展控制系统睡眠"
            alert.informativeText = "首次使用需要管理员在「系统设置 → 通用 → 登录项与扩展」中允许状态栏扩展的后台服务。批准后，再点一次菜单里的「禁用系统睡眠」。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
            // The first status query can return notFound until the system has a registration record.
            let status = service.status
            if status == .notRegistered || status == .notFound {
                do {
                    try service.register()
                } catch let error as NSError {
                    let awaitingApproval = error.domain == SMAppServiceErrorDomain
                        && error.code == Int(kSMErrorLaunchDeniedByUser)
                    guard awaitingApproval || service.status == .requiresApproval || service.status == .enabled else {
                        throw error
                    }
                }
            }
            if service.status == .enabled { return }
            SMAppService.openSystemSettingsLoginItems()
            throw CancellationError()
        default:
            throw SleepService.error("找不到睡眠控制服务。请重新打开完整的状态栏扩展.app 后重试。")
        }
    }
}

@MainActor
final class SystemSleepMenu {
    let item = NSMenuItem(title: "禁用系统睡眠", action: nil, keyEquivalent: "")
    private let read: () -> Bool?
    private let write: (Bool) async throws -> Void
    private let waitForPowerChange: () async throws -> Void
    private let report: (String) -> Void
    private var switching = false

    init(read: @escaping () -> Bool? = SystemSleep.isDisabled,
         write: @escaping (Bool) async throws -> Void = SystemSleep.setDisabled,
         waitForPowerChange: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) },
         report: @escaping (String) -> Void = { message in
             let alert = NSAlert()
             alert.messageText = "未能切换系统睡眠"
             alert.informativeText = message
             alert.runModal()
         }) {
        self.read = read
        self.write = write
        self.waitForPowerChange = waitForPowerChange
        self.report = report
        item.target = self
        item.action = #selector(toggle)
        item.toolTip = "控制合盖和空闲时的系统睡眠。首次需批准后台服务，之后优先使用指纹验证。"
        refresh()
    }

    func refresh() {
        guard !switching else { return }
        let disabled = read()
        item.title = disabled == nil ? "禁用系统睡眠（状态待确认）" : "禁用系统睡眠"
        item.state = disabled.map { $0 ? .on : .off } ?? .mixed
        item.isEnabled = disabled != nil
    }

    @objc func toggle() {
        guard !switching, item.isEnabled else { return }
        let requested = item.state == .off
        // Honor the action shown when the menu opened if another tool changed the setting meanwhile.
        refresh()
        guard item.isEnabled, requested != (item.state == .on) else { return }
        switching = true
        item.title = "禁用系统睡眠（正在切换…）"
        item.isEnabled = false
        Task {
            var failure: String?
            do {
                try await write(requested)
                // powerd applies a successful pmset write asynchronously.
                for _ in 0..<10 {
                    if read() == requested { break }
                    try await waitForPowerChange()
                }
                if let actual = read(), actual != requested {
                    failure = "系统当前仍\(actual ? "禁用" : "允许")睡眠。"
                }
            } catch is CancellationError {
                // Dismissing the system authorization sheet is a normal user action.
            } catch {
                failure = error.localizedDescription
            }
            switching = false
            refresh()
            if let failure { report(failure) }
        }
    }
}
