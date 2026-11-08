import AppKit

// Frenzy is a regular app with a Dock icon (since 9 Nov 2026): a user can always find and open it, even when macOS
// hides new menu-bar icons. The menu-bar icon stays as an extra. LSUIElement is false in Info.plist to match; setting
// the policy here also covers `swift run` during development.

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
app.setActivationPolicy(.regular)
app.run()
