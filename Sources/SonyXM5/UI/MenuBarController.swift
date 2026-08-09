import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let headphones: Headphones
    private let modes: ModeStore
    private let login: LoginItem
    private let mic: MicController
    private let notifier: Notifier
    private let updater: Updater
    private var cancellables = Set<AnyCancellable>()

    /// NSPopover rather than a hand-rolled NSPanel.
    ///
    /// A borderless panel has to solve key-window handling, activation and
    /// click-outside dismissal by hand, and getting any of it wrong leaves the
    /// controls silently inert. The popover gets all of that right, and resizes
    /// itself when SwiftUI's content grows — which the panel did not, so the
    /// ambient controls had nowhere to appear.
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let controller = NSHostingController(rootView: rootView)
        // Let SwiftUI drive the popover's height as sections appear and go.
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        return popover
    }()

    private var rootView: some View {
        HUDView(hp: headphones, modes: modes, login: login, mic: mic, notifier: notifier, updater: updater) {
            NSApp.terminate(nil)
        }
    }

    init(headphones: Headphones, modes: ModeStore, login: LoginItem,
         mic: MicController, notifier: Notifier, updater: Updater) {
        self.headphones = headphones
        self.modes = modes
        self.login = login
        self.mic = mic
        self.notifier = notifier
        self.updater = updater
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()

        // Keep the menu bar glyph in step with the live state.
        headphones.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)

        modes.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)

        updateButton()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.imagePosition = .imageLeading
    }

    /// The glyph carries the state: filled when cancelling, hollow when ambient,
    /// dimmed when the headphones aren't there.
    private func updateButton() {
        guard let button = statusItem.button else { return }

        let symbol: String
        if !headphones.isConnected {
            symbol = "headphones"
        } else {
            switch headphones.anc.mode {
            case .noiseCancelling: symbol = "headphones.circle.fill"
            case .ambient: symbol = "headphones.circle"
            case .off: symbol = "headphones"
            }
        }

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Aura")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.alphaValue = headphones.isConnected ? 1.0 : 0.45

        // Low battery is the one thing worth surfacing without a click.
        if headphones.isConnected, let level = headphones.battery, level <= 20 {
            button.title = " \(level)%"
        } else {
            button.title = ""
        }

        button.toolTip = headphones.isConnected
            ? "\(headphones.deviceName) — \(headphones.anc.mode.title)"
            : "Headphones not connected"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        headphones.refresh()
        // Login-item state can change in System Settings behind our back, and the
        // headset's microphone only exists while hands-free mode is engaged.
        login.refresh()
        mic.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // An accessory app isn't frontmost, so the popover would otherwise open
        // without keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }
}
