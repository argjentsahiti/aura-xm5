import AppKit
import SwiftUI

/// First-run window.
///
/// A menu-bar app with `LSUIElement` set has a genuine discovery problem: you
/// launch it and, as far as the screen is concerned, nothing happens. This says
/// where it went and what it needs, once, then never appears again.
@MainActor
final class WelcomeWindow {
    private static let shownKey = "welcome.shown.v1"
    private static var window: NSWindow?

    static var hasBeenShown: Bool {
        UserDefaults.standard.bool(forKey: shownKey)
    }

    static func showIfFirstLaunch() {
        guard !hasBeenShown else { return }
        show()
    }

    static func show() {
        // Re-focus rather than stacking a second copy.
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = WelcomeView {
            UserDefaults.standard.set(true, forKey: shownKey)
            close()
        }

        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Welcome to Aura"
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor = .windowBackgroundColor
        win.level = .floating          // stays above other windows
        win.center()
        win.isReleasedWhenClosed = false

        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct WelcomeView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 11) {
                Image(systemName: "headphones")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Design.accentGradient)
                    .padding(.top, 4)

                Text("Aura")
                    .font(.system(size: 26, weight: .semibold))

                Text("Control your Sony WH-1000XM5 from the menu bar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 30)
            .padding(.horizontal, 34)
            .padding(.bottom, 24)

            Divider().overlay(Design.hairline)

            // The one thing people miss about menu-bar apps.
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Design.accent)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Design.accent.opacity(0.12))
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Look up at the menu bar")
                            .font(.system(size: 13, weight: .medium))
                        Text("Aura has no Dock icon. Click the headphones icon at the top-right of your screen to open it.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                row("bolt.horizontal.fill", "Pair your headphones first",
                    "Aura attaches to an existing pairing in System Settings → Bluetooth. It connects on its own whenever they come back.")

                row("square.grid.2x2.fill", "Modes do the work",
                    "One tap sets noise cancelling and a tuned equalizer curve together. Adjust anything and you can save it as your own.")

                row("bell.badge.fill", "Optional alerts",
                    "Battery warnings and connection changes. macOS will ask permission the first time.")
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 22)

            Divider().overlay(Design.hairline)

            HStack {
                Link("View on GitHub", destination: URL(string: "https://github.com/argjentsahiti/aura-xm5")!)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: onDismiss) {
                    Text("Get Started")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Design.accentGradient)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 15)
        }
        .frame(width: 420)
    }

    private func row(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Design.fill)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(body)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
