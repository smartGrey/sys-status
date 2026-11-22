import Darwin.membership
import Foundation
import SystemConfiguration

private final class SleepDaemon: NSObject, NSXPCListenerDelegate {
    private let writeLock = NSLock()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let caller = connection.effectiveUserIdentifier
        guard Self.isActiveAdministrator(caller) else { return false }
        connection.exportedInterface = NSXPCInterface(with: SleepServiceProtocol.self)
        connection.exportedObject = SleepRequest(caller: caller, daemon: self)
        connection.resume()
        return true
    }

    fileprivate func setSleepDisabled(_ disabled: Bool, caller: uid_t) -> NSError? {
        writeLock.withLock {
            guard Self.isActiveAdministrator(caller) else {
                return SleepService.error("请从当前登录的管理员账户切换系统睡眠。")
            }
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            command.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
            command.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            command.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
            command.standardInput = FileHandle.nullDevice
            command.standardOutput = FileHandle.nullDevice
            command.standardError = FileHandle.nullDevice
            do {
                try command.run()
                command.waitUntilExit()
                if command.terminationStatus == 0 { return nil }
                return SleepService.error("pmset 未能更改系统睡眠设置（\(command.terminationStatus)）。")
            } catch {
                return SleepService.error("无法运行 pmset。\(error.localizedDescription)")
            }
        }
    }

    private static func isActiveAdministrator(_ user: uid_t) -> Bool {
        var consoleUser: uid_t = 0
        guard user != 0, SCDynamicStoreCopyConsoleUser(nil, &consoleUser, nil) != nil,
              user == consoleUser else { return false }
        var account: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var adminGroup = account
        var isMember: Int32 = 0
        // The built-in macOS admin group has GID 80.
        return mbr_uid_to_uuid(user, &account) == 0 && mbr_gid_to_uuid(80, &adminGroup) == 0
            && mbr_check_membership(&account, &adminGroup, &isMember) == 0 && isMember != 0
    }
}

private final class SleepRequest: NSObject, SleepServiceProtocol {
    private let caller: uid_t
    private let daemon: SleepDaemon

    fileprivate init(caller: uid_t, daemon: SleepDaemon) {
        self.caller = caller
        self.daemon = daemon
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping (NSError?) -> Void) {
        reply(daemon.setSleepDisabled(disabled, caller: caller))
    }
}

guard geteuid() == 0, let requirement = SleepService.signingRequirement(for: SleepService.appIdentifier) else {
    exit(EXIT_FAILURE)
}
private let daemon = SleepDaemon()
let listener = NSXPCListener(machServiceName: SleepService.label)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = daemon
listener.resume()
withExtendedLifetime((daemon, listener)) { dispatchMain() }
