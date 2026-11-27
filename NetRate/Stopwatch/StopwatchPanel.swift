import AppKit
import Carbon

private class StopwatchPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private class StopwatchFlippedView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class StopwatchPanel {
    private weak var controller: StopwatchController?
    private var window: NSPanel?
    private var content: StopwatchPanelContent?
    private var anchor: NSRect = .zero
    private var screen: NSScreen?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var presentation: StopwatchPresentation?
    private var shortcutIssues: [StopwatchAction: String] = [:]
    private var hasSaveError = false
    private var recording: StopwatchAction?
    private var sawModifier = false
    private var inputTimeout: Timer?

    var isVisible: Bool { window?.isVisible == true }

    init(controller: StopwatchController) { self.controller = controller }

    func show(under anchor: NSRect, on screen: NSScreen) {
        self.anchor = anchor
        self.screen = screen
        let window = window ?? makeWindow()
        refresh()
        window.makeKeyAndOrderFront(nil)
        installMonitors()
        controller?.panelVisibilityChanged?(true)
    }

    func dismissIfVisible() {
        guard isVisible else { return }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        endRecording()
        content?.finishEditing(commit: false)
        window?.orderOut(nil)
        content?.clearInputIssues()
        controller?.panelVisibilityChanged?(false)
    }

    func update(_ presentation: StopwatchPresentation, shortcutIssues: [StopwatchAction: String], hasSaveError: Bool) {
        self.presentation = presentation
        self.shortcutIssues = shortcutIssues
        self.hasSaveError = hasSaveError
        if isVisible { refresh() }
    }

    func trackAnchor(_ resolve: (NSScreen) -> NSRect?) {
        guard isVisible, let screen, let frame = resolve(screen) else { return }
        anchor = frame
        refresh()
    }

    private func refresh() {
        guard let presentation, let content, let window, let screen else { return }
        let bounds = screen.visibleFrame
        let size = content.update(presentation, availableWidth: bounds.width - 16, recording: recording,
                                  issues: shortcutIssues, hasSaveError: hasSaveError)
        let frame = StatusHover.panelFrame(size: size, under: anchor, within: bounds.insetBy(dx: 8, dy: 0))
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    private func makeWindow() -> NSPanel {
        let window = StopwatchPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.title = "StopWatch"
        window.setAccessibilityLabel("StopWatch")

        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 16
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 1
        material.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor

        let content = StopwatchPanelContent()
        content.autoresizingMask = [.width, .height]
        content.onSelect = { [weak self] id in
            self?.endRecording()
            self?.content?.finishEditing(commit: true)
            self?.controller?.select(id)
        }
        content.onRename = { [weak self] id, name in self?.controller?.rename(id, to: name) }
        content.onToggle = { [weak self] id in
            self?.endRecording()
            self?.controller?.toggle(id)
        }
        content.onReset = { [weak self] id in
            self?.endRecording()
            self?.controller?.reset(id)
        }
        content.onRemove = { [weak self] id in
            self?.endRecording()
            self?.controller?.remove(id)
        }
        content.onAdd = { [weak self] in
            self?.endRecording()
            if let id = self?.controller?.add() { self?.content?.beginEditing(id) }
        }
        content.onMode = { [weak self] mode in
            self?.endRecording()
            self?.controller?.setMode(mode)
            self?.refresh()
        }
        content.onRecord = { [weak self] action in self?.beginRecording(action) }
        content.onClear = { [weak self] action in
            self?.endRecording()
            self?.finishRecording(action, shortcut: nil)
        }
        material.addSubview(content)
        window.contentView = material
        self.content = content
        self.window = window
        return window
    }

    private func installMonitors() {
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [mouse, .keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown: return self.handleKey(event) ? nil : event
            case .flagsChanged: self.captureModifiers(event)
            default: self.dismissForClick(event)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouse) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.controller?.handlePanelStatusClick?(event) != true else { return }
                self.dismissForClick(event)
            }
        }
    }

    private func dismissForClick(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        guard event.window !== window, window?.frame.contains(point) != true else { return }
        // WindowServer can deliver a menu bar click through the global monitor.
        if controller?.isStatusEntry(at: point) == true { return }
        dismissIfVisible()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === window || window?.isKeyWindow == true else { return false }
        let shortcut = StopwatchShortcut(event: event)
        let code = Int(event.keyCode)
        if let recording {
            if event.isARepeat { return true }
            if shortcut.modifiers == 0 {
                switch code {
                case kVK_Escape: endRecording(); return true
                case kVK_Tab: endRecording(); return false
                case kVK_Delete, kVK_ForwardDelete: finishRecording(recording, shortcut: nil); return true
                default: break
                }
            }
            finishRecording(recording, shortcut: shortcut)
            return true
        }
        guard shortcut.modifiers == 0, content?.editorHasMarkedText != true else { return false }
        switch code {
        case kVK_Escape:
            if content?.finishEditing(commit: false) != true { dismissIfVisible() }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return content?.finishEditing(commit: true) == true
        default:
            return false
        }
    }

    // Another app can receive the primary key before AppKit sees it. Keep the
    // original binding in that case so recording cannot take over the chord.
    private func captureModifiers(_ event: NSEvent) {
        guard let recording, event.window === window || window?.isKeyWindow == true else { return }
        if StopwatchShortcut(event: event).modifiers != 0 {
            if !sawModifier {
                content?.clearInputIssue(recording)
                refresh()
            }
            sawModifier = true
        } else if sawModifier {
            sawModifier = false
            inputTimeout?.invalidate()
            content?.showShortcutError("未收到按键", for: recording)
            refresh()
        }
    }

    private func beginRecording(_ action: StopwatchAction) {
        if recording == action {
            endRecording()
            return
        }
        content?.finishEditing(commit: true)
        if recording != nil { endRecording() }
        sawModifier = false
        content?.clearInputIssue(action)
        recording = action
        controller?.record(action)
        // Some global bindings consume the complete chord, including modifier events.
        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recording == action else { return }
                self.content?.showShortcutError("未收到按键", for: action)
                self.refresh()
            }
        }
        inputTimeout = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    private func endRecording() {
        guard let recording else { return }
        inputTimeout?.invalidate()
        inputTimeout = nil
        self.recording = nil
        controller?.record(nil)
        content?.clearInputIssue(recording)
        if isVisible { refresh() }
    }

    func receiveRegisteredShortcut(_ shortcut: StopwatchShortcut) {
        guard let recording, window?.isKeyWindow == true else { return }
        finishRecording(recording, shortcut: shortcut)
    }

    private func finishRecording(_ action: StopwatchAction, shortcut: StopwatchShortcut?) {
        inputTimeout?.invalidate()
        sawModifier = false
        content?.clearInputIssue(action)
        do {
            try controller?.replaceShortcut(action, with: shortcut)
            endRecording()
        } catch {
            content?.showShortcutError((error as? StopwatchHotKeyError)?.shortMessage ?? "未能保存", for: action)
        }
        refresh()
    }
}

@MainActor
private final class StopwatchPanelContent: StopwatchFlippedView {
    private static let preferredWidth: CGFloat = 556
    private static let inset: CGFloat = 16
    private static let modeLabelWidth: CGFloat = 29
    private static let modeWidth: CGFloat = 108
    private static let groupGap: CGFloat = 14

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
    private let addButton = NSButton(title: "添加秒表", target: nil, action: nil)
    private let divider = NSBox()
    private let modeLabel = StopwatchPanelContent.caption("模式")
    private let mode = NSSegmentedControl(labels: ["互斥", "并行"], trackingMode: .selectOne, target: nil, action: nil)
    private let modeHint = StopwatchPanelContent.hint()
    private let saveHint = StopwatchPanelContent.hint()
    private let keycaps = StopwatchAction.allCases.map { StopwatchKeycap(action: $0) }
    private var inputIssues: [StopwatchAction: String] = [:]
    private var size: NSSize = .zero
    private struct Layout: Equatable {
        let width: CGFloat
        let fullWidth: CGFloat
        let totalWidth: CGFloat
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
        divider.boxType = .separator
        mode.segmentStyle = .rounded
        mode.target = self
        mode.action = #selector(modeClicked)
        mode.setWidth(50, forSegment: 0)
        mode.setWidth(50, forSegment: 1)
        mode.setAccessibilityLabel("计时模式")
        mode.setToolTip("开始一项时暂停其他秒表", forSegment: 0)
        mode.setToolTip("多个秒表可以同时计时", forSegment: 1)
        saveHint.stringValue = "秒表数据尚未保存"
        saveHint.textColor = .systemOrange

        [addButton, divider, modeLabel, mode, modeHint, saveHint].forEach(addSubview)
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
        let fullWidth = data.readings.map { StopwatchPanelRow.fullWidth($0.time.full) }.max() ?? 0
        let totalWidth = data.readings.map { StopwatchPanelRow.totalWidth($0.time.total) }.max() ?? 0
        addButton.isHidden = rows.count >= StopwatchState.maximumCount
        let addWidth = addButton.isHidden ? 0 : ceil(addButton.intrinsicContentSize.width) + Self.groupGap
        let minimumWidth = 2 * Self.inset + addWidth + controlsWidth
        let width = min(availableWidth, max(Self.preferredWidth, minimumWidth))
        let signature = Layout(width: width, fullWidth: fullWidth, totalWidth: totalWidth,
                               modeHint: modeHint.stringValue, shortcutWidths: keycaps.map(\.width), shortcutHints: keycaps.map { $0.hint.stringValue },
                               hasSaveError: hasSaveError)
        if !sameRows || signature != layout {
            layout = signature
            size = layoutContent(width: width, fullWidth: fullWidth, totalWidth: totalWidth)
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
            addSubview(row, positioned: .below, relativeTo: addButton)
            return row
        }
    }

    private var controlsWidth: CGFloat {
        Self.modeLabelWidth + 6 + Self.modeWidth + keycaps.map(\.width).reduce(0, +) + 2 * Self.groupGap
    }

    private func layoutContent(width: CGFloat, fullWidth: CGFloat, totalWidth: CGFloat) -> NSSize {
        let inset = Self.inset
        let inner = width - inset * 2
        var y: CGFloat = 16
        for row in rows {
            row.frame = NSRect(x: inset, y: y, width: inner, height: 63)
            row.arrange(fullWidth: fullWidth, totalWidth: totalWidth)
            y += 70
        }
        y += 3
        divider.frame = NSRect(x: inset, y: y, width: inner, height: 1)
        y += 11

        let modeX = width - inset - controlsWidth
        if !addButton.isHidden {
            let addWidth = min(ceil(addButton.intrinsicContentSize.width), max(0, modeX - inset - 6))
            addButton.frame = NSRect(x: inset, y: y, width: addWidth, height: 29)
        }
        modeLabel.frame = NSRect(x: modeX, y: y + 7, width: Self.modeLabelWidth, height: 17)
        mode.frame = NSRect(x: modeLabel.frame.maxX + 6, y: y + 2, width: Self.modeWidth, height: 27)
        var x = mode.frame.maxX + Self.groupGap
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
        return NSSize(width: width, height: y + 12)
    }

    private func positionHint(_ field: NSTextField, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        field.isHidden = field.stringValue.isEmpty
        guard !field.isHidden else { return 0 }
        let bounds = NSRect(x: 0, y: 0, width: width, height: 64)
        let height = ceil(field.cell?.cellSize(forBounds: bounds).height ?? 16)
        field.frame = NSRect(x: x, y: y, width: width, height: height + 1)
        return height + 2
    }

    fileprivate static func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = .secondaryLabelColor
        return field
    }

    fileprivate static func hint() -> NSTextField {
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

@MainActor
private final class StopwatchKeycap {
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

    func update(shortcut: StopwatchShortcut?, recording: Bool, issue: String?) {
        let title = recording ? "按下快捷键" : shortcut?.label ?? "未设置"
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
private final class StopwatchPanelRow: StopwatchFlippedView, NSTextFieldDelegate {
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
