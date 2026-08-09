import AppKit

final class MenuBarController {
    private let statusItem: NSStatusItem
    private let statusLineItem: NSMenuItem

    /// Invoked when the user picks "Debug Window".
    var onShowDebugWindow: (() -> Void)?

    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private static let inputMonitoringSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false

        if let button = statusItem.button {
            if let symbol = NSImage(systemSymbolName: "character.book.closed",
                                    accessibilityDescription: "Dodoma") {
                button.image = symbol
            } else {
                button.title = "⇄"
            }
        }

        statusItem.menu = makeMenu()
    }

    func update(with state: PermissionState, capturing: Bool) {
        statusLineItem.title = Self.statusText(for: state, capturing: capturing)
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
