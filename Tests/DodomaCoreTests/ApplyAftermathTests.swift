import XCTest

@testable import DodomaCore

/// Whether the buffer survives an apply decides what the *next* fix deletes,
/// so every combination is pinned rather than sampled.
final class ApplyAftermathTests: XCTestCase {
    private func decide(
        touchedNothing: Bool, droppedInput: Bool, transientFailure: Bool, bufferEmpty: Bool
    ) -> ApplyAftermath {
        ApplyAftermath.decide(
            touchedNothing: touchedNothing, droppedInput: droppedInput,
            transientFailure: transientFailure, bufferEmpty: bufferEmpty)
    }

    /// All sixteen inputs. `reset` and `rearm` are written out rather than
    /// derived, so a change to the rule has to be made twice on purpose.
    func testEveryCombination() {
        let cases:
            [(touchedNothing: Bool, dropped: Bool, transient: Bool, empty: Bool, reset: Bool,
              rearm: Bool)] = [
                // Nothing posted, nothing swallowed: the buffer is still true.
                (true, false, false, false, false, false),
                (true, false, false, true, false, false),
                (true, false, true, false, false, true),  // the retry case
                (true, false, true, true, false, false),  // nothing left to retry
                // Nothing posted, but input was swallowed while we were deaf.
                (true, true, false, false, true, false),
                (true, true, false, true, true, false),
                (true, true, true, false, true, false),  // dropped input outranks the retry
                (true, true, true, true, true, false),
                // We wrote to the screen: the buffer is stale either way.
                (false, false, false, false, true, false),
                (false, false, false, true, true, false),
                (false, false, true, false, true, false),
                (false, false, true, true, true, false),
                (false, true, false, false, true, false),
                (false, true, false, true, true, false),
                (false, true, true, false, true, false),
                (false, true, true, true, true, false),
            ]

        for row in cases {
            let result = decide(
                touchedNothing: row.touchedNothing, droppedInput: row.dropped,
                transientFailure: row.transient, bufferEmpty: row.empty)
            let label =
                "touchedNothing=\(row.touchedNothing) dropped=\(row.dropped) "
                + "transient=\(row.transient) empty=\(row.empty)"
            XCTAssertEqual(result.resetBuffer, row.reset, "resetBuffer, \(label)")
            XCTAssertEqual(result.rearmTrigger, row.rearm, "rearmTrigger, \(label)")
        }
        XCTAssertEqual(cases.count, 16)
    }

    // MARK: - The cases by the name the pipeline knows them by

    func testASuccessfulApplyResetsAndDoesNotRetry() {
        let result = decide(
            touchedNothing: false, droppedInput: false, transientFailure: false, bufferEmpty: false)
        XCTAssertTrue(result.resetBuffer)
        XCTAssertFalse(result.rearmTrigger)
    }

    func testAHeldModifierKeepsTheBufferAndRetries() {
        let result = decide(
            touchedNothing: true, droppedInput: false, transientFailure: true, bufferEmpty: false)
        XCTAssertFalse(result.resetBuffer)
        XCTAssertTrue(result.rearmTrigger)
    }

    /// The regression this function exists for: keys typed while the pipeline
    /// was deaf reached the screen but not the buffer, so retrying would delete
    /// a span measured from the wrong place.
    func testInputDroppedDuringTheApplyForcesAResetEvenWhenNothingWasTyped() {
        let result = decide(
            touchedNothing: true, droppedInput: true, transientFailure: true, bufferEmpty: false)
        XCTAssertTrue(result.resetBuffer)
        XCTAssertFalse(result.rearmTrigger)
    }

    func testAHalfAppliedFixAlwaysResets() {
        // Aborted mid-burst: some deletes landed, so the screen has changed.
        let result = decide(
            touchedNothing: false, droppedInput: false, transientFailure: true, bufferEmpty: false)
        XCTAssertTrue(result.resetBuffer)
        XCTAssertFalse(result.rearmTrigger)
    }

    /// The injector's staleness abort. It fires before any event is posted, so
    /// `touchedNothing` is true and the failure is transient — but if what
    /// invalidated the verification was a keystroke, that keystroke reached the
    /// screen while the pipeline was deaf, so the buffer still has to go.
    func testAnAbortAfterTheCaretWentStaleResetsWhenTheStalenessWasTyping() {
        let typed = decide(
            touchedNothing: true, droppedInput: true, transientFailure: true, bufferEmpty: false)
        XCTAssertTrue(typed.resetBuffer)
        XCTAssertFalse(typed.rearmTrigger)

        // Whereas an app switch moves the serial without ever reaching the
        // buffer, so the same fix is worth another quiet period.
        let switched = decide(
            touchedNothing: true, droppedInput: false, transientFailure: true, bufferEmpty: false)
        XCTAssertFalse(switched.resetBuffer)
        XCTAssertTrue(switched.rearmTrigger)
    }

    func testAPermanentFailureKeepsTheBufferButDoesNotSpinOnIt() {
        // A dead event source: nothing was typed, but retrying would only
        // produce the same fault a second later.
        let result = decide(
            touchedNothing: true, droppedInput: false, transientFailure: false, bufferEmpty: false)
        XCTAssertFalse(result.resetBuffer)
        XCTAssertFalse(result.rearmTrigger)
    }
}
