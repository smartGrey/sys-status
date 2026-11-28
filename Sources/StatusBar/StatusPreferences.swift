import SwiftUI

@MainActor
final class StatusPreferences: ObservableObject {
    @Published private(set) var order = StatusModule.allCases
    @Published var enabled: Set<StatusModule> = [.network]
    private let url: URL
    private var readError: Error?
    private var window: NSWindow?
    var didChange: (([StatusModule]) -> Void)?

    init(url: URL) { self.url = url }

    func restore() {
        do {
            let identifiers = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
            order = StatusModule.ordered(identifiers.compactMap(StatusModule.init(rawValue:)))
            readError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { readError = nil }
        catch { readError = error }
        didChange?(order)
    }

    func save(_ next: [StatusModule]) {
        let next = StatusModule.ordered(next)
        guard next != order else { return }
        do {
            if let readError { throw readError }
            try AppDataFile.write(next, to: url)
            order = next
            didChange?(next)
        } catch { NSAlert(error: error).runModal() }
    }

    @objc func show() {
        if readError != nil { restore() }
        if let readError { NSAlert(error: readError).runModal(); return }
        if window == nil {
            let view = StatusPreferencesView(model: self)
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.title = "偏好设置"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct StatusPreferencesView: View {
    @ObservedObject var model: StatusPreferences
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("状态栏模块顺序").font(.headline)
            Text("从上到下对应菜单栏从左到右。").font(.callout).foregroundStyle(.secondary)
            ReorderBoard(groups: [model.order], commit: { model.save($0[0]) }) { module in
                HStack {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    Text(module.title)
                    Spacer()
                    if !model.enabled.contains(module) { Text("未启用").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
        }.padding(18).frame(width: 300)
    }
}
