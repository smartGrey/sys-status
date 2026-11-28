import SwiftUI

@MainActor
final class StatusPreferences: ObservableObject {
    @Published private(set) var order = StatusModule.allCases
    @Published var enabled: Set<StatusModule> = [.network]
    private struct Document: Codable {
        let version: Int
        let order: [String]
        let showAllSites: Bool
    }
    private(set) var showAllSites = false
    private let url: URL
    private var readError: Error?
    private var window: NSWindow?
    var didChange: (([StatusModule]) -> Void)?

    init(url: URL) { self.url = url }

    func restore() {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let identifiers: [String]
            if let legacy = try? decoder.decode([String].self, from: data) {
                identifiers = legacy
                showAllSites = false
            } else {
                let document = try decoder.decode(Document.self, from: data)
                guard document.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                identifiers = document.order
                showAllSites = document.showAllSites
            }
            order = StatusModule.ordered(identifiers.compactMap(StatusModule.init(rawValue:)))
            readError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { readError = nil }
        catch { readError = error }
        didChange?(order)
    }

    func save(_ next: [StatusModule]) {
        let next = StatusModule.ordered(next)
        guard next != order else { return }
        if persist(order: next, showAllSites: showAllSites) {
            order = next
            didChange?(next)
        }
    }

    func setShowAllSites(_ value: Bool) -> Bool {
        guard showAllSites != value else { return true }
        guard persist(order: order, showAllSites: value) else { return false }
        showAllSites = value
        return true
    }

    private func persist(order: [StatusModule], showAllSites: Bool) -> Bool {
        do {
            if let readError { throw readError }
            try AppDataFile.write(Document(version: 1, order: order.map(\.rawValue), showAllSites: showAllSites), to: url)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
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
            self.window = window
        }
        guard let window else { return }
        if !window.isVisible, let screen = OperationFeedback.menu.screen {
            let area = screen.visibleFrame
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.setFrameOrigin(NSPoint(x: area.midX-window.frame.width/2, y: area.midY-window.frame.height/2))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.collectionBehavior.remove(.moveToActiveSpace)
    }
}

struct StatusPreferencesView: View {
    @ObservedObject var model: StatusPreferences
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("状态栏模块顺序").font(.headline)
            Text("从上到下对应总菜单顺序和状态栏从左到右的顺序。").font(.callout).foregroundStyle(.secondary)
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
        }.padding(18).frame(width: 300).allowsWindowActivationEvents()
    }
}
