import Foundation
import ServiceManagement

/// Launch-at-login, backed by `SMAppService`.
///
/// Registration is tied to the *running* bundle's path, so this registers
/// whichever copy is open — install to /Applications before enabling it, or the
/// login item points at a build directory.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    /// macOS can accept the registration but hold it until the user approves it
    /// in System Settings → General → Login Items.
    @Published private(set) var needsApproval = false

    init() {
        refresh()
        Log.write("login", "status at launch: \(describe(SMAppService.mainApp.status))")
    }

    private func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            needsApproval = false
        case .requiresApproval:
            isEnabled = true
            needsApproval = true
        default:
            isEnabled = false
            needsApproval = false
        }
    }

    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.write("login", "\(on ? "registered" : "unregistered")")
        } catch {
            Log.write("login", "failed to \(on ? "register" : "unregister"): \(error.localizedDescription)")
        }
        refresh()
    }

    /// Opens the pane where a pending registration is approved.
    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
