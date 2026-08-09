import XCTest

@testable import DodomaCore

/// The canonical fix this file works from: `hgsghl ` typed under ABC, which
/// reads `السلام ` under the Arabic layout. The trailing space is part of both
/// halves — see the `Fix` contract — and the Arabic side contains the لا
/// ligature, which is two grapheme clusters' worth of keys and one cluster on
/// screen. Both are exactly where an inverse built by counting the wrong thing
/// would go wrong.
private enum Canonical {
    static let english = "com.apple.keylayout.ABC"
    static let arabic = "com.apple.keylayout.Arabic"

    static let typed = "hgsghl "
    static let fixed = "السلام "

    static let fix = Fix(
        deleteCount: typed.count,
        insertText: fixed,
        targetLayoutID: arabic,
        sourceLayoutID: english,
        replacedText: typed,
        capsMode: .asTyped)

    static func applied(at date: Date, in bundleID: String? = "com.apple.TextEdit") -> AppliedFix {
        AppliedFix(fix: fix, appliedAt: date, bundleID: bundleID)
    }
}

final class InverseFixTests: XCTestCase {
    func testEveryFieldIsMirrored() {
        let inverse = Canonical.fix.inverted
        XCTAssertEqual(inverse.deleteCount, Canonical.fixed.count)
        XCTAssertEqual(inverse.insertText, Canonical.typed)
        XCTAssertEqual(inverse.targetLayoutID, Canonical.english)
        XCTAssertEqual(inverse.sourceLayoutID, Canonical.arabic)
        XCTAssertEqual(inverse.replacedText, Canonical.fixed)
    }

    /// The whole point of the delete count: after the fix ran, the clusters
    /// behind the caret are `insertText`, so undoing removes exactly that many.
    func testTheDeleteCountCountsWhatIsActuallyOnScreen() {
        XCTAssertEqual(Canonical.fix.inverted.deleteCount, "السلام ".count)
        XCTAssertEqual(Canonical.fix.inverted.deleteCount, 7, "six letters and the space")
    }

    /// Clusters, not UTF-16 units. A decomposed letter is one backspace and two
    /// units, and counting units would send an extra backspace into the word in
    /// front of it.
    func testTheDeleteCountIsClustersNotUTF16Units() {
        let decomposed = "\u{0627}\u{0654} "  // ALEF + HAMZA ABOVE, then a space
        XCTAssertEqual(decomposed.count, 2)
        XCTAssertEqual(decomposed.utf16.count, 3, "precondition: the two disagree here")

        let fix = Fix(
            deleteCount: 2, insertText: decomposed, targetLayoutID: Canonical.arabic,
            sourceLayoutID: Canonical.english, replacedText: "h ", capsMode: .asTyped)
        XCTAssertEqual(fix.inverted.deleteCount, 2)
    }

    /// لا is one grapheme cluster and one backspace, whatever it took to type.
    func testTheLigatureCountsAsOneCluster() {
        let fix = Fix(
            deleteCount: 3, insertText: "لا ", targetLayoutID: Canonical.arabic,
            sourceLayoutID: Canonical.english, replacedText: "gh ", capsMode: .asTyped)
        XCTAssertEqual("لا ".count, 3, "ARABIC LAM, ARABIC ALEF, space — three clusters")
        XCTAssertEqual(fix.inverted.deleteCount, 3)

        let presentationForm = "\u{FEFB} "  // ARABIC LIGATURE LAM WITH ALEF ISOLATED FORM
        let ligature = Fix(
            deleteCount: 2, insertText: presentationForm, targetLayoutID: Canonical.arabic,
            sourceLayoutID: Canonical.english, replacedText: "gh", capsMode: .asTyped)
        XCTAssertEqual(presentationForm.count, 2, "one ligature glyph and the space")
        XCTAssertEqual(ligature.inverted.deleteCount, 2)
    }

    /// Undo, then undo the undo, is the original. Nothing is lost in a round
    /// trip, which is what makes the inverse an inverse.
    func testRoundTrip() {
        XCTAssertEqual(Canonical.fix.inverted.inverted, Canonical.fix)
    }

    /// The trailing separator has to survive: dropping it would leave the user
    /// having to retype the space, and — worse — would leave `deleteCount` and
    /// `replacedText` disagreeing.
    func testTheTrailingSpaceSurvivesBothWays() {
        XCTAssertTrue(Canonical.fix.inverted.insertText.hasSuffix(" "))
        XCTAssertTrue(Canonical.fix.inverted.replacedText.hasSuffix(" "))
        XCTAssertEqual(
            Canonical.fix.inverted.deleteCount, Canonical.fix.inverted.replacedText.count,
            "the Fix contract, point 2")
    }
}

final class FixHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    private func historyWithAFix(at offset: TimeInterval = 0, in bundleID: String? = "com.apple.TextEdit")
        -> FixHistory
    {
        var history = FixHistory()
        history.record(Canonical.applied(at: now.addingTimeInterval(offset), in: bundleID))
        return history
    }

    func testNothingIsUndoableToBeginWith() {
        XCTAssertNil(FixHistory().undoableFix(now: now))
    }

    func testARecordedFixIsUndoable() {
        let history = historyWithAFix()
        XCTAssertEqual(history.undoableFix(now: now)?.fix, Canonical.fix)
    }

    // MARK: - The time limit

    func testTheWindowIsInclusiveAtTheBoundary() {
        let history = historyWithAFix()
        let boundary = now.addingTimeInterval(FixHistory.undoWindow)
        XCTAssertNotNil(history.undoableFix(now: boundary), "exactly 30 s still counts")
        XCTAssertNil(history.undoableFix(now: boundary.addingTimeInterval(0.001)))
    }

    func testTheWindowIsThirtySeconds() {
        XCTAssertEqual(FixHistory.undoWindow, 30)
        let history = historyWithAFix()
        XCTAssertNotNil(history.undoableFix(now: now.addingTimeInterval(29.9)))
        XCTAssertNil(history.undoableFix(now: now.addingTimeInterval(30.1)))
    }

    /// Expiry hides the fix; it does not erase the record, so a clock that
    /// jumps backwards cannot be told apart from one that never moved.
    func testExpiryIsAViewNotAMutation() {
        let history = historyWithAFix()
        XCTAssertNil(history.undoableFix(now: now.addingTimeInterval(100)))
        XCTAssertNotNil(history.undoableFix(now: now), "still recorded")
    }

    // MARK: - Invalidation

    func testEveryInvalidationClearsTheSlot() {
        for reason in FixHistory.Invalidation.allCases {
            var history = historyWithAFix()
            XCTAssertTrue(history.invalidate(reason), "\(reason) had something to clear")
            XCTAssertNil(history.undoableFix(now: now), "\(reason)")
            XCTAssertFalse(history.invalidate(reason), "\(reason) is idempotent")
        }
    }

    func testSwitchingApplicationsInvalidates() {
        var history = historyWithAFix()
        XCTAssertFalse(
            history.noteFrontmost(bundleID: "com.apple.TextEdit"), "same app, nothing happens")
        XCTAssertNotNil(history.undoableFix(now: now))

        XCTAssertTrue(history.noteFrontmost(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertNil(history.undoableFix(now: now))
    }

    /// ⌘-Tab away to look something up and ⌘-Tab back is one of the most
    /// ordinary things a person does, and it must not cost them the undo.
    func testTheComparisonIsAgainstTheRecordedAppNotTheLastSeenOne() {
        var history = historyWithAFix()
        history.noteFrontmost(bundleID: "com.apple.TextEdit")
        history.noteFrontmost(bundleID: "com.apple.TextEdit")
        XCTAssertNotNil(history.undoableFix(now: now))
    }

    func testAFixRecordedWithNoBundleIDIsInvalidatedByAnyNamedApp() {
        var history = historyWithAFix(in: nil)
        XCTAssertFalse(history.noteFrontmost(bundleID: nil))
        XCTAssertTrue(history.noteFrontmost(bundleID: "com.apple.TextEdit"))
    }

    func testNotingTheFrontmostAppWithAnEmptySlotDoesNothing() {
        var history = FixHistory()
        XCTAssertFalse(history.noteFrontmost(bundleID: "anything"))
    }

    // MARK: - The move-on signals

    private func key(_ keycode: UInt16, _ flags: KeyFlags = [], text: String = "x") -> SessionInput {
        .key(CapturedKey(keycode: keycode, flags: flags, producedText: text))
    }

    func testAClickEndsTheWindow() {
        XCTAssertTrue(FixHistory.endsUndoWindow(.mouseDown(at: 0)))
    }

    func testReturnEndsTheWindow() {
        XCTAssertTrue(FixHistory.endsUndoWindow(key(Keycode.returnKey, text: "")))
        XCTAssertTrue(FixHistory.endsUndoWindow(key(Keycode.keypadEnter, text: "")))
    }

    /// Everything else is reflex, and reflexes must not cost the escape hatch.
    func testOrdinaryInputDoesNotEndTheWindow() {
        let harmless: [SessionInput] = [
            key(0, text: "a"),
            key(Keycode.delete, text: ""),
            key(Keycode.escape, text: ""),
            key(Keycode.tab, text: ""),
            key(Keycode.leftArrow, [.fn], text: ""),
            key(6, [.command, .option], text: ""),
            .inputSourceChanged(at: 0),
            .appActivated(bundleID: "com.apple.TextEdit", at: 0),
        ]
        for input in harmless {
            XCTAssertFalse(FixHistory.endsUndoWindow(input), "\(input)")
        }
    }

    /// An app switch is handled by comparing identifiers, not by this rule —
    /// coming back to the same app has to leave the undo standing.
    func testAppActivationIsLeftToNoteFrontmost() {
        XCTAssertFalse(
            FixHistory.endsUndoWindow(.appActivated(bundleID: "com.other.app", at: 0)))
    }

    // MARK: - Replacement and consumption

    func testASecondApplyReplacesTheFirst() {
        var history = historyWithAFix()
        let second = AppliedFix(
            fix: Fix(
                deleteCount: 3, insertText: "ودك", targetLayoutID: Canonical.arabic,
                sourceLayoutID: Canonical.english, replacedText: "l,;", capsMode: .asTyped),
            appliedAt: now.addingTimeInterval(5),
            bundleID: "com.apple.TextEdit")
        history.record(second)

        XCTAssertEqual(history.undoableFix(now: now.addingTimeInterval(5))?.fix, second.fix)
        XCTAssertEqual(
            history.undoableFix(now: now.addingTimeInterval(5))?.appliedAt, second.appliedAt,
            "and the clock restarts with it")
    }

    func testTakingTheFixConsumesIt() {
        var history = historyWithAFix()
        XCTAssertNotNil(history.takeUndoable(now: now))
        XCTAssertNil(history.takeUndoable(now: now), "an undo cannot be run twice")
        XCTAssertNil(history.undoableFix(now: now))
    }

    func testTakingAnExpiredFixTakesNothing() {
        var history = historyWithAFix()
        XCTAssertNil(history.takeUndoable(now: now.addingTimeInterval(31)))
        XCTAssertNotNil(
            history.undoableFix(now: now), "and leaves the record where it was")
    }

    /// An undo that never reached the screen leaves the fix exactly where it
    /// was, so the offer has to come back — a modifier still held from the
    /// chord itself is the common way this happens.
    func testRestorePutsAClaimedFixBack() {
        var history = historyWithAFix()
        guard let claimed = history.takeUndoable(now: now) else { return XCTFail("nothing taken") }
        history.restore(claimed)
        XCTAssertEqual(history.undoableFix(now: now)?.appliedAt, claimed.appliedAt)
    }

    /// The clock is not restarted by a restore: the window is about how long
    /// ago the *fix* happened, and a failing undo must not extend it forever.
    func testRestoreDoesNotRestartTheClock() {
        var history = historyWithAFix()
        guard let claimed = history.takeUndoable(now: now) else { return XCTFail("nothing taken") }
        history.restore(claimed)
        XCTAssertNil(history.undoableFix(now: now.addingTimeInterval(31)))
    }

    /// A newer fix arriving while an undo was in flight wins: it is the one in
    /// front of the caret now.
    func testRestoreDoesNotOverwriteANewerFix() {
        var history = historyWithAFix()
        guard let claimed = history.takeUndoable(now: now) else { return XCTFail("nothing taken") }
        let newer = Canonical.applied(at: now.addingTimeInterval(1))
        history.record(newer)
        history.restore(claimed)
        XCTAssertEqual(history.undoableFix(now: now.addingTimeInterval(1))?.appliedAt, newer.appliedAt)
    }
}
