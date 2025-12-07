import SwiftUI

/// A view modifier that applies consistent surface styling with rounded corners and border.
/// Consolidates the common pattern of: `.background(RoundedRectangle(...).fill(...)).overlay(RoundedRectangle(...).stroke(...))`
struct SurfacePanel: ViewModifier {
    enum Style {
        case standard    // surface fill, strokeMuted border
        case raised      // surfaceRaised fill, stroke border
        case card        // card fill, strokeMuted border
    }

    let style: Style
    let radius: CGFloat

    init(style: Style = .standard, radius: CGFloat = DesignTokens.Radius.medium) {
        self.style = style
        self.radius = radius
    }

    private var fillColor: Color {
        switch style {
        case .standard:
            return DesignTokens.Colors.surface
        case .raised:
            return DesignTokens.Colors.surfaceRaised
        case .card:
            return DesignTokens.Colors.card
        }
    }

    private var strokeColor: Color {
        switch style {
        case .standard, .card:
            return DesignTokens.Colors.strokeMuted
        case .raised:
            return DesignTokens.Colors.stroke
        }
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }
}

extension View {
    /// Applies surface panel styling with a rounded background and border.
    /// - Parameters:
    ///   - style: The surface style to apply (standard, raised, or card)
    ///   - radius: The corner radius (defaults to DesignTokens.Radius.medium)
    func surfacePanel(style: SurfacePanel.Style = .standard, radius: CGFloat = DesignTokens.Radius.medium) -> some View {
        modifier(SurfacePanel(style: style, radius: radius))
    }
}
