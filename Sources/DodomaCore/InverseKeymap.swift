import Carbon.HIToolbox
import Foundation

/// Turns text back into the keystrokes that would have produced it under a
/// given layout, by enumerating the layout rather than hard-coding it.
///
/// `KeycodeMap` covers the US/ANSI Latin case with a static table; this covers
/// any layout, which is what the `--decide` and `--eval` harnesses need to
/// replay Arabic text as the keys a user pressed. Like `KeycodeMap` it is a
/// harness facility: real captures carry real keycodes.
public enum InverseKeymap {
    /// A key press that produces one character under some layout.
    public struct Stroke: Equatable, Sendable {
        public let keycode: UInt16
        public let flags: KeyFlags
    }

    /// Keys that never carry typed text, whatever the layout says they emit.
    private static let excludedKeycodes: Set<UInt16> = [
        Keycode.returnKey, Keycode.tab, Keycode.delete, Keycode.escape, Keycode.keypadEnter,
        Keycode.home, Keycode.pageUp, Keycode.forwardDelete, Keycode.end, Keycode.pageDown,
        Keycode.leftArrow, Keycode.rightArrow, Keycode.downArrow, Keycode.upArrow,
    ]

    /// character → stroke for every single-character key of `layout`.
    ///
    /// Built by translating keycodes 0…127 unshifted and shifted. The first
    /// stroke to claim a character wins, so the number row beats the keypad and
    /// an unshifted key beats a shifted one. Dead keys are skipped: they emit
    /// nothing on their own and would map a character they only compose.
    public static func table(for layout: KeyboardLayout, keyboardType: UInt32? = nil)
        -> [Character: Stroke]
    {
        let keyboardType = keyboardType ?? UInt32(LMGetKbdType())
        var table: [Character: Stroke] = [:]
        for flags in [KeyFlags(), KeyFlags.shift] {
            for keycode in UInt16(0)...127 {
                guard !excludedKeycodes.contains(keycode),
                      !BufferResetPolicy.modifierKeycodes.contains(keycode)
                else { continue }
                let probe = CapturedKey(
                    keycode: keycode, flags: flags, producedText: "", keyboardType: keyboardType)
                let rendered = LayoutRenderer.renderKeys(
                    [probe], layout: layout, capsMode: .asTyped)
                guard let key = rendered.first, !key.isDeadKey, key.text.count == 1,
                      let character = key.text.first, !character.isNewline
                else { continue }
                if table[character] == nil {
                    table[character] = Stroke(keycode: keycode, flags: flags)
                }
            }
        }
        return table
    }

    /// The keystrokes that type `text` under `layout`, or `nil` if the layout
    /// has no key for one of the characters.
    public static func keys(
        for text: String, layout: KeyboardLayout, keyboardType: UInt32? = nil
    ) -> [CapturedKey]? {
        let keyboardType = keyboardType ?? UInt32(LMGetKbdType())
        let table = table(for: layout, keyboardType: keyboardType)
        var keys: [CapturedKey] = []
        keys.reserveCapacity(text.count)
        for character in text {
            guard let stroke = table[character] else { return nil }
            keys.append(
                CapturedKey(
                    keycode: stroke.keycode,
                    flags: stroke.flags,
                    producedText: String(character),
                    keyboardType: keyboardType))
        }
        return keys
    }

    /// The first character of `text` that `layout` cannot type. For error messages.
    public static func unmappableCharacter(
        in text: String, layout: KeyboardLayout, keyboardType: UInt32? = nil
    ) -> Character? {
        let table = table(for: layout, keyboardType: keyboardType)
        return text.first { table[$0] == nil }
    }
}
