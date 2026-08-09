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

    public init(fix: Fix, appliedAt: Date, bundleID: String?) {
        self.fix = fix
        self.appliedAt = appliedAt
        self.bundleID = bundleID
    }
}
