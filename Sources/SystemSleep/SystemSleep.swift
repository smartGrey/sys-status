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
        let fingerprint = try SleepRegistration.fingerprint(in: .main, requirement: requirement)
        do {
            try await SleepRegistration.prepare(SMAppService.daemon(plistName: SleepService.label + ".plist"),
                                                fingerprint: fingerprint)
        } catch is SleepRegistration.NeedsApproval {
            showApprovalInstructions()
            throw CancellationError()
        }

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

        try await SleepConnection.write(disabled, requirement: requirement)
    }

    @MainActor
    private static func showApprovalInstructions() {
        let alert = NSAlert()
        alert.messageText = "允许状态栏扩展控制系统睡眠"
        alert.informativeText = "请在「系统设置 → 通用 → 登录项与扩展」中允许睡眠助手。批准后，再点一次菜单里的「禁用系统睡眠」。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
    }
}

struct SleepNotice {
    let title: String
    let detail: String
}

@MainActor
final class SystemSleepMenu {
    let item = NSMenuItem(title: "禁用系统睡眠", action: nil, keyEquivalent: "")
    private let read: () -> Bool?
    private let write: (Bool) async throws -> Void
    private let waitForPowerChange: () async throws -> Void
    private let report: (SleepNotice) -> Void
    private var switching = false

    init(read: @escaping () -> Bool? = SystemSleep.isDisabled,
         write: @escaping (Bool) async throws -> Void = SystemSleep.setDisabled,
         waitForPowerChange: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) },
         report: @escaping (SleepNotice) -> Void = { notice in
             let alert = NSAlert()
             alert.messageText = notice.title
             alert.informativeText = notice.detail
             NSApp.activate()
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
        display(read())
    }

    private func display(_ disabled: Bool?) {
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
        let feedback = OperationFeedback.menu
        switching = true
        item.title = "禁用系统睡眠（正在切换…）"
        item.isEnabled = false
        Task {
            var communicationError: SleepCommunicationError?
            do {
                try await write(requested)
            } catch let error as SleepCommunicationError {
                communicationError = error
            } catch {
                switching = false
                refresh()
                if !(error is CancellationError) {
                    report(SleepNotice(title: "未能切换系统睡眠", detail: error.localizedDescription))
                }
                return
            }

            // Both a successful reply and a lost reply can precede powerd applying the write.
            var actual = read()
            for _ in 0..<10 {
                if actual == requested { break }
                do { try await waitForPowerChange() } catch { break }
                actual = read()
            }
            switching = false
            display(actual)
            guard let actual else {
                report(SleepNotice(title: "系统睡眠状态待确认", detail: "暂时无法读取系统睡眠状态。请稍后重新打开菜单查看。"))
                return
            }
            if actual != requested {
                let state = actual ? "禁用" : "允许"
                report(SleepNotice(title: "未能切换系统睡眠", detail: "系统当前仍\(state)睡眠。"))
            } else if let communicationError {
                report(SleepNotice(title: actual ? "系统睡眠已禁用" : "系统睡眠已恢复",
                                   detail: "已从系统确认设置生效，无需重试。睡眠助手通信异常。\n\(communicationError.localizedDescription)"))
            } else {
                feedback.show(actual ? "系统睡眠已禁用" : "系统睡眠已恢复")
            }
        }
    }
}
