import AppKit

if let command = CLI.parse(Array(CommandLine.arguments.dropFirst())) {
    exit(CLI.run(command))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
