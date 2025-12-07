import SwiftUI

/// A capsule-shaped badge for displaying counts, codes, or metadata.
/// Consolidates the common pattern of Text with capsule background and padding.
struct BadgePill: View {
    let text: String
    var font: Font
    var foregroundColor: Color
    var backgroundColor: Color

    init(_ text: String,
         font: Font = DesignTokens.Typography.caption.weight(.bold),
         foregroundColor: Color = DesignTokens.Colors.textPrimary,
         backgroundColor: Color = DesignTokens.Colors.stroke.opacity(0.35)) {
        self.text = text
        self.font = font
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, DesignTokens.Spacing.xSmall)
            .padding(.vertical, DesignTokens.Spacing.grid)
            .background(Capsule().fill(backgroundColor))
    }
}

/// Extension for common badge styles
extension BadgePill {
    /// Creates a count badge (e.g., "12" for card counts)
    static func count(_ value: Int, accent: Color) -> BadgePill {
        BadgePill(
            "\(value)",
            font: DesignTokens.Typography.caption.weight(.bold),
            foregroundColor: DesignTokens.Colors.textPrimary,
            backgroundColor: accent.opacity(0.14)
        )
    }

    /// Creates a code badge (e.g., "1.3" for card codes)
    static func code(_ text: String) -> BadgePill {
        BadgePill(
            text,
            font: DesignTokens.Typography.code,
            foregroundColor: DesignTokens.Colors.textPrimary,
            backgroundColor: DesignTokens.Colors.stroke.opacity(0.55)
        )
    }

    /// Creates an emphasized badge for metadata (e.g., owner, risk)
    static func metadata(_ text: String, emphasized: Bool = false, colorScheme: ColorScheme) -> BadgePill {
        let bgColor = emphasized
            ? DesignTokens.Colors.preferredAccent(for: colorScheme).opacity(0.18)
            : DesignTokens.Colors.stroke.opacity(0.35)
        return BadgePill(
            text,
            font: DesignTokens.Typography.caption,
            foregroundColor: DesignTokens.Colors.textPrimary,
            backgroundColor: bgColor
        )
    }
}
