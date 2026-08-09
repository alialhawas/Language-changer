import Foundation

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
/// and the screen agree and the rewrite is safe. Anything else — mismatch,
/// short read, no accessibility value at all — downgrades the auto-apply to a
/// suggestion, which is harmless by construction.
public enum CaretVerification {
    public enum Verdict: Equatable, Sendable {
        /// Buffer and screen agree; the auto-apply may run.
        case proceed
        /// Do not delete anything. Offer the same fix as a suggestion instead.
        case downgrade(reason: String)
    }

    /// - Parameters:
    ///   - axText: the text immediately before the caret, as read over the
    ///     accessibility API. Nil when it could not be read at all, which is
    ///     routine in web views and terminals.
    ///   - replacedText: `Fix.replacedText`, i.e. exactly what the delete burst
    ///     would remove.
    ///
    /// The comparison is over UTF-16 code units, not `String.hasSuffix`:
    /// accessibility ranges are counted in UTF-16, and Swift's string
    /// comparison is canonical-equivalence based, so a decomposed rendering of
    /// the same word would compare equal and delete the wrong number of
    /// clusters. Nothing here normalises anything.
    public static func verdict(axText: String?, replacedText: String) -> Verdict {
        let expected = Array(replacedText.utf16)
        guard !expected.isEmpty else {
            return .downgrade(reason: "the fix replaces nothing")
        }
        guard let axText else {
            return .downgrade(reason: "no accessibility text at the caret")
        }
        let actual = Array(axText.utf16)
        guard actual.count >= expected.count else {
            return .downgrade(reason: "caret text is shorter than the typed text")
        }
        guard Array(actual.suffix(expected.count)) == expected else {
            return .downgrade(reason: "caret text does not end with the typed text")
        }
        return .proceed
    }
}
