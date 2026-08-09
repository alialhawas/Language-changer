import AppKit
import DodomaCore

final class MenuBarController {
    /// How long the status item shows what just happened before going back to
    /// its idle icon.
    private static let flashDuration: TimeInterval = 1.5
    /// Title shown while a fix is being applied.
    private static let autoApplyFlash = "⇄ ع/E"
    /// Title shown when a fix was offered rather than applied (M6 replaces
    /// this with the suggestion panel).
    private static let suggestFlash = "?"
    /// Longest each field of the "Last fix" line may be before it is
    /// middle-ellipsised.
    private static let fieldLimit = 20

    private let statusItem: NSStatusItem
    private let statusLineItem: NSMenuItem
    private let lastFixItem: NSMenuItem
    private let idleImage: NSImage?

    /// Bumped by every flash so a stale restore cannot undo a newer one.
    private var flashToken = 0

    /// Invoked when the user picks "Debug Window".
    var onShowDebugWindow: (() -> Void)?

    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private static let inputMonitoringSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        lastFixItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        lastFixItem.isEnabled = false
        lastFixItem.isHidden = true

        idleImage = NSImage(
            systemSymbolName: "character.book.closed", accessibilityDescription: "Dodoma")

        if let button = statusItem.button {
            if let idleImage {
                button.image = idleImage
            } else {
                button.title = "⇄"
            }
        }

        statusItem.menu = makeMenu()
    }

    func update(with state: PermissionState, capturing: Bool) {
        statusLineItem.title = Self.statusText(for: state, capturing: capturing)
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

    /// Main thread only. M6 replaces this with the suggestion panel.
    func showSuggestion() {
        flash(Self.suggestFlash)
    }

    static func lastFixText(replaced: String, inserted: String, app: String, at date: Date)
        -> String
    {
        let field = { middleTruncate($0, limit: fieldLimit) }
        return "Last fix: \(field(replaced)) → \(field(inserted)) "
            + "(\(field(app))) \(timeFormatter.string(from: date))"
    }

    /// Keeps both ends of the text, which is what makes two similar fixes
    /// distinguishable in the menu.
    static func middleTruncate(_ text: String, limit: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit, limit > 1 else { return flattened }
        let kept = limit - 1
        let tail = kept / 2
        let head = kept - tail
        return "\(flattened.prefix(head))…\(flattened.suffix(tail))"
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

    private static func statusText(for state: PermissionState, capturing: Bool) -> String {
        if !state.accessibility { return "Needs Accessibility permission" }
        if !state.inputMonitoring { return "Needs Input Monitoring permission" }
        return capturing ? "Active (capturing)" : "Active"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(statusLineItem)
        menu.addItem(lastFixItem)
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
