import AppKit
import SwiftUI

/// Borderless dropdown anchored to the status item, with explicit screen bounds.
@MainActor
final class HearingPanelController: NSObject {
    private let model: HearingModel
    private let panel: StatusPanelWindow
    private var hosting: NSHostingView<HearingPanelView>!
    private var anchor = NSRect.zero
    private var screen: NSScreen?
    private var focusObserver: NSObjectProtocol?
    private var localMonitor: Any?
    private var contentWidth: CGFloat = 360
    private var lastContentSize = CGSize.zero
    var onVisibilityChange: ((Bool) -> Void)?
    var operationScreen: NSScreen? { panel.screen }
    var isVisible: Bool { panel.isVisible }

    init(model: HearingModel) {
        self.model = model
        panel = StatusPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 1),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "监听环境音"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .statusBar
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.dismissPanel = { [weak self] in self?.close() }
        hosting = NSHostingView(rootView: rootView())
        hosting.sizingOptions = [.intrinsicContentSize]
        _ = PanelChrome(title: "监听环境音", body: hosting, window: panel)
    }
    private func rootView() -> HearingPanelView {
        HearingPanelView(model: model, contentWidth: contentWidth) { [weak self] size in
            DispatchQueue.main.async { [weak self] in self?.resize(to: size) }
        }
    }
    func follow(_ anchor: NSRect, on screen: NSScreen) {
        self.anchor = anchor
        self.screen = screen
        position(size: lastContentSize, screen: screen)
    }
    @discardableResult
    func show(under anchor: NSRect, on screen: NSScreen, focus: Bool = true) -> StatusPanelWindow {
        model.shortcuts.retryIfNeeded()
        self.anchor = anchor
        self.screen = screen
        model.setPanelVisible(true)
        let width = min(360, screen.visibleFrame.width - 24)
        if contentWidth != width { contentWidth = width; hosting.rootView = rootView() }
        hosting.layoutSubtreeIfNeeded()
        position(size: hosting.fittingSize, screen: screen)
        if focus { panel.makeKeyAndOrderFront(nil) }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endShortcutEditing() }
        }
        installDismissMonitors()
        onVisibilityChange?(true)
        return panel
    }
    func close() {
        guard isVisible else { return }
        model.setPanelVisible(false)
        endShortcutEditing()
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        panel.orderOut(nil)
        onVisibilityChange?(false)
    }
    private func resize(to size: CGSize) {
        guard isVisible, size.width > 0, size.height > 0,
              let screen else { return }
        guard abs(size.width - lastContentSize.width) > 0.5 || abs(size.height - lastContentSize.height) > 0.5 else { return }
        position(size: size, screen: screen)
    }
    private func position(size: CGSize, screen: NSScreen) {
        lastContentSize = size
        panel.place(size: CGSize(width: size.width, height: size.height + PanelChrome.headerHeight), under: anchor, on: screen, trailing: true)
    }
    private func installDismissMonitors() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.panel || self.panel.isKeyWindow else { return event }
            if event.type == .flagsChanged {
                if self.model.shortcuts.isRecording { self.model.shortcuts.updateRecordingModifiers(event.modifierFlags); return nil }
            } else if event.type == .keyDown {
                if self.model.shortcuts.isRecording {
                    let handled: Bool
                    if let recorder = self.panel.firstResponder as? ShortcutRecordingControl {
                        handled = recorder.handleRecordingKey(event)
                    } else { handled = self.model.shortcuts.handleRecordingKey(event) }
                    return handled ? nil : event
                }
                if event.keyCode == 53 { self.panel.dismissPanel?(); return nil }
            } else {
                let recorder = self.panel.firstResponder as? ShortcutRecordingControl
                if event.window !== self.panel || recorder.map({ !$0.bounds.contains($0.convert(event.locationInWindow, from: nil)) }) != false {
                    self.endShortcutEditing()
                }
            }
            return event
        }
    }
    private func endShortcutEditing() {
        if let recorder = panel.firstResponder as? ShortcutRecordingControl { recorder.endEditing() }
        else { model.shortcuts.cancelRecording() }
    }
}
