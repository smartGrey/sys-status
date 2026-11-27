import AppKit
import SwiftUI

struct ShortcutView: View {
    @ObservedObject var controller: HearingShortcutController
    var body: some View {
        HStack(spacing: 4) {
            ShortcutRecorder(controller: controller)
                .fixedSize().frame(height: 24)
            if controller.binding != nil || controller.isRecording {
                Button { controller.clear() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel("清除透传快捷键")
            }
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var controller: HearingShortcutController
    func makeNSView(context: Context) -> ShortcutRecordingControl { ShortcutRecordingControl(controller: controller) }
    func updateNSView(_ view: ShortcutRecordingControl, context: Context) {
        view.title = controller.title
        view.invalidateIntrinsicContentSize()
        view.contentTintColor = controller.isRecording ? .systemTeal : controller.binding != nil && !controller.isRegistered ? .systemOrange : .secondaryLabelColor
        view.toolTip = controller.isRecording ? "Esc 取消，Delete 清除" : "设置全局透传开关快捷键"
        view.setAccessibilityLabel("透传开关快捷键")
        view.setAccessibilityValue(controller.title)
        view.setAccessibilityHelp(view.toolTip)
        view.synchronizeRecordingFocus()
    }
}

@MainActor
final class ShortcutRecordingControl: NSButton {
    private let controller: HearingShortcutController
    private var wasRecording = false
    init(controller: HearingShortcutController) {
        self.controller = controller
        super.init(frame: .zero)
        bezelStyle = .roundRect; controlSize = .small
        font = .systemFont(ofSize: 11, weight: .medium)
        target = self; action = #selector(record)
        setButtonType(.momentaryPushIn)
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            // Keep a visible focus cue for Tab navigation, not mouse clicks.
            let event = NSApp.currentEvent
            focusRingType = event?.type == .keyDown && event?.keyCode == 48 ? .exterior : .none
        }
        return accepted
    }
    @objc private func record() {
        guard let window else { return }
        window.makeKey()
        guard window.isKeyWindow, window.makeFirstResponder(self) else { return }
        if NSApp.currentEvent?.type != .keyDown { focusRingType = .none }
        controller.beginRecording()
    }
    func endEditing() {
        controller.cancelRecording()
        focusRingType = .none
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }
    func synchronizeRecordingFocus() {
        let ended = wasRecording && !controller.isRecording
        wasRecording = controller.isRecording
        guard ended else { return }
        // Avoid changing responder state during a SwiftUI update. A Tab event
        // has already moved focus by this point, so it must not be disturbed.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.controller.isRecording, self.window?.firstResponder === self else { return }
            self.endEditing()
        }
    }
    func handleRecordingKey(_ event: NSEvent) -> Bool {
        let handled = controller.handleRecordingKey(event)
        if handled && !controller.isRecording { endEditing() }
        return handled
    }
    override func flagsChanged(with event: NSEvent) {
        if controller.isRecording { controller.updateRecordingModifiers(event.modifierFlags) }
        else { super.flagsChanged(with: event) }
    }
    override func resignFirstResponder() -> Bool {
        controller.cancelRecording()
        focusRingType = .none
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        if controller.isRecording {
            if handleRecordingKey(event) { return }
        } else if event.keyCode == 49 || event.keyCode == 36 {
            record(); return
        }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if controller.isRecording { return handleRecordingKey(event) }
        return super.performKeyEquivalent(with: event)
    }
}
