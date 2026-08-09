import Foundation

/// A fix that was actually written to the screen.
///
/// The pipeline keeps a single slot of this. M7 turns the slot into a bounded
/// `FixHistory`, which is why the record already carries everything an undo
/// needs: the edit itself, when it happened and which app it happened in.
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
