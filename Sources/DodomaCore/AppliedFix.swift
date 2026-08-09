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
    /// The input serial the caret was verified at, before the burst ran.
    ///
    /// Not the serial at the moment the record was written: an injection takes
    /// a few hundred milliseconds and real input that lands inside it is
    /// dropped by the pipeline, so a serial read afterwards would already have
    /// moved past the very thing this is meant to notice. Stamping the
    /// verification serial makes "nothing at all has happened since the fix
    /// landed" a single comparison — which is the only evidence an undo has
    /// that the correction is still the last thing in front of the caret, in
    /// the applications where the caret cannot be read.
    ///
    /// Deliberately without a default: a call site that forgot it would get an
    /// undo that believes nothing has happened when everything has.
    public let inputSerial: UInt64

    public init(fix: Fix, appliedAt: Date, bundleID: String?, inputSerial: UInt64) {
        self.fix = fix
        self.appliedAt = appliedAt
        self.bundleID = bundleID
        self.inputSerial = inputSerial
    }
}
