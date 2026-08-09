import AppKit
import Carbon.HIToolbox
import DodomaCore
import Foundation

/// Thin app-side shell around `TypingSession`.
///
/// Responsibilities kept here (and only here): the serial queue, the AppKit
/// notification subscriptions, the clock, the idle trigger, the asynchronous
/// accessibility gate, logging, and publishing snapshots. Every decision the
/// shell makes — what the policy is, in which order the safety checks apply,
/// what to do with an unverifiable caret — is a pure function in `DodomaCore`,
/// which is unit tested directly.
final class TypingPipeline {
    /// How long typed input is ignored after a fix completes. The tap already
    /// filters our own events by marker; this is the belt-and-braces second
    /// line, covering the tail of an injection that is still draining through
    /// the event system when the engine reports back.
    private static let applyTailWindow: TimeInterval = 0.3

    let queue = DispatchQueue(label: "com.ali.dodoma.pipeline", qos: .userInitiated)

    /// Called on `queue` after every processed event.
    var onChange: ((BufferSnapshot) -> Void)?
    /// Called on `queue` after every evaluation, and again when an apply ends.
    var onDecision: ((DecisionSnapshot) -> Void)?
    /// Called on `queue` after a fix has been written to the screen.
    var onAutoApply: ((AppliedFix) -> Void)?
    /// Called on `queue` when a fix was good enough to offer but not to apply,
    /// either because the app is suggest-only, because the scores were middling
    /// or because the caret could not be verified. M6 turns this into the
    /// suggestion panel; the `Fix` is everything that panel needs.
    var onSuggest: ((Fix) -> Void)?

    /// Shared, cached view of the enabled keyboard layouts. Owned here because
    /// this is where the invalidation notification is observed.
    let layoutEngine = LayoutEngine()

    private let session: TypingSession
    private let fixEngine: FixEngine
    private let settings: SettingsStore
    private let frontmost: FrontmostAppTracker
    private let secureInput: SecureInputMonitor
    private let focusOracle = FocusOracle()

    /// Queue-confined state.
    private var pendingEvaluation: DispatchWorkItem?
    private var isApplying = false
    /// True from the moment a decision is handed to the accessibility gate
    /// until the gate resolves. Distinct from `isApplying`: nothing has been
    /// written to the screen yet, so input arriving in this window is real
    /// input and must be buffered, not dropped — it just invalidates the fix.
    private var isGating = false
    /// Bumped by every input. A fix decided at one value and resolved at
    /// another describes text that has since moved.
    private var inputSerial: UInt64 = 0
    /// Set when real input was discarded because a fix was in flight. Those
    /// keystrokes reached the screen but not the buffer, so the buffer no
    /// longer describes the text in front of the caret.
    private var droppedInputDuringApply = false
    private var captureActive = false
    private var paused: Bool
    private var secureInputActive = false
    /// The policy of the app that currently has focus, cached so that the tap
    /// callback does not take the settings lock once per keystroke. Only used
    /// to decide whether to buffer at all; the evaluation resolves the policy
    /// again, authoritatively.
    private var frontmostPolicy: AppPolicy
    private var lastDecision: DecisionSnapshot?
    /// The single history slot M7 grows into `FixHistory`. Queue-confined.
    private(set) var lastAppliedFix: AppliedFix?

    private var frontmostObserver: UUID?
    private var inputSourceObserver: NSObjectProtocol?
    private var enabledSourcesObserver: NSObjectProtocol?

    /// Must be created on the main thread.
    init(
        settings: SettingsStore = .shared,
        frontmost: FrontmostAppTracker,
        secureInput: SecureInputMonitor
    ) {
        self.settings = settings
        self.frontmost = frontmost
        self.secureInput = secureInput
        self.paused = settings.paused
        self.secureInputActive = secureInput.isEnabled
        frontmostPolicy = settings.policy(for: frontmost.bundleID)
        fixEngine = FixEngine(frontmost: frontmost)
        session = TypingSession(frontmostBundleID: frontmost.bundleID)
    }

    func start() {
        frontmostObserver = frontmost.addObserver { [weak self] app in
            guard let self else { return }
            // The cached focus verdict belongs to the app that just lost focus.
            self.focusOracle.invalidate()
            self.submit(.appActivated(bundleID: app.bundleID, at: Self.now()))
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

    /// Main thread only.
    func stop() {
        if let frontmostObserver {
            frontmost.removeObserver(frontmostObserver)
            self.frontmostObserver = nil
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
            // Clearing the flags as well as the timer: a tap event already
            // queued behind this block could otherwise arm a trigger that
            // fires a second into shutdown, and a gate still in flight could
            // arm one when it resolves.
            self?.captureActive = false
            self?.isGating = false
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

    /// Takes the user's settings, from the initial load or from a menu change.
    /// Callable from any thread.
    func apply(_ updated: AppSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            if updated.paused, !self.paused {
                self.paused = true
                self.suspend(reason: .manual, describedAs: "paused")
            } else {
                self.paused = updated.paused
            }

            let policy = updated.policy(for: self.session.currentFrontmostBundleID)
            if policy == .off, self.frontmostPolicy != .off {
                self.suspend(reason: .manual, describedAs: "this app was set to Off")
            }
            self.frontmostPolicy = policy
        }
    }

    /// The system-wide secure event input flag. Callable from the main thread.
    func setSecureInput(_ active: Bool) {
        queue.async { [weak self] in
            guard let self, self.secureInputActive != active else { return }
            self.secureInputActive = active
            if active { self.suspend(reason: .secureInput, describedAs: "secure input") }
        }
    }

    /// Stops buffering and throws away what is buffered. Queue-confined.
    private func suspend(reason: ResetReason, describedAs description: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        Log.pipeline.info("capture suspended: \(description, privacy: .public)")
        cancelTrigger()
        // A gate resolving after this must not act on a decision taken before.
        inputSerial &+= 1
        resetBuffer(reason: reason)
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

        inputSerial &+= 1

        if isSuppressed, Self.isTypingSignal(input) {
            // Not "ignored": never seen. While the pause is on, secure input is
            // enabled or the frontmost app is Off, keystrokes do not enter the
            // buffer at all — so there is nothing held in memory for a password
            // manager, and nothing to evaluate later.
            return
        }

        if isApplying, Self.isTypingSignal(input) {
            // Either our own injection came back despite the marker filter, or
            // the user typed into the middle of a rewrite. Both would corrupt
            // the buffer relative to what is on screen.
            droppedInputDuringApply = true
            Log.fix.debug("input dropped while a fix was being applied")
            return
        }

        let outcome = session.handle(input)

        if case .appActivated = input {
            frontmostPolicy = settings.policy(for: session.currentFrontmostBundleID)
        }

        if let reason = outcome.performedReset {
            Log.pipeline.debug("buffer reset reason=\(reason.rawValue, privacy: .public)")
        }
        updateTrigger(after: outcome)
        onChange?(outcome.snapshot)
    }

    /// Nothing may be buffered. Queue-confined.
    private var isSuppressed: Bool { paused || secureInputActive || frontmostPolicy == .off }

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
        guard captureActive, !isApplying, !isGating, !isSuppressed else { return }

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
        guard captureActive, !isApplying, !isGating else { return }
        guard let last = session.lastKeyTime else { return }

        // A key may have landed between the last arming and this block being
        // dequeued; the timestamp is the authority, not the timer. Re-schedule
        // for the remainder rather than dropping the evaluation, so the buffer
        // cannot end up permanently un-evaluated.
        let now = Self.now()
        guard TypingSession.isEvaluationDue(lastKeyTimestamp: last, now: now) else {
            let remaining = TypingSession.triggerDelay - (now - last)
            let work = DispatchWorkItem { [weak self] in
                self?.triggerFired()
            }
            pendingEvaluation = work
            queue.asyncAfter(deadline: .now() + max(remaining, 0.001), execute: work)
            return
        }
        evaluate()
    }

    // MARK: - Evaluation

    private func evaluate() {
        dispatchPrecondition(condition: .onQueue(queue))

        let bundleID = session.currentFrontmostBundleID
        let now = Self.now()

        // Steps (a) to (c) of the safety order. `secureInput.isEnabled` is
        // re-read here rather than trusting the cached flag: the poll is a
        // second wide and this is one function call.
        let resolved = settings.policy(for: bundleID)
        let preflight = SafetyGate.preflight(
            paused: paused,
            secureInputEnabled: secureInputActive || secureInput.isEnabled,
            policy: resolved)

        let policy: AppPolicy
        switch preflight {
        case .blocked(let reason, let resetBuffer):
            if let resetBuffer { self.resetBuffer(reason: resetBuffer) }
            publish(
                .skipped(reason: reason, policy: resolved, bundleID: bundleID, evaluatedAt: now))
            return
        case .proceed(let allowed):
            policy = allowed
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
        // Step (b), second half: `suggestOnly` is capped inside the decision
        // function, which is the one place that reads `AppPolicy`.
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

        guard detection.decision.fix != nil else { return }
        beginGate(for: detection.decision, bundleID: bundleID)
    }

    /// Region text is typed text. It only ever reaches os_log through this
    /// category, and only when the user opted in.
    private func logDecision(_ snapshot: DecisionSnapshot) {
        guard settings.debugLogging else {
            Log.decision.info(
                "\(snapshot.verdict, privacy: .public) in \(snapshot.durationMillis, format: .fixed(precision: 1), privacy: .public) ms"
            )
            return
        }
        // The one interpolation in the project that is deliberately public:
        // redacting it would make the opt-in flag pointless.
        Log.decision.info(
            "\(snapshot.verdict, privacy: .public) region=\(snapshot.regionText, privacy: .public) cur=\(snapshot.currentScore, format: .fixed(precision: 2), privacy: .public) alt=\(snapshot.alternateScore, format: .fixed(precision: 2), privacy: .public) guards=\(snapshot.guards, privacy: .public) reason=\(snapshot.reason, privacy: .public) in \(snapshot.durationMillis, format: .fixed(precision: 1), privacy: .public) ms"
        )
    }

    private func publish(_ snapshot: DecisionSnapshot) {
        lastDecision = snapshot
        onDecision?(snapshot)
    }

    // MARK: - The accessibility gate

    /// Steps (c) and (d): ask the accessibility API about the focused element,
    /// off this queue, before anything is shown or deleted.
    ///
    /// The auto path asks for the caret text in the same round trip as the
    /// secure-field check — one focused-element read serves both, and the two
    /// answers then fail in opposite directions as `SafetyGate` documents.
    private func beginGate(for decision: Decision, bundleID: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let fix = decision.fix, !isGating, !isApplying else { return }

        isGating = true
        cancelTrigger()
        let serial = inputSerial
        let verifying = decision.isAuto && !settings.skipsAXVerify(bundleID)

        focusOracle.inspect(
            pid: frontmost.current.processIdentifier,
            caretTextLength: verifying ? fix.replacedText.utf16.count : nil
        ) { [weak self] inspection in
            guard let self else { return }
            self.queue.async {
                self.resolveGate(
                    inspection, decision: decision, fix: fix, bundleID: bundleID,
                    verified: verifying, serial: serial)
            }
        }
    }

    private func resolveGate(
        _ inspection: FocusInspection,
        decision: Decision,
        fix: Fix,
        bundleID: String?,
        verified: Bool,
        serial: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isGating else { return }
        isGating = false

        guard serial == inputSerial else {
            // Something happened while we were asking — a keystroke, a click,
            // an app switch. The fix is measured from a caret that has moved.
            Log.pipeline.debug("fix abandoned: input arrived during the accessibility check")
            if !session.isBufferEmpty { armTrigger() }
            return
        }

        let verification =
            verified
            ? CaretVerification.verdict(axText: inspection.caretText, replacedText: fix.replacedText)
            : .proceed

        switch SafetyGate.resolve(
            decision: decision, secureField: inspection.security, verification: verification)
        {
        case .drop(let reason):
            Log.pipeline.info("buffer dropped: \(reason, privacy: .public)")
            lastDecision?.result = "dropped: \(reason)"
            if let lastDecision { onDecision?(lastDecision) }
            resetBuffer(reason: .secureInput)

        case .suggest(let downgradedFrom):
            if let downgradedFrom {
                Log.fix.info(
                    "auto-apply downgraded to a suggestion: \(downgradedFrom, privacy: .public)")
                lastDecision?.verdict = "suggest"
                lastDecision?.result = "downgraded: \(downgradedFrom)"
                if let lastDecision { onDecision?(lastDecision) }
            }
            // M6 shows a panel here; for now the status item just blinks.
            Log.pipeline.info(
                "suggestion available: delete \(fix.deleteCount, privacy: .public) clusters (no panel until M6)"
            )
            onSuggest?(fix)

        case .autoApply:
            beginApply(fix, bundleID: bundleID)

        case .nothing:
            break
        }
    }

    // MARK: - Applying

    private func beginApply(_ fix: Fix, bundleID: String?) {
        isApplying = true
        droppedInputDuringApply = false
        cancelTrigger()
        Log.fix.info(
            "auto-applying: delete \(fix.deleteCount, privacy: .public) clusters, insert \(fix.insertText.count, privacy: .public), switch to \(fix.targetLayoutID, privacy: .public)"
        )

        fixEngine.apply(fix, in: bundleID) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.finishApply(fix, bundleID: bundleID, result: result)
            }
        }
    }

    private func finishApply(
        _ fix: Fix, bundleID: String?, result: Result<FixProgress, FixFailure>
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        let progress: FixProgress
        var transientFailure = false
        switch result {
        case .success(let succeeded):
            progress = succeeded
            let applied = AppliedFix(fix: fix, appliedAt: Date(), bundleID: bundleID)
            lastAppliedFix = applied
            lastDecision?.result = "applied"
            onAutoApply?(applied)
        case .failure(let failure):
            progress = failure.progress
            transientFailure = failure.error.isTransient
            lastDecision?.result = "failed: \(failure.error.description)"
        }
        if let lastDecision { onDecision?(lastDecision) }

        let aftermath = ApplyAftermath.decide(
            touchedNothing: progress.touchedNothing,
            droppedInput: droppedInputDuringApply,
            transientFailure: transientFailure,
            bufferEmpty: session.isBufferEmpty)

        if aftermath.resetBuffer {
            resetBuffer(reason: .manual)
        } else {
            // Nothing was posted and nothing was swallowed, so the buffer still
            // describes the screen exactly. Throwing it away here would cost
            // the user a valid fix for no reason.
            Log.fix.debug("nothing was typed, so the buffer is kept as it is")
        }

        queue.asyncAfter(deadline: .now() + Self.applyTailWindow) { [weak self] in
            guard let self else { return }
            self.isApplying = false

            if self.droppedInputDuringApply, !self.session.isBufferEmpty {
                // Input arrived during the tail window, after the decision
                // above was taken. Same reasoning, one beat later.
                self.resetBuffer(reason: .manual)
            } else if aftermath.rearmTrigger, !self.session.isBufferEmpty {
                // The obstacle was a passing one, so let the next quiet period
                // try again. Each round costs a full trigger delay plus the
                // modifier pre-flight, so a modifier held down indefinitely
                // retries about every two seconds rather than spinning.
                self.armTrigger()
            }
            self.droppedInputDuringApply = false
        }
    }

    /// The buffer no longer describes what is in front of the caret.
    private func resetBuffer(reason: ResetReason) {
        dispatchPrecondition(condition: .onQueue(queue))
        let snapshot = session.reset(reason: reason, at: Self.now())
        onChange?(snapshot)
    }

    private static func now() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }
}
