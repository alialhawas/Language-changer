import AppKit
import Carbon.HIToolbox
import DodomaCore
import Foundation

/// Thin app-side shell around `TypingSession`.
///
/// Responsibilities kept here (and only here): the serial queue, the AppKit
/// notification subscriptions, the clock, the idle trigger, logging, and
/// publishing snapshots. All state-machine and detection behaviour lives in
/// `DodomaCore`, which is unit tested directly.
final class TypingPipeline {
    /// How long our own injected keystrokes are ignored after a fix completes.
    /// The tap already filters them by marker; this is the belt-and-braces
    /// second line, and it also swallows the input-source notification the
    /// switch itself provokes.
    private static let applyTailWindow: TimeInterval = 0.3

    let queue = DispatchQueue(label: "com.ali.dodoma.pipeline", qos: .userInitiated)

    /// Called on `queue` after every processed event.
    var onChange: ((BufferSnapshot) -> Void)?
    /// Called on `queue` after every evaluation, and again when an apply ends.
    var onDecision: ((DecisionSnapshot) -> Void)?
    /// Called on `queue` after a fix has been written to the screen.
    var onAutoApply: ((AppliedFix) -> Void)?
    /// Called on `queue` when a fix was good enough to offer but not to apply.
    /// M6 turns this into the suggestion panel.
    var onSuggest: ((Fix) -> Void)?

    /// Shared, cached view of the enabled keyboard layouts. Owned here because
    /// this is where the invalidation notification is observed.
    let layoutEngine = LayoutEngine()

    private let session: TypingSession
    private let fixEngine = FixEngine()
    private let settings: SettingsStore

    /// Queue-confined state.
    private var pendingEvaluation: DispatchWorkItem?
    private var isApplying = false
    private var captureActive = false
    private var lastDecision: DecisionSnapshot?
    /// The single history slot M7 grows into `FixHistory`. Queue-confined.
    private(set) var lastAppliedFix: AppliedFix?

    private var workspaceObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var enabledSourcesObserver: NSObjectProtocol?

    init(settings: SettingsStore = .shared) {
        self.settings = settings
        session = TypingSession(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    func start() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            self?.submit(.appActivated(bundleID: bundleID, at: Self.now()))
        }

        let inputSourceName = Notification.Name(
            kTISNotifySelectedKeyboardInputSourceChanged as String)
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: inputSourceName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.submit(.inputSourceChanged(at: Self.now()))
        }

        let enabledSourcesName = Notification.Name(
            kTISNotifyEnabledKeyboardInputSourcesChanged as String)
        enabledSourcesObserver = DistributedNotificationCenter.default().addObserver(
            forName: enabledSourcesName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.layoutEngine.invalidate()
            self?.warmLayoutCache()
        }

        warmLayoutCache()
    }

    /// Enumerating input sources is a Text Input Sources call, which prefers
    /// the main thread. Warming the cache here and after every invalidation —
    /// both of which happen on the main thread — keeps the pipeline queue from
    /// having to enumerate in the middle of an evaluation.
    private func warmLayoutCache() {
        _ = layoutEngine.layouts()
    }

    func stop() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
            self.inputSourceObserver = nil
        }
        if let enabledSourcesObserver {
            DistributedNotificationCenter.default().removeObserver(enabledSourcesObserver)
            self.enabledSourcesObserver = nil
        }
        queue.async { [weak self] in
            self?.cancelTrigger()
        }
    }

    /// Nothing is evaluated — and so nothing is ever injected — unless the tap
    /// is actually running, which is the app's proxy for "permissions granted".
    func setCaptureActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self, self.captureActive != active else { return }
            self.captureActive = active
            if !active { self.cancelTrigger() }
        }
    }

    /// Must be called on `queue`. Called by the event tap.
    func handle(_ event: TapEvent) {
        switch event {
        case .key(let key):
            process(.key(key))
        case .mouseDown:
            process(.mouseDown(at: Self.now()))
        }
    }

    /// Hops onto `queue` from wherever the caller is.
    private func submit(_ input: SessionInput) {
        queue.async { [weak self] in
            self?.process(input)
        }
    }

    /// Queue-confined.
    private func process(_ input: SessionInput) {
        dispatchPrecondition(condition: .onQueue(queue))

        if isApplying, Self.isTypingSignal(input) {
            // Either our own injection came back despite the marker filter, or
            // the user typed into the middle of a rewrite. Both would corrupt
            // the buffer relative to what is on screen.
            Log.fix.debug("input dropped while a fix was being applied")
            return
        }

        let outcome = session.handle(input)

        if let reason = outcome.performedReset {
            Log.pipeline.debug("buffer reset reason=\(reason.rawValue, privacy: .public)")
        }
        updateTrigger(after: outcome)
        onChange?(outcome.snapshot)
    }

    private static func isTypingSignal(_ input: SessionInput) -> Bool {
        switch input {
        case .key, .mouseDown: return true
        case .appActivated, .inputSourceChanged: return false
        }
    }

    // MARK: - Idle trigger

    private func updateTrigger(after outcome: SessionOutcome) {
        switch outcome.action {
        case .append, .backspace:
            if outcome.snapshot.keyCount > 0 {
                armTrigger()
            } else {
                cancelTrigger()
            }
        case .reset:
            cancelTrigger()
        case .ignore:
            // The buffer did not move, so neither should the timer.
            break
        case nil:
            if outcome.performedReset != nil { cancelTrigger() }
        }
    }

    private func armTrigger() {
        cancelTrigger()
        guard captureActive, !isApplying else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.triggerFired()
        }
        pendingEvaluation = work
        queue.asyncAfter(deadline: .now() + TypingSession.triggerDelay, execute: work)
    }

    private func cancelTrigger() {
        pendingEvaluation?.cancel()
        pendingEvaluation = nil
    }

    private func triggerFired() {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingEvaluation = nil
        guard captureActive, !isApplying else { return }
        // A key may have landed between the last arming and this block being
        // dequeued; the timestamp is the authority, not the timer.
        guard let last = session.lastKeyTime,
              TypingSession.isEvaluationDue(lastKeyTimestamp: last, now: Self.now())
        else { return }
        evaluate()
    }

    // MARK: - Evaluation

    private func evaluate() {
        let bundleID = session.currentFrontmostBundleID
        let policy = AppPolicyTable.policy(forBundleID: bundleID)
        let now = Self.now()

        guard policy != .off else {
            publish(
                .skipped(
                    reason: "app not allowlisted", policy: policy, bundleID: bundleID,
                    evaluatedAt: now))
            return
        }
        guard let pair = layoutEngine.currentPair() else {
            publish(
                .skipped(
                    reason: "no English/Arabic layout pair enabled", policy: policy,
                    bundleID: bundleID, evaluatedAt: now))
            return
        }

        let detector = Detector(englishLayout: pair.english, arabicLayout: pair.arabic)
        let started = Self.now()
        guard
            let detection = session.evaluate(
                detector: detector, policy: policy, aggressiveness: settings.aggressiveness)
        else { return }
        let duration = Self.now() - started

        let snapshot = DecisionSnapshot(
            detection: detection, policy: policy, bundleID: bundleID, duration: duration,
            evaluatedAt: now)
        publish(snapshot)
        logDecision(snapshot)

        switch detection.decision {
        case .ignore:
            break
        case .suggest(let fix):
            // M6 shows a panel here; for now the status item just blinks.
            Log.pipeline.info(
                "suggestion available: delete \(fix.deleteCount, privacy: .public) clusters (no panel until M6)"
            )
            onSuggest?(fix)
        case .autoApply(let fix):
            beginApply(fix, bundleID: bundleID)
        }
    }

    /// Region text is typed text. It only ever reaches os_log through this
    /// category, and only when the user opted in.
    private func logDecision(_ snapshot: DecisionSnapshot) {
        guard settings.debugLogging else {
            Log.decision.debug(
                "\(snapshot.verdict, privacy: .public) in \(snapshot.durationMillis, format: .fixed(precision: 1), privacy: .public) ms"
            )
            return
        }
        Log.decision.debug(
            "\(snapshot.verdict, privacy: .public) region=\(snapshot.regionText) cur=\(snapshot.currentScore, format: .fixed(precision: 2), privacy: .public) alt=\(snapshot.alternateScore, format: .fixed(precision: 2), privacy: .public) guards=\(snapshot.guards, privacy: .public) reason=\(snapshot.reason, privacy: .public) in \(snapshot.durationMillis, format: .fixed(precision: 1), privacy: .public) ms"
        )
    }

    private func publish(_ snapshot: DecisionSnapshot) {
        lastDecision = snapshot
        onDecision?(snapshot)
    }

    // MARK: - Applying

    private func beginApply(_ fix: Fix, bundleID: String?) {
        isApplying = true
        cancelTrigger()
        Log.fix.info(
            "auto-applying: delete \(fix.deleteCount, privacy: .public) clusters, insert \(fix.insertText.count, privacy: .public), switch to \(fix.targetLayoutID, privacy: .public)"
        )

        fixEngine.apply(fix) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.finishApply(fix, bundleID: bundleID, result: result)
            }
        }
    }

    private func finishApply(
        _ fix: Fix, bundleID: String?, result: Result<Void, FixError>
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        // What is on screen is no longer what the user typed, whether the
        // sequence finished or died halfway. Either way the key history is
        // worthless and must never be evaluated again.
        let snapshot = session.reset(reason: .manual, at: Self.now())
        onChange?(snapshot)

        switch result {
        case .success:
            let applied = AppliedFix(fix: fix, appliedAt: Date(), bundleID: bundleID)
            lastAppliedFix = applied
            lastDecision?.result = "applied"
            onAutoApply?(applied)
        case .failure(let error):
            lastDecision?.result = "failed: \(error.description)"
        }
        if let lastDecision { onDecision?(lastDecision) }

        queue.asyncAfter(deadline: .now() + Self.applyTailWindow) { [weak self] in
            self?.isApplying = false
        }
    }

    private static func now() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }
}
