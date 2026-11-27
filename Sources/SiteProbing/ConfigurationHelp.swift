import AppKit

private final class HelpDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class HelpPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            cancelOperation(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ConfigurationHelpWindow: NSWindowController, NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource {
    private enum Topic: Equatable {
        case group(String), field(HelpField), rule(HelpRule)

        var title: String {
            switch self {
            case .group(let name): name
            case .field(let field): field.rawValue
            case .rule(let rule): rule.rawValue
            }
        }

        var isGroup: Bool {
            if case .group = self { return true }
            return false
        }
    }

    private let topics: [Topic] = [.group("配置项")] + HelpField.allCases.map(Topic.field) +
        [.group("联动规则")] + HelpRule.allCases.map(Topic.rule)
    private let navigation = NSTableView()
    private let article = NSStackView()
    private let reader = NSScrollView()
    private weak var settingsWindow: NSWindow?
    private var hasPosition = false

    init() { super.init(window: nil) }
    required init?(coder: NSCoder) { nil }

    func makeButton() -> NSButton {
        let button = NSButton(title: "配置说明", target: self, action: #selector(present(_:)))
        button.setAccessibilityHelp("打开可与配置窗口并排阅读的字段说明和联动规则。")
        return button
    }

    @objc private func present(_ button: NSButton) {
        guard let origin = button.window else { return }
        if window == nil { loadWindow() }
        guard let panel = window else { return }
        let parent = origin.sheetParent ?? origin
        settingsWindow = parent
        if !hasPosition, let screen = parent.screen {
            let area = screen.visibleFrame
            let size = panel.frame.size
            let right = parent.frame.maxX + 8
            let left = parent.frame.minX - size.width - 8
            let x = right + size.width <= area.maxX ? right : (left >= area.minX ? left : area.maxX - size.width)
            let y = min(area.maxY, max(area.minY + size.height, parent.frame.maxY))
            panel.setFrameTopLeftPoint(NSPoint(x: max(x, area.minX), y: y))
            hasPosition = true
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        settingsWindow = nil
        if isWindowLoaded { close() }
    }

    func windowWillClose(_ notification: Notification) {
        if let root = settingsWindow, root.isVisible {
            (root.attachedSheet ?? root).makeKeyAndOrderFront(nil)
        }
    }

    override func loadWindow() {
        let panel = HelpPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 455),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "配置说明"
        panel.contentMinSize = NSSize(width: 510, height: 280)
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let column = NSTableColumn(identifier: .init("topic"))
        navigation.addTableColumn(column)
        navigation.headerView = nil
        navigation.style = .sourceList
        navigation.rowHeight = 25
        navigation.floatsGroupRows = false
        navigation.allowsEmptySelection = false
        navigation.setAccessibilityLabel("说明目录")
        navigation.dataSource = self
        navigation.delegate = self
        let sidebar = NSScrollView()
        sidebar.hasVerticalScroller = true
        sidebar.documentView = navigation

        reader.hasVerticalScroller = true
        reader.drawsBackground = false
        let document = HelpDocument()
        reader.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        article.orientation = .vertical
        article.alignment = .leading
        article.spacing = 14
        article.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(article)
        let content = panel.contentView!
        for view in [sidebar, reader] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            view.topAnchor.constraint(equalTo: content.topAnchor).isActive = true
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 197),
            reader.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            reader.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            document.leadingAnchor.constraint(equalTo: reader.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: reader.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: reader.contentView.widthAnchor),
            article.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            article.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            article.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            article.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -20),
            document.heightAnchor.constraint(greaterThanOrEqualTo: reader.contentView.heightAnchor)
        ])
        // Hug the article when it needs to scroll, and fill the viewport for shorter topics.
        let fit = article.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        fit.priority = .fittingSizeCompression
        fit.isActive = true
        window = panel
        panel.initialFirstResponder = navigation
        navigation.reloadData()
        select(.field(.siteEnabled))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { topics.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { topics[row].isGroup }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !topics[row].isGroup }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let topic = topics[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: topic.title)
        label.font = topic.isGroup ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 12)
        if topic.isGroup { label.textColor = .secondaryLabelColor }
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func select(_ topic: Topic) {
        guard let row = topics.firstIndex(of: topic) else { return }
        navigation.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        navigation.scrollRowToVisible(row)
    }

    @objc private func openRule(_ sender: NSButton) { select(topics[sender.tag]) }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard topics.indices.contains(navigation.selectedRow) else { return }
        let topic = topics[navigation.selectedRow]
        for view in article.arrangedSubviews { view.removeFromSuperview() }
        append(text(topic.title, font: .systemFont(ofSize: 19, weight: .semibold)))
        switch topic {
        case .group: return
        case .field(let field):
            let help = field.help
            append(text(help.tip))
            append(text(help.detail))
            append(text("相关规则", font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor))
            let link = NSButton(title: help.rule.rawValue, target: self, action: #selector(openRule(_:)))
            link.controlSize = .small
            link.image = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: nil)
            link.imagePosition = .imageTrailing
            link.tag = topics.firstIndex(of: .rule(help.rule))!
            article.addArrangedSubview(link)
        case .rule(let rule):
            append(text(rule.summary))
            for (index, values) in rule.rows.enumerated() {
                let row = NSStackView()
                row.orientation = .horizontal
                row.distribution = .fill
                row.alignment = .firstBaseline
                row.spacing = 10
                let labels = values.map { text($0, font: .systemFont(ofSize: 12, weight: index == 0 ? .semibold : .regular)) }
                for label in labels { row.addArrangedSubview(label) }
                append(row)
                labels[0].widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: values.count == 4 ? 0.34 : 0.46).isActive = true
                for label in labels.dropFirst(2) {
                    label.widthAnchor.constraint(equalTo: labels[1].widthAnchor).isActive = true
                }
                if index == 0 {
                    let line = NSBox()
                    line.boxType = .separator
                    append(line)
                }
            }
            append(text(rule.note, font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
        }
        reader.contentView.layoutSubtreeIfNeeded()
        reader.documentView?.scroll(.zero)
    }

    private func append(_ view: NSView) {
        article.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: article.widthAnchor).isActive = true
    }

    private func text(_ value: String, font: NSFont = .systemFont(ofSize: 13), color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = font
        label.textColor = color
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
