import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var modes: ModeStore!
    private var headphones: Headphones!
    private var login: LoginItem!
    private var mic: MicController!
    private var notifier: Notifier!
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.startSession()

        modes = ModeStore()
        notifier = Notifier()
        headphones = Headphones(modes: modes, notifier: notifier)
        login = LoginItem()
        mic = MicController()
        menuBar = MenuBarController(headphones: headphones, modes: modes,
                                    login: login, mic: mic, notifier: notifier)

        headphones.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
