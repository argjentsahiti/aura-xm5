import Foundation
import Combine

/// Owns the link to the headphones and mirrors their live state for the UI.
///
/// The device is the source of truth: every setter writes to the headphones and
/// then re-reads, so pressing the physical NC button or changing something in
/// Sony's own app is reflected here too.
@MainActor
final class Headphones: ObservableObject {
    @Published private(set) var connection: SonyLink.State = .idle
    @Published private(set) var battery: Int?
    @Published private(set) var charging: Bool = false
    @Published private(set) var deviceName: String = "WH-1000XM5"
    /// Sony's internal model code (e.g. "HP002"). Not the user-facing firmware
    /// version — that isn't exposed on this table.
    @Published private(set) var modelCode: String?

    @Published private(set) var anc = ANCState()
    @Published private(set) var eq = EQState.flat

    @Published private(set) var dsee = false
    @Published private(set) var powerOffWhenTakenOff = true
    @Published private(set) var volume = 0

    let modes: ModeStore
    let notifier: Notifier

    private let link = SonyLink()
    private var pollTimer: Timer?
    /// Suppresses mode de-selection while we're the ones writing the change.
    private var applyingMode = false

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    init(modes: ModeStore, notifier: Notifier) {
        self.modes = modes
        self.notifier = notifier

        link.onState = { [weak self] state in
            guard let self else { return }
            let wasConnected = self.isConnected
            self.connection = state
            if case .connected(let name) = state {
                self.deviceName = name
                self.handshake()
            } else {
                self.battery = nil
                self.stopPolling()
            }
            if wasConnected != self.isConnected {
                self.notifier.connectionChanged(
                    connected: self.isConnected,
                    deviceName: self.deviceName,
                    battery: self.battery
                )
            }
        }

        link.onFrame = { [weak self] frame in
            self?.handle(frame)
        }
    }

    func start() { link.start() }
    func reconnect() { link.connect() }

    // MARK: Reading

    private func handshake() {
        link.send(SonyCommand.initHandshake)
        link.send(SonyCommand.getDeviceInfo)
        refresh()
        startPolling()
    }

    func refresh() {
        guard isConnected else { return }
        link.send(SonyCommand.getBattery)
        link.send(SonyCommand.getANC)
        link.send(SonyCommand.getEQ)
        link.send(SonyCommand.getDSEE)
        link.send(SonyCommand.getAutoPowerOff)
        link.send(SonyCommand.getVolume)
    }

    private func startPolling() {
        stopPolling()
        // Battery only — ANC and EQ changes arrive unprompted as notifications.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isConnected else { return }
                self.link.send(SonyCommand.getBattery)
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func handle(_ frame: SonyFrame) {
        let p = frame.payload
        Log.hex("rx", p)
        guard let opcode = frame.opcode else { return }

        switch opcode {
        // 0x23 is the reply to a request; 0x25 arrives unprompted when the level
        // changes, which is how battery stays current between polls.
        case 0x23, 0x25:
            if let (level, charging) = SonyCommand.parseBattery(p) {
                battery = level
                self.charging = charging
                notifier.batteryChanged(level: level, charging: charging, deviceName: deviceName)
            }
        // 0x67 is the reply; 0x69 is the unsolicited notification the headphones
        // send when the state changes on the device itself.
        case 0x67, 0x69:
            if let state = SonyCommand.parseANC(p) {
                anc = state
                if !applyingMode { invalidateModeIfDrifted() }
            }
        case 0x57, 0x59:
            if let state = SonyCommand.parseEQ(p) {
                eq = state
                if !applyingMode { invalidateModeIfDrifted() }
            }
        // 0xE7/0xF7/0x27/0xA7 are replies; the odd-numbered twins are the
        // unsolicited notifications the headphones send on their own.
        case 0xE7, 0xE9:
            if let on = SonyCommand.parseFlag(p, opcode: p[0]) { dsee = on }
        case 0x27, 0x29:
            if let takenOff = SonyCommand.parseAutoPowerOff([0x27] + p.dropFirst()) {
                powerOffWhenTakenOff = takenOff
            }
        case 0xA7, 0xA9:
            if let level = SonyCommand.parseVolume([0xA7] + p.dropFirst()) { volume = level }
        case 0x37:
            if let info = SonyCommand.parseDeviceInfo(p) {
                modelCode = info.model
            }
        default:
            break
        }
    }

    // MARK: Writing

    func setANCMode(_ mode: ANCMode) {
        var next = anc
        // Entering Ambient deliberately clears Focus on Voice. It filters ambient
        // down to speech only, which is nearly indistinguishable from noise
        // cancelling — inheriting it from a previous mode makes picking "Ambient"
        // look broken. Turning it back on is one toggle away, and Modes that want
        // it set it explicitly.
        if mode == .ambient {
            next.voiceFocus = false
        }
        next.mode = mode
        write(anc: next)
    }

    func setAmbientLevel(_ level: Int) {
        var next = anc
        next.ambientLevel = max(1, min(20, level))
        next.mode = .ambient
        write(anc: next)
    }

    func setVoiceFocus(_ on: Bool) {
        var next = anc
        next.voiceFocus = on
        write(anc: next)
    }

    func setBand(_ index: Int, to value: Int) {
        guard eq.bands.indices.contains(index) else { return }
        var next = eq
        next.bands[index] = max(0, min(20, value))
        // Touching a band always drops the device into its Custom slot.
        next.preset = 0xA0
        write(eq: next)
    }

    func resetEQ() {
        write(eq: .flat)
    }

    func setDSEE(_ on: Bool) {
        dsee = on
        guard isConnected else { return }
        link.send(SonyCommand.setDSEE(on))
        link.send(SonyCommand.getDSEE)
    }

    func setPowerOffWhenTakenOff(_ on: Bool) {
        powerOffWhenTakenOff = on
        guard isConnected else { return }
        link.send(SonyCommand.setAutoPowerOff(whenTakenOff: on))
        link.send(SonyCommand.getAutoPowerOff)
    }

    func setVolume(_ level: Int) {
        volume = max(0, min(30, level))
        guard isConnected else { return }
        link.send(SonyCommand.setVolume(volume))
    }

    private func write(anc next: ANCState) {
        anc = next
        guard isConnected else { return }
        link.send(SonyCommand.setANC(next))
        link.send(SonyCommand.getANC)
        if !applyingMode { invalidateModeIfDrifted() }
    }

    private func write(eq next: EQState) {
        eq = next
        guard isConnected else { return }
        link.send(SonyCommand.setEQ(next))
        link.send(SonyCommand.getEQ)
        if !applyingMode { invalidateModeIfDrifted() }
    }

    // MARK: Modes

    func apply(_ mode: Mode) {
        applyingMode = true
        anc = mode.anc
        eq = mode.eq
        if isConnected {
            link.send(SonyCommand.setANC(mode.anc))
            link.send(SonyCommand.setEQ(mode.eq))
            link.send(SonyCommand.getANC)
            link.send(SonyCommand.getEQ)
        }
        modes.setActive(mode.id)
        // Let the read-backs land before we start policing drift again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.applyingMode = false
        }
    }

    /// Captures the current device state into a new user mode.
    func captureCurrentAsMode(named name: String, symbol: String) {
        let mode = Mode(name: name, symbol: symbol, anc: anc, eq: eq)
        modes.add(mode)
        modes.setActive(mode.id)
    }

    /// Drops the active-mode highlight once the live state no longer matches it.
    private func invalidateModeIfDrifted() {
        guard let active = modes.mode(for: modes.activeModeID) else { return }
        if active.anc != anc || active.eq.bands != eq.bands {
            modes.setActive(nil)
        }
    }
}
