import DodomaCore
import Foundation

/// User preferences, backed by `UserDefaults`.
///
/// One JSON blob under the `settings` key, not a key per preference: the
/// per-app policy map has no fixed key set, and a single blob cannot be caught
/// half-upgraded. `AppSettings` owns the shape, the seeding and the migration;
/// this type owns the storage, the lock and the change notification.
///
/// Read from the pipeline queue on every evaluation and written from the main
/// thread by the menu, so the cached value is behind a lock rather than being
/// re-decoded per read.
final class SettingsStore {
    enum Key {
        static let settings = "settings"
        /// Where an unreadable `settings` blob is kept, so that restoring the
        /// defaults over it is recoverable by hand.
        static let corruptSettings = "settings.corrupt"
        /// Written by builds before the blob existed; read once, at migration.
        static let legacyAggressiveness = "aggressiveness"
        /// Still honoured as a live override so that the documented
        /// `defaults write com.ali.dodoma debugLogging -bool YES` keeps working
        /// without a settings-window round trip.
        static let debugLogging = "debugLogging"
    }

    static let shared = SettingsStore()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: AppSettings

    /// Called on the thread that made the change, after it has been persisted.
    var onChange: ((AppSettings) -> Void)?

    /// - Parameter defaults: `UserDefaults(suiteName:)` returns nil when the
    ///   suite is the running app's own bundle identifier, which is exactly the
    ///   case inside the shipped bundle — and there `.standard` already *is*
    ///   the `com.ali.dodoma` domain. Running from `swift run`, where the
    ///   process has no bundle identifier, the suite resolves and writes to the
    ///   same plist. Either way the settings land in one place.
    init(defaults: UserDefaults = UserDefaults(suiteName: "com.ali.dodoma") ?? .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Key.settings)
        let loaded = AppSettings.load(
            storedJSON: stored,
            legacyAggressiveness: defaults.string(forKey: Key.legacyAggressiveness),
            legacyDebugLogging: defaults.bool(forKey: Key.debugLogging))
        cached = loaded

        // The fallback is the *permissive* default — every app Normal, not
        // paused — so overwriting an unreadable blob with it would quietly
        // switch Dodoma back on everywhere the user had switched it off, and
        // leave nothing to restore from. Keep the bytes first.
        if let stored, AppSettings.isUnreadable(stored) {
            defaults.set(stored, forKey: Key.corruptSettings)
            Log.app.fault(
                "the settings blob could not be read; the defaults were restored and the original was kept under the \(Key.corruptSettings, privacy: .public) key"
            )
        }
        // Writing the merged result straight back is what makes the seed merge
        // durable: a policy added by this release is on disk before the user
        // touches anything, so a later release can tell "never seen" from
        // "seen and left alone".
        persist(loaded)
    }

    // MARK: - Reading

    var settings: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    var aggressiveness: Aggressiveness { settings.aggressiveness }

    var paused: Bool { settings.paused }

    /// The blob's value, or the bare key, whichever is on.
    var debugLogging: Bool { settings.debugLogging || defaults.bool(forKey: Key.debugLogging) }

    func policy(for bundleID: String?) -> AppPolicy { settings.policy(for: bundleID) }

    func skipsAXVerify(_ bundleID: String?) -> Bool { settings.skipsAXVerify(bundleID) }

    // MARK: - Writing

    func setPaused(_ paused: Bool) {
        mutate { $0.paused = paused }
    }

    func setPolicy(_ policy: AppPolicy, for bundleID: String) {
        mutate { $0.appPolicies[bundleID] = policy }
    }

    func setAggressiveness(_ aggressiveness: Aggressiveness) {
        mutate { $0.aggressiveness = aggressiveness }
    }

    private func mutate(_ body: (inout AppSettings) -> Void) {
        lock.lock()
        var updated = cached
        body(&updated)
        guard updated != cached else {
            lock.unlock()
            return
        }
        cached = updated
        lock.unlock()

        persist(updated)
        onChange?(updated)
    }

    private func persist(_ settings: AppSettings) {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Key.settings)
        } catch {
            // Nothing actionable: the in-memory value is still correct, the
            // change just will not survive a restart.
            Log.app.error(
                "settings could not be encoded: \(String(describing: error), privacy: .public)")
        }
    }
}
