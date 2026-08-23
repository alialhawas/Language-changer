import DodomaCore
import XCTest

@testable import DodomaAppKit

/// The suggestion state machine, end to end on the pipeline queue.
///
/// This is the surface the reviews kept finding things in, and none of it was
/// reachable from a test until `DodomaAppKit` existed: the decisions are pure
/// and covered in `DodomaCoreTests`, but the *sequencing* — which serial is
/// compared with which, what is remembered as a refusal, what happens when two
/// signals cross — lives here.
final class SuggestionFlowTests: XCTestCase {
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

    // MARK: - Showing

    func testAnOfferIsPublished() {
        harness.offer(Fixtures.fix)
        XCTAssertEqual(harness.offers, [Fixtures.fix])
    }

    /// Every kind of input takes the card away, because every kind of input
    /// means the text it is about has moved.
    func testTypingDismissesTheOffer() {
        harness.offer(Fixtures.fix)
        harness.type()
        XCTAssertEqual(harness.hideCount, 1)

        harness.send(.suggestionAccept)
        XCTAssertTrue(harness.engine.applied.isEmpty, "there is nothing left to accept")
    }

    // MARK: - Accepting

    func testAcceptingAppliesTheFix() {
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)

        XCTAssertEqual(harness.engine.lastFix, Fixtures.fix)
        XCTAssertEqual(harness.engine.applied.first?.bundleID, Fixtures.app)
        XCTAssertEqual(harness.applied.count, 1)
        XCTAssertFalse(
            harness.engine.applied[0].staleWhenAsked,
            "nothing happened between the offer and the burst")
    }

    /// The keys that operate the panel are swallowed by the tap, so they never
    /// reach the buffer and never move the serial. Anything else does.
    func testAcceptingAfterTypingIsARefusal() {
        harness.offer(Fixtures.fix)
        harness.type()
        harness.send(.suggestionAccept)

        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertEqual(harness.rejectionCount, 0, "typing is an implicit refusal, not a failure")

        // And it is remembered as one, so the next quiet period does not put
        // the same card straight back.
        harness.offer(Fixtures.fix)
        XCTAssertEqual(harness.offers.count, 1, "suppressed")
    }

    func testAcceptingTwiceAppliesOnce() {
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)
        harness.send(.suggestionAccept)
        XCTAssertEqual(harness.engine.applied.count, 1)
    }

    func testAcceptingWithNothingOnOfferDoesNothing() {
        harness.send(.suggestionAccept)
        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertEqual(harness.rejectionCount, 0)
    }

    // MARK: - Dismissing

    func testDismissingRemembersTheRefusal() {
        harness.offer(Fixtures.fix)
        harness.send(.suggestionDismiss)
        XCTAssertEqual(harness.hideCount, 1)

        harness.offer(Fixtures.fix)
        XCTAssertEqual(harness.offers.count, 1, "the same text is held back")

        harness.offer(Fixtures.otherFix)
        XCTAssertEqual(harness.offers.count, 2, "a different text is not")
    }

    func testTheTimeoutRemembersTheRefusalToo() {
        harness.offer(Fixtures.fix)
        harness.pipeline.suggestionTimedOut()
        harness.drain()

        harness.offer(Fixtures.fix)
        XCTAssertEqual(harness.offers.count, 1)
    }

    /// A suppression is per application: the same word is a mistake in a chat
    /// window and deliberate in an editor.
    func testTheRefusalIsNotRememberedForAnotherApplication() {
        harness.offer(Fixtures.fix)
        harness.send(.suggestionDismiss)
        harness.offer(Fixtures.fix, in: Fixtures.otherApp)
        XCTAssertEqual(harness.offers.count, 2)
    }

    // MARK: - Replacement

    /// A newer offer replaces an older one without recording a refusal: the
    /// user never saw the first card, so they cannot have turned it down.
    func testANewerOfferSupersedesTheOlderOne() {
        harness.offer(Fixtures.fix)
        harness.offer(Fixtures.otherFix)
        XCTAssertEqual(harness.offers, [Fixtures.fix, Fixtures.otherFix])

        harness.oracle.answer(caret: .value("please send l,;a"))
        harness.send(.suggestionAccept)
        XCTAssertEqual(harness.engine.lastFix, Fixtures.otherFix, "the newer one is what applies")
    }

    func testASupersededOfferIsNotRememberedAsARefusal() {
        harness.offer(Fixtures.fix)
        harness.offer(Fixtures.otherFix)
        harness.send(.suggestionDismiss)

        harness.offer(Fixtures.fix)
        XCTAssertEqual(harness.offers.count, 3, "only the card that was dismissed is held back")
    }

    // MARK: - The caret gate

    func testTheCaretIsCheckedAgainstWhatTheFixWouldDelete() {
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)
        XCTAssertEqual(
            harness.oracle.requestedLengths, [Fixtures.fix.replacedText.utf16.count])
    }

    func testAMismatchedCaretRefusesVisibly() {
        harness.oracle.answer(caret: .value("something else entirely"))
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)

        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertEqual(harness.rejectionCount, 1, "silence would look like a broken accept key")
    }

    /// The M7 ruling: an explicit request proceeds where accessibility is
    /// structurally silent, and only there.
    func testAnElementWithNoTextProceedsOnTheExplicitPath() {
        harness.oracle.answer(caret: .unreadable)
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)

        XCTAssertEqual(harness.engine.lastFix, Fixtures.fix)
        XCTAssertEqual(harness.rejectionCount, 0)
    }

    func testALiveSelectionStaysFailClosed() {
        harness.oracle.answer(caret: .selectionPresent)
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)

        XCTAssertTrue(harness.engine.applied.isEmpty, "the burst would eat the selection first")
        XCTAssertEqual(harness.rejectionCount, 1)
    }

    func testAnUnavailableAccessibilityLayerStaysFailClosed() {
        harness.oracle.answer(caret: .unavailable)
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)

        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertEqual(harness.rejectionCount, 1)
    }

    func testASecureFieldDropsEverything() {
        harness.oracle.answer(caret: Fixtures.caretBeforeFix, security: .secure)
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)

        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertEqual(harness.rejectionCount, 1)
    }

    /// A keystroke that lands while the accessibility round trip is in flight.
    /// The fix is abandoned — and the trigger has to be re-armed, because the
    /// keystroke's own attempt to arm it was swallowed by the gating guard.
    /// Without the re-arm the buffer is never looked at again until the user
    /// types more, which is the bug this pins.
    func testInputDuringTheCaretCheckAbandonsTheFixAndReArmsTheTrigger() {
        harness.oracle.beforeAnswering = { [weak harness] in
            // On the pipeline queue, mid-inspection: exactly where the race is.
            harness?.pipeline.handle(
                .key(CapturedKey(
                    keycode: 0, producedText: "z",
                    timestamp: Date().timeIntervalSinceReferenceDate)))
        }
        harness.offer(Fixtures.fix)
        harness.send(.suggestionAccept)

        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertEqual(harness.rejectionCount, 0, "the user typed; that is not a failure to show")
        XCTAssertTrue(harness.isEvaluationArmed, "the buffer must not be left unevaluated")
    }

    // MARK: - Suspension

    /// Pausing withdraws the card rather than leaving it up to be refused
    /// later: the user did not turn it down, so it is not remembered as a
    /// refusal and there is nothing left for the accept key to do.
    func testPausingWithdrawsTheOffer() {
        harness.offer(Fixtures.fix)
        var paused = harness.settings.settings
        paused.paused = true
        harness.pipeline.apply(paused)
        harness.drain()
        XCTAssertEqual(harness.hideCount, 1)

        harness.send(.suggestionAccept)
        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertEqual(harness.rejectionCount, 0, "withdrawn, not refused")
    }
}
