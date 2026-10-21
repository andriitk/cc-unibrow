import SwiftUI

/// Compact capsule buttons sized for the island.
struct PillButtonStyle: ButtonStyle {
    enum Kind {
        case primary, secondary, destructive, quiet
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        PillButton(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static func pill(_ kind: PillButtonStyle.Kind) -> PillButtonStyle {
        PillButtonStyle(kind: kind)
    }
}

/// A view (not the style itself) so it can own hover state.
private struct PillButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind

    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .quiet ? 8 : 12)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
            .contentShape(Capsule())
            .brightness(isHovered ? 0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .black
        case .secondary: .white
        case .destructive: Color(red: 1, green: 0.45, blue: 0.42)
        case .quiet: .white.opacity(isHovered ? 0.85 : 0.55)
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Color(red: 0.3, green: 0.85, blue: 0.45)
        case .secondary: .white.opacity(0.14)
        case .destructive: Color(red: 1, green: 0.3, blue: 0.28).opacity(0.18)
        case .quiet: .clear
        }
    }
}
