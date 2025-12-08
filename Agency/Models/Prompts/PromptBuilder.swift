import Foundation
import os.log

/// Builds prompts by combining templates and resolving variables.
@MainActor
final class PromptBuilder {
    private let logger = Logger(subsystem: "dev.agency.app", category: "PromptBuilder")
    private let templateLoader: PromptTemplateLoader

    init(templateLoader: PromptTemplateLoader = PromptTemplateLoader()) {
        self.templateLoader = templateLoader
    }

    // MARK: - Public API

    /// Builds a complete prompt for the given context.
    func build(context: PromptContext) async throws -> String {
        // Load templates
        let systemTemplate = try await templateLoader.loadSystemTemplate(projectRoot: context.projectRoot)
        let roleTemplate = try await templateLoader.loadRoleTemplate(context.role, projectRoot: context.projectRoot)
        let flowTemplate = try await templateLoader.loadFlowTemplate(context.flow, projectRoot: context.projectRoot)

        // Combine templates
        let combined = """
        \(systemTemplate)

        \(roleTemplate)

        \(flowTemplate)
        """

        // Resolve variables
        let resolved = resolveVariables(in: combined, context: context)

        logger.debug("Built prompt for \(context.role.rawValue)/\(context.flow.rawValue) (\(resolved.count) chars)")

        return resolved
    }

    /// Builds a simple prompt without role template (for backwards compatibility).
    func buildSimple(context: PromptContext) async throws -> String {
        let flowTemplate = try await templateLoader.loadFlowTemplate(context.flow, projectRoot: context.projectRoot)
        return resolveVariables(in: flowTemplate, context: context)
    }

    /// Loads project-specific markdown files for context.
    func loadProjectContext(projectRoot: URL) -> (agentsMd: String?, claudeMd: String?) {
        let agentsMd = templateLoader.loadAgentsMd(projectRoot: projectRoot)
        let claudeMd = templateLoader.loadClaudeMd(projectRoot: projectRoot)
        return (agentsMd, claudeMd)
    }

    // MARK: - Variable Resolution

    /// Resolves variables in a template string.
    ///
    /// Supports:
    /// - `{{VARIABLE}}` - Simple variable substitution
    /// - `{{#VARIABLE}}...{{/VARIABLE}}` - Conditional blocks (included if variable is set)
    private func resolveVariables(in template: String, context: PromptContext) -> String {
        var result = template
        let variables = context.variables

        // First, process conditional blocks
        result = resolveConditionalBlocks(in: result, variables: variables)

        // Then, substitute simple variables
        result = substituteVariables(in: result, variables: variables)

        // Clean up any remaining unresolved variables
        result = cleanupUnresolvedVariables(in: result)

        return result
    }

    /// Resolves conditional blocks like `{{#VAR}}content{{/VAR}}`.
    private func resolveConditionalBlocks(in template: String, variables: [String: String]) -> String {
        var result = template

        // Pattern: {{#VARIABLE}}...{{/VARIABLE}}
        let pattern = #"\{\{#(\w+)\}\}([\s\S]*?)\{\{/\1\}\}"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return result
        }

        // Process from end to start to maintain correct ranges
        let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            guard let varRange = Range(match.range(at: 1), in: result),
                  let contentRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else {
                continue
            }

            let variableName = String(result[varRange])
            let content = String(result[contentRange])

            if let value = variables[variableName], !value.isEmpty {
                // Variable is set - include content with variable resolved
                let resolvedContent = content.replacingOccurrences(of: "{{\(variableName)}}", with: value)
                result.replaceSubrange(fullRange, with: resolvedContent)
            } else {
                // Variable is not set - remove entire block
                result.replaceSubrange(fullRange, with: "")
            }
        }

        return result
    }

    /// Substitutes simple variables like `{{VARIABLE}}`.
    private func substituteVariables(in template: String, variables: [String: String]) -> String {
        var result = template

        for (name, value) in variables {
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
        }

        return result
    }

    /// Removes any unresolved variable placeholders.
    private func cleanupUnresolvedVariables(in template: String) -> String {
        var result = template

        // Remove simple unresolved variables
        let simplePattern = #"\{\{\w+\}\}"#
        if let regex = try? NSRegularExpression(pattern: simplePattern, options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Remove any remaining conditional blocks
        let blockPattern = #"\{\{[#/]\w+\}\}"#
        if let regex = try? NSRegularExpression(pattern: blockPattern, options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Clean up multiple consecutive blank lines
        let blankLinesPattern = #"\n{3,}"#
        if let regex = try? NSRegularExpression(pattern: blankLinesPattern, options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\n\n"
            )
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Convenience Extensions

extension PromptBuilder {
    /// Creates a context and builds a prompt from a WorkerRunRequest.
    func build(from request: WorkerRunRequest,
               projectRoot: URL,
               card: Card? = nil,
               branch: String? = nil,
               reviewTarget: String? = nil,
               researchPrompt: String? = nil) async throws -> String {
        let (agentsMd, claudeMd) = loadProjectContext(projectRoot: projectRoot)

        guard let context = PromptContext.from(
            request: request,
            projectRoot: projectRoot,
            card: card,
            agentsMd: agentsMd,
            claudeMd: claudeMd,
            branch: branch,
            reviewTarget: reviewTarget,
            researchPrompt: researchPrompt
        ) else {
            throw PromptBuilderError.invalidFlow(request.flow)
        }

        return try await build(context: context)
    }
}

// MARK: - Errors

enum PromptBuilderError: LocalizedError {
    case invalidFlow(String)

    var errorDescription: String? {
        switch self {
        case .invalidFlow(let flow):
            return "Invalid agent flow: '\(flow)'"
        }
    }
}
