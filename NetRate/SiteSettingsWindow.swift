import AppKit

private final class SettingsPanel: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let editor = firstResponder as? NSTextView, editor.isFieldEditor {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": editor.paste(nil)
            case "x": editor.cut(nil)
            case "c": editor.copy(nil)
            case "a": editor.selectAll(nil)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class SiteSettingsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct ConfigurationFile {
        let store: ProbeConfigurationStore
        let startupError: Error?
        let didReload: () -> Void
    }

    private struct TableRow {
        let draft: SiteDraft
        let details: Bool
    }
    private var rows: [TableRow]
    private var drafts: [SiteDraft]
    private var savedOrder: [String]
    private var editors: [String: SiteEditor] = [:]
    private var probingEnabled: Bool
    private let configurationFile: ConfigurationFile?
    private var configurationError: Error?
    private let commit: ([ProbeSite]) throws -> Void
    private let didClose: () -> Void
    private let footer = NSTextField(labelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let help = ConfigurationHelpWindow()
    private lazy var remove = NSButton(title: "删除站点", target: self, action: #selector(removeSite))
    private lazy var up = NSButton(title: "上移", target: self, action: #selector(moveSiteUp))
    private lazy var down = NSButton(title: "下移", target: self, action: #selector(moveSiteDown))
    private lazy var apply = NSButton(title: "应用", target: self, action: #selector(applyChanges))
    private lazy var save = NSButton(title: "保存", target: self, action: #selector(saveChanges))

    init(sites: [ProbeSite], probingEnabled: Bool,
         configurationFile: ConfigurationFile? = nil, didClose: @escaping () -> Void = {},
         commit: @escaping ([ProbeSite]) throws -> Void) {
        drafts = sites.map(SiteDraft.init)
        rows = drafts.map { TableRow(draft: $0, details: false) }
        savedOrder = sites.map(\.id)
        self.probingEnabled = probingEnabled
        self.configurationFile = configurationFile
        configurationError = configurationFile?.startupError
        self.commit = commit
        self.didClose = didClose
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1000, height: 540)
        let width = min(1000, available.width - 16)
        let height = min(540, available.height - 48)
        let window = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.title = "探测站点配置"
        window.contentMinSize = NSSize(width: min(width, 838), height: min(height, 320))
        window.center()

        let widths: [SiteColumn: CGFloat] = [.name: 198, .method: 90, .codes: 154]
        for key in SiteColumn.allCases {
            let column = NSTableColumn(identifier: .init(key.rawValue))
            column.title = key == .name ? "站点名称" : key.topic.rawValue
            column.headerToolTip = key.topic.tip()
            column.width = widths[key] ?? max(220, width - 486)
            column.minWidth = key == .address ? 190 : column.width
            column.resizingMask = key == .address ? .autoresizingMask : []
            table.addTableColumn(column)
        }
        table.style = .plain
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.floatsGroupRows = false
        table.intercellSpacing = NSSize(width: 2, height: 2)
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("站点与探测强度")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: "新增站点", target: self, action: #selector(addSite))
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelChanges))
        cancel.keyEquivalent = "\u{1b}"
        save.keyEquivalent = "\r"
        apply.toolTip = "保存并应用修改，继续编辑。"
        apply.setAccessibilityHelp(apply.toolTip)
        let actions = NSStackView(views: [add, remove, up, down, help.makeButton(), NSView(), cancel, apply, save])
        for case let button as NSButton in actions.arrangedSubviews {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        actions.orientation = .horizontal
        actions.spacing = 8
        let content = window.contentView!
        HelpField.traffic.attach(to: footer)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        feedback.font = .systemFont(ofSize: 12)
        feedback.textColor = .systemRed
        let messages = NSStackView(views: [footer, feedback])
        messages.orientation = .vertical
        messages.alignment = .leading
        feedback.isHidden = true
        let status = NSStackView(views: [messages])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 8
        if configurationFile != nil {
            let fileMenu = NSPopUpButton(frame: .zero, pullsDown: true)
            fileMenu.addItem(withTitle: "配置文件")
            fileMenu.menu?.addItem(withTitle: "重新读取配置", action: #selector(reloadConfiguration), keyEquivalent: "").target = self
            fileMenu.menu?.addItem(withTitle: "在 Finder 中显示", action: #selector(revealConfiguration), keyEquivalent: "").target = self
            fileMenu.setContentCompressionResistancePriority(.required, for: .horizontal)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            status.addArrangedSubview(spacer)
            status.addArrangedSubview(fileMenu)
        }
        for view in [scroll, status, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -9),
            status.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -9),
            actions.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        refreshActions()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func syncMenu(_ config: ProbeConfiguration) {
        probingEnabled = config.probingEnabled
        let live = Dictionary(uniqueKeysWithValues: config.sites.map { ($0.id, $0) })
        for draft in drafts {
            guard let site = live[draft.id] else { continue }
            if draft.sync(site) {
                editors[draft.id]?.rebuild()
                if let row = rowIndex(draft, details: true) {
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                }
                showFeedback("已保留从菜单选中的个人强度。")
            } else {
                editors[draft.id]?.refresh()
            }
        }
        refreshActions()
    }

    private func editor(for draft: SiteDraft) -> SiteEditor {
        if let editor = editors[draft.id] { return editor }
        let editor = SiteEditor(draft: draft) { [weak self, weak draft] resized in
            guard let self, let draft else { return }
            if resized {
                updateRows(selecting: draft)
            } else if let row = rowIndex(draft), table.selectedRow != row {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            showFeedback(nil)
            refreshActions()
        }
        editors[draft.id] = editor
        return editor
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].details }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !rows[row].details }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].details ? editor(for: rows[row].draft).rowHeight : 29
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        let editor = editor(for: entry.draft)
        if entry.details { return editor }
        guard let column, let key = SiteColumn(rawValue: column.identifier.rawValue) else { return nil }
        return editor.siteCell(key)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshActions() }

    private func rowIndex(_ draft: SiteDraft, details: Bool = false) -> Int? {
        rows.firstIndex { $0.draft === draft && $0.details == details }
    }

    private var selectedRow: Int? {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return nil }
        return drafts.firstIndex { $0 === rows[row].draft }
    }

    // A visible table row and a position in the saved site order differ when any site is expanded.
    private func updateRows(selecting draft: SiteDraft? = nil, scroll: Bool = false) {
        rows = drafts.flatMap { item in
            let parent = TableRow(draft: item, details: false)
            return item.expanded ? [parent, TableRow(draft: item, details: true)] : [parent]
        }
        table.reloadData()
        if let draft, let row = rowIndex(draft) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if scroll { table.scrollRowToVisible(row) }
        }
        table.layoutSubtreeIfNeeded()
        refreshActions()
    }

    private func refreshBudget() {
        var total = ProbeBudget()
        for draft in drafts where draft.source.enabled {
            for lane in ProbeLane.allCases where draft.source[strength: lane].enabled {
                guard let strength = draft.selected(lane) else {
                    footer.stringValue = "全部站点合计 · 请先完成探测强度参数"
                    return
                }
                total.add(.init(lane: lane, interval: strength.values.interval))
            }
        }
        footer.stringValue = "全部站点合计 · " + (probingEnabled ? "预计 8 小时　" : "恢复探测后预计 8 小时　") + total.display
    }

    private func refreshActions() {
        refreshBudget()
        if let configurationError { showFeedback(configurationError.localizedDescription) }
        let row = selectedRow
        remove.isEnabled = row.map { !drafts[$0].source.isBuiltIn } ?? false
        up.isEnabled = row.map { $0 > 0 } ?? false
        down.isEnabled = row.map { $0 + 1 < drafts.count } ?? false
        apply.isEnabled = configurationError == nil && dirty
        save.isEnabled = configurationError == nil
    }

    private func showFeedback(_ message: String?) {
        feedback.stringValue = message ?? ""
        feedback.isHidden = message == nil
        feedback.toolTip = configurationFile?.store.url.path(percentEncoded: false)
        if message != nil { NSAccessibility.post(element: feedback, notification: .valueChanged) }
    }

    @objc private func addSite() {
        let draft = SiteDraft.new()
        drafts.append(draft)
        updateRows(selecting: draft, scroll: true)
        editor(for: draft).focus(.address)
    }

    @objc private func removeSite() {
        guard let row = selectedRow, !drafts[row].source.isBuiltIn else { return }
        editors.removeValue(forKey: drafts[row].id)
        drafts.remove(at: row)
        updateRows(selecting: drafts.isEmpty ? nil : drafts[min(row, drafts.count - 1)])
    }

    @objc private func moveSiteUp() { move(by: -1) }
    @objc private func moveSiteDown() { move(by: 1) }
    private func move(by offset: Int) {
        guard let row = selectedRow, drafts.indices.contains(row + offset) else { return }
        let selected = drafts[row]
        drafts.swapAt(row, row + offset)
        updateRows(selecting: selected, scroll: true)
    }

    private var dirty: Bool {
        drafts.map(\.id) != savedOrder || drafts.contains(where: \.isDirty)
    }

    @objc private func reloadConfiguration() {
        guard let configurationFile, let window, window.attachedSheet == nil else { return }
        do {
            let candidate = try configurationFile.store.read()
            if !dirty {
                applyReload(candidate, file: configurationFile)
                return
            }
            let alert = NSAlert()
            alert.messageText = "有未保存的站点修改"
            alert.informativeText = "重新读取会丢弃窗口里的修改。"
            alert.addButton(withTitle: "继续编辑").keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: "丢弃并重新读取")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertSecondButtonReturn { self?.applyReload(candidate, file: configurationFile) }
            }
        } catch {
            showConfigurationError(error)
        }
    }

    private func applyReload(_ candidate: ProbeConfigurationStore.Snapshot, file: ConfigurationFile) {
        do {
            try file.store.accept(candidate)
            configurationError = nil
            editors.removeAll()
            drafts = candidate.configuration.sites.map(SiteDraft.init)
            savedOrder = drafts.map(\.id)
            probingEnabled = candidate.configuration.probingEnabled
            showFeedback(nil)
            updateRows()
            file.didReload()
            refreshActions()
        } catch {
            showConfigurationError(error)
        }
    }

    @objc private func revealConfiguration() {
        guard let url = configurationFile?.store.url else { return }
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let directory = url.deletingLastPathComponent()
            let existing = FileManager.default.fileExists(atPath: directory.path(percentEncoded: false))
            NSWorkspace.shared.open(existing ? directory : directory.deletingLastPathComponent())
        }
    }

    private func showConfigurationError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        if let configurationFile {
            alert.informativeText = configurationFile.store.url.path(percentEncoded: false)
        }
        alert.beginSheetModal(for: window)
    }

    private func focus(_ field: SiteFormField, in draft: SiteDraft) {
        if let row = rowIndex(draft, details: field.lane != nil) {
            table.scrollRowToVisible(row)
            table.layoutSubtreeIfNeeded()
        }
        editor(for: draft).focus(field)
    }

    @objc private func saveChanges() {
        if commitChanges() { close() }
    }

    @objc private func applyChanges() {
        if dirty { _ = commitChanges() }
    }

    private func commitChanges() -> Bool {
        var sites: [ProbeSite] = []
        for draft in drafts {
            do {
                sites.append(try draft.build())
            } catch {
                let field = (error as? SiteInputError)?.field
                if let lane = field?.lane {
                    draft.expanded = true
                    draft.openLanes.insert(lane)
                    editor(for: draft).rebuild()
                }
                updateRows(selecting: draft, scroll: true)
                if let field { focus(field, in: draft) }
                showFeedback(draft.title + "：" + error.localizedDescription)
                return false
            }
        }
        do {
            try commit(sites)
            for (draft, site) in zip(drafts, sites) {
                draft.markCommitted(site)
                editors[draft.id]?.refresh()
            }
            savedOrder = sites.map(\.id)
            showFeedback(nil)
            refreshActions()
            return true
        } catch {
            showConfigurationError(error)
            return false
        }
    }

    @objc private func cancelChanges() { close() }

    func windowWillClose(_ notification: Notification) {
        help.dismiss()
        didClose()
    }
}
