import Foundation

/// What the accessibility API managed to say about the text at the caret.
///
/// The distinction the four cases draw is the whole point: "there is no text
/// here to read" and "I could not read the text" look identical through a
/// `String?`, and they are opposite kinds of evidence. A field that structurally
/// exposes no text — a terminal, a canvas-drawn web view — is *silent*, and
/// silence carries no information about danger. A field that has a live
/// selection, or that answered nothing because it ran out of time, is *noisy*:
/// something is going on that the buffer does not know about, which is exactly
/// the situation the check exists to catch.
public enum CaretRead: Equatable, Sendable {
    /// The `n` UTF-16 units immediately before the caret, as read.
    case value(String)
    /// The focused element exposes no text at all: it answered neither
    /// `kAXSelectedTextRange` nor `kAXValue`. Nothing can be compared, and
    /// nothing suspicious was seen either.
    case unreadable
    /// The selected range is non-empty. Something — the user, or a live
    /// autocomplete — is holding a selection, and a delete burst would eat the
    /// selection before it ever reached the typed text.
    case selectionPresent
    /// No answer at all: no accessibility grant, no focused element, the
    /// inspection deadline expired, or an element that reports a caret but will
    /// not hand over the text behind it.
    case unavailable
}

/// How hard the caret check is allowed to fail.
///
/// The two modes exist because the two paths carry different evidence about
/// what the user wants, and none about what is on screen:
///
/// - `.required` is the automatic path. Nobody asked for this rewrite, so the
///   only acceptable reason to delete anything is a positive match.
/// - `.bestEffort` is the explicit path — an accepted suggestion, an undo. The
///   user asked, by name, for the text in front of the caret to be replaced.
///   That justifies proceeding where accessibility is *structurally silent*, and
///   nothing more: a live selection or a busy/lying accessibility layer is
///   evidence of danger, not absence of evidence, so those stay fail-closed.
public enum VerifyMode: String, Equatable, Sendable, CaseIterable {
    case required
    case bestEffort
}

/// Does the text in front of the caret actually match what the buffer claims?
///
/// The typed buffer is inferred from an event tap, so it is a *claim* about the
/// text immediately behind the caret, never a reading of it. Every way that
/// claim can go wrong — a keystroke the tap never saw, an autocomplete that
/// rewrote the word, a caret the user moved without an event we reset on —
/// ends in the same place: `deleteCount` backspaces eat text the user never
/// typed. That is the worst failure this app has.
///
/// So before the destructive path runs, the app reads the text before the caret
/// through the accessibility API and hands it here. A match means the buffer
/// and the screen agree and the rewrite is safe. Anything else downgrades: to a
/// suggestion on the automatic path, to a visible refusal on the explicit ones.
public enum CaretVerification {
    public enum Verdict: Equatable, Sendable {
        /// Buffer and screen agree, or the read was silent and the caller has
        /// explicit user intent. The rewrite may run.
        case proceed
        /// Do not delete anything.
        case downgrade(reason: String)
    }

    /// - Parameters:
    ///   - read: what the accessibility layer had to say at the caret.
    ///   - replacedText: `Fix.replacedText`, i.e. exactly what the delete burst
    ///     would remove. For an undo this is the *fixed* text, which is what is
    ///     on screen at that point.
    ///   - mode: see `VerifyMode`.
    ///
    /// The comparison is over UTF-16 code units, not `String.hasSuffix`:
    /// accessibility ranges are counted in UTF-16, and Swift's string
    /// comparison is canonical-equivalence based, so a decomposed rendering of
    /// the same word would compare equal and delete the wrong number of
    /// clusters. Nothing here normalises anything.
    public static func verdict(read: CaretRead, replacedText: String, mode: VerifyMode) -> Verdict {
        let expected = Array(replacedText.utf16)
        guard !expected.isEmpty else {
            // Checked before the read is even looked at: a fix that removes
            // nothing has nothing to verify and nothing to do.
            return .downgrade(reason: "the fix replaces nothing")
        }

        switch read {
        case .value(let axText):
            let actual = Array(axText.utf16)
            guard actual.count >= expected.count else {
                return .downgrade(reason: "caret text is shorter than the typed text")
            }
            guard Array(actual.suffix(expected.count)) == expected else {
                return .downgrade(reason: "caret text does not end with the typed text")
            }
            return .proceed

        case .unreadable:
            // The only cause the explicit paths are allowed to proceed on.
            return mode == .bestEffort
                ? .proceed : .downgrade(reason: "the focused element exposes no text")

        case .selectionPresent:
            return .downgrade(reason: "text is selected at the caret")

        case .unavailable:
            return .downgrade(reason: "the caret could not be read")
        }
    }
}
