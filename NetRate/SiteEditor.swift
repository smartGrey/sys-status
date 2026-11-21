import AppKit

// Accessory apps have no Edit menu to route standard field-editor shortcuts.
private final class EditorPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let field = firstResponder as? NSTextView, field.isFieldEditor, field.isEditable {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": field.paste(nil)
            case "x": field.cut(nil)
            case "c": field.copy(nil)
            case "a": field.selectAll(nil)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class SiteEditor: NSObject, NSTextFieldDelegate {
    @MainActor
    private final class LaneFields {
        static let numericFields: [(HelpField, String)] = [(.interval, "间隔（秒）"), (.warning, "告警（秒）"),
                                                          (.cutoff, "截止（秒）"), (.capacity, "并发")]
        let toggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        let numbers: [NSTextField]
        let rate = NSTextField(labelWithString: "—")
        private var lastValid: ProbeParameters

        init(kind: ProbeLane, parameters: ProbeParameters) {
            lastValid = parameters
            toggle.setAccessibilityLabel("启用" + kind.title)
            HelpField.laneEnabled.attach(to: toggle)
            toggle.state = parameters.enabled ? .on : .off
            let values = [parameters.interval, parameters.warning, parameters.cutoff, parameters.capacity]
            numbers = zip(Self.numericFields, values).map { spec, value in
                let field = NSTextField(string: String(value))
                field.alignment = .right
                field.setAccessibilityLabel(kind.title + spec.1)
                spec.0.attach(to: field)
                field.widthAnchor.constraint(equalToConstant: 59).isActive = true
                return field
            }
            HelpField.traffic.attach(to: rate)
            rate.alignment = .right
            rate.setAccessibilityLabel(kind.title + "每小时预计流量")
        }

        func parameters() throws -> ProbeParameters {
            do {
                let value = try readNumbers()
                lastValid = value
                return value
            } catch {
                guard toggle.state == .off else { throw error }
                lastValid.enabled = false
                let values = [lastValid.interval, lastValid.warning, lastValid.cutoff, lastValid.capacity]
                for (field, value) in zip(numbers, values) { field.stringValue = String(value) }
                return lastValid
            }
        }

        private func readNumbers() throws -> ProbeParameters {
            let values = try numbers.map { field in
                guard let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), number > 0 else {
                    throw SiteConfigurationError.invalidNumber
                }
                return number
            }
            let result = ProbeParameters(enabled: toggle.state == .on, interval: values[0], warning: values[1],
                                         cutoff: values[2], capacity: values[3])
            try result.validate()
            return result
        }
    }

    let sheet: NSPanel = EditorPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    private(set) var saved: ProbeSite?
    private let original: ProbeSite
    private let name: NSTextField
    private let address: NSTextField
    private let method = NSPopUpButton()
    private let codes: NSTextField
    private var rows: [ProbeLane: LaneFields] = [:]
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let error = NSTextField(wrappingLabelWithString: "")
    private let preview: (ProbeSite) -> SiteTraffic

    init(site: ProbeSite?, help: ConfigurationHelpWindow, preview: @escaping (ProbeSite) -> SiteTraffic) {
        original = site ?? ProbeSite(id: UUID().uuidString, name: "", url: URL(string: "about:blank")!, enabled: true)
        name = NSTextField(string: site?.name ?? "")
        address = NSTextField(string: site?.url.absoluteString ?? "")
        codes = NSTextField(string: original.isBuiltIn ? "204" : original.statusCodes.text)
        self.preview = preview
        super.init()
        sheet.title = site == nil ? "新增站点" : "编辑站点"
        name.placeholderString = "留空时使用主机名"
        address.placeholderString = "https://example.com/"
        codes.placeholderString = "例如 2xx, 405，留空接受 2xx"
        method.addItems(withTitles: ProbeMethod.allCases.map(\.rawValue))
        method.selectItem(withTitle: original.method.rawValue)
        method.isEnabled = !original.isBuiltIn
        method.target = self
        method.action = #selector(changed)
        method.setAccessibilityLabel(HelpField.method.rawValue)
        HelpField.method.attach(to: method, readOnly: original.isBuiltIn)
        let shared = NSGridView()
        let sharedFields: [(HelpField, NSTextField)] = [(.name, name), (.address, address), (.codes, codes)]
        func label(_ topic: HelpField) -> NSTextField {
            let label = NSTextField(labelWithString: topic.rawValue)
            topic.attach(to: label, readOnly: original.isBuiltIn)
            return label
        }
        for (topic, field) in sharedFields {
            field.delegate = self
            field.setAccessibilityLabel(topic.rawValue)
            topic.attach(to: field, readOnly: original.isBuiltIn)
            field.isEditable = !original.isBuiltIn
            field.lineBreakMode = .byTruncatingTail
            field.widthAnchor.constraint(equalToConstant: 388).isActive = true
            shared.addRow(with: [label(topic), field])
        }
        shared.addRow(with: [label(.method), method])
        shared.column(at: 1).xPlacement = .leading
        shared.yPlacement = .center
        shared.rowSpacing = 6

        let grid = NSGridView()
        let columns: [(HelpField, String)] = [(.laneEnabled, "启用"), (.type, "类型")] +
            LaneFields.numericFields + [(.traffic, "预计流量/小时")]
        let headers = columns.map { topic, title in
            let label = NSTextField(labelWithString: title)
            topic.attach(to: label)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            return label
        }
        grid.addRow(with: headers)
        for kind in ProbeLane.allCases {
            let fields = LaneFields(kind: kind, parameters: original[kind])
            rows[kind] = fields
            fields.numbers.forEach { $0.delegate = self }
            fields.toggle.target = self
            fields.toggle.action = #selector(changed)
            let type = NSTextField(labelWithString: kind.title)
            HelpField.type.attach(to: type, lane: kind)
            grid.addRow(with: [fields.toggle, type] + fields.numbers + [fields.rate])
        }
        grid.xPlacement = .trailing
        grid.yPlacement = .center
        grid.columnSpacing = 12
        grid.rowSpacing = 7
        let divider = NSBox()
        divider.boxType = .separator
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "确定", target: self, action: #selector(accept))
        save.keyEquivalent = "\r"
        let actions = NSStackView(views: [help.makeButton(), NSView(), cancel, save])
        actions.orientation = .horizontal
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        error.font = .systemFont(ofSize: 12)
        error.textColor = .systemRed
        let stack = NSStackView(views: [shared, divider, grid, hint, error, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        let width = max(shared.fittingSize.width, grid.fittingSize.width)
        for view in [divider, hint, error, actions] {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        // Reserve room for both capacity hints and an inline validation message.
        hint.heightAnchor.constraint(equalToConstant: 32).isActive = true
        error.heightAnchor.constraint(equalToConstant: 18).isActive = true
        sheet.contentView = stack
        sheet.setContentSize(stack.fittingSize)
        sheet.initialFirstResponder = original.isBuiltIn ? rows[.daily]?.toggle : (site == nil ? address : name)
        refreshPreview()
    }

    func controlTextDidChange(_ obj: Notification) { changed() }

    @objc private func changed() {
        error.stringValue = ""
        refreshPreview()
    }

    private func sharedSite() throws -> ProbeSite {
        if original.isBuiltIn { return original }
        var site = try ProbeSite.custom(id: original.id, name: name.stringValue, address: address.stringValue,
                                        enabled: original.enabled, statusCodes: StatusCodes(codes.stringValue))
        site.method = ProbeMethod(rawValue: method.titleOfSelectedItem ?? "") ?? .head
        return site
    }

    func refreshPreview() {
        var site = (try? sharedSite()) ?? original
        var hints: [String] = []
        for kind in ProbeLane.allCases {
            guard let fields = rows[kind] else { continue }
            let active = fields.toggle.state == .on
            for field in fields.numbers { field.isEnabled = active }
            var settings = (try? fields.parameters()) ?? original[kind]
            settings.enabled = active
            site[kind] = settings
            if let hint = settings.capacityHint { hints.append(kind.title + "：" + hint) }
        }
        let estimate = preview(site)
        for (kind, fields) in rows {
            fields.rate.stringValue = ProbeUsage.display(estimate[kind], perHour: false)
        }
        hint.stringValue = hints.joined(separator: "\n")
    }

    @objc private func accept() {
        do {
            var site = try sharedSite()
            for (kind, fields) in rows { site[kind] = try fields.parameters() }
            try site.validate()
            saved = site
            sheet.sheetParent?.endSheet(sheet, returnCode: .OK)
        } catch {
            self.error.stringValue = error.localizedDescription
            NSAccessibility.post(element: self.error, notification: .valueChanged)
        }
    }

    @objc private func cancel() { sheet.sheetParent?.endSheet(sheet, returnCode: .cancel) }
}
