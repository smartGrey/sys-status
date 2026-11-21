import AppKit

@MainActor
final class SiteSettingsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var draft: [ProbeSite]
    private let finish: ([ProbeSite]?) throws -> Void
    private var saved = false
    private let estimate: ([ProbeSite]) -> ProbeEstimate
    private var preview: ProbeEstimate
    private var editor: SiteEditor?
    private let footer = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let help = ConfigurationHelpWindow()
    private lazy var edit = NSButton(title: "编辑站点", target: self, action: #selector(editSite))
    private lazy var remove = NSButton(title: "删除", target: self, action: #selector(removeSite))

    init(sites: [ProbeSite], estimate: @escaping ([ProbeSite]) -> ProbeEstimate, finish: @escaping ([ProbeSite]?) throws -> Void) {
        draft = sites
        preview = estimate(sites)
        self.finish = finish
        self.estimate = estimate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 752, height: 324),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.title = "探测站点配置"
        window.contentMinSize = NSSize(width: 595, height: 258)
        window.center()

        let columns: [(String, String, CGFloat, HelpField)] = [
            ("enabled", "启用", 44, .siteEnabled), ("name", "站点", 125, .name), ("url", "HTTPS 地址", 302, .address),
            ("daily", "复用预计流量/小时", 113, .traffic), ("fresh", "新建预计流量/小时", 113, .traffic)
        ]
        for (id, title, width, topic) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.headerToolTip = topic.tip()
            column.headerCell.setAccessibilityHelp(topic.tip())
            column.width = width
            column.resizingMask = id == "url" ? .autoresizingMask : []
            column.minWidth = id == "url" ? 100 : width
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 4, height: 2)
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: "新增站点", target: self, action: #selector(addSite))
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelChanges))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "保存", target: self, action: #selector(saveChanges))
        save.keyEquivalent = "\r"
        let actions = NSStackView(views: [add, edit, remove, help.makeButton(), NSView(), cancel, save])
        for case let button as NSButton in actions.arrangedSubviews {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        actions.orientation = .horizontal
        actions.spacing = 8
        let content = window.contentView!
        HelpField.traffic.attach(to: footer)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        for view in [scroll, footer, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -9),
            footer.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            footer.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -9),
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

    func numberOfRows(in tableView: NSTableView) -> Int { draft.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let site = draft[row]
        switch column?.identifier.rawValue {
        case "enabled":
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleSite(_:)))
            HelpField.siteEnabled.attach(to: checkbox)
            checkbox.state = site.enabled ? .on : .off
            checkbox.setAccessibilityLabel("启用 " + site.name)
            let cell = NSView()
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(checkbox)
            NSLayoutConstraint.activate([
                checkbox.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        case "name":
            return label(site.isBuiltIn ? site.name + "（内置）" : site.name)
        case "daily", "fresh":
            let kind: ProbeLane = column?.identifier.rawValue == "daily" ? .daily : .fresh
            return label(ProbeUsage.display(preview.sites[site.id]?[kind] ?? 0, perHour: false), alignment: .right, topic: .traffic)
        default:
            return label(site.url.absoluteString)
        }
    }

    private func label(_ text: String, alignment: NSTextAlignment = .left, topic: HelpField? = nil) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        if let topic { topic.attach(to: field) } else { field.toolTip = text }
        let cell = NSView()
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshActions() }

    private var editableRow: Int? {
        let row = table.selectedRow
        return draft.indices.contains(row) ? row : nil
    }

    func refreshEstimate() {
        let next = estimate(draft)
        let changed = IndexSet(draft.indices.filter { next.sites[draft[$0].id] != preview.sites[draft[$0].id] })
        preview = next
        footer.stringValue = next.footer
        if !changed.isEmpty {
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 3...4))
        }
        editor?.refreshPreview()
    }

    private func refreshActions() {
        refreshEstimate()
        edit.isEnabled = editableRow != nil
        remove.isEnabled = editableRow.map { !draft[$0].isBuiltIn } ?? false
    }

    @objc private func toggleSite(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard draft.indices.contains(row) else { return }
        if sender.state == .on && !draft[row].daily.enabled && !draft[row].fresh.enabled {
            sender.state = .off
            showEditor(row: row, enabling: true)
            return
        }
        draft[row].enabled = sender.state == .on
        refreshEstimate()
    }

    @objc private func addSite() { showEditor(row: nil) }

    @objc private func editSite() {
        if let row = editableRow { showEditor(row: row) }
    }

    @objc private func removeSite() {
        guard let row = editableRow, !draft[row].isBuiltIn else { return }
        draft.remove(at: row)
        table.reloadData()
        refreshActions()
    }

    private func showEditor(row: Int?, enabling: Bool = false) {
        guard let window else { return }
        var site = row.map { draft[$0] }
        if enabling { site?.enabled = true }
        let editor = SiteEditor(site: site, help: help) { [estimate] candidate in
            estimate([candidate]).sites[candidate.id] ?? SiteTraffic()
        }
        self.editor = editor
        window.beginSheet(editor.sheet) { [weak self] response in
            guard let self else { return }
            self.editor = nil
            if response == .OK, let value = editor.saved {
                if let row { self.draft[row] = value } else { self.draft.append(value) }
                self.table.reloadData()
                self.table.selectRowIndexes(IndexSet(integer: row ?? self.draft.count - 1), byExtendingSelection: false)
            }
            self.refreshActions()
        }
    }

    @objc private func saveChanges() {
        do {
            try finish(draft)
            saved = true
            close()
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    @objc private func cancelChanges() { close() }

    func windowWillClose(_ notification: Notification) {
        help.dismiss()
        if !saved { try? finish(nil) }
    }
}
