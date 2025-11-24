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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ProjectSummary(snapshot: snapshot)

                    if let phase = selectedPhase(from: snapshot) {
                        PhaseDetail(phase: phase) { card, status in
                            await loader.moveCard(card, to: status)
                        }
                            .id(phase.phase.number)
                    } else {
                        Text("Select a phase to see its cards.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.textBackgroundColor))
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

private struct ProjectSummary: View {
    let snapshot: ProjectLoader.ProjectSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project root")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(snapshot.rootURL.path)
                .font(.headline)

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
        .background(Color(.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func color(for severity: ValidationIssue.Severity) -> Color {
        switch severity {
        case .error:
            return .red
        case .warning:
            return .yellow
        }
    }
}

private struct PhaseDetail: View {
    let phase: PhaseSnapshot
    let onMove: (Card, CardStatus) async -> Result<Void, CardMoveError>

    @State private var draggingCardPath: String?
    @State private var moveError: CardMoveError?

    private var cardsByPath: [String: Card] {
        Dictionary(uniqueKeysWithValues: phase.cards.map { ($0.filePath.standardizedFileURL.path, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Phase \(phase.phase.number) · \(phase.phase.label)")
                    .font(.title2.bold())
                Text("\(phase.cards.count) card(s)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            KanbanBoard(phase: phase,
                        draggingCardPath: $draggingCardPath,
                        onMove: handleMove)
                .frame(minHeight: 420)
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
}

private struct KanbanBoard: View {
    let phase: PhaseSnapshot
    @Binding var draggingCardPath: String?
    let onMove: (String, CardStatus) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(CardStatus.allCases, id: \.self) { status in
                    KanbanColumn(status: status,
                                 cards: cards(for: status),
                                 draggingCardPath: $draggingCardPath,
                                 onMove: onMove)
                        .frame(width: 280)
                }
            }
            .padding(.vertical, 4)
            .animation(.snappy(duration: 0.22), value: phase.cards)
        }
    }

    private func cards(for status: CardStatus) -> [Card] {
        phase.cards.filter { $0.status == status }
    }
}

private struct KanbanColumn: View {
    let status: CardStatus
    let cards: [Card]
    @Binding var draggingCardPath: String?
    let onMove: (String, CardStatus) -> Void

    @State private var isTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColumnHeader(status: status, count: cards.count)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if cards.isEmpty {
                        EmptyColumnState(status: status)
                            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                    } else {
                        ForEach(cards, id: \.filePath) { card in
                            CardTile(card: card,
                                     isGhosted: draggingCardPath == card.filePath.standardizedFileURL.path)
                                .draggable(CardDragItem(path: card.filePath.standardizedFileURL.path)) {
                                    CardTile(card: card, isGhosted: true)
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
        .padding()
        .frame(maxHeight: .infinity, alignment: .top)
        .background(columnBackground(isTargeted: isTargeted))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(columnBorder(isTargeted: isTargeted), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        RoundedRectangle(cornerRadius: 12)
            .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color(.windowBackgroundColor))
    }

    private func columnBorder(isTargeted: Bool) -> Color {
        isTargeted ? .accentColor : Color(.separatorColor)
    }
}

private struct ColumnHeader: View {
    let status: CardStatus
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title(for: status))
                .font(.headline)
            Spacer()
            Text("\(count)")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(.controlAccentColor).opacity(0.12)))
        }
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
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Drop a card here to update its status.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color(.separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isGhosted ? Color.accentColor : Color.clear, lineWidth: 1))
        .opacity(isGhosted ? 0.7 : 1)
    }
}

private struct CardRow: View {
    let card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = card.title {
                Text(title)
                    .font(.headline)
            }
            Text(card.code)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let summary = card.summary, !summary.isEmpty {
                Text(summary.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout)
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
