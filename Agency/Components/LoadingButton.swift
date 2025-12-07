import SwiftUI

/// A button that displays a loading indicator while an async operation is in progress.
/// Consolidates the common pattern of toggling between ProgressView and Label.
struct LoadingButton<Label: View>: View {
    let isLoading: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(isLoading: Bool,
         action: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.isLoading = isLoading
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                label()
            }
        }
        .disabled(isLoading)
    }
}

/// Convenience initializers for common button styles
extension LoadingButton {
    /// Creates a loading button with a text label
    init(isLoading: Bool,
         title: String,
         action: @escaping () -> Void) where Label == Text {
        self.init(isLoading: isLoading, action: action) {
            Text(title)
        }
    }

    /// Creates a loading button with an icon and text label
    init(isLoading: Bool,
         title: String,
         systemImage: String,
         action: @escaping () -> Void) where Label == SwiftUI.Label<Text, Image> {
        self.init(isLoading: isLoading, action: action) {
            SwiftUI.Label(title, systemImage: systemImage)
        }
    }
}

/// Extension to apply common button styles
extension LoadingButton {
    func loadingButtonStyle(_ style: some PrimitiveButtonStyle) -> some View {
        self.buttonStyle(style)
    }
}
