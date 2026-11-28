import AppKit

class StopwatchFlippedView: PanelDragView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        if let label = view as? NSTextField, !label.isEditable, !label.isSelectable { return self }
        return view
    }
}

@MainActor
final class StopwatchPanelContent: StopwatchFlippedView {
    private static let preferredWidth: CGFloat = 452
    private static let inset: CGFloat = 14
    private static let modeLabelWidth: CGFloat = 29
    private static let modeWidth: CGFloat = 108
    private static let groupGap: CGFloat = 10

    var onSelect: ((UUID) -> Void)?
    var onRename: ((UUID, String) -> Void)?
    var onToggle: ((UUID) -> Void)?
    var onReset: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onAdd: (() -> Void)?
    var onMode: ((StopwatchMode) -> Void)?
    var onRecord: ((StopwatchAction) -> Void)?
    var onClear: ((StopwatchAction) -> Void)?

    private var rows: [StopwatchPanelRow] = []
    let addButton = NSButton(title: "添加秒表", target: nil, action: nil)
    private let modeLabel = StopwatchPanelContent.caption("模式")
    private let mode = NSSegmentedControl(labels: ["互斥", "并行"], trackingMode: .selectOne, target: nil, action: nil)
    private let modeHint = StopwatchPanelContent.hint()
    private let saveHint = StopwatchPanelContent.hint()
    private let keycaps = StopwatchAction.allCases.map { StopwatchKeycap(action: $0) }
    private var inputIssues: [StopwatchAction: String] = [:]
    private var size: NSSize = .zero
    private struct Layout: Equatable {
        let width: CGFloat
        let columns: StopwatchPanelRow.Columns
        let modeHint: String
        let shortcutWidths: [CGFloat]
        let shortcutHints: [String]
        let hasSaveError: Bool
    }

    private var layout: Layout?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addButton.bezelStyle = .accessoryBarAction
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.font = .systemFont(ofSize: 14, weight: .medium)
        addButton.contentTintColor = .controlAccentColor
        addButton.setAccessibilityLabel("添加秒表")
        addButton.target = self
        addButton.action = #selector(addClicked)
        mode.segmentStyle = .rounded
        mode.selectedSegmentBezelColor = .darkGray
        mode.target = self
        mode.action = #selector(modeClicked)
        mode.setWidth(50, forSegment: 0)
        mode.setWidth(50, forSegment: 1)
        mode.setAccessibilityLabel("计时模式")
        mode.setToolTip("开始一项时暂停其他秒表", forSegment: 0)
        mode.setToolTip("多个秒表可以同时计时", forSegment: 1)
        saveHint.stringValue = "秒表数据尚未保存"
        saveHint.textColor = .systemOrange

        [modeLabel, mode, modeHint, saveHint].forEach(addSubview)
        for keycap in keycaps {
            addSubview(keycap.label)
            addSubview(keycap.button)
            addSubview(keycap.clear)
            addSubview(keycap.hint)
            keycap.clear.target = self
            keycap.clear.action = #selector(clearClicked(_:))
            keycap.clear.tag = Int(keycap.action.rawValue)
            keycap.button.target = self
            keycap.button.action = #selector(keyClicked(_:))
            keycap.button.tag = Int(keycap.action.rawValue)
        }
    }

    required init?(coder: NSCoder) { nil }

    var editorHasMarkedText: Bool { rows.contains(where: \.editorHasMarkedText) }

    func beginEditing(_ id: UUID) { rows.first(where: { $0.id == id })?.beginEditing() }

    @discardableResult
    func finishEditing(commit: Bool) -> Bool {
        guard let row = rows.first(where: \.isEditing) else { return false }
        row.finishEditing(commit: commit)
        return true
    }

    func showShortcutError(_ message: String, for action: StopwatchAction) {
        inputIssues[action] = message
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func clearInputIssues() { inputIssues.removeAll() }

    func clearInputIssue(_ action: StopwatchAction) { inputIssues[action] = nil }

    func update(_ data: StopwatchPresentation, availableWidth: CGFloat, recording: StopwatchAction?,
                issues: [StopwatchAction: String], hasSaveError: Bool) -> NSSize {
        let sameRows = rows.map(\.id) == data.readings.map(\.id)
        if !sameRows { reconcileRows(data.readings) }
        let canDelete = rows.count > 1
        for (row, reading) in zip(rows, data.readings) {
            row.update(reading, focused: data.focus == reading.id, canDelete: canDelete)
        }
        let selectedMode = data.mode == .exclusive ? 0 : 1
        if mode.selectedSegment != selectedMode { mode.selectedSegment = selectedMode }
        modeHint.stringValue = data.modeHint ?? ""
        saveHint.isHidden = !hasSaveError
        for keycap in keycaps {
            keycap.update(shortcut: data.shortcuts[keycap.action], recording: recording == keycap.action,
                          issue: inputIssues[keycap.action] ?? (recording == keycap.action ? nil : issues[keycap.action]))
        }
        let columns = StopwatchPanelRow.Columns(data.readings)
        addButton.isHidden = rows.count >= StopwatchState.maximumCount
        let minimumWidth = 2 * Self.inset + max(columns.minimumWidth, controlsWidth)
        let width = min(availableWidth, max(Self.preferredWidth, minimumWidth))
        let signature = Layout(width: width, columns: columns,
                               modeHint: modeHint.stringValue, shortcutWidths: keycaps.map(\.width), shortcutHints: keycaps.map { $0.hint.stringValue },
                               hasSaveError: hasSaveError)
        if !sameRows || signature != layout {
            layout = signature
            size = layoutContent(width: width, columns: columns)
        }
        return size
    }

    private func reconcileRows(_ readings: [StopwatchReading]) {
        let ids = Set(readings.map(\.id))
        let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for row in rows where !ids.contains(row.id) { row.removeFromSuperview() }
        rows = readings.map { reading in
            if let row = previous[reading.id] { return row }
            let row = StopwatchPanelRow(id: reading.id)
            row.onSelect = { [weak self] id in self?.onSelect?(id) }
            row.onRename = { [weak self] id, name in self?.onRename?(id, name) }
            row.onToggle = { [weak self] id in self?.onToggle?(id) }
            row.onReset = { [weak self] id in self?.onReset?(id) }
            row.onRemove = { [weak self] id in self?.onRemove?(id) }
            addSubview(row)
            return row
        }
    }

    private var controlsWidth: CGFloat {
        Self.modeLabelWidth + 6 + Self.modeWidth + keycaps.map(\.width).reduce(0, +) + 2 * Self.groupGap
    }

    private func layoutContent(width: CGFloat, columns: StopwatchPanelRow.Columns) -> NSSize {
        let inset = Self.inset
        let inner = width - inset * 2
        var y: CGFloat = 7
        for row in rows {
            row.frame = NSRect(x: inset, y: y, width: inner, height: 63)
            row.arrange(columns)
            y += 70
        }
        y += 8
        let modeX = inset
        modeLabel.frame = NSRect(x: modeX, y: y + 7, width: Self.modeLabelWidth, height: 17)
        mode.frame = NSRect(x: modeLabel.frame.maxX + 6, y: y + 2, width: Self.modeWidth, height: 27)
        var x = width - inset - keycaps.map(\.width).reduce(0, +) - Self.groupGap
        for keycap in keycaps {
            keycap.arrange(x: x, y: y, rightEdge: width - inset)
            x += keycap.width + Self.groupGap
        }
        let modeHintHeight = positionHint(modeHint, x: modeX, y: y + 32, width: mode.frame.maxX - modeX)
        y += 32 + modeHintHeight
        if !saveHint.isHidden {
            y += 5
            saveHint.frame = NSRect(x: inset, y: y, width: inner, height: 16)
            y += 16
        }
        return NSSize(width: width, height: y + 8)
    }

    private func positionHint(_ field: NSTextField, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        field.isHidden = field.stringValue.isEmpty
        guard !field.isHidden else { return 0 }
        let bounds = NSRect(x: 0, y: 0, width: width, height: 64)
        let height = ceil(field.cell?.cellSize(forBounds: bounds).height ?? 16)
        field.frame = NSRect(x: x, y: y, width: width, height: height + 1)
        return height + 2
    }

    static func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = .secondaryLabelColor
        return field
    }

    private static func hint() -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.isHidden = true
        return field
    }

    @objc private func addClicked() { onAdd?() }
    @objc private func modeClicked() { onMode?(mode.selectedSegment == 0 ? .exclusive : .parallel) }
    @objc private func clearClicked(_ button: NSButton) {
        if let action = StopwatchAction(rawValue: UInt32(button.tag)) { onClear?(action) }
    }
    @objc private func keyClicked(_ button: NSButton) {
        if let action = StopwatchAction(rawValue: UInt32(button.tag)) { onRecord?(action) }
    }
}
