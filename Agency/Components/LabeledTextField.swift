import SwiftUI

/// A text field with a caption label and consistent styling.
/// Consolidates the common pattern of VStack with label, TextField, and rounded border.
struct LabeledTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var focusedField: FocusState<Bool>.Binding?

    init(_ label: String,
         placeholder: String,
         text: Binding<String>,
         focused: FocusState<Bool>.Binding? = nil) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.focusedField = focused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
            Text(label)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            if let focusedField {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused(focusedField)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

/// A multiline text editor with a caption label and consistent styling.
/// Consolidates the common pattern of VStack with label, TextEditor, and custom background.
struct LabeledTextEditor: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat

    init(_ label: String,
         placeholder: String,
         text: Binding<String>,
         minHeight: CGFloat = 96) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.minHeight = minHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
            Text(label)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Colors.textMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                }

                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .font(DesignTokens.Typography.body)
            }
            .frame(minHeight: minHeight)
            .padding(DesignTokens.Spacing.xSmall)
            .surfacePanel(style: .card, radius: DesignTokens.Radius.small)
        }
    }
}
