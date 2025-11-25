import Foundation

enum CardClaimError: LocalizedError, Equatable {
    case snapshotUnavailable
    case noBacklogCards
    case cardLocked(status: String?)
    case moveFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .snapshotUnavailable:
            return "No project is loaded."
        case .noBacklogCards:
            return "No backlog cards are available to claim."
        case .cardLocked(let status):
            if let status, !status.isEmpty {
                return "Card is locked by agent_status=\(status)."
            }
            return "Card is locked and cannot be claimed."
        case .moveFailed(let message):
            return message
        case .writeFailed(let message):
            return message
        }
    }
}

/// Claims the lowest-numbered backlog card and prepares it for work.
@MainActor
final class CardClaimer {
    private let mover: CardMover
    private let writer: CardMarkdownWriter
    private let parser: CardFileParser
    private let dateProvider: () -> Date
    private let ownerProvider: () -> String?

    init(mover: CardMover = CardMover(),
         writer: CardMarkdownWriter = CardMarkdownWriter(),
         parser: CardFileParser = CardFileParser(),
         dateProvider: @escaping () -> Date = Date.init,
         ownerProvider: @escaping () -> String? = CardClaimer.defaultOwner) {
        self.mover = mover
        self.writer = writer
        self.parser = parser
        self.dateProvider = dateProvider
        self.ownerProvider = ownerProvider
    }

    /// Returns the backlog card that would be claimed without touching disk.
    func previewClaim(in snapshot: ProjectLoader.ProjectSnapshot) throws -> Card {
        let candidate = try lowestBacklogCard(in: snapshot.phases)
        guard !isLocked(candidate) else {
            throw CardClaimError.cardLocked(status: candidate.frontmatter.agentStatus)
        }
        return candidate
    }

    /// Moves the lowest backlog card to in-progress, optionally setting an owner and logging history.
    func claimLowestBacklog(in snapshot: ProjectLoader.ProjectSnapshot,
                            assignOwner: Bool = true,
                            preferredOwner: String? = nil,
                            dryRun: Bool = false) async throws -> Card {
        let candidate = try lowestBacklogCard(in: snapshot.phases)

        guard !isLocked(candidate) else {
            throw CardClaimError.cardLocked(status: candidate.frontmatter.agentStatus)
        }

        guard !dryRun else { return candidate }

        do {
            try await mover.move(card: candidate,
                                 to: .inProgress,
                                 rootURL: snapshot.rootURL,
                                 logHistoryEntry: false)
        } catch let error as CardMoveError {
            throw CardClaimError.moveFailed(error.localizedDescription)
        } catch {
            throw CardClaimError.moveFailed(error.localizedDescription)
        }

        let destinationURL = candidate.filePath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(CardStatus.inProgress.folderName, isDirectory: true)
            .appendingPathComponent(candidate.filePath.lastPathComponent, isDirectory: false)

        do {
            let contents = try String(contentsOf: destinationURL, encoding: .utf8)
            let movedCard = try parser.parse(fileURL: destinationURL, contents: contents)
            let snapshot = try writer.loadSnapshot(for: movedCard)
            var draft = CardDetailFormDraft.from(card: snapshot.card, today: dateProvider())

            if assignOwner, let owner = normalizedOwner(from: preferredOwner ?? ownerProvider()) {
                draft.owner = owner
            }

            draft.newHistoryEntry = claimHistoryEntry(owner: draft.owner)
            let saved = try writer.saveFormDraft(draft,
                                                 appendHistory: true,
                                                 snapshot: snapshot)
            return saved.card
        } catch let error as CardSaveError {
            throw CardClaimError.writeFailed(error.localizedDescription)
        } catch {
            throw CardClaimError.writeFailed(error.localizedDescription)
        }
    }

    private func lowestBacklogCard(in phases: [PhaseSnapshot]) throws -> Card {
        let backlogCards = phases.flatMap { phase in
            phase.cards.filter { $0.status == .backlog }
        }

        guard let lowest = backlogCards.min(by: codeOrdering(_:_:)) else {
            throw CardClaimError.noBacklogCards
        }

        return lowest
    }

    private func isLocked(_ card: Card) -> Bool {
        guard let status = card.frontmatter.agentStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !status.isEmpty else { return false }
        return status != "idle"
    }

    private func normalizedOwner(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func claimHistoryEntry(owner: String?) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: dateProvider())

        if let owner {
            return "\(today) - Claimed by \(owner); moved to In Progress."
        }

        return "\(today) - Claimed and moved to In Progress."
    }

    private func codeOrdering(_ lhs: Card, _ rhs: Card) -> Bool {
        let lhsParts = codeComponents(lhs.code)
        let rhsParts = codeComponents(rhs.code)

        if lhsParts.major == rhsParts.major {
            if lhsParts.minor == rhsParts.minor {
                return lhs.slug < rhs.slug
            }
            return lhsParts.minor < rhsParts.minor
        }

        return lhsParts.major < rhsParts.major
    }

    private func codeComponents(_ code: String) -> (major: Int, minor: Int) {
        let components = code.split(separator: ".", maxSplits: 1).map(String.init)
        let major = Int(components.first ?? "") ?? 0
        let minor = Int(components.dropFirst().first ?? "") ?? 0
        return (major, minor)
    }

    nonisolated private static func defaultOwner() -> String? {
        NSFullUserName()
    }
}
