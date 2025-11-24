import SwiftUI

enum DesignTokens {
    enum Colors {
        static let canvas = named("Canvas")
        static let surface = named("Surface")
        static let surfaceRaised = named("SurfaceRaised")
        static let card = named("Card")
        static let accent = named("Accent")
        static let accentMuted = named("AccentMuted")
        static let stroke = named("Stroke")
        static let strokeMuted = named("StrokeMuted")
        static let textPrimary = named("TextPrimary")
        static let textSecondary = named("TextSecondary")
        static let textMuted = named("TextMuted")

        static let riskLow = BadgePalette(foreground: named("RiskLowForeground"), background: named("RiskLowBackground"))
        static let riskMedium = BadgePalette(foreground: named("RiskMediumForeground"), background: named("RiskMediumBackground"))
        static let riskHigh = BadgePalette(foreground: named("RiskHighForeground"), background: named("RiskHighBackground"))

        private static func named(_ name: String) -> Color {
            Color(name, bundle: .main)
        }
    }

    enum Typography {
        static let titleLarge = Font.system(size: 24, weight: .semibold, design: .rounded)
        static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let headline = Font.system(size: 17, weight: .semibold, design: .rounded)
        static let body = Font.system(size: 15, weight: .regular, design: .rounded)
        static let caption = Font.system(size: 13, weight: .regular, design: .rounded)
        static let code = Font.system(size: 13, weight: .semibold, design: .monospaced)
    }

    enum Spacing {
        static let grid: CGFloat = 4
        static let xSmall: CGFloat = grid * 2   // 8pt — tight label rows
        static let small: CGFloat = grid * 3    // 12pt — compact padding
        static let medium: CGFloat = grid * 4   // 16pt — default padding/spacing
        static let large: CGFloat = grid * 6    // 24pt — section separation
        static let xLarge: CGFloat = grid * 8   // 32pt — outer gutters
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 10
        static let large: CGFloat = 12
        static let pill: CGFloat = 999
    }

    enum Shadows {
        static let card = ShadowStyle(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 6)
        static let raised = ShadowStyle(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 10)
        static let focus = ShadowStyle(color: Colors.accent.opacity(0.35), radius: 10, x: 0, y: 0)
    }

    enum Badges {
        static let neutral = BadgeStyle(foreground: Colors.textSecondary, background: Colors.stroke)
        static let info = BadgeStyle(foreground: Colors.accent, background: Colors.accent.opacity(0.2))
        static let lowRisk = BadgeStyle(foreground: Colors.riskLow.foreground, background: Colors.riskLow.background)
        static let mediumRisk = BadgeStyle(foreground: Colors.riskMedium.foreground, background: Colors.riskMedium.background)
        static let highRisk = BadgeStyle(foreground: Colors.riskHigh.foreground, background: Colors.riskHigh.background)
    }

    enum Accessibility {
        static let minimumHitTarget: CGFloat = 44
        static let spacingScale: CGFloat = 1.2  // use for reduced-density alternatives
        static let focusRingWidth: CGFloat = 2

        static func scaledSpacing(_ base: CGFloat) -> CGFloat {
            base * spacingScale
        }
    }
}

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

struct BadgeStyle {
    let foreground: Color
    let background: Color
}

struct BadgePalette {
    let foreground: Color
    let background: Color
}

extension View {
    func tokenShadow(_ style: ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }

    func badgeStyle(_ badge: BadgeStyle) -> some View {
        foregroundStyle(badge.foreground)
            .padding(.horizontal, DesignTokens.Spacing.xSmall)
            .padding(.vertical, DesignTokens.Spacing.grid)
            .background(
                Capsule()
                    .fill(badge.background)
            )
    }
}

#Preview("Tokens Overview") {
    ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Text("Design Tokens")
                    .font(DesignTokens.Typography.titleLarge)
                Text("Colors, typography, spacing grid, radii, shadows, and badges in a single source of truth.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                colorSwatch(title: "Canvas", color: DesignTokens.Colors.canvas)
                colorSwatch(title: "Surface", color: DesignTokens.Colors.surface)
                colorSwatch(title: "Card", color: DesignTokens.Colors.card)
                colorSwatch(title: "Accent", color: DesignTokens.Colors.accent)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Text("Typography")
                    .font(DesignTokens.Typography.title)
                Text("Headline")
                    .font(DesignTokens.Typography.headline)
                Text("Body text for details and secondary labels.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Text("CODE-MONO")
                    .font(DesignTokens.Typography.code)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Text("Badges")
                    .font(DesignTokens.Typography.title)
                HStack(spacing: DesignTokens.Spacing.small) {
                    Text("low").badgeStyle(DesignTokens.Badges.lowRisk)
                    Text("medium").badgeStyle(DesignTokens.Badges.mediumRisk)
                    Text("high").badgeStyle(DesignTokens.Badges.highRisk)
                    Text("info").badgeStyle(DesignTokens.Badges.info)
                }
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Text("Spacing Grid")
                    .font(DesignTokens.Typography.title)
                HStack(spacing: DesignTokens.Spacing.grid) {
                    spacingBar(label: "xs", width: DesignTokens.Spacing.xSmall)
                    spacingBar(label: "sm", width: DesignTokens.Spacing.small)
                    spacingBar(label: "md", width: DesignTokens.Spacing.medium)
                    spacingBar(label: "lg", width: DesignTokens.Spacing.large)
                    spacingBar(label: "xl", width: DesignTokens.Spacing.xLarge)
                }
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Text("Shadows")
                    .font(DesignTokens.Typography.title)
                HStack(spacing: DesignTokens.Spacing.medium) {
                    shadowCard(title: "Card", shadow: DesignTokens.Shadows.card)
                    shadowCard(title: "Raised", shadow: DesignTokens.Shadows.raised)
                }
            }
        }
        .padding(DesignTokens.Spacing.xLarge)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(DesignTokens.Colors.canvas)
}

private func colorSwatch(title: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.grid) {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
            .fill(color)
            .frame(width: 80, height: 60)
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium).stroke(DesignTokens.Colors.stroke, lineWidth: 1))
        Text(title)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
    }
}

private func spacingBar(label: String, width: CGFloat) -> some View {
    VStack(spacing: DesignTokens.Spacing.grid) {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
            .fill(DesignTokens.Colors.accent.opacity(0.5))
            .frame(width: width, height: 8)
        Text(label)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textMuted)
    }
}

private func shadowCard(title: String, shadow: ShadowStyle) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.grid) {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
            .fill(DesignTokens.Colors.card)
            .frame(width: 120, height: 70)
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium).stroke(DesignTokens.Colors.stroke, lineWidth: 1))
            .tokenShadow(shadow)
        Text(title)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
    }
}
