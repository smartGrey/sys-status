import AppKit

enum FileTool: CaseIterable, Sendable {
    case count, clean

    var title: String { self == .count ? "统计文本行数" : "清理 Mac 附加文件" }

    @MainActor func selectionPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = self == .count ? "统计" : "清理"
        panel.message = self == .count ? "选择一个文本文件或项目目录。"
            : "将删除所选目录及其子目录中的 .DS_Store 和 Mac 的 ._ 附加文件。"
        panel.canChooseFiles = self == .count
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.canCreateDirectories = false
        return panel
    }

    struct Message: Sendable {
        enum Content: Sendable {
            case lines(ProjectLineCount)
            case cleanup(MacFileCleanup)
            case failure(String)
        }
        let tool: FileTool
        let target: URL
        let content: Content
    }

    func run(at url: URL) -> Message {
        let content: Message.Content
        do {
            switch self {
            case .count: content = .lines(try ProjectLineCount.count(url))
            case .clean: content = .cleanup(try DirectoryFiles.cleanMacFiles(in: url))
            }
        } catch {
            content = .failure(error.localizedDescription)
        }
        return Message(tool: self, target: url, content: content)
    }
}

@MainActor
final class FileToolsMenu: NSObject, NSWindowDelegate {
    private let select: @MainActor (FileTool, URL?) async -> URL?
    private let present: (@MainActor (FileTool.Message) -> Void)?
    private var resultPanel: FileToolResultPanel?
    private var items: [NSMenuItem] = []
    private var busy = false

    init(select: @escaping @MainActor (FileTool, URL?) async -> URL? = { tool, directory in
             let panel = tool.selectionPanel()
             if let directory { panel.directoryURL = directory }
             NSApp.activate()
             guard await panel.begin() == .OK else { return nil }
             return panel.url
         },
         present: (@MainActor (FileTool.Message) -> Void)? = nil) {
        self.select = select
        self.present = present
    }

    func add(to menu: NSMenu) {
        for tool in FileTool.allCases {
            let item = menu.addItem(withTitle: tool.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tool
            items.append(item)
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? FileTool else { return }
        run(tool)
    }

    private func run(_ tool: FileTool, from directory: URL? = nil) {
        guard !busy else { return }
        let item = items.first { $0.representedObject as? FileTool == tool }
        busy = true
        items.forEach { $0.isEnabled = false }
        resultPanel?.setReselectEnabled(false)
        Task { [self] in
            defer {
                busy = false
                item?.title = tool.title
                items.forEach { $0.isEnabled = true }
                resultPanel?.setReselectEnabled(true)
            }
            guard let url = await select(tool, directory) else { return }
            item?.title = tool == .count ? "正在统计文本行数…" : "正在清理 Mac 附加文件…"
            let message = await Task.detached(priority: .utility) { tool.run(at: url) }.value
            if let present {
                present(message)
            } else {
                resultPanel?.close()
                let panel = FileToolResultPanel(message) { [weak self] in
                    self?.run(tool, from: url.deletingLastPathComponent())
                }
                resultPanel = panel
                panel.delegate = self
                panel.center()
                NSApp.activate()
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? FileToolResultPanel === resultPanel { resultPanel = nil }
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        (notification.object as? FileToolResultPanel)?.hasManualSize = true
    }
}
