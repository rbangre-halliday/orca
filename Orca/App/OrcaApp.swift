import Cocoa
import GhosttyKit

@main
struct OrcaApp {
    static func main() {
        // Shell integration disabled — causes backspace/key issues.
        // Users add chpwd hook to .zshrc for cwd inheritance instead.

        // Initialize the ghostty library (sets up global state, logging, etc.)
        let argc = CommandLine.argc
        let argv = CommandLine.unsafeArgv
        _ = ghostty_init(UInt(argc), argv)

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
