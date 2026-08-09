import AppKit
import DodomaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var debugWindowController: DebugWindowController?
    private var pipeline: TypingPipeline?
    private var eventTap: EventTapController?
    private var pollTimer: Timer?
    private var lastState: PermissionState?
    private var lastCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Dodoma \(DodomaCore.Dodoma.version, privacy: .public) starting")

        preloadLanguageModels()

        let controller = MenuBarController()
        menuBarController = controller

        let debugWindow = DebugWindowController()
        debugWindowController = debugWindow
        controller.onShowDebugWindow = { [weak debugWindow] in
            debugWindow?.show()
        }

        let pipeline = TypingPipeline()
        pipeline.onChange = { [weak debugWindow] snapshot in
            debugWindow?.accept(snapshot)
        }
        pipeline.onDecision = { [weak debugWindow] decision in
            debugWindow?.accept(decision)
        }
        pipeline.onAutoApply = { [weak controller] applied in
            DispatchQueue.main.async { controller?.showAutoApply(applied) }
        }
        pipeline.onSuggest = { [weak controller] _ in
            DispatchQueue.main.async { controller?.showSuggestion() }
        }
        pipeline.start()
        self.pipeline = pipeline

        eventTap = EventTapController(queue: pipeline.queue) { [weak pipeline] event in
            pipeline?.handle(event)
        }

        Permissions.requestAccessibility()
        Permissions.requestInputMonitoring()

        refreshPermissions()

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
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

        menuBarController?.update(with: state, capturing: capturing)
        // Detection — and therefore injection — only runs while the tap does.
        pipeline?.setCaptureActive(capturing && state.accessibility && state.inputMonitoring)

        guard state != lastState || capturing != lastCapturing else { return }
        lastState = state
        lastCapturing = capturing
        Log.app.info(
            "permissions accessibility=\(state.accessibility, privacy: .public) inputMonitoring=\(state.inputMonitoring, privacy: .public) capturing=\(capturing, privacy: .public)")
    }
}
