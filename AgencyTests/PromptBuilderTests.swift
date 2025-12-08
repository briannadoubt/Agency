import Foundation
import Testing
@testable import Agency

@MainActor
struct PromptBuilderTests {

    // MARK: - AgentRole Tests

    @Test func agentRoleHasCorrectDisplayNames() {
        #expect(AgentRole.implementer.displayName == "Implementer")
        #expect(AgentRole.reviewer.displayName == "Reviewer")
        #expect(AgentRole.researcher.displayName == "Researcher")
        #expect(AgentRole.architect.displayName == "Architect")
        #expect(AgentRole.supervisor.displayName == "Supervisor")
    }

    @Test func agentRoleHasCorrectDefaultFlows() {
        #expect(AgentRole.implementer.defaultFlow == .implement)
        #expect(AgentRole.reviewer.defaultFlow == .review)
        #expect(AgentRole.researcher.defaultFlow == .research)
        #expect(AgentRole.architect.defaultFlow == .plan)
        #expect(AgentRole.supervisor.defaultFlow == nil)
    }

    @Test func agentRoleInfersCorrectRoleFromFlow() {
        #expect(AgentRole.role(for: .implement) == .implementer)
        #expect(AgentRole.role(for: .review) == .reviewer)
        #expect(AgentRole.role(for: .research) == .researcher)
        #expect(AgentRole.role(for: .plan) == .architect)
    }

    @Test func agentRoleTemplateNameMatchesRawValue() {
        for role in AgentRole.allCases {
            #expect(role.templateName == role.rawValue)
        }
    }

    // MARK: - PromptContext Tests

    @Test func promptContextCreatesVariablesDictionary() {
        let projectRoot = URL(fileURLWithPath: "/test/project")
        let context = PromptContext(
            projectRoot: projectRoot,
            cardRelativePath: "project/phase-1/backlog/1.1-test.md",
            acceptanceCriteria: ["[ ] First criterion", "[x] Second criterion"],
            cardSummary: "Test summary",
            cardPhase: "1",
            cardCode: "1.1",
            flow: .implement,
            runID: UUID()
        )

        let vars = context.variables

        #expect(vars["PROJECT_ROOT"] == "/test/project")
        #expect(vars["CARD_PATH"] == "project/phase-1/backlog/1.1-test.md")
        #expect(vars["CARD_SUMMARY"] == "Test summary")
        #expect(vars["CARD_PHASE"] == "1")
        #expect(vars["CARD_CODE"] == "1.1")
        #expect(vars["FLOW"] == "implement")
        #expect(vars["ROLE"] == "implementer")
        #expect(vars["ACCEPTANCE_CRITERIA"]?.contains("First criterion") == true)
    }

    @Test func promptContextIncludesOptionalVariablesWhenPresent() {
        let projectRoot = URL(fileURLWithPath: "/test/project")
        let context = PromptContext(
            projectRoot: projectRoot,
            agentsMd: "Agent instructions",
            claudeMd: "Claude instructions",
            cardRelativePath: "card.md",
            flow: .implement,
            runID: UUID(),
            branch: "feature/test"
        )

        let vars = context.variables

        #expect(vars["AGENTS_MD"] == "Agent instructions")
        #expect(vars["CLAUDE_MD"] == "Claude instructions")
        #expect(vars["BRANCH"] == "feature/test")
    }

    @Test func promptContextOmitsNilVariables() {
        let projectRoot = URL(fileURLWithPath: "/test/project")
        let context = PromptContext(
            projectRoot: projectRoot,
            cardRelativePath: "card.md",
            flow: .implement,
            runID: UUID()
        )

        let vars = context.variables

        #expect(vars["AGENTS_MD"] == nil)
        #expect(vars["CLAUDE_MD"] == nil)
        #expect(vars["BRANCH"] == nil)
        #expect(vars["REVIEW_TARGET"] == nil)
        #expect(vars["RESEARCH_PROMPT"] == nil)
    }

    @Test func promptContextFromRequestReturnsNilForInvalidFlow() {
        let request = WorkerRunRequest(
            runID: UUID(),
            flow: "invalid-flow",
            cardRelativePath: "card.md",
            projectBookmark: Data(),
            logDirectory: URL(fileURLWithPath: "/tmp"),
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            allowNetwork: false,
            cliArgs: []
        )

        let context = PromptContext.from(
            request: request,
            projectRoot: URL(fileURLWithPath: "/test")
        )

        #expect(context == nil)
    }

    @Test func promptContextFromRequestExtractsPhaseFromCode() throws {
        let (root, card, _) = try makeSampleCard()
        defer { try? FileManager.default.removeItem(at: root) }

        let request = WorkerRunRequest(
            runID: UUID(),
            flow: "implement",
            cardRelativePath: "project/phase-5/in-progress/5.2-test.md",
            projectBookmark: Data(),
            logDirectory: URL(fileURLWithPath: "/tmp"),
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            allowNetwork: false,
            cliArgs: []
        )

        let context = PromptContext.from(
            request: request,
            projectRoot: root,
            card: card
        )

        #expect(context?.cardPhase == "5")
        #expect(context?.cardCode == "5.2")
    }

    // MARK: - DefaultPromptTemplates Tests

    @Test func defaultTemplatesExistForAllRoles() {
        for role in AgentRole.allCases {
            let template = DefaultPromptTemplates.role(role)
            #expect(!template.isEmpty)
        }
    }

    @Test func defaultTemplatesExistForAllFlows() {
        for flow in AgentFlow.allCases {
            let template = DefaultPromptTemplates.flow(flow)
            #expect(!template.isEmpty)
        }
    }

    @Test func defaultSystemTemplateContainsExpectedVariables() {
        let template = DefaultPromptTemplates.system

        #expect(template.contains("{{CLAUDE_MD}}"))
        #expect(template.contains("{{AGENTS_MD}}"))
        #expect(template.contains("{{CARD_PATH}}"))
        #expect(template.contains("{{CARD_SUMMARY}}"))
        #expect(template.contains("{{ACCEPTANCE_CRITERIA}}"))
    }

    @Test func implementFlowTemplateContainsExpectedVariables() {
        let template = DefaultPromptTemplates.implementFlow

        #expect(template.contains("{{CARD_PATH}}"))
        #expect(template.contains("{{ACCEPTANCE_CRITERIA}}"))
        #expect(template.contains("{{BRANCH}}"))
    }

    @Test func reviewFlowTemplateContainsReviewTarget() {
        let template = DefaultPromptTemplates.reviewFlow

        #expect(template.contains("{{REVIEW_TARGET}}"))
    }

    @Test func researchFlowTemplateContainsResearchPrompt() {
        let template = DefaultPromptTemplates.researchFlow

        #expect(template.contains("{{RESEARCH_PROMPT}}"))
    }

    @Test func planFlowTemplateContainsPlanOutput() {
        let template = DefaultPromptTemplates.planFlow

        #expect(template.contains("{{PLAN_OUTPUT_PATH}}"))
    }

    // MARK: - PromptBuilderError Tests

    @Test func promptBuilderErrorHasCorrectDescription() {
        let error = PromptBuilderError.invalidFlow("bad-flow")
        #expect(error.errorDescription?.contains("bad-flow") == true)
    }

    // MARK: - Helpers

    private func makeSampleCard() throws -> (URL, Card, CardFileParser) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let phaseURL = projectRoot.appendingPathComponent("phase-5", isDirectory: true)
        let inProgress = phaseURL.appendingPathComponent("in-progress", isDirectory: true)
        try fileManager.createDirectory(at: inProgress, withIntermediateDirectories: true)

        let cardURL = inProgress.appendingPathComponent("5.2-test.md")
        let contents = """
        ---
        owner: test
        agent_flow: null
        agent_status: idle
        ---

        # 5.2 Test Card

        Summary:
        Test summary

        Acceptance Criteria:
        - [ ] First
        - [x] Second

        Notes:
        none

        History:
        - 2025-12-07 - Created
        """

        try contents.write(to: cardURL, atomically: true, encoding: .utf8)
        let parser = CardFileParser()
        let card = try parser.parse(fileURL: cardURL, contents: contents)

        return (root, card, parser)
    }
}
