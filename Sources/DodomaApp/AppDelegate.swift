import AppKit
import DodomaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var pollTimer: Timer?
    private var lastState: PermissionState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Dodoma \(Dodoma.version, privacy: .public) starting")

        let controller = MenuBarController()
        menuBarController = controller

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
    }

    private func refreshPermissions() {
        let state = Permissions.current()
        menuBarController?.update(with: state)

        guard state != lastState else { return }
        lastState = state
        Log.app.info(
            "permissions accessibility=\(state.accessibility, privacy: .public) inputMonitoring=\(state.inputMonitoring, privacy: .public)")
    }
}
