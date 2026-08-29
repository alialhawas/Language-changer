import AppKit
import DodomaCore
import Foundation

/// Reading and writing every setting from a shell.
///
/// The settings window is the discoverable surface; this is the one you can
/// script, diff, put in a dotfile, or read over ssh while the app runs on a
/// machine you are not sitting at. Both edit the same blob, so a change here
/// reaches a running app on its next evaluation without a restart.
enum CLIConfig {
    // MARK: - Status

    /// Everything the app currently believes, in one screen.
    static func status(_ store: SettingsStore, lexicon: UserLexicon) -> Int32 {
        let s = store.settings
        let permissions = Permissions.current()

        print("Harf \(Dodoma.version)")
        print("")
        print("  running          \(isRunning ? "yes" : "no")")
        print("  accessibility    \(mark(permissions.accessibility))")
        print("  input monitoring \(mark(permissions.inputMonitoring))")
        print("")
        print("  paused           \(mark(s.paused))")
        print("  sensitivity      \(s.aggressiveness.rawValue)")
        print("  confident score  \(s.confidentScore.map { pct($0) } ?? "off")")
        print("  buffer           \(s.bufferCapacity) keystrokes, dropped after \(Int(s.idleTimeout))s idle")
        print("  learning words   \(mark(s.learnVocabulary))")
        print("  debug logging    \(mark(s.debugLogging))")
        print("  default policy   \(s.defaultPolicy.rawValue)")
        print("")
        print("  apps configured  \(s.appPolicies.count)")
        print("  skipping verify  \(s.axVerifySkip.count)")
        let learned = lexicon.learned(.english).count + lexicon.learned(.arabic).count
        let manual = lexicon.manualWords(.english).count + lexicon.manualWords(.arabic).count
        print("  words learned    \(learned)  (\(manual) added by hand)")
        return 0
    }

    /// The settings as JSON, for scripting and for `diff`.
    static func dump(_ store: SettingsStore) -> Int32 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store.settings),
              let text = String(data: data, encoding: .utf8)
        else { return CLI.fail("--config: could not encode the settings", code: 1) }
        print(text)
        return 0
    }

    // MARK: - Writing

    static func set(_ key: String?, _ raw: String?, store: SettingsStore) -> Int32 {
        guard let key, let raw else {
            return CLI.fail("--set: expected a KEY and a VALUE", code: 2)
        }
        switch key {
        case "paused":
            guard let on = boolean(raw) else { return badBool("paused", raw) }
            store.setPaused(on)
        case "debugLogging", "debug":
            guard let on = boolean(raw) else { return badBool(key, raw) }
            store.setDebugLogging(on)
        case "sensitivity", "aggressiveness":
            guard let level = Aggressiveness(rawValue: raw) else {
                return CLI.fail(
                    "--set sensitivity: expected one of "
                        + Aggressiveness.allCases.map(\.rawValue).joined(separator: ", "),
                    code: 2)
            }
            store.setAggressiveness(level)
        case "confidentScore", "confident":
            if raw == "off" || raw == "none" {
                store.setConfidentScore(nil)
            } else if let score = percentOrFraction(raw) {
                store.setConfidentScore(score)
            } else {
                return CLI.fail(
                    "--set confident: expected a score such as 0.9 or 90, or 'off'", code: 2)
            }
        case "buffer", "bufferCapacity":
            guard let keys = Int(raw), keys > 0 else {
                return CLI.fail("--set buffer: expected a number of keystrokes", code: 2)
            }
            store.setBufferCapacity(keys)
        case "idle", "idleTimeout":
            guard let seconds = Double(raw), seconds > 0 else {
                return CLI.fail("--set idle: expected a number of seconds", code: 2)
            }
            store.setIdleTimeout(seconds)
        case "learn", "learnVocabulary":
            guard let on = boolean(raw) else { return badBool(key, raw) }
            store.setLearnVocabulary(on)
        case "defaultPolicy":
            guard let policy = AppPolicy(rawValue: raw) else { return badPolicy(raw) }
            store.setDefaultPolicy(policy)
        default:
            return CLI.fail(
                "--set: unknown key '\(key)'. Known keys: paused, sensitivity, confident, "
                    + "debugLogging, defaultPolicy",
                code: 2)
        }
        print("\(key) = \(raw)")
        return 0
    }

    // MARK: - Per-app policy

    static func policy(_ bundleID: String?, _ mode: String?, store: SettingsStore) -> Int32 {
        guard let bundleID else {
            let s = store.settings
            print("all other apps    \(s.defaultPolicy.rawValue)")
            for (id, policy) in s.appPolicies.sorted(by: { $0.key < $1.key }) {
                print("\(id.padding(toLength: max(18, id.count), withPad: " ", startingAt: 0))"
                    + "  \(policy.rawValue)")
            }
            return 0
        }
        guard let mode else {
            print(store.settings.policy(for: bundleID).rawValue)
            return 0
        }
        guard let policy = AppPolicy(rawValue: mode) else { return badPolicy(mode) }
        store.setPolicy(policy, for: bundleID)
        print("\(bundleID) = \(policy.rawValue)")
        return 0
    }

    // MARK: - Vocabulary

    static func words(
        _ action: String?, _ word: String?, language raw: String?, lexicon: UserLexicon
    ) -> Int32 {
        let language: Language? = raw.flatMap {
            switch $0.lowercased() {
            case "en", "english": return .english
            case "ar", "arabic": return .arabic
            default: return nil
            }
        }
        if raw != nil && language == nil {
            return CLI.fail("--words: expected --lang en or --lang ar", code: 2)
        }

        switch action {
        case nil, "list":
            for lang in language.map { [$0] } ?? [.english, .arabic] {
                let learned = lexicon.learned(lang)
                let manual = lexicon.manualWords(lang)
                print("\(lang.rawValue)  \(learned.count) learned, \(manual.count) added")
                for word in manual { print("    \(word)   (added)") }
                for entry in learned.prefix(40) { print("    \(entry.word)   ×\(entry.count)") }
                if learned.count > 40 { print("    … and \(learned.count - 40) more") }
            }
            return 0
        case "clear":
            lexicon.clear()
            print("cleared every remembered word, on disk as well as in memory")
            return 0
        case "add", "remove":
            guard let word else { return CLI.fail("--words \(action!): expected a WORD", code: 2) }
            guard let language else {
                return CLI.fail("--words \(action!): expected --lang en or --lang ar", code: 2)
            }
            if action == "add" {
                lexicon.add(word, language: language)
                print("added \(word) to \(language.rawValue)")
            } else {
                lexicon.remove(word, language: language)
                print("removed \(word) from \(language.rawValue)")
            }
            lexicon.save()
            return 0
        default:
            return CLI.fail("--words: expected list, add, remove or clear", code: 2)
        }
    }

    // MARK: - Helpers

    private static var isRunning: Bool {
        !NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.ali.dodoma" }.isEmpty
    }

    private static func mark(_ on: Bool) -> String { on ? "yes" : "no" }
    private static func pct(_ score: Double) -> String { "\(Int((score * 100).rounded()))%" }

    private static func boolean(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "on", "yes", "true", "1": return true
        case "off", "no", "false", "0": return false
        default: return nil
        }
    }

    /// Accepts 0.9 and 90 alike, because both are the obvious thing to type.
    private static func percentOrFraction(_ raw: String) -> Double? {
        guard let value = Double(raw.replacingOccurrences(of: "%", with: "")) else { return nil }
        let score = value > 1 ? value / 100 : value
        return (0.5...1.0).contains(score) ? score : nil
    }

    private static func badBool(_ key: String, _ raw: String) -> Int32 {
        CLI.fail("--set \(key): expected on or off, got '\(raw)'", code: 2)
    }

    private static func badPolicy(_ raw: String) -> Int32 {
        CLI.fail(
            "expected one of " + AppPolicy.allCases.map(\.rawValue).joined(separator: ", ")
                + ", got '\(raw)'",
            code: 2)
    }
}