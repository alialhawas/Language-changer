import DodomaCore
import XCTest

@testable import DodomaAppKit

/// Undo, from the shortcut to the screen.
///
/// The rule about *whether* there is anything to undo is pure and covered in
/// `FixHistoryTests`. What is covered here is the part that only exists once
/// the pipeline is wired up: that the inverse goes through the same gate and
/// the same injector as everything else that deletes, that the slot is claimed
/// exactly once, and that the text it puts back is not immediately re-fixed.
final class UndoFlowTests: XCTestCase {
    private var harness: PipelineHarness!

    override func setUp() {
        super.setUp()
        harness = PipelineHarness()
        harness.oracle.answer(caret: Fixtures.caretBeforeFix)
    }

    override func tearDown() {
        harness = nil
        super.tearDown()
    }

    /// Gets a fix onto the screen the way the user would: an offer, accepted.
    private func applyAFix() {
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)
        XCTAssertEqual(harness.engine.applied.count, 1, "precondition: a fix was applied")
        harness.waitForApplyTail(self)
        // From here on the corrected text is what is in front of the caret.
        harness.oracle.answer(caret: Fixtures.caretAfterFix)
    }

    // MARK: - The happy path

    func testAnAppliedFixBecomesUndoable() {
        applyAFix()
        XCTAssertEqual(harness.pipeline.undoableFix()?.fix, Fixtures.fix)
        XCTAssertEqual(harness.pipeline.undoableFix()?.bundleID, Fixtures.app)
    }

    func testUndoAppliesTheInverseThroughTheSameInjector() {
        applyAFix()
        harness.undo()

        XCTAssertEqual(harness.engine.applied.count, 2)
        let inverse = harness.engine.lastFix
        XCTAssertEqual(inverse?.deleteCount, Fixtures.fix.insertText.count)
        XCTAssertEqual(inverse?.insertText, Fixtures.fix.replacedText)
        XCTAssertEqual(inverse?.targetLayoutID, Fixtures.english, "and the layout goes back")
        XCTAssertEqual(inverse?.replacedText, Fixtures.fix.insertText)
        XCTAssertEqual(harness.undoAppliedCount, 1)
    }

    /// The undo is not a new fix: it must not be recorded as one, or ⌘⌥Z twice
    /// would put the correction back.
    func testAnUndoIsNotItselfRecorded() {
        applyAFix()
        harness.undo()

        XCTAssertNil(harness.pipeline.undoableFix())
        XCTAssertEqual(harness.applied.count, 1, "the undo is not a `Last fix` line")

        harness.waitForApplyTail(self)
        harness.undo()
        XCTAssertEqual(harness.engine.applied.count, 2, "nothing more happened")
    }

    /// The caret check on the way back is against the *corrected* text, which
    /// is what is on screen now.
    func testTheCaretIsVerifiedAgainstTheCorrectedText() {
        applyAFix()
        harness.undo()
        XCTAssertEqual(
            harness.oracle.requestedLengths.last, Fixtures.fix.insertText.utf16.count)
    }

    // MARK: - Re-fixing

    /// The one outcome that would make undo worse than useless: the quiet
    /// period a second later looks at the restored gibberish and fixes it
    /// again.
    func testTheRestoredTextIsNotOfferedAgain() {
        applyAFix()
        harness.undo()
        harness.waitForApplyTail(self)

        harness.offer(Fixtures.fix)
        XCTAssertEqual(harness.offers.count, 1, "still just the original offer")

        harness.offer(Fixtures.otherFix)
        XCTAssertEqual(harness.offers.count, 2, "and only that text is held back")
    }

    // MARK: - Nothing to undo

    func testUndoWithNothingToUndoIsSilent() {
        harness.undo()
        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertEqual(
            harness.rejectionCount, 0,
            "⌘⌥Z is a global chord; most presses of it are meant for the app underneath")
    }

    func testSwitchingApplicationsWithdrawsTheUndo() {
        applyAFix()
        harness.activate(Fixtures.otherApp)
        XCTAssertNil(harness.pipeline.undoableFix())

        harness.undo()
        XCTAssertEqual(harness.engine.applied.count, 1)
    }

    func testComingBackToTheSameApplicationKeepsTheUndo() {
        applyAFix()
        harness.activate(Fixtures.app)
        XCTAssertNotNil(harness.pipeline.undoableFix())
    }

    func testAClickWithdrawsTheUndo() {
        applyAFix()
        harness.click()
        XCTAssertNil(harness.pipeline.undoableFix())
    }

    func testReturnWithdrawsTheUndo() {
        applyAFix()
        harness.type("", keycode: Keycode.returnKey)
        XCTAssertNil(harness.pipeline.undoableFix())
    }

    /// Carrying on typing is not moving on. The undo is for the fix that just
    /// happened, and the user noticing it a word later is the normal case.
    func testOrdinaryTypingKeepsTheUndo() {
        applyAFix()
        harness.type("a")
        harness.type("b")
        XCTAssertNotNil(harness.pipeline.undoableFix())
    }

    /// The undo slot holds the user's own text, both halves of it. Whatever
    /// makes the buffer unkeepable makes that unkeepable too.
    func testASecureFieldPurgesTheUndo() {
        applyAFix()
        harness.oracle.answer(caret: Fixtures.caretAfterFix, security: .secure)
        harness.offer(Fixtures.otherFix)
        harness.send(.suggestionAccept)

        XCTAssertNil(harness.pipeline.undoableFix())
    }

    // MARK: - Refusals

    func testAMismatchedCaretRefusesAndKeepsTheSlotClaimed() {
        applyAFix()
        harness.oracle.answer(caret: .value("the user has moved the caret"))
        harness.undo()

        XCTAssertEqual(harness.engine.applied.count, 1, "nothing was deleted")
        XCTAssertEqual(harness.rejectionCount, 1)
        XCTAssertNil(
            harness.pipeline.undoableFix(),
            "what is on screen is no longer the fix this undo was about")
    }

    func testALiveSelectionRefuses() {
        applyAFix()
        harness.oracle.answer(caret: .selectionPresent)
        harness.undo()

        XCTAssertEqual(harness.engine.applied.count, 1)
        XCTAssertEqual(harness.rejectionCount, 1)
    }

    /// The same best-effort exception the accepted-suggestion path gets, and
    /// for the same reason: the user asked by name.
    func testAnElementWithNoTextStillUndoes() {
        applyAFix()
        harness.oracle.answer(caret: .unreadable)
        harness.undo()

        XCTAssertEqual(harness.engine.applied.count, 2)
        XCTAssertEqual(harness.undoAppliedCount, 1)
    }

    /// The commonest failure of all: ⌘⌥ is still held down from the chord that
    /// asked for the undo, so the injector's pre-flight gives up. Nothing was
    /// posted, the fix is still on screen, and pressing again has to work.
    func testAnUndoThatNeverReachedTheScreenCanBeRetried() {
        applyAFix()
        harness.engine.result = .failure(
            FixFailure(error: .modifierHeld, progress: FixProgress()))
        harness.undo()

        XCTAssertEqual(harness.engine.applied.count, 2, "it was attempted")
        XCTAssertEqual(harness.undoAppliedCount, 0, "and it did not happen")
        XCTAssertNotNil(harness.pipeline.undoableFix(), "so it is still on offer")

        harness.waitForApplyTail(self)
        harness.engine.result = .success(FixProgress(deletedClusters: 7, insertedUTF16Units: 7))
        harness.undo()
        XCTAssertEqual(harness.engine.applied.count, 3)
        XCTAssertEqual(harness.undoAppliedCount, 1)
    }

    /// A half-restored line is not something to offer a second destructive pass
    /// over.
    func testAnUndoThatFailedHalfwayIsNotRetried() {
        applyAFix()
        harness.engine.result = .failure(
            FixFailure(
                error: .frontmostChanged,
                progress: FixProgress(deletedClusters: 3, insertedUTF16Units: 0)))
        harness.undo()

        XCTAssertNil(harness.pipeline.undoableFix())
    }

    func testInputDuringTheUndoCaretCheckAbandonsItAndKeepsTheOffer() {
        applyAFix()
        harness.oracle.beforeAnswering = { [weak harness] in
            harness?.pipeline.handle(
                .key(CapturedKey(
                    keycode: 0, producedText: "z",
                    timestamp: Date().timeIntervalSinceReferenceDate)))
        }
        harness.undo()

        XCTAssertEqual(harness.engine.applied.count, 1, "nothing was posted")
        XCTAssertNotNil(harness.pipeline.undoableFix(), "so the fix is still where it was")
        XCTAssertTrue(harness.isEvaluationArmed)
    }

    // MARK: - Input between the fix and the undo

    /// The hole the serial stamp closes. `.bestEffort` proceeds on structural
    /// silence, so without it: fix, type two characters, ⌘⌥Z — and the seven
    /// backspaces eat both of those characters and five clusters of the
    /// correction, in an application where nothing can detect that they did.
    func testUndoIsRefusedAfterFurtherTypingWhenTheCaretCannotBeRead() {
        applyAFix()
        harness.type("a")
        harness.type("b")
        harness.oracle.answer(caret: .unreadable)
        harness.undo()

        XCTAssertEqual(harness.engine.applied.count, 1, "nothing was deleted")
        XCTAssertEqual(harness.rejectionCount, 1)
    }

    /// Same hole, reached the other way: an application in `axVerifySkip` is
    /// not asked about its caret at all, so the serial is the only evidence
    /// there is.
    func testUndoIsRefusedAfterFurtherTypingWhenTheAppSkipsVerification() {
        harness = PipelineHarness(axVerifySkip: [Fixtures.app])
        harness.oracle.answer(caret: Fixtures.caretBeforeFix)
        applyAFix()
        XCTAssertEqual(
            harness.oracle.requestedLengths, [nil], "precondition: the caret is never read here")

        harness.type("a")
        harness.undo()
        XCTAssertEqual(harness.engine.applied.count, 1)
        XCTAssertEqual(harness.rejectionCount, 1)
    }

    func testAnUnverifiedUndoStillWorksWhenNothingHasHappened() {
        harness = PipelineHarness(axVerifySkip: [Fixtures.app])
        harness.oracle.answer(caret: Fixtures.caretBeforeFix)
        applyAFix()
        harness.undo()

        XCTAssertEqual(harness.engine.applied.count, 2)
        XCTAssertEqual(harness.undoAppliedCount, 1)
    }

    /// A positive caret match is direct evidence about the screen and stands on
    /// its own. Typing a character and deleting it again puts the correction
    /// back where it was, and the user is entitled to their undo.
    func testAMatchingCaretStillUndoesAfterTypingAndDeletingBack() {
        applyAFix()
        harness.type("a")
        harness.type("", keycode: Keycode.delete)
        // The screen is back to what it was, and the read says so.
        harness.oracle.answer(caret: Fixtures.caretAfterFix)
        harness.undo()

        XCTAssertEqual(harness.engine.applied.count, 2)
        XCTAssertEqual(harness.undoAppliedCount, 1)
    }

    /// The invalidation signals cannot help here: a click that lands mid-burst
    /// arrives while the slot is still empty, so it invalidates nothing, and
    /// the record is written afterwards regardless. The fix is that the record
    /// is not written at all.
    func testAClickDuringTheBurstLeavesNoUndoOffered() {
        harness.engine.duringApply = { [weak harness] in
            harness?.pipeline.handle(.mouseDown(at: .zero, primaryButton: true))
        }
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)

        XCTAssertEqual(harness.engine.applied.count, 1, "the fix itself happened")
        XCTAssertEqual(harness.applied.count, 1, "and is still reported as the last fix")
        XCTAssertNil(harness.pipeline.undoableFix(), "but there is nothing safe to undo")
    }

    /// A keystroke during the burst is the same problem: it reached the screen
    /// and not the buffer, so it is sitting after the correction.
    func testAKeystrokeDuringTheBurstLeavesNoUndoOffered() {
        harness.engine.duringApply = { [weak harness] in
            harness?.pipeline.handle(
                .key(CapturedKey(
                    keycode: 0, producedText: "z",
                    timestamp: Date().timeIntervalSinceReferenceDate)))
        }
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)

        XCTAssertNil(harness.pipeline.undoableFix())
    }

    // MARK: - The fix's own layout switch

    /// The regression this exists to stop coming back. A fix ends by selecting
    /// the target layout, and the app hears that back as an input a few
    /// milliseconds later — with no user involvement at all. A rule that
    /// counted it would make ⌘⌥Z permanently ✕ in terminals, Electron apps and
    /// everything in `axVerifySkip`: precisely the population that has nothing
    /// but the serial to go on.
    func testUndoWorksOnTheUnreadablePathAfterTheFixesOwnLayoutSwitch() {
        applyAFix()
        XCTAssertEqual(
            harness.layoutSwitches, [Fixtures.arabic],
            "precondition: the apply announced its own switch")

        harness.oracle.answer(caret: .unreadable)
        harness.undo()

        XCTAssertEqual(harness.engine.applied.count, 2)
        XCTAssertEqual(harness.undoAppliedCount, 1)
        XCTAssertEqual(harness.rejectionCount, 0)
    }

    /// The same for an application that is never asked about its caret.
    func testAnUnverifiedUndoSurvivesTheFixesOwnLayoutSwitch() {
        harness = PipelineHarness(axVerifySkip: [Fixtures.app])
        harness.oracle.answer(caret: Fixtures.caretBeforeFix)
        applyAFix()
        harness.undo()

        XCTAssertEqual(harness.undoAppliedCount, 1)
    }

    /// A *second* layout change, to somewhere the fix did not put it, is the
    /// user going their own way. It still withdraws the undo.
    func testAUserLayoutSwitchAfterTheFixWithdrawsTheUndo() {
        applyAFix()
        XCTAssertNotNil(harness.pipeline.undoableFix())

        harness.switchLayout(to: Fixtures.english)
        XCTAssertNil(harness.pipeline.undoableFix())

        harness.oracle.answer(caret: .unreadable)
        harness.undo()
        XCTAssertEqual(harness.engine.applied.count, 1, "nothing was deleted")
    }

    /// Typing after the fix still counts, layout switch or no layout switch.
    func testTheLayoutSwitchDoesNotMaskRealTyping() {
        applyAFix()
        harness.type("a")
        harness.oracle.answer(caret: .unreadable)
        harness.undo()

        XCTAssertEqual(harness.engine.applied.count, 1)
        XCTAssertEqual(harness.rejectionCount, 1)
    }

    // MARK: - What the menu is told

    func testCanUndoFollowsTheSlot() {
        XCTAssertFalse(harness.pipeline.canUndo())
        applyAFix()
        XCTAssertTrue(harness.pipeline.canUndo())
        harness.click()
        XCTAssertFalse(harness.pipeline.canUndo())
    }

    /// An enabled menu item that answers with a ✕ is worse than a greyed-out
    /// one.
    func testCanUndoIsFalseWhileSuspended() {
        applyAFix()
        var paused = harness.settings.settings
        paused.paused = true
        harness.pipeline.apply(paused)
        harness.drain()

        XCTAssertNotNil(harness.pipeline.undoableFix(), "the fix is still recorded")
        XCTAssertFalse(harness.pipeline.canUndo(), "but it would not be carried out")
    }

    // MARK: - Interaction with the panel

    func testUndoTakesAVisibleSuggestionDownWithoutRememberingARefusal() {
        applyAFix()
        harness.offer(Fixtures.otherFix)
        let hidesBefore = harness.hideCount
        harness.undo()

        XCTAssertEqual(harness.hideCount, hidesBefore + 1)
        harness.waitForApplyTail(self)
        harness.offer(Fixtures.otherFix)
        XCTAssertEqual(
            harness.offers.filter { $0 == Fixtures.otherFix }.count, 2,
            "the user was not answering that card")
    }

    // MARK: - Suspension

    func testUndoWhilePausedRefusesVisibly() {
        applyAFix()
        var paused = harness.settings.settings
        paused.paused = true
        harness.pipeline.apply(paused)
        harness.drain()

        harness.undo()
        XCTAssertEqual(harness.engine.applied.count, 1)
        XCTAssertEqual(harness.rejectionCount, 1)
        XCTAssertNotNil(harness.pipeline.undoableFix(), "and the slot was not spent")
    }
}
