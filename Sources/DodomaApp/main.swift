import AppKit

let subcommandFlags: Set<String> = ["--render", "--score", "--decide", "--eval"]

if let flag = CommandLine.arguments.dropFirst().first(where: { subcommandFlags.contains($0) }) {
    FileHandle.standardError.write(Data("\(flag): not implemented yet\n".utf8))
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
