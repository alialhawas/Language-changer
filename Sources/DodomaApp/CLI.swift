import DodomaCore
import Foundation

/// Non-GUI entry points. Every command here runs without Accessibility or
/// Input Monitoring grants and exits before `NSApplication` is touched.
enum CLI {
    enum Command {
        case render(text: String?)
        case dumpLayoutFixtures(path: String?)
        case notImplemented(flag: String)
    }

    private static let notImplementedFlags: Set<String> = ["--score", "--decide", "--eval"]

    /// Layouts snapshotted into the test fixture. Tests render through these
    /// rather than through whatever is enabled on the running machine.
    private static let fixtureSourceIDs = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.Arabic",
    ]

    static func parse(_ arguments: [String]) -> Command? {
        for (index, argument) in arguments.enumerated() {
            let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            switch argument {
            case "--render":
                return .render(text: next)
            case "--dump-layout-fixtures":
                return .dumpLayoutFixtures(path: next)
            default:
                if notImplementedFlags.contains(argument) {
                    return .notImplemented(flag: argument)
                }
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
        case .notImplemented(let flag):
            return fail("\(flag): not implemented yet", code: 1)
        }
    }

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
                let rendered = LayoutRenderer.render(keys, layout: layout, capsMode: capsMode)
                let emptyRate = LayoutRenderer.emptyRate(
                    keys, layout: layout, capsMode: capsMode)
                var line = "\(layout.sourceID) \(capsMode.rawValue): \(rendered)"
                if emptyRate > 0 {
                    line += String(format: "  (emptyRate %.2f)", emptyRate)
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

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = URL(fileURLWithPath: path)
        do {
            let data = try encoder.encode(matched.map(LayoutFixture.init(layout:)))
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
