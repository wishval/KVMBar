import AppKit

let cliArguments = Array(CommandLine.arguments.dropFirst())

if !cliArguments.isEmpty {
    CLI.run(arguments: cliArguments) // never returns
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // LSUIElement equivalent for bare-binary runs
    app.run()
}
