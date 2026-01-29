import AppKit

@main
enum MeetingVaultMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = MeetingVaultApp()
        app.delegate = delegate
        app.run()
    }
}
