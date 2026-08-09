import Carbon.HIToolbox
import Foundation

/// How a key's shift/caps state is treated when re-rendering it.
///
/// Typing Arabic-through-an-English-layout is very often done with Caps Lock
/// on, and the shifted Arabic layout is almost entirely diacritics, so the
/// same keycode sequence has to be tried with the case modifiers neutralised.
public enum CapsMode: String, CaseIterable, Sendable {
    /// Shift, caps lock and option exactly as captured.
    case asTyped
    /// Shift dropped; caps lock and option kept.
    case shiftStripped
    /// Shift and caps lock dropped; option kept.
    case lowercased
}

/// Renders captured keycode sequences through an arbitrary keyboard layout.
public struct LayoutRenderer {
    /// The text `keys` would have produced had they been typed under `layout`.
    public static func render(_ keys: [CapturedKey], layout: KeyboardLayout, capsMode: CapsMode)
        -> String
    {
        renderPerKey(keys, layout: layout, capsMode: capsMode).joined()
    }

    /// Fraction of keys that translate to nothing under `layout`. A high rate
    /// means the sequence is a poor fit for that layout.
    public static func emptyRate(_ keys: [CapturedKey], layout: KeyboardLayout, capsMode: CapsMode)
        -> Double
    {
        let pieces = renderPerKey(keys, layout: layout, capsMode: capsMode)
        guard !pieces.isEmpty else { return 0 }
        let empties = pieces.reduce(into: 0) { count, piece in
            if piece.isEmpty { count += 1 }
        }
        return Double(empties) / Double(pieces.count)
    }

    /// One translation per input key; entries may be empty or multi-character.
    public static func renderPerKey(
        _ keys: [CapturedKey], layout: KeyboardLayout, capsMode: CapsMode
    ) -> [String] {
        guard !keys.isEmpty else { return [] }

        var pieces: [String] = []
        pieces.reserveCapacity(keys.count)
        // Threaded across the whole sequence so a dead key composes with the
        // key that follows it, exactly as it would while typing.
        var deadKeyState: UInt32 = 0

        layout.uchrData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                pieces = Array(repeating: "", count: keys.count)
                return
            }
            let table = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for key in keys {
                pieces.append(
                    translate(key, table: table, capsMode: capsMode, deadKeyState: &deadKeyState))
            }
        }
        return pieces
    }

    private static func translate(
        _ key: CapturedKey,
        table: UnsafePointer<UCKeyboardLayout>,
        capsMode: CapsMode,
        deadKeyState: inout UInt32
    ) -> String {
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        let keyboardType = key.keyboardType != 0 ? key.keyboardType : UInt32(LMGetKbdType())

        let status = UCKeyTranslate(
            table,
            key.keycode,
            UInt16(kUCKeyActionDown),
            modifierState(for: key.flags, capsMode: capsMode),
            keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters)

        guard status == noErr, length > 0 else { return "" }
        return String(utf16CodeUnits: characters, count: length)
    }

    /// `UCKeyTranslate` wants the Carbon modifier word already shifted down by
    /// 8 bits, so shift becomes 2, caps lock 4 and option 8. Control never
    /// participates: control chords reset the buffer upstream and are never
    /// part of a rendered sequence.
    private static func modifierState(for flags: KeyFlags, capsMode: CapsMode) -> UInt32 {
        var state: UInt32 = 0
        switch capsMode {
        case .asTyped:
            if flags.contains(.shift) { state |= CarbonModifierState.shift }
            if flags.contains(.capsLock) { state |= CarbonModifierState.capsLock }
        case .shiftStripped:
            if flags.contains(.capsLock) { state |= CarbonModifierState.capsLock }
        case .lowercased:
            break
        }
        if flags.contains(.option) { state |= CarbonModifierState.option }
        return state
    }

    private enum CarbonModifierState {
        static let shift = UInt32((shiftKey >> 8) & 0xFF)
        static let capsLock = UInt32((alphaLock >> 8) & 0xFF)
        static let option = UInt32((optionKey >> 8) & 0xFF)
    }
}
