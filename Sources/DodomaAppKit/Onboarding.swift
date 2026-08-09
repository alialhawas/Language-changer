import Foundation

/// When the first-run window appears, as a rule rather than as a branch buried
/// in `applicationDidFinishLaunching`.
enum Onboarding {
    /// Shown on launch only when there is something to onboard *and* the user
    /// has never finished the walkthrough.
    ///
    /// Both halves matter. Without the permission test, a fully granted install
    /// would open a window on every launch until someone pressed Done — an
    /// accessory app stealing focus at login is the worst thing this app could
    /// do. Without the flag, revoking a grant later would reopen the window
    /// unbidden; the menu's status line says the same thing without taking the
    /// screen, and "Onboarding…" in the menu is there for the deliberate case.
    static func isNeeded(permissions: PermissionState, hasCompleted: Bool) -> Bool {
        guard !hasCompleted else { return false }
        return !permissions.accessibility || !permissions.inputMonitoring
    }
}
