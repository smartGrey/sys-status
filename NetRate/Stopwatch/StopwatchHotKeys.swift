import AppKit
import Carbon

struct StopwatchShortcut: Codable, Hashable {
    let keyCode: UInt16
    let modifiers: UInt32

    private static let primary = UInt32(cmdKey | controlKey | optionKey)
    private static let allowed = primary | UInt32(shiftKey)
    private static let functions = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ]

    init(keyCode: UInt16, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    @MainActor init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.init(keyCode: event.keyCode, modifiers: modifiers)
    }

    fileprivate var isReservedBySystem: Bool {
        var shortcuts: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&shortcuts) == noErr,
              let records = shortcuts?.takeRetainedValue() as? [[String: Any]] else { return false }
        return records.contains { record in
            guard record["kHISymbolicHotKeyEnabled"] as? Bool == true,
                  let code = record["kHISymbolicHotKeyCode"] as? Int,
                  let flags = record["kHISymbolicHotKeyModifiers"] as? UInt32 else { return false }
            return code == Int(keyCode) && flags == modifiers
        }
    }

    var isValid: Bool {
        let code = Int(keyCode)
        let modifiersOnly = [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option,
                             kVK_RightOption, kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function]
        return code < 128 && !modifiersOnly.contains(code) && modifiers & ~Self.allowed == 0
            && (modifiers & Self.primary != 0 || Self.functions.contains(code))
    }

    @MainActor var label: String {
        let symbols = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.compactMap { modifiers & UInt32($0.0) != 0 ? $0.1 : nil }.joined() + keyLabel
    }

    @MainActor private var keyLabel: String {
        let code = Int(keyCode)
        if let index = Self.functions.firstIndex(of: code) { return "F\(index + 1)" }
        switch code {
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "空格"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: break
        }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "键 \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "键 \(code)" }
        var deadKey: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self),
                                    keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey,
                                    chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return "键 \(code)" }
        return String(decoding: chars.prefix(length), as: UTF16.self).uppercased()
    }
}

enum StopwatchHotKeyError: LocalizedError {
    case invalid, duplicate, occupied
    case registration(OSStatus)

    var shortMessage: String {
        switch self {
        case .invalid: "请加修饰键或用 F 键"
        case .duplicate: "快捷键重复"
        case .occupied: "快捷键已被占用"
        case .registration: "注册失败"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalid: "请用 ⌘、⌥ 或 ⌃ 组合按键，或使用功能键"
        case .duplicate: "此快捷键已分配给另一项操作"
        case .occupied: "此快捷键已被系统或其他 App 占用"
        case .registration(let code): "系统未能注册快捷键（\(code)）"
        }
    }
}

@MainActor
final class StopwatchHotKeys {
    private struct Registration {
        let id: UInt32
        let ref: EventHotKeyRef
        let shortcut: StopwatchShortcut
    }

    private static let signature: OSType = 0x4E525357 // NRSW
    private var registrations: [StopwatchAction: Registration] = [:]
    private var nextID: UInt32 = 0
    private var held: Set<UInt32> = []
    private var handler: EventHandlerRef?
    var onPress: ((StopwatchAction, StopwatchShortcut) -> Void)?

    // Keep the previous registration live until the replacement is registered and saved.
    func replace(_ action: StopwatchAction, with shortcut: StopwatchShortcut?, saving: () throws -> Void) throws {
        if registrations[action]?.shortcut == shortcut {
            try saving()
            return
        }
        let candidate = try shortcut.map { try register($0) }
        do {
            try saving()
        } catch {
            if let candidate { UnregisterEventHotKey(candidate.ref) }
            throw error
        }
        if let previous = registrations[action] {
            UnregisterEventHotKey(previous.ref)
            held.remove(previous.id)
        }
        registrations[action] = candidate
    }

    func stop() {
        for registration in registrations.values { UnregisterEventHotKey(registration.ref) }
        registrations.removeAll()
        held.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    func clearHeldKeys() { held.removeAll() }

    private func register(_ shortcut: StopwatchShortcut) throws -> Registration {
        guard !shortcut.isReservedBySystem else { throw StopwatchHotKeyError.occupied }
        try installHandler()
        nextID &+= 1
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers, id,
                                         GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
        if status == OSStatus(eventHotKeyExistsErr) { throw StopwatchHotKeyError.occupied }
        guard status == noErr, let reference else { throw StopwatchHotKeyError.registration(status) }
        return Registration(id: id.id, ref: reference, shortcut: shortcut)
    }

    private func installHandler() throws {
        guard handler == nil else { return }
        let types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            return MainActor.assumeIsolated {
                Unmanaged<StopwatchHotKeys>.fromOpaque(context).takeUnretainedValue().receive(id, pressed: pressed)
            }
        }, types.count, types, context, &handler)
        guard status == noErr else { throw StopwatchHotKeyError.registration(status) }
    }

    private func receive(_ id: EventHotKeyID, pressed: Bool) -> OSStatus {
        guard id.signature == Self.signature,
              let (action, registration) = registrations.first(where: { $0.value.id == id.id })
        else { return OSStatus(eventNotHandledErr) }
        if pressed {
            if held.insert(id.id).inserted { onPress?(action, registration.shortcut) }
        } else {
            held.remove(id.id)
        }
        return noErr
    }
}

