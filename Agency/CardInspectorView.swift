import SwiftUI
import AppKit

struct CardInspectorDraft: Equatable {
    struct CriterionDraft: Identifiable, Equatable {
        let id: UUID
        var title: String
        var isComplete: Bool

        init(id: UUID = UUID(), title: String, isComplete: Bool) {
            self.id = id
            self.title = title
            self.isComplete = isComplete
        }
    }

    var title: String
    var summary: String
    var notes: String
    var acceptanceCriteria: [CriterionDraft]

    static let empty = CardInspectorDraft(title: "",
                                          summary: "",
                                          notes: "",
                                          acceptanceCriteria: [])

    init(title: String, summary: String, notes: String, acceptanceCriteria: [CriterionDraft]) {
        self.title = title
        self.summary = summary
        self.notes = notes
        self.acceptanceCriteria = acceptanceCriteria
    }

    init(card: Card) {
        self.init(title: card.title ?? "",
                  summary: card.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                  notes: card.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                  acceptanceCriteria: card.acceptanceCriteria.map { CriterionDraft(title: $0.title, isComplete: $0.isComplete) })
    }
}

struct CardInspector: View {
    let card: Card?
    @Binding var draft: CardInspectorDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Card Inspector")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Spacer()
                Button {
                    if let card {
                        openInEditor(card)
                    }
                } label: {
                    Label("Open in Editor", systemImage: "arrow.up.forward.app")
                }
                .disabled(card == nil)
            }

            if let card {
                CardInspectorContent(card: card, draft: $draft)
            } else {
                Text("Select a card to see its summary, acceptance criteria, and notes.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .surfaceStyle(DesignTokens.Surfaces.panel)
    }

    private func openInEditor(_ card: Card) {
        NSWorkspace.shared.open(card.filePath.standardizedFileURL)
    }
}

private struct CardInspectorContent: View {
    let card: Card
    @Binding var draft: CardInspectorDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title ?? "Untitled Card")
                    .font(DesignTokens.Typography.headline)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text(card.code)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            LabeledField(title: "Title") {
                TextField("Title", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
            }
            .disabled(true)

            LabeledTextEditor(title: "Summary",
                              text: $draft.summary,
                              placeholder: "No summary provided.")
            .disabled(true)

            AcceptanceCriteriaList(criteria: $draft.acceptanceCriteria)
                .disabled(true)

            LabeledTextEditor(title: "Notes",
                              text: $draft.notes,
                              placeholder: "No notes yet.")
            .disabled(true)
        }
    }
}

private struct AcceptanceCriteriaList: View {
    @Binding var criteria: [CardInspectorDraft.CriterionDraft]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
                Text("Acceptance Criteria")
                    .font(DesignTokens.Typography.headline)

            if criteria.isEmpty {
                Text("No acceptance criteria yet.")
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            } else {
                ForEach($criteria) { $criterion in
                    Toggle(isOn: $criterion.isComplete) {
                        TextField("Criterion", text: $criterion.title)
                            .textFieldStyle(.roundedBorder)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }
}

private struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DesignTokens.Typography.headline)
            content()
        }
    }
}

private struct LabeledTextEditor: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DesignTokens.Typography.headline)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(DesignTokens.Colors.card))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(DesignTokens.Colors.stroke, lineWidth: 1))

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(placeholder)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
