import DodomaCore
import Foundation

/// User preferences, backed by `UserDefaults`.
///
/// Only the keys a shipped milestone actually reads live here; M8 grows this
/// into the settings window's model. `UserDefaults` is thread safe, so the
/// pipeline queue may read straight through it.
final class SettingsStore {
    enum Key {
        static let aggressiveness = "aggressiveness"
        static let debugLogging = "debugLogging"
    }

    static let shared = SettingsStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// How willing Dodoma is to rewrite without asking. Defaults to balanced,
    /// which is what the seed corpus was labelled against.
    var aggressiveness: Aggressiveness {
        get {
            defaults.string(forKey: Key.aggressiveness)
                .flatMap(Aggressiveness.init(rawValue:)) ?? .balanced
        }
        set { defaults.set(newValue.rawValue, forKey: Key.aggressiveness) }
    }

    /// Opt-in switch for the `decision` log category, which is the only place
    /// typed text may reach os_log. Off unless the user turns it on with
    /// `defaults write com.ali.dodoma debugLogging -bool YES`.
    var debugLogging: Bool {
        defaults.bool(forKey: Key.debugLogging)
    }
}
