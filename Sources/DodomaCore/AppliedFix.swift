import Foundation

/// A fix that was actually written to the screen.
///
/// `FixHistory` keeps one of these, and it carries exactly what deciding on an
/// undo needs: the edit itself (so it can be inverted), when it happened (the
/// time limit) and which application it happened in (the invalidation rule and
/// the frontmost check the injector makes before typing anything).
public struct AppliedFix: Equatable, Sendable {
    public let fix: Fix
    public let appliedAt: Date
    public let bundleID: String?
    /// Count of *user* inputs — keystrokes and clicks — as it stood when the
    /// caret was verified, just before the burst ran.
    ///
    /// Two things about it are load-bearing:
    ///
    /// - **User inputs only.** The general input serial also counts the app
    ///   switches and layout changes that invalidate work in flight, and a fix
    ///   *ends* by switching the layout — which the app hears back as an input
    ///   a few milliseconds later. Comparing against that serial would mean
    ///   every fix looked, immediately, as though something had happened since.
    ///   Keystrokes and clicks are the signals that move the caret; the other
    ///   two have their own, sharper rules (`noteFrontmost`, `noteInputSource`).
    /// - **Taken at verification, not at record time.** An injection runs for a
    ///   few hundred milliseconds, and real input inside it is dropped by the
    ///   pipeline *after* moving the count, so a value read afterwards would
    ///   already have moved past the very thing this is meant to notice.
    ///
    /// Together they make "nothing the user did has happened since the fix
    /// landed" one comparison — the only evidence an undo has that the
    /// correction is still the last thing in front of the caret, in the
    /// applications where the caret cannot be read at all.
    ///
    /// Deliberately without a default: a call site that forgot it would get an
    /// undo that believes nothing has happened when everything has.
    public let userInputSerial: UInt64

    public init(fix: Fix, appliedAt: Date, bundleID: String?, userInputSerial: UInt64) {
        self.fix = fix
        self.appliedAt = appliedAt
        self.bundleID = bundleID
        self.userInputSerial = userInputSerial
    }
}
