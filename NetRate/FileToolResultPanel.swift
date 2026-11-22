import AppKit

// The selectable units are leaves: a directory subtotal and its children must never
// both contribute to the selected total. A zero-line leaf still has a checkbox.
private struct DirectorySelection {
    let leaves: [LineGroup]
    private var excluded: Set<LineGroup> = []
    private(set) var lines: Int
    var isAll: Bool { excluded.isEmpty }
    var isNone: Bool { excluded.count == leaves.count }

    init(groups: [LineGroup]) {
        var files: [LineGroup] = []
        for group in groups { group.forEachLeaf { files.append($0) } }
        leaves = files
        lines = leaves.reduce(0) { $0 + $1.lines }
    }

    func state(of group: LineGroup) -> NSControl.StateValue {
        if group.children.isEmpty { return excluded.contains(group) ? .off : .on }
        let first = state(of: group.children[0])
        return group.children.dropFirst().contains { state(of: $0) != first } ? .mixed : first
    }

    mutating func toggle(_ group: LineGroup) {
        let enable = state(of: group) != .on
        group.forEachLeaf { leaf in
            if enable {
                if excluded.remove(leaf) != nil { lines += leaf.lines }
            } else if excluded.insert(leaf).inserted {
                lines -= leaf.lines
            }
        }
    }

    mutating func setAll(_ enable: Bool) {
        excluded = enable ? [] : Set(leaves)
        lines = enable ? leaves.reduce(0) { $0 + $1.lines } : 0
    }
}

private extension LineGroup {
    func forEachLeaf(_ visit: (LineGroup) -> Void) {
        if children.isEmpty { visit(self) }
        else { for child in children { child.forEachLeaf(visit) } }
    }
}

private final class DirectoryOutline: NSOutlineView {
    var toggleSelected: ((LineGroup) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", selectedRow >= 0,
           let item = item(atRow: selectedRow) as? LineGroup {
            toggleSelected?(item)
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class FileToolResultPanel: NSPanel, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let body = NSStackView()
    private let minimumWidth: CGFloat = 464
    private let minimumListHeight: CGFloat = 70
    private let margin: CGFloat = 24
    private var groups: [LineGroup] = []
    private let outline = DirectoryOutline()
    private var selection = DirectorySelection(groups: [])
    private let number = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private var totalLabel = ""
    private let controls = NSStackView()
    private let selectAll = NSButton()
    private let clearAll = NSButton()
    private let scroll = NSScrollView()
    private let disclosure = NSButton()
    private var detailsBottom: NSLayoutConstraint!
    private var scrollWidth: NSLayoutConstraint?
    private var compactHeight: CGFloat = 180
    var hasManualSize = false
    private let reselectButton = NSButton()
    private let reselect: () -> Void

    init(_ message: FileTool.Message, reselect: @escaping () -> Void) {
        self.reselect = reselect
        super.init(contentRect: NSRect(x: 0, y: 0, width: 464, height: 180),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = message.tool.title
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = false
        addReselectButton()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        let content = contentView!
        content.addSubview(body)
        detailsBottom = body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            body.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -margin)
        ])

        let name = NSTextField(labelWithString: message.target.lastPathComponent)
        name.font = .systemFont(ofSize: 14, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = message.target.path
        let icon = NSImageView()
        let isFile: Bool
        if case .lines(let count) = message.content { isFile = !count.isDirectory } else { isFile = false }
        icon.image = NSImage(systemSymbolName: isFile ? "doc.text" : "folder", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        let heading = NSStackView(views: [icon, name, NSView()])
        addRow(heading)
        switch message.content {
        case .lines(let count):
            let label = count.issues.count == 0 ? "总行数" : "已统计行数"
            addMetric(count.lines, unit: "行", label: label)
            if !count.groups.isEmpty { addDirectoryDetails(count.groups, total: count.lines) }
            if let reason = count.issues.first { addNote("部分内容未能读取。\n" + reason, warning: true) }
            separator()
            addNote(count.isDirectory
                    ? "统计代码、脚本、文档和配置，包含空行和注释。跳过点号开头的隐藏项、常见依赖、构建产物、数据和生成文件。无符合口径的目录显示 0 行。"
                    : "按所选文件的实际行数统计，包含空行和注释。")
        case .cleanup(let result):
            addMetric(result.total, unit: "个文件", label: "共清理")
            separator()
            addCategory("Finder 文件夹记录（.DS_Store）", count: result.finderRecords)
            addCategory("Mac 文件附加信息（._）", count: result.appleDoubleFiles)
            if let reason = result.issues.first {
                addNote("有 \(result.issues.count) 项处理失败。\n" + reason, warning: true)
            } else if result.total == 0 {
                addNote("未发现可清理的 Mac 附加文件")
            }
        case .failure(let reason):
            addNote(message.tool == .count ? "无法统计行数" : "未能清理目录", warning: true)
            addNote(reason)
        }
        compactHeight = ceil(body.fittingSize.height) + margin * 2
        contentMinSize = NSSize(width: minimumWidth, height: compactHeight)
        resizeContent(height: compactHeight)
    }

    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    func setReselectEnabled(_ enabled: Bool) { reselectButton.isEnabled = enabled }

    private func addReselectButton() {
        reselectButton.title = "重新选择"
        reselectButton.toolTip = "重新选择要处理的位置"
        reselectButton.bezelStyle = .accessoryBarAction
        reselectButton.controlSize = .small
        reselectButton.target = self
        reselectButton.action = #selector(chooseAgain)
        reselectButton.sizeToFit()
        let size = reselectButton.frame.size
        reselectButton.setFrameOrigin(NSPoint(x: 0, y: 2))
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 12, height: size.height + 4))
        accessory.view.addSubview(reselectButton)
        accessory.layoutAttribute = .right
        addTitlebarAccessoryViewController(accessory)
    }

    @objc private func chooseAgain() { reselect() }

    private func addRow(_ view: NSView) {
        body.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    private func addNote(_ text: String, warning: Bool = false) {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: 12)
        note.textColor = warning ? .labelColor : .secondaryLabelColor
        note.preferredMaxLayoutWidth = minimumWidth - margin * 2
        note.maximumNumberOfLines = 5
        note.lineBreakMode = .byWordWrapping
        note.toolTip = text
        addRow(note)
    }

    private func separator() {
        let line = NSBox()
        line.boxType = .separator
        addRow(line)
    }

    private func addMetric(_ value: Int, unit: String, label: String) {
        totalLabel = label
        caption.stringValue = label
        caption.textColor = .secondaryLabelColor
        caption.font = .systemFont(ofSize: 12)
        body.addArrangedSubview(caption)
        body.setCustomSpacing(2, after: caption)
        number.stringValue = value.formatted()
        number.font = .monospacedDigitSystemFont(ofSize: 32, weight: .semibold)
        let suffix = NSTextField(labelWithString: unit)
        suffix.textColor = .secondaryLabelColor
        let row = NSStackView(views: [number, suffix])
        row.alignment = .firstBaseline
        row.spacing = 6
        body.addArrangedSubview(row)
    }

    private func addCategory(_ name: String, count: Int) {
        let number = NSTextField(labelWithString: count.formatted())
        number.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let row = NSStackView(views: [NSTextField(labelWithString: name), NSView(), number])
        addRow(row)
    }

    private func addDirectoryDetails(_ entries: [LineGroup], total: Int) {
        groups = entries
        selection = DirectorySelection(groups: entries)
        disclosure.title = "目录详情"
        disclosure.isBordered = false
        disclosure.setButtonType(.toggle)
        disclosure.imagePosition = .imageLeading
        disclosure.target = self
        disclosure.action = #selector(toggleDetails)
        updateDisclosure()
        controls.addArrangedSubview(disclosure)
        controls.addArrangedSubview(NSView())
        for (button, title) in [(selectAll, "全选"), (clearAll, "取消全选")] {
            button.title = title
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.target = self
            button.action = #selector(changeAll(_:))
            controls.addArrangedSubview(button)
        }
        addRow(controls)
        outline.toggleSelected = { [weak self] entry in self?.toggleGroup(entry) }
        refreshSelection()

        let path = NSTableColumn(identifier: .init("directory"))
        let amount = NSTableColumn(identifier: .init("lines"))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        amount.width = max(64, (total.formatted() as NSString).size(withAttributes: [.font: font]).width + 16)
        amount.resizingMask = []
        path.width = minimumWidth - margin * 2 - amount.width - 16
        path.resizingMask = .autoresizingMask
        outline.addTableColumn(path)
        outline.addTableColumn(amount)
        outline.outlineTableColumn = path
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = 25
        outline.intercellSpacing = NSSize(width: 2, height: 2)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("文件和目录的统计行数")
        outline.autoresizingMask = [.width]
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        outline.backgroundColor = .clear
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumListHeight).isActive = true
        outline.reloadData()
    }

    private func updateDisclosure() {
        let open = disclosure.state == .on
        disclosure.image = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        disclosure.setAccessibilityValue(open ? "已展开" : "已收起")
        selectAll.isHidden = !open
        clearAll.isHidden = !open
    }

    @objc private func toggleDetails() {
        updateDisclosure()
        if disclosure.state == .on {
            let minimumHeight = compactHeight + body.spacing + minimumListHeight
            contentMinSize.height = minimumHeight
            resizeContent(height: hasManualSize ? max(contentView!.bounds.height, minimumHeight) : preferredDetailsHeight)
            let index = body.arrangedSubviews.firstIndex(of: controls)!
            body.insertArrangedSubview(scroll, at: index + 1)
            scrollWidth = scroll.widthAnchor.constraint(equalTo: body.widthAnchor)
            scrollWidth?.isActive = true
            detailsBottom.isActive = true
        } else {
            detailsBottom.isActive = false
            scrollWidth?.isActive = false
            body.removeArrangedSubview(scroll)
            scroll.removeFromSuperview()
            contentMinSize.height = compactHeight
            if !hasManualSize { resizeContent(height: compactHeight) }
        }
    }

    private var preferredDetailsHeight: CGFloat {
        let visibleRows = CGFloat(outline.numberOfRows) * (outline.rowHeight + outline.intercellSpacing.height)
        return compactHeight + body.spacing + min(240, max(minimumListHeight, visibleRows + 2))
    }

    func outlineViewItemDidExpand(_ notification: Notification) { fitExpandedRows() }
    func outlineViewItemDidCollapse(_ notification: Notification) { fitExpandedRows() }

    private func fitExpandedRows() {
        if !hasManualSize && detailsBottom.isActive { resizeContent(height: preferredDetailsHeight) }
    }

    @objc private func changeAll(_ sender: NSButton) {
        selection.setAll(sender === selectAll)
        refreshSelection()
    }

    @objc private func checkDirectory(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, let entry = outline.item(atRow: row) as? LineGroup else { return }
        toggleGroup(entry)
    }

    private func toggleGroup(_ group: LineGroup) {
        selection.toggle(group)
        refreshSelection()
    }

    private func refreshSelection() {
        number.stringValue = selection.lines.formatted()
        caption.stringValue = selection.isAll ? totalLabel : "已选行数"
        selectAll.isEnabled = !selection.isAll
        clearAll.isEnabled = !selection.isNone
        guard scroll.superview != nil else { return }
        // Refresh the checkbox column without rebuilding the tree or changing its expansion.
        outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows),
                           columnIndexes: IndexSet(integer: 0))
    }

    private func resizeContent(height: CGFloat) {
        let size = NSSize(width: contentView!.bounds.width, height: height)
        var target = frameRect(forContentRect: NSRect(origin: .zero, size: size))
        target.origin = NSPoint(x: frame.minX, y: frame.maxY - target.height)
        setFrame(constrainFrameRect(target, to: screen), display: true)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? LineGroup)?.children.count ?? groups.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? LineGroup)?.children ?? groups)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let group = item as? LineGroup else { return false }
        return !group.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let group = item as? LineGroup, let id = tableColumn?.identifier else { return nil }
        if tableColumn === outline.outlineTableColumn {
            let button = outline.makeView(withIdentifier: id, owner: self) as? NSButton
                ?? NSButton(checkboxWithTitle: "", target: self, action: #selector(checkDirectory(_:)))
            button.identifier = id
            button.title = group.name
            button.alignment = .left
            button.lineBreakMode = .byTruncatingMiddle
            button.allowsMixedState = true
            button.state = selection.state(of: group)
            button.toolTip = group.name
            return button
        }
        let cell = outline.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            field.alignment = .right
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2)
            ])
        }
        cell.textField?.stringValue = group.lines.formatted()
        cell.toolTip = "共 \(group.lines.formatted()) 行"
        return cell
    }
}
