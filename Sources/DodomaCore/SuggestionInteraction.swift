import CoreGraphics
import Foundation

/// What the event tap should do with a key while a suggestion is on screen.
public enum KeyDisposition: String, Equatable, Sendable {
    /// Forward the key untouched. No suggestion is up.
    case pass
    /// Consume the key and treat it as "apply the suggestion".
    case swallowAndAccept
    /// Consume the key and treat it as "put the panel away".
    case swallowAndDismiss
    /// Forward the key — it is real typing and must land in the application —
    /// and take the panel down on the way past.
    case dismissAndPass
}

/// What the pipeline should do with a mouse-down while a suggestion is up.
public enum MouseDisposition: String, Equatable, Sendable {
    /// No suggestion is up: an ordinary click.
    case pass
    /// The click landed on the card, which is the second way to accept.
    case accept
    /// A click somewhere else. It is still an ordinary click — the caret has
    /// moved, so the buffer goes — and the panel goes with it.
    case dismissAndPass
}

/// Whether an acceptance still refers to the text the panel was shown about.
public enum AcceptanceVerdict: String, Equatable, Sendable {
    case apply
    /// Input arrived after the panel appeared, so the span the fix would delete
    /// is no longer the span it was computed for.
    case stale
    /// Nothing is pending — a duplicate accept, or one that raced a dismissal.
    case gone
}

/// The three rules the suggestion panel's interaction is made of, as pure
/// functions.
///
/// They are here rather than in the app target because each of them is read
/// from a different thread — the key rule from the event tap's own run loop, the
/// mouse rule and the acceptance rule from the pipeline queue — and because
/// getting any of them wrong is invisible until somebody's Tab key stops
/// working in a text editor.
public enum SuggestionKeys {
    /// Tab. Chosen over Return because Return is how you send a message, and
    /// because the tap only ever consumes it while a panel is visible.
    public static let acceptKeycode = Keycode.tab
    public static let dismissKeycode = Keycode.escape

    /// - Parameters:
    ///   - visible: a suggestion panel is on screen right now.
    ///   - consumesKeys: the tap is allowed to swallow events. False after the
    ///     watchdog has tripped, where consuming input is the thing most likely
    ///     to be making the situation worse; the panel is then click-only.
    ///   - flags: the modifiers the event carried. Only the bare key is ever
    ///     the panel's — see `KeyFlags.panelKeyBlockers`. Deliberately without
    ///     a default: a caller that forgot to pass them would consume ⌘⇥ and
    ///     hand it to the pipeline as an acceptance, which applies a fix
    ///     because the swallowed key never moved the input serial.
    public static func disposition(
        visible: Bool, consumesKeys: Bool, keycode: UInt16, flags: KeyFlags
    ) -> KeyDisposition {
        guard visible else { return .pass }
        guard consumesKeys else { return .dismissAndPass }
        guard flags.isDisjoint(with: .panelKeyBlockers) else { return .dismissAndPass }
        switch keycode {
        case acceptKeycode: return .swallowAndAccept
        case dismissKeycode: return .swallowAndDismiss
        default: return .dismissAndPass
        }
    }

    /// - Parameters:
    ///   - primaryButton: a left mouse-down. A right or middle click on the
    ///     card is not an acceptance; it is a click, and it takes the card away
    ///     like any other.
    ///   - panelFrame: the card's rectangle, in the same coordinate space as
    ///     `location`. The app layer keeps it in display coordinates, because
    ///     that is what a `CGEvent` reports and the tap must not do arithmetic.
    public static func mouseDisposition(
        visible: Bool, primaryButton: Bool, panelFrame: CGRect, location: CGPoint
    ) -> MouseDisposition {
        guard visible else { return .pass }
        guard primaryButton, panelFrame.contains(location) else { return .dismissAndPass }
        return .accept
    }

    /// The acceptance-validity rule.
    ///
    /// The panel is shown against an input serial. Anything at all that moves
    /// that serial — a keystroke, a click elsewhere, an application switch —
    /// means the text in front of the caret is not what the fix was computed
    /// from, and a delete burst measured from the caret would eat the wrong
    /// span. Accepting is therefore only valid on an unmoved serial. The keys
    /// that operate the panel are swallowed by the tap and never reach the
    /// buffer, so they do not move it.
    public static func acceptance(pendingSerial: UInt64?, currentSerial: UInt64)
        -> AcceptanceVerdict
    {
        guard let pendingSerial else { return .gone }
        return pendingSerial == currentSerial ? .apply : .stale
    }
}

/// Region texts that have been offered and turned down recently.
///
/// Without this, a dismissed suggestion comes straight back: the buffer is not
/// reset by a dismissal — the text really is still on screen — so the next quiet
/// period re-evaluates the same keys and reaches the same verdict, once a
/// second, forever. Suppression is per application because the same word can be
/// wrong in a chat window and deliberate in an editor.
public struct SuggestionSuppression: Equatable, Sendable {
    /// How long a dismissal is remembered.
    public static let window: TimeInterval = 60

    private var entries: [String: TimeInterval] = [:]

    public init() {}

    public var count: Int { entries.count }

    /// The `\0` separator cannot occur in a bundle identifier, so no pair of
    /// (text, app) can collide with another by concatenation.
    public static func key(text: String, bundleID: String?) -> String {
        "\(bundleID ?? "")\u{0}\(text)"
    }

    public mutating func record(text: String, bundleID: String?, at now: TimeInterval) {
        prune(before: now)
        entries[Self.key(text: text, bundleID: bundleID)] = now
    }

    public func isSuppressed(text: String, bundleID: String?, at now: TimeInterval) -> Bool {
        guard let recorded = entries[Self.key(text: text, bundleID: bundleID)] else { return false }
        return now - recorded < Self.window
    }

    /// Drops expired entries. Called on every record, so the set cannot grow
    /// without bound over a long session.
    public mutating func prune(before now: TimeInterval) {
        entries = entries.filter { now - $0.value < Self.window }
    }
}
