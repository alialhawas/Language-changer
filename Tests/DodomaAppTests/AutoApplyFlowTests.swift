import DodomaCore
import XCTest

@testable import DodomaAppKit

/// The automatic path, from the detector's `.autoApply` verdict to the screen.
///
/// The scoring that produces the verdict is pure and covered in the core
/// tests; what is covered here is the part that only exists once the pipeline
/// is wired up: that a `.autoApply` decision passes the accessibility gate,
/// reaches the injector through `beginApply(kind: .auto)`, is reported as an
/// applied fix rather than a suggestion, and leaves an undoable fix behind.
/// The accept and undo flows exercise the other two `ApplyKind`s; this closes
/// the seam they do not cover.
final class AutoApplyFlowTests: XCTestCase {
    private var harness: PipelineHarness!
    private let lock = NSLock()
    private var decisions: [DecisionSnapshot] = []

    override func setUp() {
        super.setUp()
        harness = PipelineHarness()
        harness.oracle.answer(caret: Fixtures.caretBeforeFix)
        harness.pipeline.onDecision = { [weak self] snapshot in
            guard let self else { return }
            self.lock.lock()
            self.decisions.append(snapshot)
            self.lock.unlock()
        }
    }

    override func tearDown() {
        harness = nil
        lock.lock()
        decisions.removeAll()
        lock.unlock()
        super.tearDown()
    }

    private var lastDecision: DecisionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return decisions.last
    }

    /// The whole happy path: the fix reaches the injector, is reported as an
    /// auto-apply and not as a suggestion, and the decision is labelled
    /// `applied`.
    func testAnAutoApplyDecisionReachesTheInjectorAndIsReportedAsApplied() {
        harness.autoApply(Fixtures.fix)

        XCTAssertEqual(harness.engine.applied.count, 1, "the injector was asked to apply it")
        XCTAssertEqual(harness.engine.lastFix, Fixtures.fix)

        XCTAssertEqual(harness.applied.count, 1, "reported through the auto-apply callback")
        XCTAssertEqual(harness.applied.first?.fix, Fixtures.fix)
        XCTAssertEqual(harness.applied.first?.bundleID, Fixtures.app)

        XCTAssertTrue(harness.offers.isEmpty, "the auto path does not raise a suggestion")
        XCTAssertEqual(harness.undoAppliedCount, 0, "and it is not an undo")

        XCTAssertEqual(lastDecision?.verdict, "autoApply")
        XCTAssertEqual(lastDecision?.result, "applied", "the `.auto` ApplyKind label")
    }

    /// A successful auto-apply is undoable, exactly like an accepted suggestion:
    /// the `.auto` and `.accepted` kinds both record the fix.
    func testASuccessfulAutoApplyRecordsAnUndoableFix() {
        harness.autoApply(Fixtures.fix)

        XCTAssertEqual(harness.pipeline.undoableFix()?.fix, Fixtures.fix)
        XCTAssertEqual(harness.pipeline.undoableFix()?.bundleID, Fixtures.app)
    }

    /// The gate the auto path shares with the explicit paths: a grant revoked
    /// inside the ~250ms accessibility round trip must not reach `beginApply`.
    func testCaptureRevokedDuringTheGateStopsTheAutoApply() {
        harness.oracle.beforeAnswering = { [weak harness] in
            harness?.pipeline.setCaptureActive(false)
        }
        harness.autoApply(Fixtures.fix)

        XCTAssertTrue(harness.engine.applied.isEmpty, "nothing was deleted")
        XCTAssertNil(harness.pipeline.undoableFix())
    }

    /// A password field turned up by the same read that fetched the caret text
    /// drops the buffer and applies nothing.
    func testASecureFieldDropsTheAutoApply() {
        harness.oracle.answer(caret: Fixtures.caretBeforeFix, security: .secure)
        harness.autoApply(Fixtures.fix)

        XCTAssertTrue(harness.engine.applied.isEmpty)
        XCTAssertNil(harness.pipeline.undoableFix())
    }

    /// A caret that does not match the buffer downgrades the automatic path to a
    /// suggestion rather than deleting on a guess.
    func testAMismatchedCaretDowngradesToASuggestion() {
        harness.oracle.answer(caret: .value("something else entirely"))
        harness.autoApply(Fixtures.fix)

        XCTAssertTrue(harness.engine.applied.isEmpty, "nothing was deleted")
        XCTAssertEqual(harness.offers.count, 1, "it was offered instead")
        XCTAssertEqual(harness.offers.first, Fixtures.fix)
    }
}
