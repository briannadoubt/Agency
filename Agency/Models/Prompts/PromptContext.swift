import Foundation

/// Context containing all variables needed to build a prompt.
struct PromptContext: Sendable, Equatable {
    // MARK: - System Context

    /// The project root directory.
    let projectRoot: URL

    /// Contents of AGENTS.md at project root, if present.
    let agentsMd: String?

    /// Contents of CLAUDE.md at project root, if present.
    let claudeMd: String?

    // MARK: - Card Context

    /// The card being processed, if available.
    let card: Card?

    /// Relative path to the card file from project root.
    let cardRelativePath: String

    /// The card's acceptance criteria as strings.
    let acceptanceCriteria: [String]

    /// The card's summary text.
    let cardSummary: String?

    /// The card's phase identifier (e.g., "1", "2").
    let cardPhase: String?

    /// The card's code identifier (e.g., "1.3").
    let cardCode: String?

    // MARK: - Flow Context

    /// The agent flow being executed.
    let flow: AgentFlow

    /// The agent role for this run.
    let role: AgentRole

    /// Unique identifier for this run.
    let runID: UUID

    // MARK: - Flow-Specific Context

    /// Branch name for implement flow.
    let branch: String?

    /// Target branch or commit for review flow.
    let reviewTarget: String?

    /// Research topic or prompt for research flow.
    let researchPrompt: String?

    /// Plan output directory for plan flow.
    let planOutputPath: String?

    // MARK: - Initialization

    init(projectRoot: URL,
         agentsMd: String? = nil,
         claudeMd: String? = nil,
         card: Card? = nil,
         cardRelativePath: String,
         acceptanceCriteria: [String] = [],
         cardSummary: String? = nil,
         cardPhase: String? = nil,
         cardCode: String? = nil,
         flow: AgentFlow,
         role: AgentRole? = nil,
         runID: UUID,
         branch: String? = nil,
         reviewTarget: String? = nil,
         researchPrompt: String? = nil,
         planOutputPath: String? = nil) {
        self.projectRoot = projectRoot
        self.agentsMd = agentsMd
        self.claudeMd = claudeMd
        self.card = card
        self.cardRelativePath = cardRelativePath
        self.acceptanceCriteria = acceptanceCriteria
        self.cardSummary = cardSummary
        self.cardPhase = cardPhase
        self.cardCode = cardCode
        self.flow = flow
        self.role = role ?? AgentRole.role(for: flow)
        self.runID = runID
        self.branch = branch
        self.reviewTarget = reviewTarget
        self.researchPrompt = researchPrompt
        self.planOutputPath = planOutputPath
    }

    // MARK: - Convenience Factory

    /// Creates a context from a WorkerRunRequest.
    /// - Parameters:
    ///   - request: The worker run request
    ///   - projectRoot: The project root URL
    ///   - card: Optional card being processed
    ///   - agentsMd: Optional AGENTS.md content
    ///   - claudeMd: Optional CLAUDE.md content
    ///   - branch: Optional branch name for implement flow
    ///   - reviewTarget: Optional review target for review flow
    ///   - researchPrompt: Optional research topic for research flow
    static func from(request: WorkerRunRequest,
                     projectRoot: URL,
                     card: Card? = nil,
                     agentsMd: String? = nil,
                     claudeMd: String? = nil,
                     branch: String? = nil,
                     reviewTarget: String? = nil,
                     researchPrompt: String? = nil) -> PromptContext? {
        // Parse flow from string
        guard let flow = AgentFlow(rawValue: request.flow) else {
            return nil
        }

        let criteria: [String]
        if let card {
            criteria = card.acceptanceCriteria.map { criterion in
                let prefix = criterion.isComplete ? "[x]" : "[ ]"
                return "\(prefix) \(criterion.title)"
            }
        } else {
            criteria = []
        }

        // Extract phase from code (e.g., "1.3" -> "1")
        let cardPhase: String?
        if let code = card?.code {
            cardPhase = code.split(separator: ".").first.map(String.init)
        } else {
            cardPhase = nil
        }

        return PromptContext(
            projectRoot: projectRoot,
            agentsMd: agentsMd,
            claudeMd: claudeMd,
            card: card,
            cardRelativePath: request.cardRelativePath,
            acceptanceCriteria: criteria,
            cardSummary: card?.summary,
            cardPhase: cardPhase,
            cardCode: card?.code,
            flow: flow,
            role: AgentRole.role(for: flow),
            runID: request.runID,
            branch: branch,
            reviewTarget: reviewTarget,
            researchPrompt: researchPrompt
        )
    }
}

// MARK: - Variable Resolution

extension PromptContext {
    /// All available template variables and their values.
    var variables: [String: String] {
        var vars: [String: String] = [
            "PROJECT_ROOT": projectRoot.path,
            "CARD_PATH": cardRelativePath,
            "FLOW": flow.rawValue,
            "ROLE": role.rawValue,
            "RUN_ID": runID.uuidString
        ]

        // Optional system context
        if let agentsMd {
            vars["AGENTS_MD"] = agentsMd
        }
        if let claudeMd {
            vars["CLAUDE_MD"] = claudeMd
        }

        // Optional card context
        if let cardSummary {
            vars["CARD_SUMMARY"] = cardSummary
        }
        if let cardPhase {
            vars["CARD_PHASE"] = cardPhase
        }
        if let cardCode {
            vars["CARD_CODE"] = cardCode
        }
        if !acceptanceCriteria.isEmpty {
            vars["ACCEPTANCE_CRITERIA"] = acceptanceCriteria.joined(separator: "\n")
        }

        // Flow-specific context
        if let branch {
            vars["BRANCH"] = branch
        }
        if let reviewTarget {
            vars["REVIEW_TARGET"] = reviewTarget
        }
        if let researchPrompt {
            vars["RESEARCH_PROMPT"] = researchPrompt
        }
        if let planOutputPath {
            vars["PLAN_OUTPUT_PATH"] = planOutputPath
        }

        return vars
    }
}
