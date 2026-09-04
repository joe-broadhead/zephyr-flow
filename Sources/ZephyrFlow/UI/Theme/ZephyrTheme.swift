import SwiftUI

/// Dark tech-space visual language for ZephyrFlow surfaces.
enum ZephyrTheme {
    // MARK: Palette
    static let bgDeep = Color(red: 0.04, green: 0.05, blue: 0.08)
    static let bgCard = Color(red: 0.09, green: 0.10, blue: 0.14)
    static let bgElevated = Color(red: 0.12, green: 0.13, blue: 0.18)
    static let border = Color.white.opacity(0.08)
    static let borderGlow = Color(red: 0.35, green: 0.85, blue: 0.95).opacity(0.35)

    static let cyan = Color(red: 0.30, green: 0.90, blue: 0.95)
    static let violet = Color(red: 0.55, green: 0.40, blue: 0.98)
    static let mint = Color(red: 0.35, green: 0.92, blue: 0.70)
    static let danger = Color(red: 1.0, green: 0.35, blue: 0.40)
    static let warning = Color(red: 1.0, green: 0.75, blue: 0.30)

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textMuted = Color.white.opacity(0.35)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [cyan, violet],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var panelGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.12, green: 0.14, blue: 0.20).opacity(0.94),
                Color(red: 0.06, green: 0.07, blue: 0.11).opacity(0.96),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let cornerLarge: CGFloat = 20
    static let cornerMedium: CGFloat = 14
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.78)
}

// MARK: - Shared chrome

struct ZephyrCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: ZephyrTheme.cornerMedium, style: .continuous)
            .fill(ZephyrTheme.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: ZephyrTheme.cornerMedium, style: .continuous)
                    .strokeBorder(ZephyrTheme.border, lineWidth: 1)
            )
    }
}

struct ZephyrPrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(enabled ? Color.black.opacity(0.9) : ZephyrTheme.textMuted)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        enabled
                            ? ZephyrTheme.brandGradient
                            : LinearGradient(
                                colors: [ZephyrTheme.bgElevated], startPoint: .leading, endPoint: .trailing))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct ZephyrSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(ZephyrTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(ZephyrTheme.bgElevated)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(ZephyrTheme.border, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Force dark appearance on a window-hosted SwiftUI tree.
struct ZephyrDarkChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(.dark)
            .background(ZephyrTheme.bgDeep.ignoresSafeArea())
            .tint(ZephyrTheme.cyan)
    }
}

extension View {
    func zephyrDarkChrome() -> some View {
        modifier(ZephyrDarkChrome())
    }
}
