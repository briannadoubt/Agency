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

    @State private var draggingCardPath: String?
    @State private var moveError: CardMoveError?
    @State private var selectedCardPath: String?
    @State private var inspectorDraft = CardInspectorDraft.empty

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
                        onSelect: handleSelect)
                .frame(minHeight: DesignTokens.Layout.boardMinimumHeight)

            CardInspector(card: selectedCard,
                          draft: $inspectorDraft)
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
        .onChange(of: selectedCardPath) { _, newPath in
            guard let newPath, let card = cardsByPath[newPath] else {
                inspectorDraft = .empty
                return
            }
            inspectorDraft = CardInspectorDraft(card: card)
        }
        .onChange(of: phase.cards) { _, updatedCards in
            guard let selectedCardPath else {
                inspectorDraft = .empty
                return
            }

            if let updatedCard = updatedCards.first(where: { $0.filePath.standardizedFileURL.path == selectedCardPath }) {
                inspectorDraft = CardInspectorDraft(card: updatedCard)
            } else {
                self.selectedCardPath = nil
                inspectorDraft = .empty
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
        inspectorDraft = CardInspectorDraft(card: card)
    }
}

private struct KanbanBoard: View {
    let phase: PhaseSnapshot
    @Binding var draggingCardPath: String?
    @Binding var selectedCardPath: String?
    let onMove: (String, CardStatus) -> Void
    let onSelect: (Card) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: DesignTokens.Layout.boardColumnSpacing) {
                ForEach(CardStatus.allCases, id: \.self) { status in
                    KanbanColumn(status: status,
                                 cards: cards(for: status),
                                 draggingCardPath: $draggingCardPath,
                                 selectedCardPath: $selectedCardPath,
                                 onMove: onMove,
                                 onSelect: onSelect)
                        .frame(width: DesignTokens.Layout.boardColumnWidth)
                }
            }
            .padding(.horizontal, DesignTokens.Layout.boardHorizontalGutter)
            .padding(.vertical, DesignTokens.Layout.boardVerticalGutter)
            .frame(minWidth: DesignTokens.Layout.boardContentWidth, alignment: .leading)
            .animation(.snappy(duration: 0.22), value: phase.cards)
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

    @State private var isTargeted: Bool = false

    private let columnCornerRadius = DesignTokens.Radius.large

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColumnHeader(status: status, count: cards.count)

            ScrollView {
                LazyVStack(spacing: DesignTokens.Spacing.small) {
                    if cards.isEmpty {
                        EmptyColumnState(status: status)
                            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                    } else {
                        ForEach(cards, id: \.filePath) { card in
                            let cardPath = card.filePath.standardizedFileURL.path
                            CardTile(card: card,
                                     isGhosted: draggingCardPath == cardPath,
                                     isSelected: selectedCardPath == cardPath)
                                .onTapGesture {
                                    selectedCardPath = cardPath
                                    onSelect(card)
                                }
                                .draggable(CardDragItem(path: card.filePath.standardizedFileURL.path)) {
                                    CardTile(card: card, isGhosted: true, isSelected: false)
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
                .animation(.snappy(duration: 0.2), value: cards)
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
    let isGhosted: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardRow(card: card)

            if !card.acceptanceCriteria.isEmpty {
                let completed = card.acceptanceCriteria.filter(\.isComplete).count
                let total = card.acceptanceCriteria.count
                ProgressView(value: Double(completed), total: Double(total))
                    .progressViewStyle(.linear)
            }
        }
        .padding(DesignTokens.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceStyle(DesignTokens.Surfaces.card(border: borderColor))
        .opacity(isGhosted ? 0.7 : 1)
    }

    private var borderColor: Color {
        if isGhosted { return DesignTokens.Colors.accent }
        if isSelected { return DesignTokens.Colors.accent.opacity(0.7) }
        return DesignTokens.Colors.strokeMuted
    }
}

private struct CardRow: View {
    let card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = card.title {
                Text(title)
                    .font(DesignTokens.Typography.headline)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
            }
            Text(card.code)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            if let summary = card.summary, !summary.isEmpty {
                Text(summary.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
