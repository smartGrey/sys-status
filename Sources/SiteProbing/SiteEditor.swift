import AppKit

@MainActor
final class FormButton: NSButton {
    private let handler: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(activate)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func activate() { handler() }
}

@MainActor
private final class FormField: NSTextField, NSTextFieldDelegate {
    let changed: (String) -> Void
    init(_ text: String, label: String, topic: HelpField, locked: Bool = false, changed: @escaping (String) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
        stringValue = text
        isEditable = !locked
        isSelectable = true
        isBezeled = !locked
        drawsBackground = !locked
        lineBreakMode = .byTruncatingTail
        setAccessibilityLabel(label)
        topic.attach(to: self, readOnly: locked)
        delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func controlTextDidChange(_ obj: Notification) { changed(stringValue) }
}

@MainActor
private final class FormPopup: NSPopUpButton {
    let changed: (Int) -> Void
    init(titles: [String], changed: @escaping (Int) -> Void) {
        self.changed = changed
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        target = self
        action = #selector(picked)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func picked() { changed(indexOfSelectedItem) }
}

enum SiteColumn: String, CaseIterable {
    case name, address, method, codes
    var topic: HelpField {
        switch self {
        case .name: .name
        case .address: .address
        case .method: .method
        case .codes: .codes
        }
    }
}

/// The table supplies native column cells for the site and one full-width detail row beneath it.
@MainActor
final class SiteEditor: NSView {
    let draft: SiteDraft
    private let grid = NSGridView()
    private let onChange: (Bool) -> Void
    private var cells: [SiteColumn: NSView] = [:]
    private var fields: [SiteFormField: NSTextField] = [:]
    private var arrow: NSButton?
    private var siteNote: NSTextField?
    private var laneLabels: [ProbeLane: [NSTextField]] = [:]
    private var addMenus: [ProbeLane: NSPopUpButton] = [:]
    private struct PersonalRow {
        let mark: NSTextField
        let count: NSTextField
        let traffic: NSTextField
        let remove: NSButton
    }
    private var personalRows: [ProbeLane: [String: PersonalRow]] = [:]
    private static let numberTopics: [HelpField] = [.interval, .warning, .cutoff, .capacity]
    // Only the strength name grows. Keeping the numeric columns identical makes comparisons possible across sites.
    private static let widths: [CGFloat?] = [108, nil, 60, 60, 60, 42, 100, 82, 106]

    init(draft: SiteDraft, onChange: @escaping (Bool) -> Void) {
        self.draft = draft
        self.onChange = onChange
        super.init(frame: .zero)
        grid.rowSpacing = 2
        grid.columnSpacing = 7
        grid.xPlacement = .fill
        grid.yPlacement = .center
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 2)
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { nil }
    var rowHeight: CGFloat { grid.fittingSize.height + 6 }
    var addressField: NSTextField? { fields[.address] }

    private func text(_ value: String = "", secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 12)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func disclosure(_ label: String, open: Bool, action: @escaping () -> Void) -> NSButton {
        let button = FormButton("", action: action)
        button.bezelStyle = .disclosure
        button.setButtonType(.pushOnPushOff)
        button.state = open ? .on : .off
        button.setAccessibilityLabel(label)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func siteCell(_ column: SiteColumn) -> NSView {
        if let cell = cells[column] { return cell }
        let locked = draft.source.isBuiltIn
        let tcp = draft.source.endpoint.type == .tcp
        func input(_ key: WritableKeyPath<SiteForm, String>, _ placeholder: String, topic: HelpField? = nil) -> NSTextField {
            let topic = topic ?? column.topic
            let field = FormField(draft.form[keyPath: key], label: topic.rawValue, topic: topic, locked: locked) { [weak self] value in
                self?.draft.form[keyPath: key] = value
                self?.changed()
            }
            field.placeholderString = placeholder
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return field
        }
        let control: NSView
        switch column {
        case .name:
            let toggle = disclosure("展开或折叠" + draft.title, open: draft.expanded) { [weak self] in self?.toggle() }
            arrow = toggle
            let name = input(\.name, "留空使用主机名")
            let note = text("", secondary: true)
            note.font = .systemFont(ofSize: 11)
            note.setContentCompressionResistancePriority(.required, for: .horizontal)
            siteNote = note
            let line = NSStackView(views: [toggle, name, note])
            line.spacing = 4
            line.distribution = .fill
            control = line
        case .address:
            let field = input(\.address, tcp ? "主机名或 IP" : "https://example.com/", topic: tcp ? .host : .address)
            fields[.address] = field
            control = field
        case .method where tcp:
            let label = text("TCP")
            HelpField.host.attach(to: label)
            control = label
        case .method where locked:
            let method = text(draft.form.method.rawValue)
            method.setAccessibilityLabel(column.topic.rawValue)
            column.topic.attach(to: method, readOnly: true)
            control = method
        case .method:
            let method = FormPopup(titles: ProbeMethod.allCases.map(\.rawValue)) { [weak self] index in
                self?.draft.form.method = ProbeMethod.allCases[index]
                self?.changed()
            }
            method.selectItem(withTitle: draft.form.method.rawValue)
            method.setAccessibilityLabel(column.topic.rawValue)
            column.topic.attach(to: method, readOnly: locked)
            control = method
        case .codes where tcp:
            let field = input(\.port, "1–65535", topic: .port)
            fields[.port] = field
            control = field
        case .codes:
            let field = input(\.codes, "2xx")
            fields[.codes] = field
            control = field
        }
        let cell = NSView()
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            control.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cells[column] = cell
        updateSite()
        return cell
    }

    private func updateSite() {
        siteNote?.stringValue = [draft.source.isBuiltIn ? "内置" : "", draft.source.enabled ? "" : "未启用"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        siteNote?.isHidden = siteNote?.stringValue.isEmpty == true
        arrow?.state = draft.expanded ? .on : .off
        arrow?.setAccessibilityLabel("展开或折叠" + draft.title)
        if let addressField {
            let hint = (draft.source.endpoint.type == .tcp ? HelpField.host : .address).tip(readOnly: draft.source.isBuiltIn)
            addressField.toolTip = draft.form.address.isEmpty ? hint : draft.form.address + "\n" + hint
        }
    }

    private func gridRow(_ views: [NSView], height: CGFloat) {
        let cells = views.enumerated().map { index, view -> NSView in
            guard (2...5).contains(index), let label = view as? NSTextField, !label.isEditable else { return view }
            // Match the text edge inside the bordered number editors, including the label's optical inset.
            let cell = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                cell.heightAnchor.constraint(equalTo: label.heightAnchor)
            ])
            return cell
        }
        let row = grid.addRow(with: cells)
        row.height = height
        for (i, width) in Self.widths.enumerated() {
            if let width { grid.column(at: i).width = width }
            else {
                views[i].setContentHuggingPriority(.defaultLow, for: .horizontal)
                views[i].setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
        }
    }

    func toggle() {
        draft.expanded.toggle()
        structuralChange()
    }

    private func structuralChange() {
        rebuild()
        onChange(true)
    }

    func rebuild() {
        while grid.numberOfRows > 0 {
            let last = grid.numberOfRows - 1
            let views = (0..<grid.numberOfColumns).compactMap { grid.cell(atColumnIndex: $0, rowIndex: last).contentView }
            grid.removeRow(at: last)
            views.forEach { $0.removeFromSuperview() }
        }
        fields = fields.filter { $0.key.lane == nil }
        laneLabels.removeAll()
        addMenus.removeAll()
        personalRows.removeAll()
        if draft.expanded {
            let columns = ["", "当前强度", "间隔 (秒)", "提醒 (秒)", "截止 (秒)", "并发", draft.source.endpoint.type == .tcp ? "8 小时连接数" : "8 小时请求数", "预计流量", ""]
            let help: [HelpField?] = [nil, .intensity, .interval, .warning, .cutoff, .capacity, .traffic, .traffic, nil]
            let header = columns.enumerated().map { i, title in
                let label = text(title, secondary: true)
                label.font = .systemFont(ofSize: 11, weight: .medium)
                if (2...7).contains(i) { label.alignment = .right }
                help[i]?.attach(to: label)
                return label
            }
            gridRow(header, height: 18)
            for lane in draft.source.lanes { laneRow(lane) }
        }
        refresh()
    }

    private func laneRow(_ lane: ProbeLane) {
        let inputs = draft.form.personal[lane] ?? []
        let open = draft.openLanes.contains(lane)
        let arrow = disclosure("管理" + lane.title + "探测强度", open: open) { [weak self] in
            guard let self else { return }
            if open { draft.openLanes.remove(lane) } else { draft.openLanes.insert(lane) }
            structuralChange()
        }
        // An empty slot preserves the indentation when there are no personal strengths to expand.
        let slot = NSView()
        slot.widthAnchor.constraint(equalToConstant: 15).isActive = true
        if !inputs.isEmpty {
            arrow.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(arrow)
            NSLayoutConstraint.activate([arrow.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                                         arrow.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
                                         slot.heightAnchor.constraint(equalToConstant: 22)])
        }
        let name = text(lane.title)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        HelpField.type.attach(to: name, lane: lane)
        let count = text(inputs.isEmpty ? "" : "\(inputs.count) 项", secondary: true)
        count.toolTip = "本站的" + lane.title + "个人强度数量"
        let lead = NSStackView(views: [slot, name, count, NSView()])
        lead.spacing = 3
        let labels = (0..<7).map { i in
            let label = text()
            if i > 0 { label.alignment = .right }
            return label
        }
        laneLabels[lane] = labels
        let add = NSPopUpButton(frame: .zero, pullsDown: true)
        add.addItem(withTitle: "新增强度")
        add.setAccessibilityLabel(lane.title + "新增强度")
        add.toolTip = "选择模板，为本站创建" + lane.title + "个人强度。"
        addMenus[lane] = add
        gridRow([lead] + labels + [add], height: 26)
        if open { for input in inputs { personalRow(input, lane: lane) } }
    }

    private func updateTemplates(for lane: ProbeLane, menu: NSMenu) {
        let selection = draft.selectedID(lane)
        let selectionLabel = draft.source[strength: lane].enabled ? "（当前）" : "（已保留）"
        let personal = draft.form.personal[lane] ?? []
        let templates = lane.strengths.map(StrengthInput.init) + personal
        let ordered = templates.filter { $0.id == selection } + templates.filter { $0.id != selection }
        let choices = ordered.map { template in
            let name = template.name.isEmpty ? "未命名强度" : template.name
            return Template(lane: lane, id: template.id, title: name + (template.id == selection ? selectionLabel : ""))
        }
        // Pull-down buttons reserve the first item for their permanent title.
        let existing = menu.items.dropFirst().compactMap { $0.representedObject as? Template }
        guard existing != choices else { return }
        for item in menu.items.dropFirst() { menu.removeItem(item) }
        for choice in choices {
            let item = menu.addItem(withTitle: choice.title, action: #selector(addFromTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice
        }
    }

    private struct Template: Equatable {
        let lane: ProbeLane
        let id: String
        let title: String
    }

    @objc private func addFromTemplate(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? Template else { return }
        let lane = template.lane
        let inputs = draft.form.personal[lane] ?? []
        guard let original = inputs.first(where: { $0.id == template.id })
                ?? lane.strengths.first(where: { $0.id == template.id }).map(StrengthInput.init) else { return }
        let names = Set(inputs.map(\.name))
        var suffix = 1
        while names.contains("自定义 \(suffix)") { suffix += 1 }
        let copy = StrengthInput(id: UUID().uuidString, name: "自定义 \(suffix)", numbers: original.numbers)
        draft.form.personal[lane, default: []].append(copy)
        draft.openLanes.insert(lane)
        structuralChange()
        focus(.personalName(lane, copy.id))
    }

    func focus(_ key: SiteFormField) {
        guard let field = fields[key], let window = field.window else { return }
        field.scrollToVisible(field.bounds.insetBy(dx: -2, dy: -3))
        window.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func personalRow(_ input: StrengthInput, lane: ProbeLane) {
        let update: ((inout StrengthInput) -> Void) -> Void = { [weak self] change in
            guard let self, let index = draft.form.personal[lane]?.firstIndex(where: { $0.id == input.id }) else { return }
            change(&draft.form.personal[lane]![index])
            changed()
        }
        let mark = text("", secondary: true)
        mark.alignment = .right
        let name = FormField(input.name, label: lane.title + "个人强度名称", topic: .intensity) { value in update { $0.name = value } }
        fields[.personalName(lane, input.id)] = name
        var cells: [NSView] = [mark, name]
        for (index, topic) in Self.numberTopics.enumerated() {
            let field = FormField(input.numbers[index], label: lane.title + topic.rawValue, topic: topic) { value in
                update { $0.numbers[index] = value }
            }
            field.alignment = .right
            fields[.number(lane, input.id, index)] = field
            cells.append(field)
        }
        let count = text()
        let traffic = text()
        for field in [count, traffic] {
            field.alignment = .right
            HelpField.traffic.attach(to: field)
        }
        let remove = FormButton("删除") { [weak self] in
            guard let self, draft.canRemoveStrength(input.id, lane: lane) else { return }
            draft.form.personal[lane]?.removeAll { $0.id == input.id }
            if draft.form.personal[lane]?.isEmpty == true { draft.openLanes.remove(lane) }
            structuralChange()
        }
        personalRows[lane, default: [:]][input.id] = PersonalRow(mark: mark, count: count, traffic: traffic, remove: remove)
        gridRow(cells + [count, traffic, remove], height: 25)
    }

    private func changed() { refresh(); onChange(false) }

    func refresh() {
        updateSite()
        let tcp = draft.source.endpoint.type == .tcp
        for lane in draft.source.lanes {
            guard let labels = laneLabels[lane], let menu = addMenus[lane]?.menu else { continue }
            updateTemplates(for: lane, menu: menu)
            let selected = draft.source[strength: lane]
            let id = draft.selectedID(lane)
            let input = draft.form.personal[lane]?.first { $0.id == id }
                ?? lane.strengths.first { $0.id == id }.map(StrengthInput.init)
            let budget = selected.enabled ? draft.selected(lane).map { ProbeBudget(lane: lane, interval: $0.values.interval, type: draft.source.endpoint.type) } : ProbeBudget()
            let title = (selected.enabled ? "" : "已停止 · ") + (input?.name ?? "—")
            let values = [title] + (input?.numbers ?? Array(repeating: "—", count: 4)) +
                [budget?.requests.formatted() ?? "—", budget?.trafficDisplay ?? "—"]
            for (field, value) in zip(labels, values) {
                field.stringValue = value
                field.textColor = selected.enabled ? .labelColor : .secondaryLabelColor
            }
            let topics: [HelpField] = [.intensity] + Self.numberTopics + [.traffic, .traffic]
            for (label, topic) in zip(labels, topics) {
                topic.attach(to: label)
                label.setAccessibilityLabel(lane.title + "当前" + topic.rawValue)
            }
            labels[0].toolTip = title + "\n" + HelpField.intensity.tip()
            labels[5].setAccessibilityLabel(lane.title + (tcp ? "预计 8 小时连接数" : "预计 8 小时请求数"))
            labels[6].setAccessibilityLabel(lane.title + "预计 8 小时流量")
            if selected.enabled && !draft.source.enabled {
                for label in labels.suffix(2) { label.toolTip = "启用此站点后，连续探测 8 小时的估算。" }
            }
            for input in draft.form.personal[lane] ?? [] {
                guard let row = personalRows[lane]?[input.id] else { continue }
                let chosen = input.id == selected.selectedID
                row.mark.stringValue = chosen ? (selected.enabled ? "个人 · 已选" : "个人 · 已保留") : "个人"
                let budget = (try? input.strength(for: lane)).map { ProbeBudget(lane: lane, interval: $0.values.interval, type: draft.source.endpoint.type) }
                row.count.stringValue = budget?.requests.formatted() ?? "—"
                row.traffic.stringValue = budget?.trafficDisplay ?? "—"
                row.remove.isEnabled = draft.canRemoveStrength(input.id, lane: lane)
                row.remove.toolTip = row.remove.isEnabled ? nil : (tcp ? "先在菜单中停用此站点或切换探测强度，再删除。" : "先在菜单中停止该方式或切换探测强度，再删除。")
            }
        }
    }
}

private extension StrengthInput {
    init(id: String, name: String, numbers: [String]) {
        self.id = id
        self.name = name
        self.numbers = numbers
    }
}
