import AppKit
import CoreGraphics

enum VolumeEventFilter {
    static let mediaEventType = CGEventType(rawValue: UInt32(NSEvent.EventType.systemDefined.rawValue))!
    static let eventMask = CGEventMask(1) << mediaEventType.rawValue
    private static let userModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    /// Returns the same event. No reposting, synthetic modifier presses, or audio writes.
    @discardableResult
    static func transform(_ event: CGEvent) -> Bool {
        guard event.type == mediaEventType,
              event.flags.intersection(userModifiers).isEmpty,
              let media = NSEvent(cgEvent: event), media.subtype.rawValue == 8 else { return false }
        let key = (media.data1 >> 16) & 0xffff
        guard key == 0 || key == 1 else { return false } // NX_KEYTYPE_SOUND_UP / SOUND_DOWN
        let state = (media.data1 >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return false }
        event.flags.formUnion([.maskAlternate, .maskShift])
        return true
    }
}
