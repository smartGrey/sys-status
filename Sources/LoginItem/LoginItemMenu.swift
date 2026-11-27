import AppKit
import ServiceManagement

protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

@MainActor
final class LoginItemMenu: NSObject {
    private let service: any LoginItemService
    private let openSettings: @MainActor () -> Void
    private let report: (Error) -> Void

    init(service: any LoginItemService = SMAppService.mainApp,
         openSettings: @escaping @MainActor () -> Void = SMAppService.openSystemSettingsLoginItems,
         report: @escaping (Error) -> Void = { NSAlert(error: $0).runModal() }) {
        self.service = service
        self.openSettings = openSettings
        self.report = report
    }

    lazy var item: StatusMenuToggleItem = {
        let item = StatusMenuToggleItem.make(title: "登录时启动", action: #selector(toggleLogin))
        item.target = self
        return item
    }()

    func refresh() {
        let status = service.status
        item.title = status == .requiresApproval ? "登录时启动（待批准）" : "登录时启动"
        item.state = status == .enabled ? .on : status == .requiresApproval ? .mixed : .off
        item.refreshRow()
    }

    @objc private func toggleLogin() {
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: item.afterClosingMenu(openSettings)
            default: try service.register()
            }
            refresh()
        } catch {
            refresh()
            item.afterClosingMenu { [report] in report(error) }
        }
    }
}
