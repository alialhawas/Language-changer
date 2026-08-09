import XCTest

@testable import DodomaCore

/// The evaluation order of the safety layer, which is the part most easily
/// broken by a later edit.
final class SafetyGateTests: XCTestCase {
    private func fix(_ replaced: String = "hgsghl") -> Fix {
        Fix(
            deleteCount: replaced.count,
            insertText: "السلام",
            targetLayoutID: "com.apple.keylayout.Arabic",
            sourceLayoutID: "com.apple.keylayout.ABC",
            replacedText: replaced,
            capsMode: .asTyped)
    }

    // MARK: - Preflight

    func testPausedBlocksEverythingAndKeepsTheBuffer() {
        // Nothing is buffered while the pause is on, and the buffer was already
        // dropped when it was switched on, so there is nothing left to reset.
        XCTAssertEqual(
            SafetyGate.preflight(paused: true, secureInputEnabled: false, policy: .normal),
            .blocked(reason: "paused", resetBuffer: nil))
    }

    func testPolicyOffBlocks() {
        XCTAssertEqual(
            SafetyGate.preflight(paused: false, secureInputEnabled: false, policy: .off),
            .blocked(reason: "app policy is off", resetBuffer: nil))
    }

    func testSecureInputBlocksAndDropsTheBuffer() {
        XCTAssertEqual(
            SafetyGate.preflight(paused: false, secureInputEnabled: true, policy: .normal),
            .blocked(reason: "secure input is enabled", resetBuffer: .secureInput))
    }

    func testNormalAndSuggestOnlyBothProceed() {
        XCTAssertEqual(
            SafetyGate.preflight(paused: false, secureInputEnabled: false, policy: .normal),
            .proceed(policy: .normal))
        XCTAssertEqual(
            SafetyGate.preflight(paused: false, secureInputEnabled: false, policy: .suggestOnly),
            .proceed(policy: .suggestOnly))
    }

    /// The order is pause, then policy, then secure input — asserted by making
    /// each earlier check win against every later one.
    func testTheOrderOfTheChecksIsFixed() {
        XCTAssertEqual(
            SafetyGate.preflight(paused: true, secureInputEnabled: true, policy: .off),
            .blocked(reason: "paused", resetBuffer: nil))
        XCTAssertEqual(
            SafetyGate.preflight(paused: false, secureInputEnabled: true, policy: .off),
            .blocked(reason: "app policy is off", resetBuffer: nil))
    }

    // MARK: - Resolution

    func testSecureFieldDropsWhateverTheDecisionWas() {
        for decision in [Decision.ignore(reason: "x"), .suggest(fix()), .autoApply(fix())] {
            XCTAssertEqual(
                SafetyGate.resolve(decision: decision, secureField: .secure),
                .drop(reason: "the focused field is a password field"),
                "\(decision)")
        }
    }

    func testAutoApplyProceedsOnlyWhenTheCaretVerifies() {
        XCTAssertEqual(
            SafetyGate.resolve(
                decision: .autoApply(fix()), secureField: .notSecure, verification: .proceed),
            .autoApply)
        XCTAssertEqual(
            SafetyGate.resolve(
                decision: .autoApply(fix()), secureField: .notSecure,
                verification: .downgrade(reason: "no accessibility text at the caret")),
            .suggest(downgradedFrom: "no accessibility text at the caret"))
    }

    /// The rationale that the whole design hangs on: an unanswered secure-field
    /// check carries on, an unanswered caret check does not delete.
    func testUnknownFailsOpenForSecurityAndClosedForVerification() {
        XCTAssertEqual(
            SafetyGate.resolve(
                decision: .autoApply(fix()), secureField: .unknown, verification: .proceed),
            .autoApply,
            "an app that will not answer is not thereby a password field")
        XCTAssertEqual(
            SafetyGate.resolve(
                decision: .autoApply(fix()), secureField: .unknown,
                verification: .downgrade(reason: "no accessibility text at the caret")),
            .suggest(downgradedFrom: "no accessibility text at the caret"),
            "but it does not get to have text deleted unverified")
    }

    func testSuggestionsAreNeverVerified() {
        // The caret check only guards deletion, so a suggestion passes through
        // whatever it would have said.
        XCTAssertEqual(
            SafetyGate.resolve(
                decision: .suggest(fix()), secureField: .notSecure,
                verification: .downgrade(reason: "irrelevant")),
            .suggest(downgradedFrom: nil))
    }

    func testIgnoreDoesNothing() {
        XCTAssertEqual(
            SafetyGate.resolve(decision: .ignore(reason: "no gate met"), secureField: .notSecure),
            .nothing)
    }

    // MARK: - Policy capping, end to end through the decision function

    /// A region that auto-applies under `.normal` must come out as a suggestion
    /// under `.suggestOnly` — the terminal seeds depend on it.
    func testSuggestOnlyCapsAnAutoApplyAtSuggest() {
        let typedText = "aaaaa aaaaa"
        let region = CandidateRegion(
            keys: [], typedText: typedText, letterCount: 10, completedTokenCount: 1)
        let candidate = fix(typedText)
        let strong = Score(bigram: 0.75, dictCoverage: 0.75)
        let weak = Score(bigram: 0.0, dictCoverage: 0.0)

        func resolve(_ policy: AppPolicy) -> SafetyGate.Resolution {
            let decision = FixDecision.verdict(
                region: region, current: weak, alternate: strong, fix: candidate,
                guards: GuardResult(vetoes: []), policy: policy, thresholds: .balanced)
            return SafetyGate.resolve(decision: decision, secureField: .notSecure)
        }

        XCTAssertEqual(resolve(.normal), .autoApply)
        XCTAssertEqual(resolve(.suggestOnly), .suggest(downgradedFrom: nil))
        XCTAssertEqual(resolve(.off), .nothing, "and .off never even reaches the gate")
    }
}
