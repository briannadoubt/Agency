import SwiftUI

/// A dismissible banner for displaying error, warning, or info messages.
/// Consolidates the common pattern of HStack with icon, message, and dismiss button.
struct DismissibleBanner: View {
    enum BannerStyle {
        case error
        case warning
        case info
        case success

        var iconName: String {
            switch self {
            case .error:
                return "exclamationmark.circle.fill"
            case .warning:
                return "exclamationmark.triangle.fill"
            case .info:
                return "info.circle.fill"
            case .success:
                return "checkmark.circle.fill"
            }
        }

        var iconColor: Color {
            switch self {
            case .error:
                return .red
            case .warning:
                return .yellow
            case .info:
                return .blue
            case .success:
                return .green
            }
        }
    }

    let message: String
    let style: BannerStyle
    let onDismiss: () -> Void
    var secondaryAction: (() -> Void)?
    var secondaryActionLabel: String?

    init(message: String,
         style: BannerStyle = .warning,
         onDismiss: @escaping () -> Void,
         secondaryAction: (() -> Void)? = nil,
         secondaryActionLabel: String? = nil) {
        self.message = message
        self.style = style
        self.onDismiss = onDismiss
        self.secondaryAction = secondaryAction
        self.secondaryActionLabel = secondaryActionLabel
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.small) {
            Image(systemName: style.iconName)
                .foregroundStyle(style.iconColor)

            Text(message)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Spacer()

            if let secondaryAction, let label = secondaryActionLabel {
                Button(label, action: secondaryAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding()
        .surfacePanel(style: .raised)
    }
}

/// Convenience initializer for error banners
extension DismissibleBanner {
    static func error(_ message: String, onDismiss: @escaping () -> Void) -> DismissibleBanner {
        DismissibleBanner(message: message, style: .error, onDismiss: onDismiss)
    }

    static func warning(_ message: String, onDismiss: @escaping () -> Void) -> DismissibleBanner {
        DismissibleBanner(message: message, style: .warning, onDismiss: onDismiss)
    }

    static func info(_ message: String, onDismiss: @escaping () -> Void) -> DismissibleBanner {
        DismissibleBanner(message: message, style: .info, onDismiss: onDismiss)
    }
}
