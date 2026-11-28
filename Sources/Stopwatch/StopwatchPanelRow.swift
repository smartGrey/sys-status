import AppKit

@MainActor
final class StopwatchKeycap {
    let action: StopwatchAction
    let label: NSTextField
    let button = NSButton(title: "未设置", target: nil, action: nil)
    let clear = NSButton()
    let hint = NSTextField(labelWithString: "")
    private var buttonWidth: CGFloat { max(46, ceil(button.intrinsicContentSize.width)) }
    var width: CGFloat { 32 + buttonWidth + (clear.isHidden ? 0 : 23) }

    func arrange(x: CGFloat, y: CGFloat, rightEdge: CGFloat) {
        label.frame = NSRect(x: x, y: y + 7, width: 28, height: 17)
        button.frame = NSRect(x: x + 32, y: y + 1, width: buttonWidth, height: 28)
        clear.frame = NSRect(x: button.frame.maxX + 1, y: y + 3, width: 22, height: 24)
        let hintWidth = ceil(hint.intrinsicContentSize.width) + 10
        hint.frame = NSRect(x: min(button.frame.minX, rightEdge - hintWidth), y: y - 13,
                            width: hintWidth, height: 15)
    }

    init(action: StopwatchAction) {
        self.action = action
        label = StopwatchPanelContent.caption(action.title)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.toolTip = "点击录入。按 Esc 取消，按 Delete 清除绑定。"
        button.setAccessibilityHelp(button.toolTip)
        button.setAccessibilityLabel("\(action.title)快捷键")
        clear.isBordered = false
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        clear.imagePosition = .imageOnly
        clear.contentTintColor = .secondaryLabelColor
        clear.toolTip = "清除\(action.title)快捷键"
        clear.setAccessibilityLabel(clear.toolTip)
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = .systemOrange
        hint.alignment = .center

    }

    func update(shortcut: ShortcutBinding?, recording: Bool, issue: String?) {
        let title = recording ? "按下快捷键" : shortcut?.stopwatchLabel ?? "未设置"
        if button.title != title || button.accessibilityValue() == nil || button.state != (recording ? .on : .off) {
            button.title = title
            button.state = recording ? .on : .off
            button.contentTintColor = recording ? .controlAccentColor : shortcut == nil ? .secondaryLabelColor : nil
            button.setAccessibilityValue(title)
        }
        clear.isHidden = shortcut == nil
        hint.stringValue = issue ?? ""
        hint.isHidden = issue == nil
    }
}

@MainActor
final class StopwatchPanelRow: StopwatchFlippedView, NSTextFieldDelegate {
    let id: UUID
    var onSelect: ((UUID) -> Void)?
    var onRename: ((UUID, String) -> Void)?
    var onToggle: ((UUID) -> Void)?
    var onReset: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?

    private static let clockFont = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .medium)
    private static let secondsFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private let nameLabel = NSTextField(labelWithString: "")
    private let nameEditor = NSTextField()
    private let full = NSTextField(labelWithString: "")
    private let total = NSTextField(labelWithString: "")
    private let playback = NSButton()
    private let reset = NSButton()
    private let remove = NSButton()
    private var name = ""
    private var focused = false
    private var running: Bool?
    private(set) var isEditing = false

    var editorHasMarkedText: Bool { (nameEditor.currentEditor() as? NSTextView)?.hasMarkedText() == true }

    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
        let nameFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
        nameLabel.font = nameFont
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.toolTip = "双击改名"
        nameEditor.placeholderString = "未命名"
        nameEditor.font = nameFont
        nameEditor.focusRingType = .exterior
        nameEditor.isHidden = true
        nameEditor.usesSingleLineMode = true
        nameEditor.delegate = self
        nameEditor.setAccessibilityLabel("秒表名称")
        nameEditor.setAccessibilityHelp("最多 5 个字，可留空。按回车保存，按 Esc 取消。")
        full.font = Self.clockFont
        full.alignment = .right
        full.lineBreakMode = .byClipping
        total.font = Self.secondsFont
        total.textColor = .secondaryLabelColor
        total.alignment = .right

        configure(playback, action: #selector(toggleClicked), style: .rounded)
        configure(reset, action: #selector(resetClicked), style: .accessoryBarAction)
        configure(remove, action: #selector(removeClicked), style: .accessoryBarAction)
        setIcon(reset, symbol: "stop.fill", label: "停止并归零")
        setIcon(remove, symbol: "trash", label: "删除")
        reset.contentTintColor = .secondaryLabelColor
        remove.contentTintColor = .secondaryLabelColor
        [nameLabel, nameEditor, full, total, playback, reset, remove].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "设为快捷键焦点") { [weak self] in
                guard let self else { return false }
                onSelect?(id)
                return true
            },
            NSAccessibilityCustomAction(name: "改名") { [weak self] in
                guard let self else { return false }
                onSelect?(id)
                beginEditing()
                return true
            }
        ])
    }

    required init?(coder: NSCoder) { nil }

    static func fullWidth(_ value: String) -> CGFloat {
        ceil((value as NSString).size(withAttributes: [.font: clockFont]).width)
    }

    static func totalWidth(_ value: String) -> CGFloat {
        ceil((value as NSString).size(withAttributes: [.font: secondsFont]).width)
    }

    func update(_ reading: StopwatchReading, focused: Bool, canDelete: Bool) {
        if name != reading.name || nameLabel.stringValue.isEmpty {
            name = reading.name
            nameLabel.stringValue = name.isEmpty ? "未命名" : name
            nameLabel.textColor = name.isEmpty ? .secondaryLabelColor : .labelColor
            setAccessibilityLabel(nameLabel.stringValue)
        }
        if self.focused != focused {
            self.focused = focused
            setAccessibilitySelected(focused)
            needsDisplay = true
        }
        if running != reading.isRunning {
            running = reading.isRunning
            setIcon(playback, symbol: reading.isRunning ? "pause.fill" : "play.fill",
                    label: reading.isRunning ? "暂停" : reading.canReset ? "继续" : "开始")
            playback.contentTintColor = reading.isRunning ? .systemGreen : .labelColor
            needsDisplay = true
        } else if !reading.isRunning {
            let label = reading.canReset ? "继续" : "开始"
            if playback.toolTip != label { setIcon(playback, symbol: "play.fill", label: label) }
        }
        if full.stringValue != reading.time.full { full.stringValue = reading.time.full }
        if total.stringValue != reading.time.total { total.stringValue = reading.time.total }
        reset.isEnabled = reading.canReset
        remove.isEnabled = canDelete
    }

    func arrange(fullWidth: CGFloat, totalWidth: CGFloat) {
        let right = bounds.width - 12
        remove.frame = NSRect(x: right - 34, y: 16, width: 34, height: 31)
        reset.frame = NSRect(x: right - 92, y: 16, width: 34, height: 31)
        playback.frame = NSRect(x: right - 146, y: 15, width: 43, height: 33)

        let secondsEnd = playback.frame.minX - 20
        let secondsWidth = max(67, totalWidth + 4)
        total.frame = NSRect(x: secondsEnd - secondsWidth, y: 24, width: secondsWidth, height: 18)
        let fullEnd = total.frame.minX - 22
        let timeWidth = max(133, fullWidth + 4)
        full.frame = NSRect(x: fullEnd - timeWidth, y: 14, width: timeWidth, height: 35)
        let nameWidth = max(32, full.frame.minX - 25)
        nameLabel.frame = NSRect(x: 14, y: 21, width: nameWidth, height: 23)
        nameEditor.frame = NSRect(x: 11, y: 19, width: nameWidth + 6, height: 25)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        let surface = if running == true {
            NSColor.systemGreen.withAlphaComponent(dark ? 0.13 : 0.08)
        } else {
            NSColor.labelColor.withAlphaComponent(dark ? 0.045 : 0.026)
        }
        surface.setFill()
        outline.fill()
        if focused {
            NSColor.controlAccentColor.withAlphaComponent(0.76).setStroke()
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === nameLabel || hit === full || hit === total { return self }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onSelect?(id)
        let location = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, nameLabel.frame.contains(location) { beginEditing() }
    }

    func beginEditing() {
        guard !isEditing, window != nil else { return }
        isEditing = true
        nameEditor.stringValue = name
        nameLabel.isHidden = true
        nameEditor.isHidden = false
        nameEditor.selectText(nil)
    }

    func finishEditing(commit: Bool) {
        guard isEditing else { return }
        let proposed = nameEditor.currentEditor()?.string ?? nameEditor.stringValue
        isEditing = false
        if nameEditor.currentEditor() != nil { window?.makeFirstResponder(nil) }
        nameEditor.isHidden = true
        nameLabel.isHidden = false
        if commit { onRename?(id, proposed) }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let editor = nameEditor.currentEditor() as? NSTextView, !editor.hasMarkedText(),
              editor.string.count > StopwatchState.nameLimit else { return }
        let selection = editor.selectedRange()
        editor.string = String(editor.string.prefix(StopwatchState.nameLimit))
        editor.setSelectedRange(NSRange(location: min(selection.location, editor.string.utf16.count), length: 0))
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEditing else { return }
        isEditing = false
        nameEditor.isHidden = true
        nameLabel.isHidden = false
        onRename?(id, nameEditor.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() {
            finishEditing(commit: true)
            return true
        }
        return false
    }

    private func configure(_ button: NSButton, action: Selector, style: NSButton.BezelStyle) {
        button.target = self
        button.action = action
        button.bezelStyle = style
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    }

    private func setIcon(_ button: NSButton, symbol: String, label: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    @objc private func toggleClicked() { onToggle?(id) }
    @objc private func resetClicked() { onReset?(id) }
    @objc private func removeClicked() { onRemove?(id) }
}
