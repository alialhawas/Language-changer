import AppKit
import DodomaCore
import XCTest

@testable import DodomaAppKit

/// The handful of bytes the event tap thread reads on every keystroke.
final class SuggestionStateTests: XCTestCase {
    func testNothingIsVisibleToBeginWith() {
        let state = SuggestionState()
        XCTAssertFalse(state.isVisible)
        XCTAssertEqual(state.snapshot.panelFrame, .zero)
    }

    /// The tap's default has to be "consume", or the accept key never works on
    /// a healthy machine.
    func testKeysAreConsumedUntilTheWatchdogSaysOtherwise() {
        let state = SuggestionState()
        XCTAssertTrue(state.consumesKeys)
    }

    func testShowingPublishesTheFrameAtomically() {
        let state = SuggestionState()
        let frame = CGRect(x: 10, y: 20, width: 200, height: 60)
        state.show(displayFrame: frame)

        let snapshot = state.snapshot
        XCTAssertTrue(snapshot.visible)
        XCTAssertEqual(snapshot.panelFrame, frame, "one read, both fields, no torn pair")
    }

    /// The frame goes with the card. A stale rectangle left behind would make
    /// the pipeline read an ordinary click somewhere on screen as an
    /// acceptance.
    func testHidingClearsTheFrame() {
        let state = SuggestionState()
        state.show(displayFrame: CGRect(x: 10, y: 20, width: 200, height: 60))
        state.hide()

        XCTAssertFalse(state.isVisible)
        XCTAssertEqual(state.snapshot.panelFrame, .zero)
    }

    /// The watchdog's verdict is for the rest of the session, so it must not be
    /// cleared by the next card.
    func testTheDegradedFlagSurvivesShowAndHide() {
        let state = SuggestionState()
        state.setConsumesKeys(false)
        state.show(displayFrame: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertFalse(state.consumesKeys)
        state.hide()
        XCTAssertFalse(state.consumesKeys)
    }

    /// Three threads touch this: the tap's run loop, the pipeline queue and the
    /// main thread. The lock is the only thing making that safe.
    func testConcurrentReadsAndWritesDoNotTear() {
        let state = SuggestionState()
        let frame = CGRect(x: 1, y: 2, width: 3, height: 4)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index.isMultiple(of: 2) {
                state.show(displayFrame: frame)
            } else {
                let snapshot = state.snapshot
                XCTAssertTrue(snapshot.panelFrame == frame || snapshot.panelFrame == .zero)
                state.hide()
            }
        }
    }
}

/// The lock around the undo slot. The rule itself is `FixHistoryTests`; this is
/// about the box, which the menu reads from the main thread while the pipeline
/// queue writes to it.
final class FixHistoryStoreTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    private func applied(at offset: TimeInterval = 0, in bundleID: String? = "com.apple.TextEdit")
        -> AppliedFix
    {
        AppliedFix(
            fix: Fix(
                deleteCount: 7, insertText: "السلام ",
                targetLayoutID: "com.apple.keylayout.Arabic",
                sourceLayoutID: "com.apple.keylayout.ABC", replacedText: "hgsghl ",
                capsMode: .asTyped),
            appliedAt: now.addingTimeInterval(offset),
            bundleID: bundleID)
    }

    func testRecordThenRead() {
        let store = FixHistoryStore()
        XCTAssertNil(store.undoableFix(now: now))
        store.record(applied())
        XCTAssertEqual(store.undoableFix(now: now)?.bundleID, "com.apple.TextEdit")
    }

    func testTakingIsExactlyOnce() {
        let store = FixHistoryStore()
        store.record(applied())
        XCTAssertNotNil(store.takeUndoable(now: now))
        XCTAssertNil(store.takeUndoable(now: now))
    }

    func testInvalidationAndRestore() {
        let store = FixHistoryStore()
        store.record(applied())
        store.invalidate(.userMovedOn)
        XCTAssertNil(store.undoableFix(now: now))

        store.record(applied())
        guard let claimed = store.takeUndoable(now: now) else { return XCTFail("nothing taken") }
        store.restore(claimed)
        XCTAssertNotNil(store.undoableFix(now: now))
    }

    func testNoteFrontmost() {
        let store = FixHistoryStore()
        store.record(applied())
        store.noteFrontmost(bundleID: "com.apple.TextEdit")
        XCTAssertNotNil(store.undoableFix(now: now))
        store.noteFrontmost(bundleID: "com.other.app")
        XCTAssertNil(store.undoableFix(now: now))
    }

    /// Two requests racing must not both be served: the second undo would
    /// delete a span that the first one has already replaced.
    func testOnlyOneOfManyConcurrentTakesWins() {
        let store = FixHistoryStore()
        store.record(applied())

        let taken = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if let fix = store.takeUndoable(now: now) {
                lock.lock()
                taken.add(fix.appliedAt)
                lock.unlock()
            }
        }
        XCTAssertEqual(taken.count, 1)
    }
}

/// The menu's two pure pieces. The controller itself owns an `NSStatusItem`,
/// which needs a status bar, so it is not built here.
final class MenuBarControllerTests: XCTestCase {
    func testTheLastFixLine() {
        let text = MenuBarController.lastFixText(
            replaced: "hgsghl ", inserted: "السلام ", app: "com.apple.TextEdit",
            at: Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertTrue(text.hasPrefix("Last fix: hgsghl  → السلام "))
        XCTAssertTrue(text.contains("com.apple.TextEdit"))
    }

    func testTheUndoneSuffix() {
        let line = MenuBarController.lastFixText(
            replaced: "hgsghl ", inserted: "السلام ", app: "TextEdit", at: Date())
        let undone = MenuBarController.undoneText(line)
        XCTAssertTrue(undone.hasSuffix(MenuBarController.undoneSuffix))
        XCTAssertEqual(
            MenuBarController.undoneText(undone), undone, "a second undo cannot stack the suffix")
        XCTAssertEqual(MenuBarController.undoneText(""), "", "nothing has been fixed yet")
    }

    /// The menu item and the Carbon registration describe the same chord in two
    /// different vocabularies, and a reader of either one has to be able to
    /// trust it matches the other.
    func testTheMenuItemMirrorsTheHotKey() {
        XCTAssertEqual(MenuBarController.undoModifiers, [.command, .option])
        XCTAssertEqual(
            MenuBarController.modifierFlags(Hotkeys.undoLastFix.modifiers),
            MenuBarController.undoModifiers)
        XCTAssertEqual(
            Hotkeys.undoLastFix.keycode, 6,
            "key code 6 is Z, which is what \(MenuBarController.undoKeyEquivalent) renders")
        XCTAssertEqual(MenuBarController.undoKeyEquivalent, "z")
    }
}
