import Foundation

extension Fix {
    /// The edit that puts back exactly what this fix replaced.
    ///
    /// Every field is the mirror of the original, and the `Fix` contract holds
    /// for the result the same way it holds for the original:
    ///
    /// - `deleteCount` counts grapheme clusters immediately behind the caret,
    ///   and after the fix ran those clusters are `insertText`;
    /// - `replacedText` is what the burst will remove, which is now the
    ///   *corrected* text — that is what the caret verification compares
    ///   against on the way back;
    /// - the layout swap runs the other way, so the user is left typing in the
    ///   language they were typing in before Dodoma interfered.
    ///
    /// `capsMode` is carried over unchanged. It describes how the alternate
    /// rendering was produced and has no meaning for text that is simply being
    /// replayed, but dropping it would mean inventing a value.
    public var inverted: Fix {
        Fix(
            deleteCount: insertText.count,
            insertText: replacedText,
            targetLayoutID: sourceLayoutID,
            sourceLayoutID: targetLayoutID,
            replacedText: insertText,
            capsMode: capsMode)
    }
}

/// The undo slot: which fix, if any, the user may still take back.
///
/// One entry deep by design. Undo here is an escape hatch from a rewrite the
/// user did not ask for, not an edit stack — the application underneath has its
/// own undo, and a second Dodoma-level step would fight it. What makes this a
/// type rather than a variable is that "is there something to undo" is a rule
/// with five ways to answer no, and every one of them is a way to delete the
/// wrong text if it is forgotten.
///
/// Pure: no clock, no locks. The owner supplies `now` and serialises access.
public struct FixHistory: Equatable, Sendable {
    /// How long after a fix the undo stays on offer. Long enough to notice the
    /// rewrite and react, short enough that ⌘⌥Z minutes later is about whatever
    /// the user is doing now rather than about a fix they have forgotten.
    public static let undoWindow: TimeInterval = 30

    /// Why the undo slot was given up. Recorded for the log line only; every
    /// case clears the slot.
    public enum Invalidation: String, Equatable, Sendable, CaseIterable {
        /// The frontmost application is no longer the one the fix landed in.
        case appChanged
        /// A focus change inside the same application. No signal emits this
        /// yet: the app has no focused-element observer, so a move between two
        /// fields of one window is invisible to it. The case is here because
        /// the `FocusMonitor` the plan defers is the thing that will emit it,
        /// and the caret verification is what covers the gap until then.
        case focusChanged
        /// The user moved on: a click, or a committed line.
        case userMovedOn
        /// The undo ran.
        case undone
        /// The buffer was purged for a reason that also forbids keeping the
        /// user's text around — see `ResetReason.purgesHistory`.
        case purged
    }

    private var slot: AppliedFix?

    public init() {}

    /// The recorded fix, ignoring the time limit. For diagnostics; callers
    /// deciding whether to offer an undo want `undoableFix(now:)`.
    public var recorded: AppliedFix? { slot }

    /// Records a fix that reached the screen. A second apply replaces the
    /// first: the older text is behind the newer one, so undoing it in place
    /// would rewrite the wrong span.
    public mutating func record(_ applied: AppliedFix) {
        slot = applied
    }

    /// Gives up the slot. Returns whether there was anything to give up.
    ///
    /// The reason is not stored. It names the call site for the reader, and
    /// the app layer logs it; keeping it here would be a field nothing reads.
    /// Hence the unnamed parameter.
    @discardableResult
    public mutating func invalidate(_: Invalidation) -> Bool {
        guard slot != nil else { return false }
        slot = nil
        return true
    }

    /// Invalidates when focus moved to a different application.
    ///
    /// The comparison is against the *recorded* bundle identifier rather than
    /// against a remembered "current" one, so a round trip away and back —
    /// ⌘-Tab to look something up, ⌘-Tab back — leaves the undo on offer, which
    /// is what the user means by it.
    @discardableResult
    public mutating func noteFrontmost(bundleID: String?) -> Bool {
        guard let slot, slot.bundleID != bundleID else { return false }
        return invalidate(.appChanged)
    }

    /// The fix the user may still take back, or nil.
    public func undoableFix(now: Date) -> AppliedFix? {
        guard let slot, Self.isWithinWindow(appliedAt: slot.appliedAt, now: now) else { return nil }
        return slot
    }

    /// Takes the undoable fix and clears the slot in one step, so that two
    /// undo requests racing on the owner's queue cannot both be served.
    public mutating func takeUndoable(now: Date) -> AppliedFix? {
        guard let applied = undoableFix(now: now) else { return nil }
        slot = nil
        return applied
    }

    /// Puts a taken fix back, for an undo that was abandoned before it changed
    /// anything on screen. The original is therefore still on screen, still in
    /// its original window, and still worth offering.
    public mutating func restore(_ applied: AppliedFix) {
        guard slot == nil else { return }
        slot = applied
    }

    /// Inclusive at the boundary: a fix applied exactly `undoWindow` ago is
    /// still undoable. Anything else would make the constant a lie by one tick.
    ///
    /// A negative interval — a fix stamped in the future, which is what a
    /// clock correction or a wake from sleep looks like — is out of the window
    /// rather than comfortably inside it. The window is a safety limit, and
    /// the direction to fail in when the clock is not trustworthy is closed.
    public static func isWithinWindow(appliedAt: Date, now: Date) -> Bool {
        (0...undoWindow).contains(now.timeIntervalSince(appliedAt))
    }

    /// Whether an input means the user has moved on from the text a fix
    /// touched, and the undo should stop being offered.
    ///
    /// Keyed off the *input* rather than off the reset the session performed:
    /// the buffer is already empty after a fix, so a click there resets nothing
    /// and would report no reason at all.
    public static func endsUndoWindow(_ input: SessionInput) -> Bool {
        switch input {
        case .mouseDown:
            // The caret is somewhere else now.
            return true
        case .key(let key):
            // Return commits the line. Everything else — arrows, escape, even a
            // command chord — leaves the text where it is and is routinely
            // pressed by reflex, so it must not cost the user their undo.
            if case .reset(let reason) = BufferResetPolicy.action(for: key) {
                return reason == .enterKey
            }
            return false
        case .appActivated:
            // Handled by `noteFrontmost`, which compares identifiers: coming
            // back to the same application does not end the window.
            return false
        case .inputSourceChanged:
            return false
        }
    }
}
