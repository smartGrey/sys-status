import AppKit
import Carbon

/// Persisted identically by both features. Registration and key-down/key-up policies belong to the owner.
struct ShortcutBinding: Codable, Hashable, Sendable {
    let keyCode: UInt16
    let modifiers: UInt32

    static let primaryModifiers = UInt32(cmdKey | controlKey | optionKey)
    static let allowedModifiers = primaryModifiers | UInt32(shiftKey)
    static let functionKeys: [UInt16: String] = {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { (UInt16($0.element), "F\($0.offset + 1)") })
    }()

    init(keyCode: UInt16, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: Self.carbonModifiers(event.modifierFlags))
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        (flags.contains(.command) ? UInt32(cmdKey) : 0)
            | (flags.contains(.control) ? UInt32(controlKey) : 0)
            | (flags.contains(.option) ? UInt32(optionKey) : 0)
            | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
    }

    static func modifierSymbols(_ modifiers: UInt32) -> String {
        [(controlKey,"⌃"), (optionKey,"⌥"), (shiftKey,"⇧"), (cmdKey,"⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
    }

    /// nil means macOS could not supply the list. Each feature retains its existing fallback.
    func systemReservation(mask: UInt32 = .max) -> Bool? {
        var shortcuts: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&shortcuts) == noErr,
              let records = shortcuts?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return records.contains { record in
            guard (record[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
                  let key = record[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let flags = record[kHISymbolicHotKeyModifiers as String] as? NSNumber else { return false }
            return key.uint16Value == keyCode && flags.uint32Value & mask == modifiers
        }
    }

    @MainActor func translatedKey(using source: Unmanaged<TISInputSource>?) -> String? {
        guard let source = source?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        var deadKey: UInt32 = 0, length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self),
                                    keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        return String(decoding: chars.prefix(length), as: UTF16.self).uppercased()
    }
}
