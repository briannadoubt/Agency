import Foundation
import os.log

/// Defines multi-step agent workflows that chain flows together.
enum FlowPipeline: String, Codable, Sendable, CaseIterable {
    /// Just run the implement flow.
    case implementOnly = "implement-only"

    /// Implement, then review the changes.
    case implementThenReview = "implement-review"

    /// Research first, then implement.
    case researchThenImplement = "research-implement"

    /// Full pipeline: research → plan → implement → review.
    case fullPipeline = "full"

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .implementOnly: return "Implement Only"
        case .implementThenReview: return "Implement → Review"
        case .researchThenImplement: return "Research → Implement"
        case .fullPipeline: return "Full Pipeline"
        }
    }

    /// The first flow in this pipeline.
    var startingFlow: AgentFlow {
        switch self {
        case .implementOnly: return .implement
        case .implementThenReview: return .implement
        case .researchThenImplement: return .research
        case .fullPipeline: return .research
        }
    }

    /// All flows in this pipeline in order.
    var flows: [AgentFlow] {
        switch self {
        case .implementOnly: return [.implement]
        case .implementThenReview: return [.implement, .review]
        case .researchThenImplement: return [.research, .implement]
        case .fullPipeline: return [.research, .plan, .implement, .review]
        }
    }
}

/// Result of a flow completion that determines what happens next.
enum FlowCompletionAction: Equatable, Sendable {
    /// Continue to the next flow in the pipeline.
    case continueToNextFlow(AgentFlow)

    /// Pipeline is complete, move card to done.
    case pipelineComplete

    /// Flow failed, retry with backoff.
    case retryWithBackoff(Duration)

    /// Flow failed permanently, stop processing.
    case abort(reason: String)
}

/// Tracks the state of a pipeline execution for a single card.
struct PipelineExecution: Codable, Equatable, Sendable {
    let cardPath: String
    let pipeline: FlowPipeline
    let currentFlowIndex: Int
    let startedAt: Date
    let flowResults: [FlowResult]

    struct FlowResult: Codable, Equatable, Sendable {
        let flow: AgentFlow
        let status: String
        let completedAt: Date
        let duration: TimeInterval
    }

    var currentFlow: AgentFlow? {
        guard pipeline.flows.indices.contains(currentFlowIndex) else { return nil }
        return pipeline.flows[currentFlowIndex]
    }

    var isComplete: Bool {
        currentFlowIndex >= pipeline.flows.count
    }

    func advancing(with result: FlowResult) -> PipelineExecution {
        PipelineExecution(
            cardPath: cardPath,
            pipeline: pipeline,
            currentFlowIndex: currentFlowIndex + 1,
            startedAt: startedAt,
            flowResults: flowResults + [result]
        )
    }
}

/// Orchestrates multi-step agent flows for cards.
@MainActor
final class FlowPipelineOrchestrator {
    private let logger = Logger(subsystem: "dev.agency.app", category: "FlowPipelineOrchestrator")
    private let backoffPolicy: BackoffPolicy
    private let dateProvider: @Sendable () -> Date

    /// Active pipeline executions by card path.
    private var executions: [String: PipelineExecution] = [:]

    /// Failure counts by card path for backoff calculation.
    private var failureCounts: [String: Int] = [:]

    init(backoffPolicy: BackoffPolicy = .standard,
         dateProvider: @escaping @Sendable () -> Date = Date.init) {
        self.backoffPolicy = backoffPolicy
        self.dateProvider = dateProvider
    }

    // MARK: - Public API

    /// Starts a new pipeline execution for a card.
    func startPipeline(cardPath: String, pipeline: FlowPipeline) -> AgentFlow {
        let execution = PipelineExecution(
            cardPath: cardPath,
            pipeline: pipeline,
            currentFlowIndex: 0,
            startedAt: dateProvider(),
            flowResults: []
        )
        executions[cardPath] = execution
        failureCounts[cardPath] = 0

        logger.info("Started \(pipeline.rawValue) pipeline for \(cardPath)")
        return pipeline.startingFlow
    }

    /// Returns the next flow after the current one completes successfully.
    func nextFlow(after current: AgentFlow, pipeline: FlowPipeline) -> AgentFlow? {
        guard let currentIndex = pipeline.flows.firstIndex(of: current) else {
            return nil
        }
        let nextIndex = currentIndex + 1
        guard pipeline.flows.indices.contains(nextIndex) else {
            return nil
        }
        return pipeline.flows[nextIndex]
    }

    /// Called when a flow completes. Returns the action to take next.
    func onFlowCompleted(
        cardPath: String,
        runID: UUID,
        flow: AgentFlow,
        result: WorkerRunResult
    ) -> FlowCompletionAction {
        guard var execution = executions[cardPath] else {
            logger.warning("No active execution for \(cardPath)")
            return .abort(reason: "No active pipeline execution")
        }

        let flowResult = PipelineExecution.FlowResult(
            flow: flow,
            status: result.status.rawValue,
            completedAt: dateProvider(),
            duration: result.duration
        )

        switch result.status {
        case .succeeded:
            failureCounts[cardPath] = 0
            execution = execution.advancing(with: flowResult)
            executions[cardPath] = execution

            if let nextFlow = execution.currentFlow {
                logger.info("Flow \(flow.rawValue) succeeded for \(cardPath); continuing to \(nextFlow.rawValue)")
                return .continueToNextFlow(nextFlow)
            } else {
                logger.info("Pipeline complete for \(cardPath)")
                executions.removeValue(forKey: cardPath)
                return .pipelineComplete
            }

        case .failed:
            let failures = (failureCounts[cardPath] ?? 0) + 1
            failureCounts[cardPath] = failures

            if failures >= self.backoffPolicy.maxAttempts {
                logger.warning("Flow \(flow.rawValue) failed \(failures) times for \(cardPath); aborting")
                executions.removeValue(forKey: cardPath)
                return .abort(reason: "Exceeded maximum retry attempts (\(self.backoffPolicy.maxAttempts))")
            }

            let delay = self.backoffPolicy.delay(forFailureCount: failures)
            logger.info("Flow \(flow.rawValue) failed for \(cardPath); retry \(failures)/\(self.backoffPolicy.maxAttempts) after \(delay)")
            return .retryWithBackoff(delay)

        case .canceled:
            logger.info("Flow \(flow.rawValue) canceled for \(cardPath)")
            executions.removeValue(forKey: cardPath)
            return .abort(reason: "Canceled by user")
        }
    }

    /// Gets the current execution state for a card.
    func execution(for cardPath: String) -> PipelineExecution? {
        executions[cardPath]
    }

    /// Gets the current flow for a card if it's in a pipeline.
    func currentFlow(for cardPath: String) -> AgentFlow? {
        executions[cardPath]?.currentFlow
    }

    /// Cancels an active pipeline execution.
    func cancelPipeline(cardPath: String) {
        executions.removeValue(forKey: cardPath)
        failureCounts.removeValue(forKey: cardPath)
        logger.info("Canceled pipeline for \(cardPath)")
    }

    /// Returns all active pipeline executions.
    var activeExecutions: [PipelineExecution] {
        Array(executions.values)
    }

    // MARK: - Pipeline Selection Helpers

    /// Suggests a pipeline based on card content and state.
    static func suggestPipeline(for card: Card) -> FlowPipeline {
        // If card has explicit agent_flow, use single-flow pipeline
        if let flowString = card.frontmatter.agentFlow,
           let flow = AgentFlow(rawValue: flowString) {
            switch flow {
            case .implement:
                return .implementThenReview
            case .review:
                return .implementOnly // Just review existing work
            case .research:
                return .researchThenImplement
            case .plan:
                return .fullPipeline
            }
        }

        // Default to implement + review
        return .implementThenReview
    }

    /// Determines if a card needs research before implementation.
    static func needsResearch(_ card: Card) -> Bool {
        // Check if card mentions research or investigation
        guard let summary = card.summary?.lowercased() else { return false }
        let researchKeywords = ["research", "investigate", "explore", "understand", "analyze"]
        return researchKeywords.contains { summary.contains($0) }
    }
}
