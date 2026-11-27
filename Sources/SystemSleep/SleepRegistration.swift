import CryptoKit
import Security
import ServiceManagement

@MainActor
protocol SleepServiceManaging {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: SleepServiceManaging {}

enum SleepRegistration {
    struct NeedsApproval: Error {}
    private static let fingerprintKey = "SleepHelperSubmittedFingerprint"
    private static let registrationRetryDelays: [Duration] = [
        .zero, .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2)
    ]

    // A CodeDirectory hash identifies signed content across re-signing with the same
    // identity. The plist is independently significant to launchd.
    static func fingerprint(in bundle: Bundle, requirement: String) throws -> String {
        let executable = bundle.bundleURL.appending(path: "Contents/MacOS/NetRateSleepHelper")
        let plist = bundle.bundleURL.appending(path: "Contents/Library/LaunchDaemons/\(SleepService.label).plist")
        var code: SecStaticCode?
        var rule: SecRequirement?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess, let rule,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), rule) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let hash = (info as NSDictionary?)?[kSecCodeInfoUnique] as? Data else {
            throw SleepService.error("无法验证睡眠助手的签名。请重新安装完整的状态栏扩展。")
        }
        let plistHash = SHA256.hash(data: try Data(contentsOf: plist))
        return hash.base64EncodedString() + "." + Data(plistHash).base64EncodedString()
    }

    @MainActor
    static func prepare(_ service: SleepServiceManaging, fingerprint: String,
                        defaults: UserDefaults = .standard,
                        waitBeforeRetry: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws {
        switch service.status {
        case .enabled:
            guard defaults.string(forKey: fingerprintKey) != fingerprint else { return }
            // The async overload completes only after the running helper has stopped.
            try await service.unregister()
        case .requiresApproval:
            throw NeedsApproval()
        case .notFound, .notRegistered:
            break
        @unknown default:
            throw SleepService.error("无法读取睡眠助手的注册状态。")
        }

        // Background Task Management can still reject registrations for a short
        // time after launchd has reported that the old job stopped.
        for delay in registrationRetryDelays {
            if delay != .zero { try await waitBeforeRetry(delay) }
            let status: SMAppService.Status
            do {
                try service.register()
                status = service.status
            } catch let error as NSError {
                guard error.domain == SMAppServiceErrorDomain else { throw error }
                switch error.code {
                case Int(kSMErrorLaunchDeniedByUser):
                    if service.status == .requiresApproval { defaults.set(fingerprint, forKey: fingerprintKey) }
                    throw NeedsApproval()
                case Int(POSIXErrorCode.EPERM.rawValue):
                    guard service.status == .requiresApproval else { continue }
                    status = .requiresApproval
                default:
                    throw error
                }
            }
            switch status {
            case .enabled, .requiresApproval:
                // A submitted registration awaiting approval belongs to this build too.
                defaults.set(fingerprint, forKey: fingerprintKey)
                if status == .requiresApproval { throw NeedsApproval() }
                return
            default:
                throw SleepService.error("睡眠助手尚未完成注册。请稍后再试。")
            }
        }
        throw SleepService.error("macOS 暂未允许启动睡眠助手。请稍后再点一次。若仍无法使用，请检查「系统设置 → 通用 → 登录项与扩展」是否允许状态栏扩展在后台运行。")
    }
}
