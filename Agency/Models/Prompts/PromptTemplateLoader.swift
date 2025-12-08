import Foundation
import os.log

/// Loads prompt templates with project → app → built-in fallback.
@MainActor
final class PromptTemplateLoader {
    private let logger = Logger(subsystem: "dev.agency.app", category: "PromptTemplateLoader")
    private let fileManager: FileManager
    private var cache: [String: String] = [:]

    /// Directory names for template organization.
    private enum Directory {
        static let prompts = "prompts"
        static let roles = "roles"
        static let flows = "flows"
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Public API

    /// Loads the system template with project override support.
    func loadSystemTemplate(projectRoot: URL?) async throws -> String {
        let cacheKey = "system:\(projectRoot?.path ?? "nil")"
        if let cached = cache[cacheKey] {
            return cached
        }

        let template = try loadTemplate(
            name: "system",
            directory: nil,
            projectRoot: projectRoot,
            fallback: DefaultPromptTemplates.system
        )
        cache[cacheKey] = template
        return template
    }

    /// Loads a role-specific template.
    func loadRoleTemplate(_ role: AgentRole, projectRoot: URL?) async throws -> String {
        let cacheKey = "role:\(role.rawValue):\(projectRoot?.path ?? "nil")"
        if let cached = cache[cacheKey] {
            return cached
        }

        let template = try loadTemplate(
            name: role.templateName,
            directory: Directory.roles,
            projectRoot: projectRoot,
            fallback: DefaultPromptTemplates.role(role)
        )
        cache[cacheKey] = template
        return template
    }

    /// Loads a flow-specific template.
    func loadFlowTemplate(_ flow: AgentFlow, projectRoot: URL?) async throws -> String {
        let cacheKey = "flow:\(flow.rawValue):\(projectRoot?.path ?? "nil")"
        if let cached = cache[cacheKey] {
            return cached
        }

        let template = try loadTemplate(
            name: flow.rawValue,
            directory: Directory.flows,
            projectRoot: projectRoot,
            fallback: DefaultPromptTemplates.flow(flow)
        )
        cache[cacheKey] = template
        return template
    }

    /// Loads AGENTS.md from project root if present.
    func loadAgentsMd(projectRoot: URL) -> String? {
        let agentsMdURL = projectRoot.appendingPathComponent("AGENTS.md")
        guard fileManager.fileExists(atPath: agentsMdURL.path) else { return nil }
        return try? String(contentsOf: agentsMdURL, encoding: .utf8)
    }

    /// Loads CLAUDE.md from project root if present.
    func loadClaudeMd(projectRoot: URL) -> String? {
        let claudeMdURL = projectRoot.appendingPathComponent("CLAUDE.md")
        guard fileManager.fileExists(atPath: claudeMdURL.path) else { return nil }
        return try? String(contentsOf: claudeMdURL, encoding: .utf8)
    }

    /// Clears the template cache.
    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    private func loadTemplate(name: String,
                              directory: String?,
                              projectRoot: URL?,
                              fallback: String) throws -> String {
        // 1. Try project-level template
        if let projectRoot {
            let projectTemplate = templateURL(
                name: name,
                directory: directory,
                base: projectRoot.appendingPathComponent(".agency")
            )
            if let content = readTemplate(at: projectTemplate) {
                logger.debug("Loaded project template: \(projectTemplate.path)")
                return content
            }
        }

        // 2. Try app-level template
        let appTemplate = templateURL(
            name: name,
            directory: directory,
            base: Self.appTemplatesDirectory
        )
        if let content = readTemplate(at: appTemplate) {
            logger.debug("Loaded app template: \(appTemplate.path)")
            return content
        }

        // 3. Use built-in fallback
        logger.debug("Using built-in template for: \(name)")
        return fallback
    }

    private func templateURL(name: String, directory: String?, base: URL) -> URL {
        var url = base.appendingPathComponent(Directory.prompts)
        if let directory {
            url = url.appendingPathComponent(directory)
        }
        return url.appendingPathComponent("\(name).md")
    }

    private func readTemplate(at url: URL) -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// App-level templates directory.
    private static var appTemplatesDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Agency", isDirectory: true)
    }
}

// MARK: - Template Errors

enum PromptTemplateError: LocalizedError {
    case templateNotFound(name: String)
    case invalidTemplate(name: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .templateNotFound(let name):
            return "Template '\(name)' not found."
        case .invalidTemplate(let name, let reason):
            return "Invalid template '\(name)': \(reason)"
        }
    }
}
