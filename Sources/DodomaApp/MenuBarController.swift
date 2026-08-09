import AppKit
import DodomaCore

final class MenuBarController: NSObject, NSMenuDelegate {
    /// How long the status item shows what just happened before going back to
    /// its idle icon.
    private static let flashDuration: TimeInterval = 1.5
    /// Title shown while a fix is being applied.
    private static let autoApplyFlash = "⇄ ع/E"
    /// Title shown when the user accepted a suggestion but the text in front of
    /// the caret turned out not to be what the fix was computed from. Applying
    /// it anyway would delete the wrong characters, so nothing happens and the
    /// refusal has to be visible — otherwise the accept key looks broken.
    private static let rejectedFlash = "✕"
    /// Longest each field of the "Last fix" line may be before it is
    /// middle-ellipsised.
    private static let fieldLimit = 20
    /// Longest an app name may be in the "Mode for …" title.
    private static let appNameLimit = 24

    private let settings: SettingsStore
    private let frontmost: FrontmostAppTracker

    private let statusItem: NSStatusItem
    private let statusLineItem: NSMenuItem
    private let lastFixItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let modeItem: NSMenuItem
    private var modeOptions: [AppPolicy: NSMenuItem] = [:]
    private let idleImage: NSImage?

    /// Bumped by every flash so a stale restore cannot undo a newer one.
    private var flashToken = 0

    /// Invoked when the user picks "Debug Window".
    var onShowDebugWindow: (() -> Void)?
    /// Invoked after the user toggles the pause item, with the new value.
    var onPauseChanged: ((Bool) -> Void)?

    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private static let inputMonitoringSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(settings: SettingsStore, frontmost: FrontmostAppTracker) {
        self.settings = settings
        self.frontmost = frontmost

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        lastFixItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        lastFixItem.isEnabled = false
        lastFixItem.isHidden = true
        pauseItem = NSMenuItem(title: "Pause Dodoma", action: nil, keyEquivalent: "")
        modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")

        idleImage = NSImage(
            systemSymbolName: "character.book.closed", accessibilityDescription: "Dodoma")

        super.init()

        if let button = statusItem.button {
            if let idleImage {
                button.image = idleImage
            } else {
                button.title = "⇄"
            }
        }

        statusItem.menu = makeMenu()
    }

    func update(with state: PermissionState, capturing: Bool, secureInput: Bool, degraded: Bool) {
        statusLineItem.title = Self.statusText(
            for: state, capturing: capturing, paused: settings.paused, secureInput: secureInput,
            degraded: degraded)
        pauseItem.state = settings.paused ? .on : .off
    }

    // MARK: - Fix feedback

    /// Main thread only.
    func showAutoApply(_ applied: AppliedFix) {
        flash(Self.autoApplyFlash)
        lastFixItem.title = Self.lastFixText(
            replaced: applied.fix.replacedText,
            inserted: applied.fix.insertText,
            app: applied.bundleID ?? "unknown",
            at: applied.appliedAt)
        lastFixItem.isHidden = false
    }

    /// Main thread only.
    func showSuggestionRejected() {
        flash(Self.rejectedFlash)
    }

    static func lastFixText(replaced: String, inserted: String, app: String, at date: Date)
        -> String
    {
        let field = { TextDisplay.middleTruncate($0, limit: fieldLimit) }
        return "Last fix: \(field(replaced)) → \(field(inserted)) "
            + "(\(field(app))) \(timeFormatter.string(from: date))"
    }

    private func flash(_ title: String) {
        guard let button = statusItem.button else { return }
        flashToken += 1
        let token = flashToken

        button.image = nil
        button.title = title

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashDuration) { [weak self] in
            guard let self, self.flashToken == token else { return }
            button.title = self.idleImage == nil ? "⇄" : ""
            button.image = self.idleImage
        }
    }

    private static func statusText(
        for state: PermissionState, capturing: Bool, paused: Bool, secureInput: Bool,
        degraded: Bool
    ) -> String {
        // Permissions first: without them nothing else in this line is true.
        if !state.accessibility { return "Needs Accessibility permission" }
        if !state.inputMonitoring { return "Needs Input Monitoring permission" }
        if paused { return "Paused" }
        if secureInput { return "Paused — secure input" }
        let base = capturing ? "Active (capturing)" : "Active"
        // The watchdog has switched off event consumption for the session, so
        // the accept key no longer works and the user needs to be told why
        // clicking is now the only way to take a suggestion.
        return degraded ? "\(base) — degraded, click suggestions to accept" : base
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        menu.addItem(statusLineItem)
        menu.addItem(lastFixItem)
        menu.addItem(.separator())

        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)

        modeItem.submenu = makeModeSubmenu()
        menu.addItem(modeItem)

        menu.addItem(.separator())

        let accessibilityItem = NSMenuItem(title: "Open Accessibility Settings…",
                                           action: #selector(openAccessibilitySettings),
                                           keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let inputMonitoringItem = NSMenuItem(title: "Open Input Monitoring Settings…",
                                             action: #selector(openInputMonitoringSettings),
                                             keyEquivalent: "")
        inputMonitoringItem.target = self
        menu.addItem(inputMonitoringItem)

        menu.addItem(.separator())

        let debugItem = NSMenuItem(title: "Debug Window",
                                   action: #selector(showDebugWindow),
                                   keyEquivalent: "")
        debugItem.target = self
        menu.addItem(debugItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Dodoma",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func makeModeSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (policy, title) in Self.modeTitles {
            let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = policy.rawValue
            submenu.addItem(item)
            modeOptions[policy] = item
        }
        return submenu
    }

    /// Ordered most permissive first, which is also the order they read in.
    private static let modeTitles: [(AppPolicy, String)] = [
        (.normal, "Normal"),
        (.suggestOnly, "Suggest only"),
        (.off, "Off"),
    ]

    /// The menu is rebuilt from the live frontmost app every time it opens.
    ///
    /// Opening a status-item menu does not change the frontmost application for
    /// an accessory app, so this reads the app the user was actually typing in.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let app = frontmost.lastNonSelfApp
        let policy = settings.policy(for: app.bundleID)

        modeItem.title =
            "Mode for \(TextDisplay.middleTruncate(app.displayName, limit: Self.appNameLimit))"
        modeItem.isEnabled = app.bundleID != nil
        for (option, item) in modeOptions {
            item.state = option == policy ? .on : .off
            item.isEnabled = app.bundleID != nil
        }
        pauseItem.state = settings.paused ? .on : .off
    }

    // MARK: - Actions

    @objc private func togglePause() {
        let paused = !settings.paused
        settings.setPaused(paused)
        pauseItem.state = paused ? .on : .off
        onPauseChanged?(paused)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let policy = AppPolicy(rawValue: raw),
              let bundleID = frontmost.lastNonSelfApp.bundleID
        else { return }
        settings.setPolicy(policy, for: bundleID)
        Log.app.info(
            "policy for \(bundleID, privacy: .public) set to \(policy.rawValue, privacy: .public)")
        for (option, item) in modeOptions {
            item.state = option == policy ? .on : .off
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
    }

    @objc private func openInputMonitoringSettings() {
        NSWorkspace.shared.open(Self.inputMonitoringSettingsURL)
    }

    @objc private func showDebugWindow() {
        onShowDebugWindow?()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
