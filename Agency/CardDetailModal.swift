import SwiftUI
import AppKit

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
    @Environment(AgentRunner.self) private var agentRunner
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
                                                       newHistoryEntry: CardDetailFormDraft.defaultHistoryPrefix(on: Date()),
                                                       hadFrontmatter: false)
    @State private var rawDraft = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var appendHistory = false
    @State private var skipRawRefreshOnce = false
    @State private var selectedFlow: AgentFlow = .implement
    @State private var agentError: String?
    @State private var externalChangePending = false
    @State private var chatFilter: AgentChatMessage.Role?

    private let pipeline = CardEditingPipeline.shared
    private let branchHelper = BranchHelper()

    @State private var branchPrefix = "implement"
    @State private var branchStatusMessage: String?
    @State private var isApplyingBranch = false

    private var hasUnsavedChanges: Bool {
        guard let snapshot else { return false }

        if pendingRawSnapshot != nil {
            return true
        }

        switch mode {
        case .raw:
            let mergedRaw = appendHistoryIfNeeded(to: rawDraft)
            return mergedRaw != snapshot.contents
        case .view, .form:
            let rendered = CardMarkdownWriter().renderMarkdown(from: formDraft,
                                                               basedOn: snapshot.card,
                                                               existingContents: snapshot.contents,
                                                               appendHistory: appendHistory)
            return rendered != snapshot.contents
        }
    }

    private var recommendedBranch: String {
        branchHelper.recommendedBranch(for: snapshot?.card ?? card, prefix: branchPrefix)
    }

    private var checkoutCommand: String {
        branchHelper.checkoutCommand(for: recommendedBranch)
    }

    private var currentCard: Card {
        snapshot?.card ?? card
    }

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
                    VStack(spacing: DesignTokens.Spacing.medium) {
                        if let errorMessage {
                            InlineErrorBanner(message: errorMessage) {
                                self.errorMessage = nil
                            }
                        }

                        if externalChangePending {
                            ExternalChangeBanner(onReload: {
                                Task { await reloadFromDisk() }
                            }, onDismiss: {
                                externalChangePending = false
                            })
                        }

                        content
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, DesignTokens.Spacing.large)
            .padding(.bottom, DesignTokens.Spacing.large)
            .background(DesignTokens.Colors.canvas)
            .animation(DesignTokens.Motion.enabled(DesignTokens.Motion.modal, reduceMotion: reduceMotion), value: mode)

            footer
        }
        .frame(minWidth: 1300,
               idealWidth: 1400,
               maxWidth: .infinity,
               minHeight: 900,
               idealHeight: 1000,
               maxHeight: .infinity)
        .task {
            await loadSnapshot()
            CardUserActivity.donate(for: card, phase: phase)
        }
        .onChange(of: card) { _, _ in
            Task { await handleExternalCardUpdate() }
        }
        .alert("Agent error", isPresented: Binding(get: { agentError != nil }, set: { newValue in
            if !newValue { agentError = nil }
        })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(agentError ?? "")
        }
        .onChange(of: mode) { oldValue, newValue in
            syncDraftsForModeChange(from: oldValue, to: newValue)
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
            CardViewMode(card: currentCard,
                         formDraft: $formDraft,
                         phase: phase,
                         branchPrefix: $branchPrefix,
                         recommendedBranch: recommendedBranch,
                         checkoutCommand: checkoutCommand,
                         branchStatusMessage: branchStatusMessage,
                         isApplyingBranch: isApplyingBranch,
                         onCopyBranch: { copyBranchToPasteboard(recommendedBranch) },
                         onCopyCommand: { copyCheckoutCommand() },
                         onApplyBranch: { Task { await applyRecommendedBranch() } },
                         agentControls: agentControls,
                         chatFilter: $chatFilter)
        case .form:
            CardFormMode(formDraft: $formDraft)
        case .raw:
            CardRawMode(rawText: $rawDraft)
        }
    }

    @ViewBuilder
    private var agentControls: some View {
        AgentControlPanel(card: currentCard,
                          selectedFlow: $selectedFlow,
                          agentError: $agentError,
                          onRun: { flow in
                              await handleRun(flow: flow)
                          },
                          onCancel: { runID in
                              agentRunner.cancel(runID: runID)
                          },
                          onReset: {
                              await handleReset()
                          })
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: DesignTokens.Spacing.small) {
                if mode == .view {
                    Button {
                        resetDraftsFromSnapshot()
                    } label: {
                        Label("Revert Changes", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!hasUnsavedChanges)

                    Button {
                        mode = .form
                    } label: {
                        Label("Open Form", systemImage: "slider.horizontal.3")
                    }
                } else {
                    Button("Cancel") {
                        resetDraftsFromSnapshot()
                        mode = .view
                    }
                    .keyboardShortcut(.cancelAction)
                }

                Button {
                    Task { await reloadFromDisk() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(isSaving)

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
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !hasUnsavedChanges)

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
        await MainActor.run {
            isLoading = true
        }
        do {
            let loaded = try pipeline.loadSnapshot(for: card)
            await MainActor.run {
                errorMessage = nil
                snapshot = loaded
                pendingRawSnapshot = nil
                formDraft = CardDetailFormDraft.from(card: loaded.card)
                let preferredPrefix = formDraft.agentFlow.isFrontmatterEmpty ? "implement" : formDraft.agentFlow
                branchPrefix = BranchHelper.normalizeSegment(preferredPrefix, fallback: "implement")
                branchStatusMessage = nil
                rawDraft = loaded.contents
                selectedFlow = AgentFlow(rawValue: formDraft.agentFlow.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .implement
                isLoading = false
                externalChangePending = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func handleExternalCardUpdate() async {
        if hasUnsavedChanges {
            await MainActor.run {
                externalChangePending = true
            }
            return
        }

        await loadSnapshot()
    }

    private func reloadFromDisk() async {
        await loadSnapshot()
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

            rawDraft = CardMarkdownWriter().renderMarkdown(from: formDraft,
                                                           basedOn: baseline.card,
                                                           existingContents: baseline.contents,
                                                           appendHistory: false)
        }

        if old == .raw && (new == .form || new == .view) {
            do {
                let priorHistoryEntry = formDraft.newHistoryEntry
                let parsedCard = try CardMarkdownWriter().formDraft(fromRaw: rawDraft, fileURL: snapshot!.card.filePath)
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
        appendHistory = false
        errorMessage = nil
        let preferredPrefix = formDraft.agentFlow.isFrontmatterEmpty ? "implement" : formDraft.agentFlow
        branchPrefix = BranchHelper.normalizeSegment(preferredPrefix, fallback: "implement")
        branchStatusMessage = nil
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
    private func copyBranchToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        branchStatusMessage = "Copied \(value) to the clipboard."
    }

    @MainActor
    private func copyCheckoutCommand() {
        copyBranchToPasteboard(checkoutCommand)
    }

    private func handleRun(flow: AgentFlow) async {
        let backend: AgentBackendKind = (flow == .plan) ? .cli : .codex
        let result = await agentRunner.startRun(card: currentCard, flow: flow, backend: backend)
        await MainActor.run {
            switch result {
            case .success:
                agentError = nil
                selectedFlow = flow
            case .failure(let error):
                agentError = error.localizedDescription
            }
        }
    }

    private func handleReset() async {
        let result = await agentRunner.resetAgentState(for: currentCard)
        await MainActor.run {
            if case .failure(let error) = result {
                agentError = error.localizedDescription
            } else {
                agentError = nil
            }
        }
    }

    @MainActor
    private func applyRecommendedBranch() async {
        guard let snapshot else {
            branchStatusMessage = "Load a card before applying a branch."
            return
        }

        isApplyingBranch = true
        defer { isApplyingBranch = false }

        let baseline = pendingRawSnapshot ?? snapshot
        var draft = formDraft
        let branch = recommendedBranch
        let existing = baseline.card.frontmatter.branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldAppendHistory = existing != branch

        draft.branch = branch
        if shouldAppendHistory {
            draft.newHistoryEntry = BranchHelper.historyEntry(branch: branch, date: Date())
        }

        let rendered = CardMarkdownWriter().renderMarkdown(from: draft,
                                                           basedOn: baseline.card,
                                                           existingContents: baseline.contents,
                                                           appendHistory: shouldAppendHistory)

        do {
            let updated = try pipeline.saveRaw(rendered, snapshot: snapshot)
            self.snapshot = updated
            pendingRawSnapshot = nil
            formDraft = CardDetailFormDraft.from(card: updated.card)
            rawDraft = updated.contents
            appendHistory = false
            branchStatusMessage = shouldAppendHistory ? "Applied \(branch) to frontmatter." : "Branch already set to \(branch)."
        } catch let error as CardSaveError {
            branchStatusMessage = error.localizedDescription
        } catch {
            branchStatusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard let snapshot else { return }
        guard hasUnsavedChanges else {
            mode = .view
            return
        }
        isSaving = true
        defer { isSaving = false }

        do {
            let updated: CardDocumentSnapshot
            switch mode {
            case .form, .view:
                let mergeBaseline = pendingRawSnapshot ?? snapshot
                let merged = CardMarkdownWriter().renderMarkdown(from: formDraft,
                                                                  basedOn: mergeBaseline.card,
                                                                  existingContents: mergeBaseline.contents,
                                                                  appendHistory: appendHistory)

                // Preserve pending raw edits by merging against the pending baseline, then write using the
                // original snapshot for conflict detection.
                updated = try pipeline.saveRaw(merged, snapshot: snapshot)
            case .raw:
                let mergedRaw = appendHistoryIfNeeded(to: rawDraft)
                updated = try pipeline.saveRaw(mergedRaw, snapshot: snapshot)
            }

            self.snapshot = updated
            pendingRawSnapshot = nil
            formDraft = CardDetailFormDraft.from(card: updated.card)
            rawDraft = updated.contents
            appendHistory = false
            errorMessage = nil
            mode = .view
        } catch let error as CardSaveError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CardViewMode<AgentControls: View>: View {
    let card: Card
    @Binding var formDraft: CardDetailFormDraft
    let phase: Phase
    @Binding var branchPrefix: String
    let recommendedBranch: String
    let checkoutCommand: String
    let branchStatusMessage: String?
    let isApplyingBranch: Bool
    let onCopyBranch: () -> Void
    let onCopyCommand: () -> Void
    let onApplyBranch: () -> Void
    let agentControls: AgentControls
    @Binding var chatFilter: AgentChatMessage.Role?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AgentRunner.self) private var agentRunner

    var body: some View {
        GeometryReader { proxy in
            let spacing = DesignTokens.Spacing.large
            let availableWidth = max(proxy.size.width, 720)
            let sidebarWidth = max(340, availableWidth * 0.32)
            let contentWidth = max(520, availableWidth - sidebarWidth - spacing)
            let columnHeight = proxy.size.height - (DesignTokens.Spacing.large * 2)

            HStack(alignment: .top, spacing: spacing) {
                ScrollView(.vertical) {
                    contentColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.vertical, DesignTokens.Spacing.large)
                }
                .frame(width: contentWidth, height: columnHeight, alignment: .topLeading)

                ScrollView(.vertical) {
                    AgentContextPanel(card: card,
                                      agentControls: agentControls,
                                      runState: agentRunner.state(for: card),
                                      chatFilter: $chatFilter)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.vertical, DesignTokens.Spacing.large)
                }
                .frame(width: sidebarWidth, height: columnHeight, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var accentColor: Color {
        DesignTokens.Colors.preferredAccent(for: colorScheme)
    }

    @ViewBuilder
    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            BranchHelperPanel(formDraft: formDraft,
                               branchPrefix: $branchPrefix,
                               recommendedBranch: recommendedBranch,
                               checkoutCommand: checkoutCommand,
                               statusMessage: branchStatusMessage,
                               isApplying: isApplyingBranch,
                               onCopyBranch: onCopyBranch,
                               onCopyCommand: onCopyCommand,
                               onApplyBranch: onApplyBranch)
            MetadataGrid(formDraft: formDraft, phase: phase)
            SummaryBlock(summary: $formDraft.summary)
            CriteriaList(criteria: $formDraft.criteria, accentColor: accentColor)
            NotesBlock(notes: $formDraft.notes, accentColor: accentColor)
            AttachmentsCommentsBlock()
            HistoryTimeline(history: formDraft.history, accentColor: accentColor)
        }
        .padding(.horizontal, DesignTokens.Spacing.small)
    }
}

private struct AgentContextPanel<AgentControls: View>: View {
    let card: Card
    let agentControls: AgentControls
    let runState: AgentRunState?
    @Binding var chatFilter: AgentChatMessage.Role?

    @Environment(\.colorScheme) private var colorScheme

    private let filterOptions: [AgentChatMessage.Role?] = [nil, .system, .user, .assistant, .status]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            HStack(spacing: DesignTokens.Spacing.small) {
                Label("Agent Context", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(DesignTokens.Typography.headline)
                Spacer()
                statusBadge
            }

            agentControls

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Picker("Filter transcript", selection: $chatFilter) {
                        ForEach(filterOptions, id: \.self) { option in
                            Text(filterLabel(for: option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(minWidth: 320)
                }

                AgentChatTranscript(runState: runState,
                                    filter: chatFilter)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.large)
            .fill(DesignTokens.Colors.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.large)
            .stroke(DesignTokens.Colors.stroke, lineWidth: 1))
        .tokenShadow(DesignTokens.Shadows.raised)
    }

    private var statusBadge: some View {
        let statusText: String
        let badgeColor: Color
        if let runState {
            statusText = runState.phase.rawValue.capitalized
            badgeColor = DesignTokens.Colors.preferredAccent(for: colorScheme)
        } else {
            statusText = "Idle"
            badgeColor = DesignTokens.Colors.textSecondary
        }

        return Text(statusText)
            .font(DesignTokens.Typography.caption.weight(.semibold))
            .padding(.horizontal, DesignTokens.Spacing.small)
            .padding(.vertical, DesignTokens.Spacing.grid)
            .background(Capsule().fill(badgeColor.opacity(0.15)))
            .foregroundStyle(badgeColor)
    }

    private func filterLabel(for option: AgentChatMessage.Role?) -> String {
        switch option {
        case .none: return "All"
        case .some(.system): return "System"
        case .some(.user): return "User"
        case .some(.assistant): return "Assistant"
        case .some(.status): return "Status"
        }
    }
}

private struct AgentChatTranscript: View {
    let runState: AgentRunState?
    let filter: AgentChatMessage.Role?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack {
                Label("Transcript", systemImage: "message.fill")
                    .font(DesignTokens.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Spacer()
                if let runState, let finished = runState.finishedAt {
                    Text(finished, style: .time)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textMuted)
                }
            }

            transcriptBody
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
            .fill(DesignTokens.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
            .stroke(DesignTokens.Colors.strokeMuted, lineWidth: 1))
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if messages.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.grid) {
                Text("No agent messages yet.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Text("Run any flow to stream the agent’s conversation and execution log.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                        ForEach(messages) { message in
                            AgentChatBubble(message: message,
                                            accent: DesignTokens.Colors.preferredAccent(for: colorScheme))
                                .id(message.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 260, maxHeight: 420)
                .onAppear {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var messages: [AgentChatMessage] {
        guard let runState else { return [] }
        var rendered: [AgentChatMessage] = []
        let recentLogs = Array(runState.logs.suffix(80))

        for line in recentLogs {
            for message in parseLogLine(line) {
                rendered.append(message)
            }
        }

        if rendered.isEmpty, let summary = runState.summary {
            rendered.append(AgentChatMessage(role: .status, text: summary))
        }

        if let filter {
            return rendered.filter { $0.role == filter }
        }

        return rendered
    }

    private func parseLogLine(_ line: String) -> [AgentChatMessage] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // JSON event payloads from worker logs.
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var messages: [AgentChatMessage] = []
            let message = object["message"] as? String ?? object["summary"] as? String
            let event = (object["event"] as? String ?? "").lowercased()
            let statusString = (object["status"] as? String ?? "").lowercased()
            let percent = double(from: object["percent"]) ?? double(from: object["progress"])

            if event == "progress" || percent != nil {
                let text: String
                if let message {
                    text = message
                } else if let percent {
                    text = "Progress \(Int(percent * 100))%"
                } else {
                    text = "Progress"
                }
                messages.append(AgentChatMessage(role: .status, text: text))
            } else if !statusString.isEmpty {
                messages.append(AgentChatMessage(role: .status,
                                                 text: message ?? statusString.capitalized))
            } else if let message {
                messages.append(AgentChatMessage(role: .assistant, text: message))
            }

            if !messages.isEmpty { return messages }
        }

        // Timestamp + role prefix, e.g., "[02:00] system: ..."
        if let bracketRange = trimmed.range(of: "] "),
           trimmed.first == "[",
           let _ = trimmed[trimmed.index(after: bracketRange.upperBound)...]
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first {
            let remaining = trimmed[bracketRange.upperBound...]
            if let parsed = parsePrefixed(String(remaining)) {
                return [parsed]
            }
        }

        // Simple role prefixes.
        if let parsed = parsePrefixed(trimmed) {
            return [parsed]
        }

        // Errors / warnings bubble.
        let lower = trimmed.lowercased()
        if lower.contains("error") || lower.contains("failed") || lower.contains("cancel") {
            return [AgentChatMessage(role: .status, text: trimmed)]
        }

        // Default: treat as assistant narration.
        return [AgentChatMessage(role: .assistant, text: trimmed)]
    }

    private func parsePrefixed(_ text: String) -> AgentChatMessage? {
        let lower = text.lowercased()
        if lower.hasPrefix("system:") || lower.hasPrefix("[system]") {
            return AgentChatMessage(role: .system, text: stripped(text, removingPrefixes: ["system:", "[system]"]))
        }
        if lower.hasPrefix("user:") || lower.hasPrefix("[user]") || lower.hasPrefix("user>") {
            return AgentChatMessage(role: .user, text: stripped(text, removingPrefixes: ["user:", "[user]", "user>"]))
        }
        if lower.hasPrefix("assistant:") || lower.hasPrefix("[assistant]") || lower.hasPrefix("assistant>") {
            return AgentChatMessage(role: .assistant, text: stripped(text, removingPrefixes: ["assistant:", "[assistant]", "assistant>"]))
        }
        return nil
    }

    private func stripped(_ text: String, removingPrefixes prefixes: [String]) -> String {
        for prefix in prefixes {
            if text.lowercased().hasPrefix(prefix) {
                let index = text.index(text.startIndex, offsetBy: prefix.count)
                return text[index...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func double(from value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

private struct AgentChatBubble: View {
    let message: AgentChatMessage
    let accent: Color

    private let systemColor = Color(red: 112/255, green: 86/255, blue: 218/255)
    private let userColor = Color(red: 58/255, green: 96/255, blue: 180/255)
    private let assistantColor = Color(red: 46/255, green: 146/255, blue: 121/255)
    private let statusColor = Color(red: 209/255, green: 173/255, blue: 78/255)

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.grid) {
            Text(message.role.label)
                .font(DesignTokens.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Text(message.text)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
            .fill(background))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
            .stroke(stroke, lineWidth: 1))
    }

    private var background: Color {
        switch message.role {
        case .system:
            return systemColor.opacity(0.18)
        case .user:
            return userColor.opacity(0.18)
        case .assistant:
            return assistantColor.opacity(0.16)
        case .status:
            return statusColor.opacity(0.22)
        }
    }

    private var stroke: Color {
        switch message.role {
        case .system:
            return systemColor.opacity(0.45)
        case .user:
            return userColor.opacity(0.55)
        case .assistant:
            return assistantColor.opacity(0.45)
        case .status:
            return statusColor.opacity(0.65)
        }
    }
}

private struct AgentChatMessage: Identifiable {
    enum Role {
        case system
        case user
        case assistant
        case status

        var label: String {
            switch self {
            case .system: return "System"
            case .user: return "User"
            case .assistant: return "Assistant"
            case .status: return "Status"
            }
        }
    }

    let id = UUID()
    let role: Role
    let text: String
}

private struct AgentControlPanel: View {
    let card: Card
    @Binding var selectedFlow: AgentFlow
    @Binding var agentError: String?
    let onRun: (AgentFlow) async -> Void
    let onCancel: (UUID) -> Void
    let onReset: () async -> Void

    @Environment(AgentRunner.self) private var agentRunner
    @Environment(\.colorScheme) private var colorScheme

    private var runState: AgentRunState? {
        agentRunner.state(for: card)
    }

    private var logDirectory: URL? { runState?.logDirectory }

    private var failureSummary: String? {
        guard let runState, runState.phase == .failed else { return nil }
        if let summary = runState.summary, !summary.isEmpty {
            return summary
        }
        if let exit = runState.result?.exitCode {
            return "Run failed with exit \(exit)"
        }
        return "Run failed"
    }

    private var statusLabel: String {
        if let runState {
            return runState.phase.rawValue.capitalized
        }
        let status = card.frontmatter.agentStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        return status?.isEmpty == false ? status!.capitalized : "Idle"
    }

    private var isActive: Bool {
        guard let runState else { return false }
        return runState.phase == .queued || runState.phase == .running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            HStack(spacing: DesignTokens.Spacing.small) {
                Label("Agent", systemImage: "bolt.horizontal")
                    .font(DesignTokens.Typography.headline)
                Spacer()
                Text(statusLabel)
                    .font(DesignTokens.Typography.caption.weight(.semibold))
                    .padding(.horizontal, DesignTokens.Spacing.small)
                    .padding(.vertical, DesignTokens.Spacing.grid)
                    .background(Capsule().fill(DesignTokens.Colors.preferredAccent(for: colorScheme).opacity(0.14)))
            }

            Picker("Flow", selection: $selectedFlow) {
                ForEach(AgentFlow.allCases) { flow in
                    Text(flow.label).tag(flow)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: DesignTokens.Spacing.small) {
                if let runState, isActive {
                    Button(role: .cancel) {
                        onCancel(runState.id)
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await onRun(selectedFlow) }
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if runState != nil, !isActive {
                    Button {
                        Task { await onRun(selectedFlow) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    Task { await onReset() }
                } label: {
                    Label("Reset", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(isActive)
            }

            if let runState {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                    ProgressView(value: runState.progress)
                        .tint(DesignTokens.Colors.preferredAccent(for: colorScheme))
                    if let summary = runState.summary {
                        Text(summary)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                    if let result = runState.result {
                        Text(resultDetailText(result))
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                    if let failureSummary {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Label(failureSummary, systemImage: "exclamationmark.triangle")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(.red)

                            if let logDirectory {
                                Button {
                                    openLogs(logDirectory)
                                } label: {
                                    Label("View Logs", systemImage: "doc.text.magnifyingglass")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            } else {
                Text("Runs will stream here once started.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            if let agentError {
                InlineErrorBanner(message: agentError) {
                    self.agentError = nil
                }
            }
        }
        .padding()
        .surfaceStyle(DesignTokens.Surfaces.mutedPanel)
    }

    private func resultDetailText(_ result: WorkerRunResult) -> String {
        let formattedDuration: String
        if result.duration >= 1 {
            formattedDuration = String(format: "%.1fs", result.duration)
        } else {
            formattedDuration = String(format: "%.0fms", result.duration * 1000)
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let read = formatter.string(fromByteCount: result.bytesRead)
        let written = formatter.string(fromByteCount: result.bytesWritten)

        return "Exit \(result.exitCode) • \(formattedDuration) • read \(read) / wrote \(written)"
    }

    private func openLogs(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

private struct AgentLogView: View {
    let logs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.grid) {
            Text("Logs")
                .font(DesignTokens.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.grid) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(DesignTokens.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 200)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small).fill(DesignTokens.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small).stroke(DesignTokens.Colors.stroke))
        }
    }
}

private struct BranchHelperPanel: View {
    let formDraft: CardDetailFormDraft
    @Binding var branchPrefix: String
    let recommendedBranch: String
    let checkoutCommand: String
    let statusMessage: String?
    let isApplying: Bool
    let onCopyBranch: () -> Void
    let onCopyCommand: () -> Void
    let onApplyBranch: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.small) {
                Label("Branch Helper", systemImage: "arrow.branch")
                    .font(DesignTokens.Typography.headline)
                Spacer()
                Text(currentBranchLabel)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            Text("Generate a normalized branch for this card, copy it, and write it to frontmatter.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            HStack(alignment: .center, spacing: DesignTokens.Spacing.small) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prefix")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    TextField("implement", text: $branchPrefix)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Recommended")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    Text(recommendedBranch)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                            .fill(DesignTokens.Colors.surface))
                        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                            .stroke(DesignTokens.Colors.stroke, lineWidth: 1))
                }

                Spacer(minLength: DesignTokens.Spacing.medium)

                Button(action: onCopyBranch) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button(action: onApplyBranch) {
                    if isApplying {
                        ProgressView()
                    } else {
                        Label("Apply", systemImage: "tray.and.arrow.down")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplying)
            }

            HStack(alignment: .center, spacing: DesignTokens.Spacing.small) {
                Text(checkoutCommand)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(action: onCopyCommand) {
                    Label("Copy Command", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
            }

            if let statusMessage {
                HStack(spacing: DesignTokens.Spacing.small) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(DesignTokens.Colors.preferredAccent(for: colorScheme))
                    Text(statusMessage)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
            }
        }
        .padding()
        .surfaceStyle(DesignTokens.Surfaces.card())
    }

    private var currentBranchLabel: String {
        let existing = formDraft.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty {
            return "Frontmatter branch: —"
        }
        return "Frontmatter branch: \(existing)"
    }
}

private struct CardFormMode: View {
    @Binding var formDraft: CardDetailFormDraft

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
                GroupBox(label: Label("Frontmatter", systemImage: "doc.text.magnifyingglass")) {
                    FrontmatterEditor(formDraft: $formDraft)
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

private struct FrontmatterEditor: View {
    @Binding var formDraft: CardDetailFormDraft
    @Environment(\.colorScheme) private var colorScheme

    private let riskOptions = ["normal", "low", "medium", "high"]
    private let reviewOptions = ["not-requested", "requested", "changes-requested", "approved", "passed"]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            HStack(spacing: DesignTokens.Spacing.small) {
                Image(systemName: frontmatterWillBeWritten ? "checkmark.seal.fill" : "plus.square.dashed")
                    .foregroundStyle(frontmatterWillBeWritten ? DesignTokens.Colors.preferredAccent(for: colorScheme) : DesignTokens.Colors.textSecondary)
                Text(frontmatterStatusText)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Spacer()
                Text("YAML is validated before saving.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textMuted)
            }

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

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.grid) {
                HStack(spacing: DesignTokens.Spacing.medium) {
                    Picker("Risk", selection: riskSelection) {
                        ForEach(riskOptions, id: \.self) { option in
                            Text(riskLabel(for: option)).tag(option)
                        }
                        Text("Custom…").tag("custom")
                    }
                    .pickerStyle(.menu)

                    Picker("Review", selection: reviewSelection) {
                        ForEach(reviewOptions, id: \.self) { option in
                            Text(reviewLabel(for: option)).tag(option)
                        }
                        Text("Custom…").tag("custom")
                    }
                    .pickerStyle(.menu)
                }

                if riskSelection.wrappedValue == "custom" {
                    TextField("Custom risk (kept as-is)", text: $formDraft.risk)
                        .textFieldStyle(.roundedBorder)
                }

                if reviewSelection.wrappedValue == "custom" {
                    TextField("Custom review (kept as-is)", text: $formDraft.review)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Toggle("Parallelizable", isOn: $formDraft.parallelizable)
                .toggleStyle(.switch)
        }
    }

    private var frontmatterWillBeWritten: Bool {
        formDraft.hadFrontmatter || hasFrontmatterFields
    }

    private var hasFrontmatterFields: Bool {
        !formDraft.owner.isFrontmatterEmpty ||
        !formDraft.agentFlow.isFrontmatterEmpty ||
        !formDraft.agentStatus.isFrontmatterEmpty ||
        !formDraft.branch.isFrontmatterEmpty ||
        !formDraft.risk.isFrontmatterEmpty ||
        !formDraft.review.isFrontmatterEmpty ||
        formDraft.parallelizable
    }

    private var frontmatterStatusText: String {
        if formDraft.hadFrontmatter {
            return "Frontmatter detected; unknown keys stay ordered."
        }
        if hasFrontmatterFields {
            return "No frontmatter found — block will be added on save."
        }
        return "No frontmatter yet; fill any field to add it."
    }

    private var riskSelection: Binding<String> {
        Binding<String>(
            get: {
                let normalized = formDraft.risk.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return riskOptions.contains(normalized) ? normalized : "custom"
            },
            set: { selection in
                if selection == "custom" {
                    if riskOptions.contains(formDraft.risk.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                        formDraft.risk = ""
                    }
                } else {
                    formDraft.risk = selection
                }
            }
        )
    }

    private var reviewSelection: Binding<String> {
        Binding<String>(
            get: {
                let normalized = formDraft.review.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return reviewOptions.contains(normalized) ? normalized : "custom"
            },
            set: { selection in
                if selection == "custom" {
                    if reviewOptions.contains(formDraft.review.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                        formDraft.review = ""
                    }
                } else {
                    formDraft.review = selection
                }
            }
        )
    }

    private func riskLabel(for value: String) -> String {
        value.capitalized
    }

    private func reviewLabel(for value: String) -> String {
        value.replacingOccurrences(of: "-", with: " ").capitalized
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

private struct InlineErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
            .fill(DesignTokens.Colors.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
            .stroke(DesignTokens.Colors.stroke, lineWidth: 1))
    }
}

private struct ExternalChangeBanner: View {
    let onReload: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.small) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Text("Card changed on disk. Reload to pick up manual edits and overrides.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Spacer()
            Button {
                onReload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
            .fill(DesignTokens.Colors.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
            .stroke(DesignTokens.Colors.stroke, lineWidth: 1))
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
    @Binding var summary: String

    var body: some View {
        EditableTextCard(title: "Summary",
                         placeholder: "Add a concise summary…",
                         text: $summary)
    }
}

private struct CriteriaList: View {
    @Binding var criteria: [CardDetailFormDraft.Criterion]
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text("Acceptance Criteria")
                .font(DesignTokens.Typography.headline)

            if criteria.isEmpty {
                Text("No criteria yet.")
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                    ForEach($criteria) { $criterion in
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.small) {
                            Toggle(isOn: $criterion.isComplete) {
                                TextField("Criterion", text: $criterion.title)
                                    .textFieldStyle(.plain)
                            }
                            .toggleStyle(.checkbox)
                            .tint(accentColor)

                            Spacer(minLength: DesignTokens.Spacing.small)

                            Button {
                                criteria.removeAll { $0.id == criterion.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete criterion")
                        }
                        .padding(.vertical, DesignTokens.Spacing.grid)
                    }
                }
            }

            Button {
                criteria.append(.init(title: "New criterion", isComplete: false))
            } label: {
                Label("Add criterion", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.top, DesignTokens.Spacing.small)
        }
        .padding()
        .surfaceStyle(DesignTokens.Surfaces.card())
    }
}

private struct NotesBlock: View {
    @Binding var notes: String
    let accentColor: Color

    var body: some View {
        EditableTextCard(title: "Notes",
                         placeholder: "Capture notes, risks, and open questions…",
                         text: $notes,
                         accentFill: accentColor.opacity(0.08))
    }
}

private struct EditableTextCard: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var accentFill: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text(title)
                .font(DesignTokens.Typography.headline)

            ZStack(alignment: .topLeading) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(placeholder)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Colors.textMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }

                TextEditor(text: $text)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                        .fill(accentFill ?? DesignTokens.Colors.card))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                        .stroke(DesignTokens.Colors.stroke, lineWidth: 1))
            }
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

private struct AttachmentsCommentsBlock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text("Attachments & Comments")
                .font(DesignTokens.Typography.headline)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.grid) {
                Label("No attachments yet", systemImage: "paperclip")
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Label("No comments yet", systemImage: "text.bubble")
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                .fill(DesignTokens.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                .stroke(DesignTokens.Colors.strokeMuted, lineWidth: 1))

            Text("Coming soon: upload files and thread comments when the shared editor lands.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textMuted)
        }
        .padding()
        .surfaceStyle(DesignTokens.Surfaces.card())
    }
}

private extension String {
    var isFrontmatterEmpty: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
