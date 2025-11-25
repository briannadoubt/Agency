import SwiftUI
import Observation
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var loader = ProjectLoader()
    @State private var showingImporter = false
    @State private var selectedPhaseNumber: Int?
    @State private var importError: String?

    var body: some View {
        @Bindable var loader = loader

        NavigationSplitView {
            List(selection: $selectedPhaseNumber) {
                Section("Project") {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Open Project…", systemImage: "folder.badge.plus")
                    }

                    if let snapshot = loader.loadedSnapshot {
                        Text(snapshot.rootURL.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Choose the repository root that contains project/")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Status") {
                    switch loader.state {
                    case .idle:
                        Label("Waiting for selection", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    case .loading:
                        Label("Loading project…", systemImage: "arrow.clockwise")
                    case .loaded(let snapshot):
                        Label("Loaded \(snapshot.phases.count) phase(s)", systemImage: "checkmark.circle")
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if let snapshot = loader.loadedSnapshot {
                    Section("Phases") {
                        ForEach(snapshot.phases, id: \.phase.number) { phase in
                            PhaseRow(phase: phase)
                                .tag(phase.phase.number)
                                .onTapGesture {
                                    selectedPhaseNumber = phase.phase.number
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        } detail: {
            DetailView(loader: loader,
                       snapshot: loader.loadedSnapshot,
                       selectedPhaseNumber: $selectedPhaseNumber)
        }
        .navigationTitle(Text("Agency"))
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    loader.loadProject(at: url)
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .task {
            loader.restoreBookmarkIfAvailable()
        }
        .onChange(of: loader.loadedSnapshot) { _, snapshot in
            guard selectedPhaseNumber == nil,
                  let first = snapshot?.phases.first?.phase.number else { return }
            selectedPhaseNumber = first
        }
        .alert("Unable to open folder", isPresented: Binding(get: { importError != nil },
                                                            set: { newValue in
                                                                if !newValue {
                                                                    importError = nil
                                                                }
                                                            })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importError ?? "")
        }
    }
}

private struct DetailView: View {
    let loader: ProjectLoader
    let snapshot: ProjectLoader.ProjectSnapshot?
    @Binding var selectedPhaseNumber: Int?

    var body: some View {
        if let snapshot {
            VStack(spacing: 0) {
                BoardHeader(title: "Agency Board",
                            subtitle: headerSubtitle(from: snapshot))

                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
                        ProjectSummary(snapshot: snapshot)

                        if let phase = selectedPhase(from: snapshot) {
                            PhaseDetail(phase: phase) { card, status in
                                await loader.moveCard(card, to: status)
                            }
                            .id(phase.phase.number)
                        } else {
                            Text("Select a phase to see its cards.")
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                                .font(DesignTokens.Typography.body)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Layout.boardHorizontalGutter)
                    .padding(.vertical, DesignTokens.Layout.boardVerticalGutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(DesignTokens.Colors.canvas)
            }
            .background(DesignTokens.Colors.canvas)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Open a project folder to begin.")
                    .font(.title3)
                Text("Agency watches the markdown-driven kanban and reloads automatically when files change.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectedPhase(from snapshot: ProjectLoader.ProjectSnapshot) -> PhaseSnapshot? {
        guard let selectedPhaseNumber else { return nil }
        return snapshot.phases.first { $0.phase.number == selectedPhaseNumber }
    }

    private func headerSubtitle(from snapshot: ProjectLoader.ProjectSnapshot) -> String {
        if let phase = selectedPhase(from: snapshot) {
            return "Phase \(phase.phase.number): \(phase.phase.label)"
        }
        return "Select a phase to see its cards."
    }
}

private struct PhaseRow: View {
    let phase: PhaseSnapshot

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Phase \(phase.phase.number): \(phase.phase.label)")
                    .font(.headline)
                Text("\(phase.cards.count) card(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BoardHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.grid) {
            Text(title)
                .font(DesignTokens.Typography.titleLarge)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Text(subtitle)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .padding(DesignTokens.Layout.headerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .bottom)
    }
}

private struct ProjectSummary: View {
    let snapshot: ProjectLoader.ProjectSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project root")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Text(snapshot.rootURL.path)
                .font(DesignTokens.Typography.headline)
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            if !snapshot.validationIssues.isEmpty {
                ValidationIssuesView(issues: snapshot.validationIssues)
            }
        }
    }
}

private struct ValidationIssuesView: View {
    let issues: [ValidationIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Validation")
                .font(.headline)

            ForEach(issues, id: \.path) { issue in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(color(for: issue.severity))
                        .frame(width: 10, height: 10)
                    Text(issue.message)
                        .font(.subheadline)
                    Spacer()
                    Text(issue.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .surfaceStyle(DesignTokens.Surfaces.mutedPanel)
    }

    private func color(for severity: ValidationIssue.Severity) -> Color {
        switch severity {
        case .error:
            return DesignTokens.Colors.riskHigh.foreground
        case .warning:
            return DesignTokens.Colors.riskMedium.foreground
        }
    }
}

private struct PhaseDetail: View {
    let phase: PhaseSnapshot
    let onMove: (Card, CardStatus) async -> Result<Void, CardMoveError>

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draggingCardPath: String?
    @State private var moveError: CardMoveError?
    @State private var selectedCardPath: String?
    @State private var isShowingDetailModal = false

    private var cardsByPath: [String: Card] {
        Dictionary(uniqueKeysWithValues: phase.cards.map { ($0.filePath.standardizedFileURL.path, $0) })
    }

    private var selectedCard: Card? {
        guard let selectedCardPath else { return nil }
        return cardsByPath[selectedCardPath]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Phase \(phase.phase.number) · \(phase.phase.label)")
                    .font(DesignTokens.Typography.titleLarge)
                Text("\(phase.cards.count) card(s)")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            KanbanBoard(phase: phase,
                        draggingCardPath: $draggingCardPath,
                        selectedCardPath: $selectedCardPath,
                        onMove: handleMove,
                        onSelect: handleSelect,
                        reduceMotion: reduceMotion)
                .frame(minHeight: DesignTokens.Layout.boardMinimumHeight)

        }
        .alert("Move failed", isPresented: Binding(get: { moveError != nil },
                                                 set: { newValue in
                                                     if !newValue {
                                                         moveError = nil
                                                     }
                                                 })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(moveError?.localizedDescription ?? "Unknown error.")
                .foregroundStyle(DesignTokens.Colors.textPrimary)
        }
        .sheet(isPresented: $isShowingDetailModal) {
            if let selectedCard {
                CardDetailModal(card: selectedCard,
                                phase: phase.phase)
                    .presentationDetents([.large])
            }
        }
        .onChange(of: selectedCardPath) { _, newPath in
            guard let newPath, cardsByPath[newPath] != nil else {
                isShowingDetailModal = false
                return
            }
            isShowingDetailModal = true
        }
        .onChange(of: phase.cards) { _, updatedCards in
            guard let selectedCardPath else {
                isShowingDetailModal = false
                return
            }

            if updatedCards.contains(where: { $0.filePath.standardizedFileURL.path == selectedCardPath }) {
                // Keep showing modal with updated card
            } else {
                self.selectedCardPath = nil
                isShowingDetailModal = false
            }
        }
    }

    private func handleMove(cardPath: String, targetStatus: CardStatus) {
        guard let card = cardsByPath[cardPath] else {
            draggingCardPath = nil
            return
        }

        guard card.status != targetStatus else {
            draggingCardPath = nil
            return
        }

        Task {
            let result = await onMove(card, targetStatus)
            await MainActor.run {
                draggingCardPath = nil
                if case .failure(let error) = result {
                    moveError = error
                }
            }
        }
    }

    private func handleSelect(_ card: Card) {
        let path = card.filePath.standardizedFileURL.path
        selectedCardPath = path
        isShowingDetailModal = true
    }
}

private struct KanbanBoard: View {
    let phase: PhaseSnapshot
    @Binding var draggingCardPath: String?
    @Binding var selectedCardPath: String?
    let onMove: (String, CardStatus) -> Void
    let onSelect: (Card) -> Void
    let reduceMotion: Bool

    @FocusState private var focusedCardPath: String?

    var body: some View {
        let boardAnimation: Animation? = reduceMotion ? nil : DesignTokens.Motion.board

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: DesignTokens.Layout.boardColumnSpacing) {
                ForEach(CardStatus.allCases, id: \.self) { status in
                    KanbanColumn(status: status,
                                 cards: cards(for: status),
                                 draggingCardPath: $draggingCardPath,
                                 selectedCardPath: $selectedCardPath,
                                 onMove: onMove,
                                 onSelect: onSelect,
                                 focusedCardPath: $focusedCardPath,
                                 reduceMotion: reduceMotion)
                        .frame(width: DesignTokens.Layout.boardColumnWidth)
                }
            }
            .padding(.horizontal, DesignTokens.Layout.boardHorizontalGutter)
            .padding(.vertical, DesignTokens.Layout.boardVerticalGutter)
            .frame(minWidth: DesignTokens.Layout.boardContentWidth, alignment: .leading)
            .animation(boardAnimation, value: phase.cards)
        }
        .frame(minHeight: DesignTokens.Layout.boardMinimumHeight)
    }

    private func cards(for status: CardStatus) -> [Card] {
        phase.cards.filter { $0.status == status }
    }
}

private struct KanbanColumn: View {
    let status: CardStatus
    let cards: [Card]
    @Binding var draggingCardPath: String?
    @Binding var selectedCardPath: String?
    let onMove: (String, CardStatus) -> Void
    let onSelect: (Card) -> Void
    let focusedCardPath: FocusState<String?>.Binding
    let reduceMotion: Bool

    @State private var isTargeted: Bool = false

    private let columnCornerRadius = DesignTokens.Radius.large

    var body: some View {
        content
    }

    private var content: some View {
        let boardAnimation: Animation? = reduceMotion ? nil : DesignTokens.Motion.board

        return VStack(alignment: .leading, spacing: 10) {
            ColumnHeader(status: status, count: cards.count)

            ScrollView {
                LazyVStack(spacing: DesignTokens.Spacing.small) {
                    if cards.isEmpty {
                        EmptyColumnState(status: status)
                            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                    } else {
                        ForEach(cards, id: \.filePath) { card in
                            let presentation = CardPresentation(card: card)
                            let cardPath = card.filePath.standardizedFileURL.path
                            let isFocused = focusedCardPath.wrappedValue == cardPath

                            Button {
                                selectedCardPath = cardPath
                                onSelect(card)
                            } label: {
                                CardTile(card: card,
                                         presentation: presentation,
                                         isGhosted: draggingCardPath == cardPath,
                                         isSelected: selectedCardPath == cardPath,
                                         isFocused: isFocused,
                                         reduceMotion: reduceMotion)
                            }
                            .buttonStyle(.plain)
                            .focused(focusedCardPath, equals: cardPath)
                            .focusable(true)
                            .draggable(CardDragItem(path: card.filePath.standardizedFileURL.path)) {
                                CardTile(card: card,
                                         presentation: presentation,
                                         isGhosted: true,
                                         isSelected: false,
                                         isFocused: false,
                                         reduceMotion: reduceMotion)
                            }
                            .dropDestination(for: CardDragItem.self) { items, _ in
                                guard let item = items.first else { return false }
                                draggingCardPath = item.path
                                onMove(item.path, status)
                                return true
                            } isTargeted: { targeted in
                                isTargeted = targeted
                            }
                        }
                    }
                }
                .animation(boardAnimation, value: cards)
            }
        }
        .padding(DesignTokens.Spacing.medium)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(columnBackground(isTargeted: isTargeted))
        .overlay(RoundedRectangle(cornerRadius: columnCornerRadius, style: .continuous)
            .stroke(columnBorder(isTargeted: isTargeted), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: columnCornerRadius, style: .continuous))
        .dropDestination(for: CardDragItem.self) { items, _ in
            guard let item = items.first else { return false }
            draggingCardPath = item.path
            onMove(item.path, status)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    private func columnBackground(isTargeted: Bool) -> some View {
        RoundedRectangle(cornerRadius: columnCornerRadius, style: .continuous)
            .fill(isTargeted ? DesignTokens.Colors.accent.opacity(0.16) : DesignTokens.Colors.surface)
    }

    private func columnBorder(isTargeted: Bool) -> Color {
        isTargeted ? DesignTokens.Colors.accent : DesignTokens.Colors.stroke
    }
}

private struct ColumnHeader: View {
    let status: CardStatus
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title(for: status))
                .font(DesignTokens.Typography.headline)
            Spacer()
            Text("\(count)")
                .font(DesignTokens.Typography.caption.weight(.bold))
                .padding(.horizontal, DesignTokens.Spacing.xSmall)
                .padding(.vertical, DesignTokens.Spacing.grid)
                .background(Capsule().fill(DesignTokens.Colors.accent.opacity(0.14)))
        }
        .foregroundStyle(DesignTokens.Colors.textPrimary)
    }

    private func title(for status: CardStatus) -> String {
        switch status {
        case .backlog:
            return "Backlog"
        case .inProgress:
            return "In Progress"
        case .done:
            return "Done"
        }
    }
}

private struct EmptyColumnState: View {
    let status: CardStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No \(title) cards")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Text("Drop a card here to update its status.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).stroke(DesignTokens.Colors.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private var title: String {
        switch status {
        case .backlog:
            return "backlog"
        case .inProgress:
            return "in-progress"
        case .done:
            return "done"
        }
    }
}

private struct CardTile: View {
    let card: Card
    let presentation: CardPresentation
    let isGhosted: Bool
    let isSelected: Bool
    let isFocused: Bool
    let reduceMotion: Bool

    @State private var isHovering = false

    private let cornerRadius = DesignTokens.Radius.medium

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            header

            if let title = presentation.title, !title.isEmpty {
                Text(title)
                    .font(DesignTokens.Typography.headline)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
            }

            if let summary = presentation.summary, !summary.isEmpty {
                Text(summary)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            metadataRow

            if presentation.totalCriteria > 0 {
                ProgressView(value: Double(presentation.completedCriteria), total: Double(presentation.totalCriteria))
                    .progressViewStyle(.linear)
                    .tint(DesignTokens.Colors.accent)
            }
        }
        .padding(DesignTokens.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(backgroundColor))
        .overlay(shape.stroke(borderColor, lineWidth: isFocused ? 2 : 1))
        .tokenShadow(isFocused ? DesignTokens.Shadows.focus : DesignTokens.Shadows.card)
        .opacity(isGhosted ? 0.8 : 1)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(DesignTokens.Motion.hover) {
                    isHovering = hovering
                }
            }
        }
    }

    private var backgroundColor: Color {
        if isGhosted { return DesignTokens.Colors.card.opacity(0.92) }
        if isSelected { return DesignTokens.Colors.card }
        return isHovering ? DesignTokens.Colors.surfaceRaised : DesignTokens.Colors.card
    }

    private var borderColor: Color {
        if isFocused { return DesignTokens.Colors.accent }
        if isGhosted { return DesignTokens.Colors.accent }
        if isSelected { return DesignTokens.Colors.accent.opacity(0.8) }
        return isHovering ? DesignTokens.Colors.stroke : DesignTokens.Colors.strokeMuted
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(presentation.code)
                .font(DesignTokens.Typography.code)
                .padding(.horizontal, DesignTokens.Spacing.xSmall)
                .padding(.vertical, DesignTokens.Spacing.grid)
                .background(Capsule().fill(DesignTokens.Colors.stroke.opacity(0.55)))
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Spacer(minLength: DesignTokens.Spacing.small)

            Text(presentation.riskLevel.label)
                .font(DesignTokens.Typography.caption.weight(.semibold))
                .badgeStyle(badgeStyle(for: presentation.riskLevel))
                .accessibilityLabel("Risk \(presentation.riskLevel.label)")
        }
    }

    private var metadataRow: some View {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
            MetadataPill(icon: "person.fill", text: presentation.owner ?? "Unassigned")

            MetadataPill(icon: "arrow.triangle.branch", text: presentation.branch ?? "No branch", emphasize: presentation.branch != nil)

            MetadataPill(icon: "bolt.horizontal", text: presentation.agentStatus?.capitalized ?? "Idle")

            MetadataPill(icon: "arrow.triangle.2.circlepath", text: presentation.parallelizable ? "Parallel" : "Serial", emphasize: presentation.parallelizable)
        }
    }

    private func badgeStyle(for risk: RiskLevel) -> BadgeStyle {
        switch risk {
        case .low:
            return DesignTokens.Badges.lowRisk
        case .medium:
            return DesignTokens.Badges.mediumRisk
        case .high:
            return DesignTokens.Badges.highRisk
        }
    }
}

private struct MetadataPill: View {
    let icon: String
    let text: String
    var emphasize: Bool = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.grid) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(DesignTokens.Typography.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, DesignTokens.Spacing.small)
        .padding(.vertical, DesignTokens.Spacing.grid)
        .background(Capsule().fill(emphasize ? DesignTokens.Colors.accent.opacity(0.18) : DesignTokens.Colors.stroke.opacity(0.35)))
        .foregroundStyle(emphasize ? DesignTokens.Colors.accent : DesignTokens.Colors.textSecondary)
    }
}

private struct CardDragItem: Transferable {
    let path: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .plainText) { item in
            Data(item.path.utf8)
        } importing: { data in
            guard let path = String(data: data, encoding: .utf8) else {
                throw TransferError.invalidData
            }
            return CardDragItem(path: path)
        }
    }

    private enum TransferError: Error {
        case invalidData
    }
}

#Preview {
    ContentView()
}
