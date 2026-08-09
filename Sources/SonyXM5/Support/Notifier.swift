import Foundation
import UserNotifications

/// System notifications for the events you'd otherwise only find out about by
/// noticing silence: the headphones connecting, dropping, running low, or
/// powering themselves off.
///
/// Every alert is edge-triggered — it fires on a transition, never on a repeat —
/// so a battery hovering at 30% doesn't notify once a minute.
@MainActor
final class Notifier: ObservableObject {
    /// User-facing switch; alerts are off until macOS grants authorization.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: enabledKey) }
    }
    @Published private(set) var isAuthorized = false

    private let enabledKey = "notifications.enabled"

    /// Descending thresholds. Crossing one downward fires exactly once; the set
    /// resets when the level climbs back above a threshold or the pack charges.
    private static let batteryThresholds = [30, 20, 10, 5]
    private var firedThresholds = Set<Int>()

    private var lastLevel: Int?
    private var lastCharging: Bool?
    private var wasConnected: Bool?

    init() {
        let defaults = UserDefaults.standard
        // Default on — this is the point of the feature.
        isEnabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        requestAuthorization()
    }

    private func requestAuthorization() {
        Log.write("notify", "requesting authorization…")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                self.isAuthorized = granted
                if let error {
                    Log.write("notify", "authorization failed: \(error.localizedDescription)")
                } else {
                    Log.write("notify", "authorization granted: \(granted)")
                }
            }
        }
    }

    private func post(_ title: String, _ body: String, sound: Bool = false) {
        guard isEnabled, isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil          // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Task { @MainActor in
                    Log.write("notify", "post failed: \(error.localizedDescription)")
                }
            }
        }
        Log.write("notify", "\(title) — \(body)")
    }

    // MARK: Events

    /// Called on every connection-state change.
    func connectionChanged(connected: Bool, deviceName: String, battery: Int?) {
        defer { wasConnected = connected }
        // Don't announce the state we launched into.
        guard let previous = wasConnected else { return }
        guard previous != connected else { return }

        if connected {
            let charge = battery.map { " · \($0)%" } ?? ""
            post("\(deviceName) connected", "Ready\(charge)")
        } else {
            // A disconnect is either the headphones powering off or going out of
            // range; from the host side these are indistinguishable.
            post("\(deviceName) disconnected", "Powered off or out of range")
            firedThresholds.removeAll()
            lastLevel = nil
            lastCharging = nil
        }
    }

    /// Called whenever a battery report arrives.
    func batteryChanged(level: Int, charging: Bool, deviceName: String) {
        defer {
            lastLevel = level
            lastCharging = charging
        }

        if let wasCharging = lastCharging, wasCharging != charging {
            if charging {
                post("\(deviceName) charging", "\(level)%")
            } else {
                post("\(deviceName) unplugged", "\(level)%")
            }
        }

        if charging {
            // Charging clears the low-battery latches so they can fire again on
            // the next discharge.
            firedThresholds.removeAll()
            if level >= 100, lastLevel ?? 0 < 100 {
                post("\(deviceName) fully charged", "100%")
            }
            return
        }

        // Re-arm any threshold the level has climbed back above.
        firedThresholds = firedThresholds.filter { level <= $0 }

        for threshold in Self.batteryThresholds where level <= threshold {
            guard !firedThresholds.contains(threshold) else { continue }
            firedThresholds.insert(threshold)
            let critical = threshold <= 10
            post(
                critical ? "\(deviceName) battery critical" : "\(deviceName) battery low",
                critical ? "\(level)% — charge soon to avoid a shutdown" : "\(level)% remaining",
                sound: critical
            )
            break   // Only the highest threshold just crossed.
        }
    }

}
