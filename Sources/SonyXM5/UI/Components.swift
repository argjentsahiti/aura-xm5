import SwiftUI

// MARK: - Battery

/// A thin ring that fills with charge level. Reads at a glance from across the
/// desk, and carries the only non-accent colour in the app (red, when low).
struct BatteryRing: View {
    let level: Int?
    let charging: Bool

    private var fraction: Double { Double(level ?? 0) / 100.0 }

    private var tint: Color {
        guard let level else { return .secondary }
        if charging { return Color(red: 0.30, green: 0.82, blue: 0.45) }
        if level <= 15 { return Color(red: 1.00, green: 0.36, blue: 0.34) }
        if level <= 30 { return Color(red: 1.00, green: 0.72, blue: 0.24) }
        return .primary.opacity(0.85)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Design.fill, lineWidth: 3.5)

            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Design.spring, value: fraction)

            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
            } else if let level {
                Text("\(level)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            } else {
                Text("–")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 38, height: 38)
    }
}

// MARK: - Ambient control

/// Three-way ambient selector with a sliding indicator. The pill is a single
/// matched-geometry element so the selection travels rather than blinks.
struct ANCSelector: View {
    let selection: ANCMode
    let onSelect: (ANCMode) -> Void

    @Namespace private var ns
    private let order: [ANCMode] = [.noiseCancelling, .off, .ambient]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(order, id: \.rawValue) { mode in
                let active = mode == selection
                Button {
                    onSelect(mode)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 13, weight: .medium))
                        Text(label(for: mode))
                            .font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Design.accentGradient)
                                .matchedGeometryEffect(id: "ancPill", in: ns)
                                .shadow(color: Design.accent.opacity(0.35), radius: 6, y: 2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Design.fill)
        )
        .animation(Design.spring, value: selection)
    }

    private func label(for mode: ANCMode) -> String {
        switch mode {
        case .noiseCancelling: return "Noise Cancel"
        case .off: return "Off"
        case .ambient: return "Ambient"
        }
    }
}

/// Horizontal level track with a soft gradient fill, draggable anywhere along
/// its length rather than only on a small knob.
struct LevelSlider: View {
    let value: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let span = Double(range.upperBound - range.lowerBound)
            let f = (Double(value - range.lowerBound) / span).clamped()
            let w = geo.size.width

            ZStack(alignment: .leading) {
                Capsule().fill(Design.fill)
                Capsule()
                    .fill(Design.accentGradient)
                    .frame(width: max(6, w * f))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: dragging ? 5 : 3, y: 1)
                    .frame(width: dragging ? 15 : 13, height: dragging ? 15 : 13)
                    .offset(x: max(0, w * f - (dragging ? 7.5 : 6.5)))
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { withAnimation(Design.quick) { dragging = true } }
                        let f = (g.location.x / max(w, 1)).clamped()
                        let v = range.lowerBound + Int((f * span).rounded())
                        if v != value { onChange(v) }
                    }
                    .onEnded { _ in withAnimation(Design.quick) { dragging = false } }
            )
        }
        .frame(height: 18)
        .animation(Design.quick, value: value)
    }
}

// MARK: - Equalizer

/// Vertical fader. Fills up or down from the centre detent so a flat EQ reads
/// as visually flat, and boosts/cuts are legible without reading numbers.
struct EQBand: View {
    let label: String
    let value: Int          // 0…20, 10 = flat
    let onChange: (Int) -> Void

    @State private var dragging = false
    private let height: CGFloat = 74

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let h = geo.size.height
                let mid = h / 2
                let f = Double(value - 10) / 10.0          // −1 … +1
                let barH = abs(f) * mid

                ZStack(alignment: .top) {
                    Capsule().fill(Design.fill)
                        .frame(width: 5)
                        .frame(maxWidth: .infinity)

                    // Centre detent
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 11, height: 1)
                        .offset(y: mid - 0.5)

                    Capsule()
                        .fill(Design.accentGradient)
                        .frame(width: 5, height: max(barH, f == 0 ? 0 : 3))
                        .frame(maxWidth: .infinity)
                        .offset(y: f >= 0 ? mid - barH : mid)

                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.28), radius: dragging ? 5 : 3, y: 1)
                        .frame(width: dragging ? 13 : 11, height: dragging ? 13 : 11)
                        .frame(maxWidth: .infinity)
                        .offset(y: mid - CGFloat(f) * mid - (dragging ? 6.5 : 5.5))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if !dragging { withAnimation(Design.quick) { dragging = true } }
                            let t = (1 - (g.location.y / max(h, 1))).clamped()
                            let v = Int((t * 20).rounded())
                            if v != value { onChange(v) }
                        }
                        .onEnded { _ in withAnimation(Design.quick) { dragging = false } }
                )
            }
            .frame(height: height)

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .animation(Design.quick, value: value)
    }
}

// MARK: - Modes

/// A mode tile. Selected state uses the accent fill; unselected stays neutral so
/// the active mode is unmistakable.
struct ModeChip: View {
    let mode: Mode
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 17)
                Text(mode.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(Design.accentGradient)
                                   : AnyShapeStyle(hovering ? Design.fillHover : Design.fill))
            )
            .shadow(color: isActive ? Design.accent.opacity(0.3) : .clear, radius: 7, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Design.quick) { hovering = h } }
        .animation(Design.spring, value: isActive)
    }
}

// MARK: - Helpers

extension Double {
    func clamped() -> Double { Swift.max(0, Swift.min(1, self)) }
}

extension CGFloat {
    func clamped() -> Double { Double(Swift.max(0, Swift.min(1, self))) }
}
