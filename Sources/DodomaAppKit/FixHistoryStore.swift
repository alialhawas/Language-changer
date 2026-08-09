import DodomaCore
import Foundation

/// The undo slot, made readable from the main thread.
///
/// `FixHistory` is the rule; this is the box it lives in. Every mutation
/// happens on the pipeline queue, but the menu has to answer "is Undo Last Fix
/// enabled" *synchronously* while the menu is opening, and the answer changes
/// with the clock as well as with events — a queue hop would either block the
/// main thread or show a stale item. One uncontended lock, like `SuggestionState`.
final class FixHistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var history = FixHistory()

    /// The fix the user may still take back, at `now`. Callable from any thread.
    func undoableFix(now: Date) -> AppliedFix? {
        lock.lock()
        defer { lock.unlock() }
        return history.undoableFix(now: now)
    }

    func record(_ applied: AppliedFix) {
        lock.lock()
        history.record(applied)
        lock.unlock()
    }

    /// Claims the undoable fix, so two requests cannot both be served.
    func takeUndoable(now: Date) -> AppliedFix? {
        lock.lock()
        defer { lock.unlock() }
        return history.takeUndoable(now: now)
    }

    /// Puts back a fix claimed by an undo that never reached the screen.
    func restore(_ applied: AppliedFix) {
        lock.lock()
        history.restore(applied)
        lock.unlock()
    }

    func invalidate(_ reason: FixHistory.Invalidation) {
        lock.lock()
        let cleared = history.invalidate(reason)
        lock.unlock()
        if cleared {
            Log.fix.debug("undo withdrawn: \(reason.rawValue, privacy: .public)")
        }
    }

    func noteFrontmost(bundleID: String?) {
        lock.lock()
        let cleared = history.noteFrontmost(bundleID: bundleID)
        lock.unlock()
        if cleared {
            Log.fix.debug(
                "undo withdrawn: \(FixHistory.Invalidation.appChanged.rawValue, privacy: .public)")
        }
    }
}
