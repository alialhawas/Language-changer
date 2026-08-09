import AppKit
import DodomaCore

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    private var menuBarController: MenuBarController?
    private var debugWindowController: DebugWindowController?
    private var pipeline: TypingPipeline?
    private var eventTap: EventTapController?
    private var suggestionController: SuggestionController?
    private let hotkeys = HotkeyCenter()
    private var pollTimer: Timer?
    private var lastState: PermissionState?
    private var lastCapturing = false
    /// Set once, by the tap watchdog. Only the menu line reads it; the tap and
    /// the panel take their own copy from `suggestionState`.
    private var tapDegraded = false

    /// The single frontmost-app observer, shared by the pipeline (which needs
    /// the switch as a buffer-reset event), the injector (which re-checks
    /// between keystrokes) and the menu (which labels its per-app submenu).
    private let frontmost = FrontmostAppTracker()
    private let secureInput = SecureInputMonitor()
    private let settings = SettingsStore.shared
    /// The one piece of state the event tap thread, the pipeline queue and the
    /// main thread all touch. Created here so no one of the three owns it.
    private let suggestionState = SuggestionState()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Dodoma \(DodomaCore.Dodoma.version, privacy: .public) starting")

        preloadLanguageModels()

        let controller = MenuBarController(settings: settings, frontmost: frontmost)
        menuBarController = controller

        let debugWindow = DebugWindowController()
        debugWindowController = debugWindow
        controller.onShowDebugWindow = { [weak debugWindow] in
            debugWindow?.show()
        }

        let pipeline = TypingPipeline(
            settings: settings, frontmost: frontmost, secureInput: secureInput,
            suggestionState: suggestionState)

        // The panel borrows the pipeline's accessibility oracle rather than
        // making a second one: the caret lookup and the security check have to
        // queue behind one another, and one serial queue is what guarantees it.
        let suggestions = SuggestionController(
            state: suggestionState, oracle: pipeline.focusOracle)
        suggestionController = suggestions
        suggestions.onTimeout = { [weak pipeline] in
            pipeline?.suggestionTimedOut()
        }

        pipeline.onChange = { [weak debugWindow] snapshot in
            debugWindow?.accept(snapshot)
        }
        pipeline.onDecision = { [weak debugWindow] decision in
            debugWindow?.accept(decision)
        }
        pipeline.onAutoApply = { [weak controller] applied in
            DispatchQueue.main.async { controller?.showAutoApply(applied) }
        }
        pipeline.onSuggest = { [weak suggestions] offer in
            DispatchQueue.main.async { suggestions?.show(fix: offer.fix, pid: offer.pid) }
        }
        pipeline.onHideSuggestion = { [weak suggestions] in
            DispatchQueue.main.async { suggestions?.dismiss() }
        }
        pipeline.onRequestRejected = { [weak controller] in
            DispatchQueue.main.async { controller?.showRejected() }
        }
        pipeline.onUndoApplied = { [weak controller] in
            DispatchQueue.main.async { controller?.showUndo() }
        }
        pipeline.start()
        self.pipeline = pipeline

        controller.onUndo = { [weak pipeline] in
            pipeline?.undoLastFix()
        }
        controller.isUndoAvailable = { [weak pipeline] in
            // Not just "is there one": an item that is enabled and then
            // answers with a ✕ because the app is paused is worse than a
            // greyed-out one.
            pipeline?.canUndo() ?? false
        }

        // Carbon, not the event tap: the shortcut has to work in exactly the
        // situations where the tap does not. See `HotkeyCenter`.
        hotkeys.onAction = { [weak self] action in
            switch action {
            case .undoLastFix:
                self?.pipeline?.undoLastFix()
            case .togglePause:
                // Through the menu controller so the checkmark, the settings
                // blob and the pipeline all move together.
                self?.menuBarController?.togglePause()
                self?.menuBarController?.showPauseChanged(paused: self?.settings.paused ?? false)
            }
        }
        hotkeys.register()
        if !hotkeys.registeredActions.contains(.undoLastFix) {
            controller.clearUndoShortcut()
        }

        // Both halves of the safety layer feed the pipeline the same way: a
        // flag it caches on its own queue, plus a buffer drop on the way up.
        settings.onChange = { [weak pipeline] updated in
            pipeline?.apply(updated)
        }
        controller.onPauseChanged = { [weak self] _ in
            self?.refreshPermissions()
        }
        secureInput.onChange = { [weak self] active in
            self?.pipeline?.setSecureInput(active)
            self?.refreshPermissions()
        }
        // Activating an app is the usual way secure input comes on between two
        // polls, so it is checked there as well as every second.
        frontmost.addObserver { [weak self] _ in
            self?.secureInput.refresh()
        }
        secureInput.start()
        pipeline.setSecureInput(secureInput.isEnabled)
        pipeline.apply(settings.settings)

        eventTap = EventTapController(
            queue: pipeline.queue,
            suggestion: suggestionState,
            onDegraded: { [weak self] in
                DispatchQueue.main.async {
                    self?.tapDegraded = true
                    self?.refreshPermissions()
                }
            },
            handler: { [weak pipeline] event in
                pipeline?.handle(event)
            })

        Permissions.requestAccessibility()
        Permissions.requestInputMonitoring()

        refreshPermissions()

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    public func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        hotkeys.unregister()
        suggestionController?.dismiss()
        secureInput.stop()
        eventTap?.stop()
        pipeline?.stop()
    }

    /// The tables are ~800 KB of JSON and word lists. Loading them here, off
    /// the main thread, keeps the first evaluation from stalling the typing
    /// queue a second after the user's first keystroke.
    private func preloadLanguageModels() {
        DispatchQueue.global(qos: .utility).async {
            let started = Date()
            do {
                for language in Language.allCases {
                    try LanguageModel.shared(language).preload()
                }
            } catch {
                Log.app.fault(
                    "language models failed to load: \(String(describing: error), privacy: .public); nothing will ever be detected"
                )
                return
            }
            let millis = Date().timeIntervalSince(started) * 1000
            Log.app.info(
                "language models loaded in \(millis, format: .fixed(precision: 0), privacy: .public) ms"
            )
        }
    }

    private func refreshPermissions() {
        let state = Permissions.current()

        // The tap can only be created once the grants are in place, so retry on
        // every poll until it succeeds and then leave it alone.
        if let eventTap, !eventTap.isRunning {
            eventTap.start()
        }
        let capturing = eventTap?.isRunning ?? false

        menuBarController?.update(
            with: state, capturing: capturing, secureInput: secureInput.isEnabled,
            degraded: tapDegraded)
        // Detection — and therefore injection — only runs while the tap does.
        pipeline?.setCaptureActive(capturing && state.accessibility && state.inputMonitoring)

        guard state != lastState || capturing != lastCapturing else { return }
        lastState = state
        lastCapturing = capturing
        Log.app.info(
            "permissions accessibility=\(state.accessibility, privacy: .public) inputMonitoring=\(state.inputMonitoring, privacy: .public) capturing=\(capturing, privacy: .public)")
    }
}
