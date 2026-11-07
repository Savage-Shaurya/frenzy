import AppKit

// Halo is a menu-bar accessory: no Dock icon, no main window. LSUIElement in Info.plist does the same for the
// bundled app; setting the policy here also covers `swift run` during development.

// Command-line diagnostics (run the binary inside Halo.app; they need the bundled worker):
//   Halo.app/Contents/MacOS/Halo --worker-self-test          probe the worker's sandbox, print the result
//   Halo.app/Contents/MacOS/Halo --convert <action-id> FILE…  convert through the worker, print the outputs
if let exitCode = CommandLineTools.runIfRequested(CommandLine.arguments) {
    exit(exitCode)
}

guard SingleInstance.acquire() else {
    // Another copy is already running. It has been asked to show its Settings window; this copy just leaves.
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
