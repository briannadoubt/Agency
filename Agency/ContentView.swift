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
                        ForEach(orderedPhases(from: snapshot), id: \.phase.number) { phase in
                            PhaseRow(phase: phase,
                                     isSelected: selectedPhaseNumber == phase.phase.number)
                                .tag(phase.phase.number)
                                .listRowBackground(phaseRowBackground(isSelected: selectedPhaseNumber == phase.phase.number))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        } detail: {
            DetailView(snapshot: loader.loadedSnapshot,
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
            syncSelection(with: snapshot)
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

    private func orderedPhases(from snapshot: ProjectLoader.ProjectSnapshot) -> [PhaseSnapshot] {
        snapshot.phases.sorted { lhs, rhs in
            if lhs.phase.number == rhs.phase.number { return lhs.phase.label < rhs.phase.label }
            return lhs.phase.number < rhs.phase.number
        }
    }

    private func syncSelection(with snapshot: ProjectLoader.ProjectSnapshot?) {
        guard let snapshot else {
            selectedPhaseNumber = nil
            return
        }

        let phases = orderedPhases(from: snapshot)

        if let selectedPhaseNumber,
           phases.contains(where: { $0.phase.number == selectedPhaseNumber }) {
            return
        }

        selectedPhaseNumber = phases.first?.phase.number
    }

    private func phaseRowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

private struct DetailView: View {
    let snapshot: ProjectLoader.ProjectSnapshot?
    @Binding var selectedPhaseNumber: Int?

    var body: some View {
        if let snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ProjectSummary(snapshot: snapshot)

                    if let phase = selectedPhase(from: snapshot) {
                        PhaseDetail(phase: phase)
                            .id(phase.phase.number)
                    } else {
                        Text("Select a phase to see its cards.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(selectedPhaseNumber ?? -1)
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
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Phase \(phase.phase.number): \(phase.phase.label)")
                    .font(.headline)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Text("\(phase.cards.count) card(s)")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor.opacity(0.85) : .secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
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
    private var statusesWithCards: [CardStatus] {
        CardStatus.allCases.filter { status in
            phase.cards.contains(where: { $0.status == status })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Phase \(phase.phase.number) · \(phase.phase.label)")
                .font(.title2.bold())

            ForEach(statusesWithCards, id: \.self) { status in
                let cardsForStatus = phase.cards.filter { $0.status == status }

                VStack(alignment: .leading, spacing: 8) {
                    Text(statusTitle(for: status))
                        .font(.headline)

                    ForEach(cardsForStatus, id: \.filePath) { card in
                        CardRow(card: card)
                    }
                }
                .padding()
                .background(Color(.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func statusTitle(for status: CardStatus) -> String {
        switch status {
        case .backlog:
            "Backlog"
        case .inProgress:
            "In Progress"
        case .done:
            "Done"
        }
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

#Preview {
    ContentView()
}
