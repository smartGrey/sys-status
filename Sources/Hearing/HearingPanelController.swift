import AppKit
import SwiftUI

private final class HearingPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

/// Borderless dropdown anchored to the status item, with explicit screen bounds.
@MainActor
final class HearingPanelController: NSObject {
    private let model: HearingModel
    private let panel: HearingPanel
    private var hosting: NSHostingView<HearingPanelView>!
    private var anchor = NSRect.zero
    private var screen: NSScreen?
    var containsButton: ((NSPoint) -> Bool)?
    var handleStatusClick: ((NSEvent) -> Bool)?
    private var focusObserver: NSObjectProtocol?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var contentWidth: CGFloat = 360
    private var lastContentSize = CGSize.zero
    var onVisibilityChange: ((Bool) -> Void)?
    var operationScreen: NSScreen? { panel.screen }
    var isVisible: Bool { panel.isVisible }

    init(model: HearingModel) {
        self.model = model
        panel = HearingPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 1),
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
        panel.dismiss = { [weak self] in self?.close() }
        hosting = NSHostingView(rootView: rootView())
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
    }
    private func rootView() -> HearingPanelView {
        HearingPanelView(model: model, contentWidth: contentWidth) { [weak self] size in
            DispatchQueue.main.async { [weak self] in self?.resize(to: size) }
        }
    }
    func trackAnchor(_ resolve: (NSScreen) -> NSRect?) {
        guard isVisible, let screen, let frame = resolve(screen) else { return }
        anchor = frame
        position(size: lastContentSize, screen: screen)
    }
    func show(under anchor: NSRect, on screen: NSScreen) {
        model.shortcuts.retryIfNeeded()
        self.anchor = anchor
        self.screen = screen
        model.setPanelVisible(true)
        let width = min(360, screen.visibleFrame.width - 24)
        if contentWidth != width { contentWidth = width; hosting.rootView = rootView() }
        hosting.layoutSubtreeIfNeeded()
        position(size: hosting.fittingSize, screen: screen)
        panel.makeKeyAndOrderFront(nil)
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endShortcutEditing() }
        }
        installDismissMonitors()
        onVisibilityChange?(true)
    }
    func close() {
        guard isVisible else { return }
        model.setPanelVisible(false)
        endShortcutEditing()
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
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
        panel.setFrame(StatusPanelGeometry.frame(size: size, under: anchor, within: screen.visibleFrame.insetBy(dx: 8, dy: 0), trailing: true), display: true)
    }
    private func installDismissMonitors() {
        guard localMonitor == nil, globalMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
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
                if event.keyCode == 53 { self.close(); return nil }
            } else {
                let recorder = self.panel.firstResponder as? ShortcutRecordingControl
                if event.window !== self.panel || recorder.map({ !$0.bounds.contains($0.convert(event.locationInWindow, from: nil)) }) != false {
                    self.endShortcutEditing()
                }
                if event.window !== self.panel && !self.isOverStatusItem { self.close() }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.handleStatusClick?(event) != true, !self.isOverStatusItem else { return }
            self.close()
        }
    }
    private func endShortcutEditing() {
        if let recorder = panel.firstResponder as? ShortcutRecordingControl { recorder.endEditing() }
        else { model.shortcuts.cancelRecording() }
    }
    // Let the status button's action handle its own click. Closing on mouse-down
    // here would cause the subsequent button action to reopen the panel.
    private var isOverStatusItem: Bool { containsButton?(NSEvent.mouseLocation) == true }
}
