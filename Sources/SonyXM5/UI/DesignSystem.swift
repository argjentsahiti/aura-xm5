import SwiftUI

/// Shared visual language. Kept deliberately small — a handful of tokens used
/// consistently reads as considered; a large palette reads as noise.
enum Design {
    static let panelWidth: CGFloat = 344
    static let corner: CGFloat = 22
    static let hPad: CGFloat = 20

    /// The one accent in the app. Everything else is monochrome so the accent
    /// only ever means "this is active".
    static let accent = Color(red: 0.29, green: 0.60, blue: 1.00)
    static let accentSoft = Color(red: 0.42, green: 0.72, blue: 1.00)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentSoft, accent],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let hairline = Color.primary.opacity(0.08)
    static let fill = Color.primary.opacity(0.06)
    static let fillHover = Color.primary.opacity(0.10)

    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.78)
    static let quick = Animation.spring(response: 0.24, dampingFraction: 0.85)
}

/// Small caps section header — the quiet structural element that lets the rest
/// of the panel stay uncluttered.
struct SectionLabel: View {
    let text: String
    var trailing: AnyView? = nil

    init(_ text: String) {
        self.text = text
        self.trailing = nil
    }

    init<T: View>(_ text: String, @ViewBuilder trailing: () -> T) {
        self.text = text
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
    }
}

/// A borderless text button that only reveals itself on hover — present when
/// you look for it, invisible when you don't.
struct QuietButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(Design.accent) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Design.quick) { hovering = h } }
    }
}

extension View {
    /// Fades and lifts content in as it appears — used for the sections that
    /// only exist in some states, so they arrive rather than pop.
    func revealTransition() -> some View {
        transition(
            .opacity.combined(with: .move(edge: .top))
                .combined(with: .scale(scale: 0.97, anchor: .top))
        )
    }
}
