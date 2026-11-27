import AppKit
import Carbon

extension ShortcutBinding {
    var isValidForStopwatch: Bool {
        let code = Int(keyCode)
        let modifiersOnly = [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option,
                             kVK_RightOption, kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function]
        return code < 128 && !modifiersOnly.contains(code) && modifiers & ~Self.allowedModifiers == 0
            && (modifiers & Self.primaryModifiers != 0 || Self.functionKeys[keyCode] != nil)
    }

    @MainActor var stopwatchLabel: String {
        Self.modifierSymbols(modifiers) + keyLabel
    }

    @MainActor private var keyLabel: String {
        let code = Int(keyCode)
        if let name = Self.functionKeys[keyCode] { return name }
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
        return translatedKey(using: TISCopyCurrentASCIICapableKeyboardLayoutInputSource()) ?? "键 \(code)"
    }
}

enum StopwatchHotKeyError: LocalizedError {
    case invalid, duplicate, occupied, hearing
    case registration(OSStatus)

    var shortMessage: String {
        switch self {
        case .invalid: "请加修饰键或用 F 键"
        case .hearing: "已用于环境音透传"
        case .duplicate: "快捷键重复"
        case .occupied: "快捷键已被占用"
        case .registration: "注册失败"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalid: "请用 ⌘、⌥ 或 ⌃ 组合按键，或使用功能键"
        case .hearing: "已用于环境音透传"
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
        let shortcut: ShortcutBinding
    }

    private static let signature: OSType = 0x4E525357 // NRSW
    private var registrations: [StopwatchAction: Registration] = [:]
    private var nextID: UInt32 = 0
    private var held: Set<UInt32> = []
    private var handler: EventHandlerRef?
    var onPress: ((StopwatchAction, ShortcutBinding) -> Void)?

    // Keep the previous registration live until the replacement is registered and saved.
    func replace(_ action: StopwatchAction, with shortcut: ShortcutBinding?, saving: () throws -> Void) throws {
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

    private func register(_ shortcut: ShortcutBinding) throws -> Registration {
        guard shortcut.systemReservation() != true else { throw StopwatchHotKeyError.occupied }
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

