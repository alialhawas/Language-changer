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

/// One key's contribution to a rendered sequence.
public struct RenderedKey: Equatable, Sendable {
    /// Text this key contributed. Empty for a dead key that is still pending,
    /// and for a key the layout does not map at all.
    public let text: String
    /// The key armed a dead key rather than emitting text. Its glyph arrives
    /// with the key that follows (composition) or, at the end of a sequence,
    /// as the spacing form appended here by the trailing flush.
    public let isDeadKey: Bool

    public init(text: String, isDeadKey: Bool) {
        self.text = text
        self.isDeadKey = isDeadKey
    }

    /// The layout has nothing on this key. A pending dead key is *not*
    /// unproducible: it renders through the next keystroke.
    public var isUnproducible: Bool {
        text.isEmpty && !isDeadKey
    }
}

/// Renders captured keycode sequences through an arbitrary keyboard layout.
public struct LayoutRenderer {
    /// The text `keys` would have produced had they been typed under `layout`.
    public static func render(_ keys: [CapturedKey], layout: KeyboardLayout, capsMode: CapsMode)
        -> String
    {
        renderKeys(keys, layout: layout, capsMode: capsMode).map(\.text).joined()
    }

    /// Fraction of keys the layout cannot produce anything for. A high rate
    /// means the sequence is a poor fit for that layout.
    public static func emptyRate(_ keys: [CapturedKey], layout: KeyboardLayout, capsMode: CapsMode)
        -> Double
    {
        let rendered = renderKeys(keys, layout: layout, capsMode: capsMode)
        guard !rendered.isEmpty else { return 0 }
        let unproducible = rendered.reduce(into: 0) { count, key in
            if key.isUnproducible { count += 1 }
        }
        return Double(unproducible) / Double(rendered.count)
    }

    /// One translation per input key; entries may be empty or multi-character.
    public static func renderPerKey(
        _ keys: [CapturedKey], layout: KeyboardLayout, capsMode: CapsMode
    ) -> [String] {
        renderKeys(keys, layout: layout, capsMode: capsMode).map(\.text)
    }

    /// One `RenderedKey` per input key, preserving the dead-key distinction
    /// that `emptyRate` needs.
    public static func renderKeys(
        _ keys: [CapturedKey], layout: KeyboardLayout, capsMode: CapsMode
    ) -> [RenderedKey] {
        guard !keys.isEmpty else { return [] }

        var rendered: [RenderedKey] = []
        rendered.reserveCapacity(keys.count)
        // Threaded across the whole sequence so a dead key composes with the
        // key that follows it, exactly as it would while typing.
        var deadKeyState: UInt32 = 0

        layout.uchrData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                rendered = Array(
                    repeating: RenderedKey(text: "", isDeadKey: false), count: keys.count)
                return
            }
            let table = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for key in keys {
                rendered.append(
                    translate(key, table: table, capsMode: capsMode, deadKeyState: &deadKeyState))
            }
            flushTrailingDeadKey(
                into: &rendered,
                table: table,
                keyboardType: keyboardType(of: keys[keys.count - 1]),
                deadKeyState: &deadKeyState)
        }
        return rendered
    }

    /// A sequence that ends on a dead key is one glyph short of what is on
    /// screen: macOS shows the pending accent in its spacing form until the
    /// next keystroke resolves it. Translating a space against the pending
    /// state yields exactly that glyph (option+e → `´`, option+` → `` ` ``),
    /// so it is appended to the dead key's own entry.
    private static func flushTrailingDeadKey(
        into rendered: inout [RenderedKey],
        table: UnsafePointer<UCKeyboardLayout>,
        keyboardType: UInt32,
        deadKeyState: inout UInt32
    ) {
        guard let last = rendered.last, last.isDeadKey, deadKeyState != 0 else { return }

        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = UCKeyTranslate(
            table,
            Keycode.space,
            UInt16(kUCKeyActionDown),
            0,
            keyboardType,
            translateOptions,
            &deadKeyState,
            characters.count,
            &length,
            &characters)
        guard status == noErr, length > 0 else { return }

        var spacing = String(utf16CodeUnits: characters, count: length)
        // Every dead key on the layouts we ship fixtures for resolves to a
        // single scalar, but a layout that echoed the space as well would
        // otherwise leak it into the output.
        if spacing.count > 1, spacing.hasSuffix(" ") { spacing.removeLast() }
        guard !spacing.isEmpty else { return }

        rendered[rendered.index(before: rendered.endIndex)] = RenderedKey(
            text: last.text + spacing, isDeadKey: true)
    }

    private static func translate(
        _ key: CapturedKey,
        table: UnsafePointer<UCKeyboardLayout>,
        capsMode: CapsMode,
        deadKeyState: inout UInt32
    ) -> RenderedKey {
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0

        let status = UCKeyTranslate(
            table,
            key.keycode,
            UInt16(kUCKeyActionDown),
            modifierState(for: key.flags, capsMode: capsMode),
            keyboardType(of: key),
            translateOptions,
            &deadKeyState,
            characters.count,
            &length,
            &characters)

        guard status == noErr else { return RenderedKey(text: "", isDeadKey: false) }
        guard length > 0 else {
            // A key that emits nothing but leaves dead-key state behind armed a
            // dead key; one that leaves the state clear is simply unmapped.
            // Verified exhaustively over 128 keycodes x 6 modifier states on
            // both fixture layouts: the two cases never overlap.
            return RenderedKey(text: "", isDeadKey: deadKeyState != 0)
        }
        return RenderedKey(text: String(utf16CodeUnits: characters, count: length), isDeadKey: false)
    }

    /// Captures made before the keyboard type was recorded carry 0; fall back
    /// to the running machine's type for those.
    private static func keyboardType(of key: CapturedKey) -> UInt32 {
        key.keyboardType != 0 ? key.keyboardType : UInt32(LMGetKbdType())
    }

    /// Dead-key processing is deliberately left ON.
    ///
    /// Do not "fix" this to `kUCKeyTranslateNoDeadKeysMask`: composition is the
    /// behaviour we want. Rendering a sequence must yield what the user would
    /// have seen under the correct layout — which is exactly the string M4
    /// types back — so `option+e, e` has to render as `é`, not as `e`. The
    /// composition is carried by the `deadKeyState` threaded through the whole
    /// sequence. `kUCKeyTranslateNoDeadKeysBit` is a bit *index* (0) rather
    /// than a mask, so spelling it that way reads as the exact opposite of
    /// what it does; the literal is used instead.
    private static let translateOptions = OptionBits(0)

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
