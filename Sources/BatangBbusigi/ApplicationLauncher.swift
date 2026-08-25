import AppKit

@main
enum ApplicationLauncher {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let applicationDelegate = AppDelegate()
        application.delegate = applicationDelegate
        application.run()
    }
}
