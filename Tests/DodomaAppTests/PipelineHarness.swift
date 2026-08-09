import DodomaCore
import Foundation
import XCTest

@testable import DodomaAppKit

// MARK: - Stand-ins for the three things that touch the machine

/// The injector, without the injection.
///
/// The real one posts backspaces at the window server. A test that used it
/// would delete text out of whatever window the person running the tests
/// happened to have in front of them.
final class FakeFixEngine: FixApplying {
    struct Call {
        let fix: Fix
        let bundleID: String?
        /// Whether the pipeline's abort predicate said the caret verification
        /// had gone stale by the time the engine asked.
        let staleWhenAsked: Bool
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    /// What the next apply reports back. Defaults to a clean success.
    var result: Result<FixProgress, FixFailure> = .success(
        FixProgress(deletedClusters: 1, insertedUTF16Units: 1))

    /// Run on the pipeline queue while the apply is notionally in flight — i.e.
    /// with `isApplying` set. The only way to reproduce a click or a keystroke
    /// landing in the middle of a delete burst.
    var duringApply: (() -> Void)?

    var applied: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var lastFix: Fix? { applied.last?.fix }

    func apply(
        _ fix: Fix,
        in bundleID: String?,
        isStale: @escaping () -> Bool,
        completion: @escaping (Result<FixProgress, FixFailure>) -> Void
    ) {
        lock.lock()
        calls.append(Call(fix: fix, bundleID: bundleID, staleWhenAsked: isStale()))
        let result = self.result
        lock.unlock()
        duringApply?()
        completion(result)
    }
}

/// The accessibility gate's answers, dictated.
final class FakeFocusOracle: FocusInspecting {
    private let lock = NSLock()
    private var answer = FocusInspection(security: .notSecure, caretRead: .unavailable)
    private var lengths: [Int?] = []
    private var invalidations = 0

    /// Run on the pipeline queue, just before the answer is handed back. The
    /// only way to reproduce a keystroke landing *during* the round trip, which
    /// is the race the input serial exists for.
    var beforeAnswering: (() -> Void)?

    func answer(_ inspection: FocusInspection) {
        lock.lock()
        answer = inspection
        lock.unlock()
    }

    func answer(caret: CaretRead, security: SecureFieldState = .notSecure) {
        answer(FocusInspection(security: security, caretRead: caret))
    }

    /// The UTF-16 lengths the pipeline asked for, one per inspection.
    var requestedLengths: [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return lengths
    }

    var invalidateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invalidations
    }

    func inspect(
        pid: pid_t?, caretTextLength: Int?, completion: @escaping (FocusInspection) -> Void
    ) {
        lock.lock()
        lengths.append(caretTextLength)
        let answer = self.answer
        lock.unlock()
        beforeAnswering?()
        completion(answer)
    }

    func invalidate() {
        lock.lock()
        invalidations += 1
        lock.unlock()
    }
}

/// The system-wide secure input flag, without the system.
final class FakeSecureInput: SecureInputReading {
    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func readNow() -> Bool { isEnabled }

    func set(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }
}

// MARK: - The harness

/// A `TypingPipeline` with the three system edges replaced, plus everything a
/// test needs to drive it and to see what it did.
///
/// `start()` is deliberately not called: it registers the frontmost observer and
/// two distributed notification observers, and the tests supply those events
/// themselves. Nothing here touches the window server, the accessibility API or
/// the event tap.
final class PipelineHarness {
    let engine = FakeFixEngine()
    let oracle = FakeFocusOracle()
    let secureInput = FakeSecureInput()
    let suggestionState = SuggestionState()
    let frontmost = FrontmostAppTracker()
    let settings: SettingsStore
    let pipeline: TypingPipeline

    private let suiteName: String
    private let lock = NSLock()
    private var offered: [Fix] = []
    private var appliedFixes: [AppliedFix] = []
    private var rejections = 0
    private var undoCount = 0
    private var hides = 0

    /// - Parameter axVerifySkip: seeded into the settings blob before the store
    ///   reads it, because there is no setter for it — it is a hand-edited
    ///   preference by design.
    init(bundleID: String? = Fixtures.app, axVerifySkip: Set<String> = []) {
        suiteName = "com.ali.dodoma.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        if !axVerifySkip.isEmpty {
            var seeded = AppSettings.defaults
            seeded.axVerifySkip = axVerifySkip
            defaults.set(try! JSONEncoder().encode(seeded), forKey: SettingsStore.Key.settings)
        }
        settings = SettingsStore(defaults: defaults)
        pipeline = TypingPipeline(
            settings: settings,
            frontmost: frontmost,
            secureInput: secureInput,
            suggestionState: suggestionState,
            fixEngine: engine,
            focus: oracle)

        pipeline.onSuggest = { [weak self] offer in self?.append(offer: offer.fix) }
        pipeline.onAutoApply = { [weak self] applied in self?.append(applied: applied) }
        pipeline.onRequestRejected = { [weak self] in self?.bumpRejections() }
        pipeline.onUndoApplied = { [weak self] in self?.bumpUndos() }
        pipeline.onHideSuggestion = { [weak self] in self?.bumpHides() }

        pipeline.setCaptureActive(true)
        activate(bundleID)
        drain()
    }

    deinit {
        UserDefaults.standard.removeSuite(named: suiteName)
    }

    // MARK: Driving

    /// Tells the pipeline an application came to the front, the way the real
    /// frontmost observer would.
    func activate(_ bundleID: String?) {
        pipeline.frontmostChanged(
            to: FrontmostApp(bundleID: bundleID, processIdentifier: 42, localizedName: "Test"))
        drain()
    }

    func offer(_ fix: Fix, in bundleID: String? = Fixtures.app) {
        pipeline.queue.sync { pipeline.offerNow(fix, bundleID: bundleID) }
        drain()
    }

    func send(_ event: TapEvent) {
        pipeline.queue.sync { pipeline.handle(event) }
        drain()
    }

    func type(_ text: String = "x", keycode: UInt16 = 0) {
        send(.key(CapturedKey(
            keycode: keycode, producedText: text,
            timestamp: Date().timeIntervalSinceReferenceDate)))
    }

    func click() {
        send(.mouseDown(at: .zero, primaryButton: true))
    }

    func undo() {
        pipeline.undoLastFix()
        drain()
    }

    /// Lets everything already queued run, and everything those blocks queue in
    /// turn. Six rounds is comfortably more than the deepest chain — gate,
    /// resolve, apply, finish.
    func drain(_ rounds: Int = 6) {
        for _ in 0..<rounds { pipeline.queue.sync {} }
    }

    /// Waits out the window in which input is ignored after an apply. Needed
    /// only by tests that do a second thing to the pipeline afterwards.
    func waitForApplyTail(_ test: XCTestCase) {
        let done = test.expectation(description: "apply tail window")
        pipeline.queue.asyncAfter(deadline: .now() + TypingPipeline.applyTailWindow + 0.05) {
            done.fulfill()
        }
        test.wait(for: [done], timeout: 5)
        drain()
    }

    // MARK: Observing

    var offers: [Fix] {
        lock.lock()
        defer { lock.unlock() }
        return offered
    }

    var applied: [AppliedFix] {
        lock.lock()
        defer { lock.unlock() }
        return appliedFixes
    }

    var rejectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rejections
    }

    var undoAppliedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return undoCount
    }

    var hideCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return hides
    }

    var isEvaluationArmed: Bool {
        pipeline.queue.sync { pipeline.isEvaluationArmed }
    }

    private func append(offer fix: Fix) {
        lock.lock()
        offered.append(fix)
        lock.unlock()
    }

    private func append(applied: AppliedFix) {
        lock.lock()
        appliedFixes.append(applied)
        lock.unlock()
    }

    private func bumpRejections() {
        lock.lock()
        rejections += 1
        lock.unlock()
    }

    private func bumpUndos() {
        lock.lock()
        undoCount += 1
        lock.unlock()
    }

    private func bumpHides() {
        lock.lock()
        hides += 1
        lock.unlock()
    }
}

// MARK: - Fixtures

enum Fixtures {
    static let app = "com.apple.TextEdit"
    static let otherApp = "com.tinyspeck.slackmacgap"

    static let english = "com.apple.keylayout.ABC"
    static let arabic = "com.apple.keylayout.Arabic"

    /// `hgsghl ` → `السلام `, the canonical fix, trailing separator and all.
    static let fix = Fix(
        deleteCount: 7,
        insertText: "السلام ",
        targetLayoutID: arabic,
        sourceLayoutID: english,
        replacedText: "hgsghl ",
        capsMode: .asTyped)

    /// A second, different fix, for the tests about replacement.
    static let otherFix = Fix(
        deleteCount: 4,
        insertText: "ودك ",
        targetLayoutID: arabic,
        sourceLayoutID: english,
        replacedText: "l,;a",
        capsMode: .asTyped)

    /// A caret read that matches `fix`: the typed text is what is on screen.
    static let caretBeforeFix = CaretRead.value("please send hgsghl ")
    /// A caret read that matches the *inverse* of `fix`: the correction is on
    /// screen, which is what an undo verifies against.
    static let caretAfterFix = CaretRead.value("please send السلام ")
}
