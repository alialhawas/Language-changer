import Carbon.HIToolbox
import DodomaCore
import Foundation

/// Non-GUI entry points. Every command here runs without Accessibility or
/// Input Monitoring grants and exits before `NSApplication` is touched.
enum CLI {
    enum Command {
        case render(text: String?)
        case dumpLayoutFixtures(path: String?)
        case score(text: String?)
        case decide(text: String?, language: String?, aggressiveness: String?)
        case eval(path: String?, aggressiveness: String?)
    }

    /// Layouts snapshotted into the test fixture. Tests render through these
    /// rather than through whatever is enabled on the running machine.
    private static let fixtureSourceIDs = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.Arabic",
    ]

    static func parse(_ arguments: [String]) -> Command? {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1)
            else { return nil }
            return arguments[index + 1]
        }

        for (index, argument) in arguments.enumerated() {
            let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            switch argument {
            case "--render":
                return .render(text: next)
            case "--dump-layout-fixtures":
                return .dumpLayoutFixtures(path: next)
            case "--score":
                return .score(text: next)
            case "--decide":
                return .decide(
                    text: next,
                    language: value(after: "--lang"),
                    aggressiveness: value(after: "--aggressiveness"))
            case "--eval":
                return .eval(path: next, aggressiveness: value(after: "--aggressiveness"))
            default:
                continue
            }
        }
        return nil
    }

    static func run(_ command: Command) -> Int32 {
        switch command {
        case .render(let text):
            guard let text else {
                return fail("--render: expected a TEXT argument", code: 2)
            }
            return render(text)
        case .dumpLayoutFixtures(let path):
            guard let path else {
                return fail("--dump-layout-fixtures: expected an output path", code: 2)
            }
            return dumpLayoutFixtures(to: path)
        case .score(let text):
            guard let text else {
                return fail("--score: expected a TEXT argument", code: 2)
            }
            return score(text)
        case .decide(let text, let language, let aggressiveness):
            guard let text else {
                return fail("--decide: expected a TEXT argument", code: 2)
            }
            return decide(text, language: language, aggressiveness: aggressiveness)
        case .eval(let path, let aggressiveness):
            guard let path else {
                return fail("--eval: expected a corpus path", code: 2)
            }
            return eval(path, aggressiveness: aggressiveness)
        }
    }

    // MARK: - Scoring

    private static func score(_ text: String) -> Int32 {
        if let message = preloadModels() { return fail("--score: \(message)", code: 1) }
        print("text: \(text)")
        print("lang   bigram  dict    combined")
        for language in Language.allCases {
            let model = LanguageModel.shared(language)
            let score = model.combined(text)
            print(
                String(
                    format: "%@     %-7.3f %-7.3f %.3f", language.rawValue,
                    score.bigram, score.dictCoverage, score.combined))
        }
        return 0
    }

    // MARK: - Deciding

    private static func decide(_ text: String, language: String?, aggressiveness: String?)
        -> Int32
    {
        if let message = preloadModels() { return fail("--decide: \(message)", code: 1) }
        guard let detector = liveDetector() else {
            return fail(
                "--decide: this machine needs both an English and an Arabic keyboard layout "
                    + "enabled in System Settings > Keyboard > Input Sources",
                code: 1)
        }

        let typedLanguage: Language
        switch language?.lowercased() {
        case nil:
            typedLanguage = Detector.scriptLanguage(of: text)
        case "en", "english":
            typedLanguage = .english
        case "ar", "arabic":
            typedLanguage = .arabic
        case let other?:
            return fail("--decide: --lang expects en or ar, got \(other)", code: 2)
        }

        guard let level = parseAggressiveness(aggressiveness) else {
            return fail(
                "--decide: --aggressiveness expects one of "
                    + Aggressiveness.allCases.map(\.rawValue).joined(separator: ", "),
                code: 2)
        }

        let sourceLayout = detector.layout(for: typedLanguage)
        guard let detection = detector.detect(text: text, typedLanguage: typedLanguage,
                                              aggressiveness: level)
        else {
            let character = InverseKeymap.unmappableCharacter(in: text, layout: sourceLayout)
            return fail(
                "--decide: \(sourceLayout.sourceID) has no key for "
                    + "'\(character.map(String.init) ?? "?")'",
                code: 2)
        }

        print("text:          \(text)")
        print("typed layout:  \(sourceLayout.sourceID) (\(typedLanguage.rawValue))")
        print("aggressiveness: \(level.rawValue)")

        guard let region = detection.region, let analysis = detection.analysis else {
            print("decision:      ignore (\(reasonText(detection.decision)))")
            return 0
        }

        print("region:        \(region.typedText)")
        print(
            "               letters \(region.letterCount), tokens \(region.tokenCount), "
                + "completed \(region.completedTokenCount)")
        print(String(format: "current:       bigram %.3f dict %.3f combined %.3f",
                     analysis.current.bigram, analysis.current.dictCoverage,
                     analysis.current.combined))
        print(String(format: "alternate:     bigram %.3f dict %.3f combined %.3f",
                     analysis.alternate.bigram, analysis.alternate.dictCoverage,
                     analysis.alternate.combined))
        print(String(format: "gap:           %.3f", analysis.gap))
        print("capsMode:      \(analysis.capsMode?.rawValue ?? "none")")
        print("guards:        \(analysis.guards.summary)")

        switch detection.decision {
        case .ignore(let reason):
            print("decision:      ignore (\(reason))")
        case .suggest(let fix):
            printFix("suggest", fix)
        case .autoApply(let fix):
            printFix("autoApply", fix)
        }
        return 0
    }

    private static func printFix(_ verdict: String, _ fix: Fix) {
        print("decision:      \(verdict)")
        print("  delete:      \(fix.deleteCount)")
        print("  insert:      \(fix.insertText)")
        print("  target:      \(fix.targetLayoutID)")
    }

    private static func reasonText(_ decision: Decision) -> String {
        if case .ignore(let reason) = decision { return reason }
        return ""
    }

    // MARK: - Eval

    private static func eval(_ path: String, aggressiveness: String?) -> Int32 {
        if let message = preloadModels() { return fail("--eval: \(message)", code: 1) }
        guard let detector = liveDetector() else {
            return fail(
                "--eval: this machine needs both an English and an Arabic keyboard layout enabled",
                code: 1)
        }
        guard let level = parseAggressiveness(aggressiveness) else {
            return fail("--eval: unknown --aggressiveness value", code: 2)
        }

        let contents: String
        do {
            contents = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return fail("--eval: cannot read \(path): \(error.localizedDescription)", code: 2)
        }

        let rows: [EvalRow]
        do {
            rows = try EvalHarness.parse(contents)
        } catch {
            return fail("--eval: \(error)", code: 2)
        }

        let report = EvalHarness.run(rows: rows, detector: detector, aggressiveness: level)
        print(report.render())
        return report.exitCode
    }

    // MARK: - Shared helpers

    /// Forces both language models in so a missing or malformed resource
    /// exits with a message instead of quietly scoring everything as zero.
    /// Returns a description of the failure, or nil on success.
    private static func preloadModels() -> String? {
        for language in Language.allCases {
            do {
                try LanguageModel.shared(language).preload()
            } catch {
                return "\(error)"
            }
        }
        return nil
    }

    private static func parseAggressiveness(_ raw: String?) -> Aggressiveness? {
        guard let raw else { return .balanced }
        return Aggressiveness(rawValue: raw)
    }

    private static func liveDetector() -> Detector? {
        guard let pair = LayoutEngine().currentPair() else { return nil }
        return Detector(englishLayout: pair.english, arabicLayout: pair.arabic)
    }

    // MARK: - Existing commands

    private static func render(_ text: String) -> Int32 {
        guard let keys = KeycodeMap.keys(forLatin: text) else {
            return fail("--render: input has characters with no US keycode mapping", code: 2)
        }

        let layouts = LayoutEngine.enabledKeyboardLayouts()
        guard !layouts.isEmpty else {
            return fail("--render: no enabled keyboard layout carries a uchr table", code: 1)
        }

        print("selected: \(LayoutEngine.selectedLayoutID() ?? "unknown")")
        for layout in layouts {
            for capsMode in CapsMode.allCases {
                let rendered = LayoutRenderer.renderSequence(
                    keys, layout: layout, capsMode: capsMode)
                var line = "\(layout.sourceID) \(capsMode.rawValue): \(rendered.text)"
                if rendered.emptyRate > 0 {
                    line += String(format: "  (emptyRate %.2f)", rendered.emptyRate)
                }
                print(line)
            }
        }
        return 0
    }

    private static func dumpLayoutFixtures(to path: String) -> Int32 {
        let layouts = LayoutEngine.enabledKeyboardLayouts()
        let matched = fixtureSourceIDs.compactMap { sourceID in
            layouts.first { $0.sourceID == sourceID }
        }
        guard !matched.isEmpty else {
            return fail(
                "--dump-layout-fixtures: none of \(fixtureSourceIDs.joined(separator: ", ")) are enabled",
                code: 1)
        }
        for sourceID in fixtureSourceIDs where !matched.contains(where: { $0.sourceID == sourceID })
        {
            warn("--dump-layout-fixtures: \(sourceID) is not enabled, skipping")
        }

        let keyboardType = UInt32(LMGetKbdType())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = URL(fileURLWithPath: path)
        do {
            let fixtures = matched.map {
                LayoutFixture(layout: $0, keyboardType: keyboardType)
            }
            let data = try encoder.encode(fixtures)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return fail("--dump-layout-fixtures: \(error.localizedDescription)", code: 1)
        }

        print("wrote \(matched.count) layout fixture(s) to \(path)")
        return 0
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static func fail(_ message: String, code: Int32) -> Int32 {
        warn(message)
        return code
    }
}
