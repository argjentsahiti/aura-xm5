import SwiftUI

/// Panes the panel can show. The primary view stays short enough to read at a
/// glance; everything else drills in, the way Control Center expands a tile
/// rather than stacking every control in one column.
enum Pane: String, Identifiable {
    case home, equalizer, playback, microphone, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return ""
        case .equalizer: return "Equalizer"
        case .playback: return "Playback"
        case .microphone: return "Microphone"
        case .settings: return "Settings"
        }
    }
}

struct HUDView: View {
    @ObservedObject var hp: Headphones
    @ObservedObject var modes: ModeStore
    @ObservedObject var login: LoginItem
    @ObservedObject var mic: MicController
    @ObservedObject var notifier: Notifier
    var onQuit: () -> Void

    @State private var pane: Pane = .home
    @State private var naming = false
    @State private var newModeName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().overlay(Design.hairline)

            Group {
                if !hp.isConnected {
                    disconnected
                } else {
                    switch pane {
                    case .home: homePane
                    case .equalizer: equalizerPane
                    case .playback: playbackPane
                    case .microphone: microphonePane
                    case .settings: settingsPane
                    }
                }
            }
            .padding(.horizontal, Design.hPad)
            .padding(.top, 15)
            .padding(.bottom, 17)
        }
        .frame(width: Design.panelWidth)
        .animation(Design.spring, value: pane)
        .animation(Design.spring, value: hp.isConnected)
        .animation(Design.spring, value: hp.anc.mode)
        .onChange(of: hp.isConnected) { _, connected in
            if !connected { pane = .home }
        }
    }

    // MARK: - Header

    /// Doubles as the navigation bar: the battery ring gives way to a back
    /// control once you're a level down.
    private var header: some View {
        HStack(spacing: 11) {
            if pane != .home {
                Button {
                    pane = .home
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Design.fill)
                        )
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(pane == .home ? hp.deviceName : pane.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(pane == .home ? statusText : hp.deviceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if pane == .home {
                BatteryRing(level: hp.battery, charging: hp.charging)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, Design.hPad)
        .padding(.vertical, 15)
    }

    private var statusText: String {
        switch hp.connection {
        case .connected:
            if let active = modes.mode(for: modes.activeModeID) {
                return "\(active.name) · \(hp.anc.mode.title)"
            }
            return hp.anc.mode.title
        case .connecting: return "Connecting…"
        case .waitingForHeadphones: return "Waiting for headphones"
        case .failed(let reason): return reason
        case .idle: return "Not connected"
        }
    }

    // MARK: - Home

    private var homePane: some View {
        VStack(alignment: .leading, spacing: 17) {
            modeSection

            VStack(alignment: .leading, spacing: 9) {
                SectionLabel("Ambient Sound")
                ANCSelector(selection: hp.anc.mode) { hp.setANCMode($0) }
                ambientDetail
            }

            VStack(spacing: 0) {
                NavRow(icon: "slider.horizontal.3", title: "Equalizer",
                       value: eqSummary) { pane = .equalizer }
                Divider().overlay(Design.hairline).padding(.leading, 30)
                NavRow(icon: "speaker.wave.2.fill", title: "Playback",
                       value: "Vol \(hp.volume)") { pane = .playback }
                Divider().overlay(Design.hairline).padding(.leading, 30)
                NavRow(icon: "mic.fill", title: "Microphone",
                       value: mic.isAvailable ? (mic.isMuted ? "Muted" : "\(Int(mic.volume * 100))%") : "Not in use",
                       enabled: mic.isAvailable) { pane = .microphone }
                Divider().overlay(Design.hairline).padding(.leading, 30)
                NavRow(icon: "gearshape.fill", title: "Settings",
                       value: nil) { pane = .settings }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Design.fill)
            )
        }
    }

    /// Modes wrap into a grid so saved ones don't squeeze the built-ins.
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Modes") {
                // Only offered when the live state matches no saved mode —
                // otherwise you'd be saving a duplicate of what's selected.
                if modes.activeModeID == nil && !naming {
                    QuietButton(title: "Save Current") {
                        newModeName = ""
                        naming = true
                    }
                    .transition(.opacity)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4),
                spacing: 7
            ) {
                ForEach(modes.modes) { mode in
                    ModeChip(mode: mode, isActive: modes.activeModeID == mode.id) {
                        hp.apply(mode)
                    }
                    .contextMenu {
                        if mode.isBuiltIn {
                            Text("Built-in mode")
                        } else {
                            Button("Delete \(mode.name)", role: .destructive) {
                                modes.delete(mode.id)
                            }
                        }
                    }
                }
            }

            if naming {
                HStack(spacing: 7) {
                    TextField("Mode name", text: $newModeName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Design.fill)
                        )
                        .onSubmit(saveMode)

                    QuietButton(title: "Save", action: saveMode)
                    QuietButton(title: "Cancel") { naming = false }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Design.spring, value: naming)
        .animation(Design.spring, value: modes.modes.count)
    }

    private func saveMode() {
        let name = newModeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        hp.captureCurrentAsMode(named: name, symbol: "star.fill")
        naming = false
    }

    private var isFlat: Bool { hp.eq.bands.allSatisfy { $0 == 10 } }
    private var eqSummary: String { isFlat ? "Flat" : "Custom" }

    /// Stays visible but inert unless Ambient is selected — a control that
    /// vanishes teaches nothing; one that greys out shows what enables it.
    private var ambientDetail: some View {
        let active = hp.anc.mode == .ambient
        // Both controls only mean anything while ambient sound is passing
        // through: with Noise Cancelling or Off there is nothing to set a level
        // for, so they read as unavailable rather than silently doing nothing.
        let reason = hp.anc.mode == .noiseCancelling
            ? "Level — unavailable with Noise Cancelling"
            : "Level — unavailable when off"
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(active ? "Level" : reason)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if active {
                    Text("\(hp.anc.ambientLevel)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }

            LevelSlider(value: hp.anc.ambientLevel, range: 1...20) { hp.setAmbientLevel($0) }

            Toggle(isOn: Binding(get: { hp.anc.voiceFocus }, set: { hp.setVoiceFocus($0) })) {
                Text("Focus on Voice")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Design.accent)
        }
        .padding(.top, 2)
        .disabled(!active)
        .opacity(active ? 1 : 0.4)
        .animation(Design.spring, value: active)
    }

    // MARK: - Equalizer

    private var equalizerPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Bands") {
                // Nothing to reset when every band already sits at the detent.
                if !isFlat {
                    QuietButton(title: "Reset") { hp.resetEQ() }
                        .transition(.opacity)
                }
            }

            HStack(spacing: 2) {
                ForEach(Array(hp.eq.bands.enumerated()), id: \.offset) { idx, value in
                    EQBand(
                        label: idx < EQState.bandLabels.count ? EQState.bandLabels[idx] : "\(idx)",
                        value: value
                    ) { hp.setBand(idx, to: $0) }
                }
            }

            Text("Clear Bass is the low shelf; the rest are graphic bands. Adjusting any band switches the headphones to their Custom preset.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Playback

    private var playbackPane: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Volume") {
                    Text("\(hp.volume)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                LevelSlider(value: hp.volume, range: 0...30) { hp.setVolume($0) }
            }

            Divider().overlay(Design.hairline)

            settingRow("DSEE Extreme", "Upscales compressed audio",
                       isOn: hp.dsee) { hp.setDSEE($0) }

            // The XM5 dropped its predecessors' timed shutoff — wearing
            // detection is the only auto-off it honours.
            settingRow("Power Off When Removed", "Shuts down when taken off",
                       isOn: hp.powerOffWhenTakenOff) { hp.setPowerOffWhenTakenOff($0) }
        }
    }

    // MARK: - Microphone

    private var microphonePane: some View {
        VStack(alignment: .leading, spacing: 13) {
            if mic.isAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Input Level") {
                        Text(mic.isMuted ? "Muted" : "\(Int(mic.volume * 100))%")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(mic.isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                            .contentTransition(.numericText())
                    }

                    HStack(spacing: 10) {
                        Button {
                            mic.setMuted(!mic.isMuted)
                        } label: {
                            Image(systemName: mic.isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(mic.isMuted
                                                 ? AnyShapeStyle(Color(red: 1.0, green: 0.36, blue: 0.34))
                                                 : AnyShapeStyle(.secondary))
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Design.fill)
                                )
                        }
                        .buttonStyle(.plain)

                        LevelSlider(value: Int((mic.volume * 100).rounded()), range: 0...100) {
                            mic.setVolume(Float($0) / 100)
                        }
                        .disabled(mic.isMuted)
                        .opacity(mic.isMuted ? 0.4 : 1)
                    }
                }
            } else {
                Text("The microphone appears once an app starts using it. Bluetooth stays in playback-only mode until then.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Adjusts the input gain macOS applies to the headset — the level that reaches calls. The XM5 exposes no microphone gain of its own.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Settings

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 13) {
            settingRow("Launch at Login", "Start Aura when you sign in",
                       isOn: login.isEnabled) { login.set($0) }

            if login.needsApproval {
                Button { login.openSettings() } label: {
                    Text("Approve in System Settings →")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Design.accent)
                }
                .buttonStyle(.plain)
            }

            settingRow("Alerts", "Connection, battery and shutdown",
                       isOn: notifier.isEnabled, enabled: notifier.isAuthorized) {
                notifier.isEnabled = $0
            }

            Divider().overlay(Design.hairline)

            HStack(spacing: 10) {
                if let model = hp.modelCode {
                    Text("Model \(model)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                QuietButton(title: "Reconnect") { hp.reconnect(); hp.refresh() }
                QuietButton(title: "Quit", action: onQuit)
            }
        }
    }

    // MARK: - Shared

    private func settingRow(_ title: String, _ subtitle: String, isOn: Bool,
                            enabled: Bool = true,
                            set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Design.accent)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private var disconnected: some View {
        VStack(spacing: 9) {
            Image(systemName: "headphones")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Turn on your headphones")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Aura connects automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            QuietButton(title: "Quit", action: onQuit)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

/// A drill-in row: icon, title, current value, chevron.
private struct NavRow: View {
    let icon: String
    let title: String
    var value: String?
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Design.accent)
                    .frame(width: 15)

                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                if let value {
                    Text(value)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(hovering ? Design.fill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { h in withAnimation(Design.quick) { hovering = h && enabled } }
    }
}
