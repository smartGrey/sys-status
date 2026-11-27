import AppKit
import Carbon
import Combine

struct ShortcutBinding: Codable, Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: UInt32 // Carbon modifiers; only command, control, option, shift
    static let allowedModifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
    static let functionKeys: [UInt16: String] = [122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",
        97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",
        107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
    static let ordinaryKeys: Set<UInt16> = Set(Array(UInt16(0)...51) + [53,65,67,69,71,75,76,78,81,82,83,84,85,86,87,88,89,91,92,93,94,95,102,104,114,115,116,117,119,121,123,124,125,126])
    var validationError: String? {
        guard modifiers & ~Self.allowedModifiers == 0,
              Self.ordinaryKeys.contains(keyCode) || Self.functionKeys[keyCode] != nil else {
            return "请选择普通按键或 F1–F20。"
        }
        guard Self.functionKeys[keyCode] != nil || modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else {
            return "请搭配 ⌘、⌃ 或 ⌥ 使用。"
        }
        if keyCode == 12 && modifiers == UInt32(cmdKey) { return "⌘Q 用于退出网速。" }
        return nil
    }
    init(keyCode: UInt16, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    init(event: NSEvent) {
        keyCode = event.keyCode
        modifiers = Self.carbonModifiers(event.modifierFlags)
    }
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        (flags.contains(.command) ? UInt32(cmdKey) : 0)
            | (flags.contains(.control) ? UInt32(controlKey) : 0)
            | (flags.contains(.option) ? UInt32(optionKey) : 0)
            | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
    }
    static func modifierSymbols(_ modifiers: UInt32) -> String {
        [(controlKey,"⌃"),(optionKey,"⌥"),(shiftKey,"⇧"),(cmdKey,"⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
    }
    @MainActor var display: String {
        let prefix = Self.modifierSymbols(modifiers)
        let named: [UInt16: String] = [36:"↩",48:"⇥",49:"Space",53:"⎋",76:"⌤",114:"Help",
            115:"↖",116:"⇞",117:"⌦",119:"↘",121:"⇟",123:"←",124:"→",125:"↓",126:"↑"]
        if let name = Self.functionKeys[keyCode] ?? named[keyCode] { return prefix + name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return prefix + "Key \(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return prefix + "Key \(keyCode)" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0, length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let result = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKey, characters.count, &length, &characters)
        guard result == noErr, length > 0 else { return prefix + "Key \(keyCode)" }
        return prefix + String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

@MainActor
protocol HotKeyRegistering: AnyObject {
    var onRelease: (() -> Void)? { get set }
    func register(_ binding: ShortcutBinding) -> String?
    func unregister()
}

/// Carbon supplies registered hotkeys, rather than observing all global typing.
/// All lifecycle operations and callbacks run on the main event loop.
@MainActor
final class SystemHotKey: HotKeyRegistering {
    var onRelease: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var serial: UInt32 = 0
    private var pressed = false
    private let signature: OSType = 0x48454152

    func register(_ binding: ShortcutBinding) -> String? {
        unregister()
        if let error = binding.validationError { return error }
        var symbolic: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&symbolic)
        guard status == noErr, let items = symbolic?.takeRetainedValue() as? [[String: Any]] else {
            return "无法检查系统快捷键，请重试。"
        }
        for item in items {
            if (item[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
               (item[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint16Value == binding.keyCode,
               ((item[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value ?? 0)
                    & ShortcutBinding.allowedModifiers == binding.modifiers {
                return "此组合键已被系统使用，请换一组。"
            }
        }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                Unmanaged<SystemHotKey>.fromOpaque(context).takeUnretainedValue().receive(event)
            }
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return "快捷键服务暂不可用（\(installed)）。" }
        serial &+= 1
        let result = RegisterEventHotKey(UInt32(binding.keyCode), binding.modifiers,
                                         EventHotKeyID(signature: signature, id: serial),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard result == noErr else {
            unregister()
            return result == eventHotKeyExistsErr ? "此组合键已被占用，请换一组。" : "无法注册快捷键（\(result)）。"
        }
        return nil
    }
    private func receive(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
              hotKey != nil, id.signature == signature, id.id == serial else { return OSStatus(eventNotHandledErr) }
        if GetEventKind(event) == UInt32(kEventHotKeyPressed) { pressed = true }
        else if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
            let shouldFire = pressed; pressed = false
            if shouldFire { onRelease?() }
        }
        return noErr
    }
    func unregister() {
        pressed = false
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}

@MainActor
final class HearingShortcutController: ObservableObject {
    @Published private(set) var binding: ShortcutBinding?
    @Published private(set) var isRecording = false
    @Published private(set) var isRegistered = false
    @Published private(set) var message: String?
    @Published private(set) var recordingModifiers: UInt32 = 0
    var onToggle: (() -> Void)?
    var interceptToggle: ((ShortcutBinding) -> Bool)?
    private let store: HearingStore
    private let conflict: (ShortcutBinding) -> String?
    private let registration: any HotKeyRegistering
    private var sleeping = false, stopped = false
    private var layoutObserver: NSObjectProtocol?
    init(store: HearingStore, registration: any HotKeyRegistering = SystemHotKey(),
         conflict: @escaping (ShortcutBinding) -> String? = { _ in nil }) {
        self.store = store
        self.registration = registration
        self.conflict = conflict
        binding = store.settings.shortcut
        self.registration.onRelease = { [weak self] in
            guard let self, !self.isRecording, !self.sleeping, !self.stopped, self.isRegistered else { return }
            if let binding = self.binding, self.interceptToggle?(binding) == true { return }
            self.onToggle?()
        }
        if binding != nil { restore() }
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.objectWillChange.send() } }
    }
    var title: String {
        if isRecording { return recordingModifiers == 0 ? "按下快捷键…" : ShortcutBinding.modifierSymbols(recordingModifiers) + " …" }
        return binding?.display ?? "设置快捷键"
    }
    func beginRecording() {
        guard !sleeping, !stopped, !isRecording else { return }
        registration.unregister(); isRegistered = false; message = nil; isRecording = true
        recordingModifiers = ShortcutBinding.carbonModifiers(NSEvent.modifierFlags)
    }
    func updateRecordingModifiers(_ flags: NSEvent.ModifierFlags) {
        guard isRecording else { return }
        recordingModifiers = ShortcutBinding.carbonModifiers(flags)
    }
    func accept(_ candidate: ShortcutBinding) {
        guard isRecording else { return }
        if let error = candidate.validationError { message = error; return }
        if let error = conflict(candidate) ?? registration.register(candidate) { message = error; return }
        do {
            try store.update { $0.shortcut = candidate }
            binding = candidate; isRegistered = true; isRecording = false; message = nil
        } catch {
            registration.unregister()
            message = "快捷键未能保存，请重试。"
        }
    }
    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false; message = nil; restore()
    }
    func clear() {
        registration.unregister(); isRegistered = false; isRecording = false
        do {
            try store.update { $0.shortcut = nil }
            binding = nil; message = nil
        } catch {
            restore()
            message = "快捷键未能清除，请重试。"
        }
    }
    func retryIfNeeded() {
        if binding != nil && !isRegistered && !isRecording && !sleeping && !stopped { restore() }
    }
    func setSleeping(_ value: Bool) {
        sleeping = value; isRecording = false
        registration.unregister(); isRegistered = false
        if !value { restore() }
    }
    // Return false only for Tab, which must continue through the responder chain.
    func handleRecordingKey(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if event.isARepeat { return true }
        let candidate = ShortcutBinding(event: event)
        if candidate.modifiers == 0 {
            if event.keyCode == 53 { cancelRecording(); return true }
            if event.keyCode == 51 || event.keyCode == 117 { clear(); return true }
        }
        if event.keyCode == 48 && (candidate.modifiers == 0 || candidate.modifiers == UInt32(shiftKey)) {
            cancelRecording(); return false
        }
        accept(candidate); return true
    }
    private func restore() {
        guard let binding, !sleeping, !stopped else { return }
        message = conflict(binding) ?? registration.register(binding); isRegistered = message == nil
    }
    func shutdown() {
        stopped = true; isRecording = false; isRegistered = false; registration.unregister()
        registration.onRelease = nil
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver); self.layoutObserver = nil }
    }
}
