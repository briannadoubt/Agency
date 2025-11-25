import SwiftUI

enum CardDetailMode: String, CaseIterable, Identifiable {
    case view
    case form
    case raw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .view: return "View"
        case .form: return "Form"
        case .raw: return "Raw"
        }
    }

    var icon: String {
        switch self {
        case .view: return "eye"
        case .form: return "square.and.pencil"
        case .raw: return "chevron.left.slash.chevron.right"
        }
    }
}

struct CardDetailModal: View {
    let card: Card
    let phase: Phase

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode: CardDetailMode = .view
    @State private var snapshot: CardDocumentSnapshot?
    @State private var pendingRawSnapshot: CardDocumentSnapshot?
    @State private var formDraft = CardDetailFormDraft(title: "",
                                                       owner: "",
                                                       agentFlow: "",
                                                       agentStatus: "",
                                                       branch: "",
                                                       risk: "",
                                                       review: "",
                                                       parallelizable: false,
                                                       summary: "",
                                                       notes: "",
                                                       criteria: [],
                                                       history: [],
                                                       newHistoryEntry: CardDetailFormDraft.defaultHistoryPrefix(on: Date()))
    @State private var rawDraft = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var appendHistory = false
    @State private var skipRawRefreshOnce = false

    private let writer = CardMarkdownWriter()

    var body: some View {
        VStack(spacing: 0) {
            header
            modePicker

            Group {
                if isLoading {
                    ProgressView("Loading card…")
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, DesignTokens.Spacing.large)
            .padding(.bottom, DesignTokens.Spacing.large)
            .background(DesignTokens.Colors.canvas)
            .animation(DesignTokens.Motion.enabled(DesignTokens.Motion.modal, reduceMotion: reduceMotion), value: mode)

            footer
        }
        .frame(minWidth: 860, minHeight: 640)
        .task {
            await loadSnapshot()
        }
        .onChange(of: mode) { oldValue, newValue in
            syncDraftsForModeChange(from: oldValue, to: newValue)
        }
        .alert("Problem", isPresented: Binding(get: { errorMessage != nil }, set: { value in
            if !value { errorMessage = nil }
        })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(spacing: DesignTokens.Spacing.small) {
                Text(card.code)
                    .font(DesignTokens.Typography.code)
                    .padding(.horizontal, DesignTokens.Spacing.small)
                    .padding(.vertical, DesignTokens.Spacing.grid)
                    .background(Capsule().fill(DesignTokens.Colors.stroke.opacity(0.5)))

                Text(card.filePath.lastPathComponent)
                    .font(DesignTokens.Typography.caption.weight(.semibold))
                    .padding(.horizontal, DesignTokens.Spacing.small)
                    .padding(.vertical, DesignTokens.Spacing.grid)
                    .background(Capsule().fill(DesignTokens.Colors.surface))
                    .overlay(Capsule().stroke(DesignTokens.Colors.stroke, lineWidth: 1))

                Spacer()

                Label("Phase \(phase.number): \(phase.label)", systemImage: "flag")
                    .font(DesignTokens.Typography.caption)
                    .badgeStyle(DesignTokens.Badges.info(for: colorScheme))

                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)
            }

            Text(card.slug.replacingOccurrences(of: "-", with: " ").capitalized)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .padding(DesignTokens.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .bottom)
    }

    private var modePicker: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Picker("Mode", selection: $mode) {
                ForEach(CardDetailMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            Spacer()

            Toggle("Add history on save", isOn: $appendHistory)
                .toggleStyle(.switch)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.large)
        .padding(.vertical, DesignTokens.Spacing.medium)
        .background(DesignTokens.Colors.surface)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .view:
            CardViewMode(formDraft: formDraft, phase: phase)
        case .form:
            CardFormMode(formDraft: $formDraft)
        case .raw:
            CardRawMode(rawText: $rawDraft)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: DesignTokens.Spacing.small) {
                if mode == .view {
                    Button {
                        mode = .form
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") {
                        resetDraftsFromSnapshot()
                        mode = .view
                    }
                    .keyboardShortcut(.cancelAction)

                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Label("Save", systemImage: "tray.and.arrow.down")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(DesignTokens.Spacing.large)
            .background(.ultraThinMaterial)
        }
    }

    private func loadSnapshot() async {
        do {
            let loaded = try writer.loadSnapshot(for: card)
            await MainActor.run {
                snapshot = loaded
                pendingRawSnapshot = nil
                formDraft = CardDetailFormDraft.from(card: loaded.card)
                rawDraft = loaded.contents
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func syncDraftsForModeChange(from old: CardDetailMode, to new: CardDetailMode) {
        guard snapshot != nil else { return }

        if old != .raw && new == .raw {
            if skipRawRefreshOnce {
                skipRawRefreshOnce = false
                return
            }

            let baseline = pendingRawSnapshot ?? snapshot
            guard let baseline else { return }

            rawDraft = writer.renderMarkdown(from: formDraft,
                                             basedOn: baseline.card,
                                             existingContents: baseline.contents,
                                             appendHistory: false)
        }

        if old == .raw && (new == .form || new == .view) {
            do {
                let priorHistoryEntry = formDraft.newHistoryEntry
                let parsedCard = try writer.formDraft(fromRaw: rawDraft, fileURL: snapshot!.card.filePath)
                // Preserve transient fields not represented in markdown.
                formDraft = parsedCard
                formDraft.newHistoryEntry = priorHistoryEntry
                let parsed = try CardFileParser().parse(fileURL: snapshot!.card.filePath, contents: rawDraft)
                pendingRawSnapshot = CardDocumentSnapshot(card: parsed,
                                                           contents: rawDraft,
                                                           modifiedAt: snapshot!.modifiedAt)
            } catch {
                errorMessage = error.localizedDescription
                mode = .raw
                skipRawRefreshOnce = true
            }
        }
    }

    private func resetDraftsFromSnapshot() {
        guard let snapshot else { return }
        formDraft = CardDetailFormDraft.from(card: snapshot.card)
        rawDraft = snapshot.contents
        pendingRawSnapshot = nil
    }

    private func appendHistoryIfNeeded(to raw: String) -> String {
        guard appendHistory,
              let entry = CardDetailFormDraft.normalizedHistoryEntry(formDraft.newHistoryEntry) else { return raw }

        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var didAppend = false
        var inHistory = false

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "History:" {
                inHistory = true
                output.append(line)
                continue
            }

            if inHistory {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix(":") && !trimmed.hasPrefix("-") {
                    // Next section begins; insert before leaving history.
                    if !didAppend {
                        output.append("- \(entry)")
                        didAppend = true
                    }
                    inHistory = false
                }
            }

            output.append(line)
        }

        if inHistory && !didAppend {
            output.append("- \(entry)")
            didAppend = true
        }

        if !didAppend {
            // No History section found; append a new one.
            output.append("")
            output.append("History:")
            output.append("- \(entry)")
        }

        return output.joined(separator: "\n")
    }

    @MainActor
    private func save() async {
        guard let snapshot else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let updated: CardDocumentSnapshot
            switch mode {
            case .form:
                // TODO(Phase2): Route form saves through shared editing pipeline once the Phase 2 editor is available.
                let mergeBaseline = pendingRawSnapshot ?? snapshot
                let merged = writer.renderMarkdown(from: formDraft,
                                                   basedOn: mergeBaseline.card,
                                                   existingContents: mergeBaseline.contents,
                                                   appendHistory: appendHistory)
                updated = try writer.saveMergedContents(merged, snapshot: snapshot)
            case .raw:
                // TODO(Phase2): Enforce schema validation before raw saves when collaborative editing lands.
                let mergedRaw = appendHistoryIfNeeded(to: rawDraft)
                updated = try writer.saveRaw(mergedRaw, snapshot: snapshot)
            case .view:
                return
            }

            self.snapshot = updated
            pendingRawSnapshot = nil
            formDraft = CardDetailFormDraft.from(card: updated.card)
            rawDraft = updated.contents
            appendHistory = false
            mode = .view
        } catch let error as CardSaveError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CardViewMode: View {
    let formDraft: CardDetailFormDraft
    let phase: Phase

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
                MetadataGrid(formDraft: formDraft, phase: phase)
                SummaryBlock(summary: formDraft.summary)
                CriteriaList(criteria: formDraft.criteria, accentColor: accentColor)
                NotesBlock(notes: formDraft.notes, accentColor: accentColor)
                HistoryTimeline(history: formDraft.history, accentColor: accentColor)
            }
        }
    }

    private var accentColor: Color {
        DesignTokens.Colors.preferredAccent(for: colorScheme)
    }
}

private struct CardFormMode: View {
    @Binding var formDraft: CardDetailFormDraft

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
                GroupBox(label: Label("Metadata", systemImage: "info.circle")) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        TextField("Title", text: $formDraft.title)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: DesignTokens.Spacing.medium) {
                            TextField("Owner", text: $formDraft.owner)
                            TextField("Branch", text: $formDraft.branch)
                        }
                        .textFieldStyle(.roundedBorder)

                        HStack(spacing: DesignTokens.Spacing.medium) {
                            TextField("Agent flow", text: $formDraft.agentFlow)
                            TextField("Agent status", text: $formDraft.agentStatus)
                        }
                        .textFieldStyle(.roundedBorder)

                        HStack(spacing: DesignTokens.Spacing.medium) {
                            TextField("Risk", text: $formDraft.risk)
                            TextField("Review", text: $formDraft.review)
                        }
                        .textFieldStyle(.roundedBorder)

                        Toggle("Parallelizable", isOn: $formDraft.parallelizable)
                    }
                }

                GroupBox(label: Label("Summary", systemImage: "text.justify")) {
                    TextEditor(text: $formDraft.summary)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                            .fill(DesignTokens.Colors.card))
                        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                            .stroke(DesignTokens.Colors.stroke, lineWidth: 1))
                }

                GroupBox(label: Label("Acceptance Criteria", systemImage: "checkmark.circle")) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                        ForEach($formDraft.criteria) { $criterion in
                            HStack {
                                Toggle(isOn: $criterion.isComplete) {
                                    TextField("Criterion", text: $criterion.title)
                                }
                                .toggleStyle(.checkbox)

                                Button {
                                    formDraft.criteria.removeAll { $0.id == criterion.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete criterion")
                            }
                        }

                        Button {
                            formDraft.criteria.append(.init(title: "New criterion", isComplete: false))
                        } label: {
                            Label("Add criterion", systemImage: "plus")
                        }
                    }
                }

                GroupBox(label: Label("Notes", systemImage: "note.text")) {
                    TextEditor(text: $formDraft.notes)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                            .fill(DesignTokens.Colors.card))
                        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                            .stroke(DesignTokens.Colors.stroke, lineWidth: 1))
                }

                GroupBox(label: Label("History", systemImage: "clock.arrow.circlepath")) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                        ForEach(Array(formDraft.history.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                        }

                        HStack(spacing: DesignTokens.Spacing.small) {
                            TextField("Add entry", text: $formDraft.newHistoryEntry)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                formDraft.appendHistoryIfNeeded()
                            } label: {
                                Label("Add", systemImage: "plus")
                            }
                        }
                        .padding(.top, DesignTokens.Spacing.small)
                    }
                }
            }
            .padding(.vertical, DesignTokens.Spacing.large)
        }
    }
}

private struct CardRawMode: View {
    @Binding var rawText: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Editing raw markdown bypasses validation. Save carefully.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                .fill(DesignTokens.Colors.surface))

            TextEditor(text: $rawText)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                    .fill(DesignTokens.Colors.card))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                    .stroke(DesignTokens.Colors.stroke, lineWidth: 1))
        }
        .padding(.vertical, DesignTokens.Spacing.large)
    }
}

private struct MetadataGrid: View {
    let formDraft: CardDetailFormDraft
    let phase: Phase

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: verticalSpacing) {
            Text("Metadata")
                .font(DesignTokens.Typography.headline)

            LazyVGrid(columns: columns, spacing: verticalSpacing) {
                metadataCell(label: "Owner", value: formDraft.owner)
                metadataCell(label: "Branch", value: formDraft.branch)
                metadataCell(label: "Agent Flow", value: formDraft.agentFlow)
                metadataCell(label: "Agent Status", value: formDraft.agentStatus)
                metadataCell(label: "Risk", value: formDraft.risk)
                metadataCell(label: "Review", value: formDraft.review)
                metadataCell(label: "Parallelizable", value: formDraft.parallelizable ? "Yes" : "No")
                metadataCell(label: "Phase", value: "\(phase.number) · \(phase.label)")
            }
        }
        .padding()
        .surfaceStyle(DesignTokens.Surfaces.card())
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilityCategory {
            return [GridItem(.flexible())]
        }
        return [GridItem(.flexible()), GridItem(.flexible())]
    }

    private var verticalSpacing: CGFloat {
        dynamicTypeSize.isAccessibilityCategory ?
            DesignTokens.Accessibility.scaledSpacing(DesignTokens.Spacing.small) :
            DesignTokens.Spacing.small
    }

    private func metadataCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Text(value.isEmpty ? "—" : value)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.small)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
            .fill(DesignTokens.Colors.surface))
    }
}

private struct SummaryBlock: View {
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text("Summary")
                .font(DesignTokens.Typography.headline)
            Text(summary.isEmpty ? "No summary provided." : summary)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(summary.isEmpty ? DesignTokens.Colors.textMuted : DesignTokens.Colors.textPrimary)
        }
        .padding()
        .surfaceStyle(DesignTokens.Surfaces.card())
    }
}

private struct CriteriaList: View {
    let criteria: [CardDetailFormDraft.Criterion]
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text("Acceptance Criteria")
                .font(DesignTokens.Typography.headline)

            if criteria.isEmpty {
                Text("No criteria yet.")
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.grid) {
                    ForEach(criteria) { criterion in
                        HStack(spacing: DesignTokens.Spacing.grid) {
                            Image(systemName: criterion.isComplete ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(criterion.isComplete ? accentColor : DesignTokens.Colors.textSecondary)
                            Text(criterion.title)
                                .strikethrough(criterion.isComplete)
                                .foregroundStyle(DesignTokens.Colors.textPrimary)
                        }
                    }
                }
            }
        }
        .padding()
        .surfaceStyle(DesignTokens.Surfaces.card())
    }
}

private struct NotesBlock: View {
    let notes: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text("Notes")
                .font(DesignTokens.Typography.headline)
            Text(notes.isEmpty ? "No notes yet." : notes)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(notes.isEmpty ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.textPrimary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                    .fill(accentColor.opacity(0.1)))
        }
        .padding()
        .surfaceStyle(DesignTokens.Surfaces.card())
    }
}

private struct HistoryTimeline: View {
    let history: [String]
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text("History")
                .font(DesignTokens.Typography.headline)

            if history.isEmpty {
                Text("No history entries yet.")
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                    ForEach(Array(history.enumerated()), id: \.offset) { index, entry in
                        HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                            Circle()
                                .fill(index == history.count - 1 ? accentColor : DesignTokens.Colors.stroke)
                                .frame(width: 10, height: 10)
                                .padding(.top, 3)
                            Text(entry)
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(DesignTokens.Colors.textPrimary)
                        }
                    }
                }
            }
        }
        .padding()
        .surfaceStyle(DesignTokens.Surfaces.card())
    }
}
