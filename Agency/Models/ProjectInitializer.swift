import Foundation

/// Options controlling how the project initializer behaves.
struct ProjectInitializationOptions: Equatable {
    let projectRoot: URL
    let roadmapPath: URL?
    let goal: String?
    let dryRun: Bool
    let applyChanges: Bool

    init(projectRoot: URL,
         roadmapPath: URL? = nil,
         goal: String? = nil,
         dryRun: Bool = true,
         applyChanges: Bool = false) {
        self.projectRoot = projectRoot
        self.roadmapPath = roadmapPath
        self.goal = goal
        self.dryRun = dryRun
        self.applyChanges = applyChanges && !dryRun
    }

    var shouldWrite: Bool { applyChanges && !dryRun }

    var resolvedRoadmapPath: URL {
        roadmapPath ?? projectRoot.appendingPathComponent("ROADMAP.md")
    }
}

/// Outcome of running the initializer. When `dryRun` is true, the entries are a preview of planned writes.
struct ProjectInitializationResult: Codable, Equatable {
    let dryRun: Bool
    let roadmapPath: String
    let createdDirectories: [String]
    let createdFiles: [String]
    let skipped: [String]
    let warnings: [String]

    var hasWarnings: Bool { !warnings.isEmpty }
}

enum ProjectInitializationError: LocalizedError, Equatable {
    case missingRoadmap(URL)
    case invalidRoadmap(URL)
    case emptyRoadmap
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRoadmap(let url):
            return "Missing ROADMAP.md (looked in \(url.path))."
        case .invalidRoadmap:
            return "ROADMAP.md is missing a valid machine-readable block."
        case .emptyRoadmap:
            return "Roadmap has no phases; cannot lay out project structure."
        case .generationFailed(let message):
            return message
        }
    }
}

/// Materializes the project folder structure from a roadmap file.
@MainActor
struct ProjectInitializer {
    private let fileManager: FileManager
    private let parser: RoadmapParser
    private let generator: RoadmapGenerator

    init(fileManager: FileManager = .default,
         parser: RoadmapParser = RoadmapParser(),
         generator: RoadmapGenerator = RoadmapGenerator()) {
        self.fileManager = fileManager
        self.parser = parser
        self.generator = generator
    }

    func initialize(options: ProjectInitializationOptions) throws -> ProjectInitializationResult {
        var createdDirectories: [String] = []
        var createdFiles: [String] = []
        var skipped: [String] = []
        var warnings: [String] = []

        prepareRootDirectory(options: options,
                             createdDirectories: &createdDirectories,
                             warnings: &warnings)

        let (document, roadmapSource, roadmapDestination) = try resolveRoadmap(options: options,
                                                                               createdFiles: &createdFiles,
                                                                               warnings: &warnings)

        guard !document.phases.isEmpty else { throw ProjectInitializationError.emptyRoadmap }

        let projectURL = options.projectRoot.appendingPathComponent(ProjectConventions.projectRootName,
                                                                   isDirectory: true)
        ensureDirectory(projectURL,
                        root: options.projectRoot,
                        createdDirectories: &createdDirectories,
                        skipped: &skipped,
                        warnings: &warnings,
                        shouldWrite: options.shouldWrite)

        for phase in document.phases {
            let phaseDirectory = projectURL.appendingPathComponent("phase-\(phase.number)-\(phase.label)",
                                                                  isDirectory: true)
            ensureDirectory(phaseDirectory,
                            root: options.projectRoot,
                            createdDirectories: &createdDirectories,
                            skipped: &skipped,
                            warnings: &warnings,
                            shouldWrite: options.shouldWrite)

            for status in CardStatus.allCases {
                let statusDirectory = phaseDirectory.appendingPathComponent(status.folderName, isDirectory: true)
                ensureDirectory(statusDirectory,
                                root: options.projectRoot,
                                createdDirectories: &createdDirectories,
                                skipped: &skipped,
                                warnings: &warnings,
                                shouldWrite: options.shouldWrite)

                let gitkeep = statusDirectory.appendingPathComponent(".gitkeep")
                if !fileManager.fileExists(atPath: gitkeep.path) {
                    if options.shouldWrite {
                        fileManager.createFile(atPath: gitkeep.path, contents: Data())
                    }
                    createdFiles.append(relativePath(of: gitkeep, from: options.projectRoot))
                } else {
                    skipped.append(relativePath(of: gitkeep, from: options.projectRoot))
                }
            }
        }

        if roadmapDestination != roadmapSource,
           !fileManager.fileExists(atPath: roadmapDestination.path) {
            if options.shouldWrite {
                try fileManager.copyItem(at: roadmapSource, to: roadmapDestination)
            }
            createdFiles.append(relativePath(of: roadmapDestination, from: options.projectRoot))
        }

        return ProjectInitializationResult(dryRun: options.dryRun,
                                           roadmapPath: relativePath(of: roadmapDestination, from: options.projectRoot),
                                           createdDirectories: createdDirectories.uniquePreservingOrder(),
                                           createdFiles: createdFiles.uniquePreservingOrder(),
                                           skipped: skipped.uniquePreservingOrder(),
                                           warnings: warnings.uniquePreservingOrder())
    }

    // MARK: - Helpers

    private func resolveRoadmap(options: ProjectInitializationOptions,
                                createdFiles: inout [String],
                                warnings: inout [String]) throws -> (RoadmapDocument, URL, URL) {
        let destination = options.projectRoot.appendingPathComponent("ROADMAP.md")
        let source = options.resolvedRoadmapPath

        if fileManager.fileExists(atPath: source.path) {
            let contents = try String(contentsOf: source, encoding: .utf8)
            let parsed = parser.parse(contents: contents)
            guard let document = parsed.document else { throw ProjectInitializationError.invalidRoadmap(source) }
            return (document, source, destination)
        }

        guard let goal = options.goal else {
            throw ProjectInitializationError.missingRoadmap(source)
        }

        do {
            let result = try generator.generate(goal: goal,
                                                at: options.projectRoot,
                                                writeToDisk: options.shouldWrite)
            createdFiles.append(relativePath(of: result.roadmapURL, from: options.projectRoot))
            return (result.document, result.roadmapURL, destination)
        } catch {
            throw ProjectInitializationError.generationFailed(error.localizedDescription)
        }
    }

    private func prepareRootDirectory(options: ProjectInitializationOptions,
                                      createdDirectories: inout [String],
                                      warnings: inout [String]) {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: options.projectRoot.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                warnings.append("Cannot initialize because \(options.projectRoot.path) is a file.")
            }
            return
        }

        if options.shouldWrite {
            do {
                try fileManager.createDirectory(at: options.projectRoot, withIntermediateDirectories: true)
            } catch {
                warnings.append("Failed to create root directory: \(error.localizedDescription)")
            }
        }
        createdDirectories.append(options.projectRoot.lastPathComponent)
    }

    private func ensureDirectory(_ url: URL,
                                 root: URL,
                                 createdDirectories: inout [String],
                                 skipped: inout [String],
                                 warnings: inout [String],
                                 shouldWrite: Bool) {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                skipped.append(relativePath(of: url, from: root))
            } else {
                warnings.append("Path exists as a file: \(relativePath(of: url, from: root))")
            }
            return
        }

        if shouldWrite {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                warnings.append("Failed to create directory \(relativePath(of: url, from: root)): \(error.localizedDescription)")
            }
        }
        createdDirectories.append(relativePath(of: url, from: root))
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        url.path.replacingOccurrences(of: root.path + "/", with: "")
    }
}

private extension Array where Element: Hashable {
    func uniquePreservingOrder() -> [Element] {
        var seen: Set<Element> = []
        var result: [Element] = []
        for element in self where !seen.contains(element) {
            seen.insert(element)
            result.append(element)
        }
        return result
    }
}

// MARK: - CLI wrapper

enum ProjectInitializationParseError: LocalizedError {
    case missingProjectRoot

    var errorDescription: String? {
        switch self {
        case .missingProjectRoot:
            return "--project-root is required."
        }
    }
}

/// CLI-style wrapper that mirrors the phase scaffolding command behavior for agent integration.
struct ProjectInitializationCommand {
    struct Output {
        let exitCode: Int
        let stdout: String
        let result: ProjectInitializationResult?
    }

    @MainActor
    func run(arguments: [String], fileManager: FileManager = .default) async -> Output {
        var stdout = ""
        func write(_ line: String) {
            stdout.append(line)
            stdout.append("\n")
        }

        do {
            let options = try parse(arguments: arguments)
            write("Project initialization starting…")
            write("Mode: \(options.dryRun ? "dry-run (no writes)" : "apply")")
            write("Project root: \(options.projectRoot.path)")
            write("Roadmap: \(options.resolvedRoadmapPath.path)")

            let initializer = ProjectInitializer(fileManager: fileManager,
                                                 parser: RoadmapParser(),
                                                 generator: RoadmapGenerator(fileManager: fileManager,
                                                                             scanner: ProjectScanner(fileManager: fileManager,
                                                                                                     parser: CardFileParser()),
                                                                             parser: RoadmapParser(),
                                                                             renderer: RoadmapRenderer()))
            let result = try initializer.initialize(options: options)

            for dir in result.createdDirectories {
                write("create: \(dir)")
            }
            for file in result.createdFiles {
                write("write: \(file)")
            }
            for skip in result.skipped {
                write("skip: \(skip)")
            }
            for warning in result.warnings {
                write("warning: \(warning)")
            }

            if result.dryRun {
                write("Dry run complete. Re-run with --yes to apply changes.")
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                write(json)
            }

            return Output(exitCode: 0, stdout: stdout, result: result)
        } catch let error as ProjectInitializationParseError {
            write("error: \(error.localizedDescription)")
            return Output(exitCode: 3, stdout: stdout, result: nil)
        } catch let error as ProjectInitializationError {
            write("error: \(error.localizedDescription)")
            let exitCode: Int
            switch error {
            case .missingRoadmap:
                exitCode = 4
            case .invalidRoadmap:
                exitCode = 5
            case .emptyRoadmap:
                exitCode = 6
            case .generationFailed:
                exitCode = 7
            }
            return Output(exitCode: exitCode, stdout: stdout, result: nil)
        } catch {
            write("error: \(error.localizedDescription)")
            return Output(exitCode: 1, stdout: stdout, result: nil)
        }
    }

    // MARK: - Argument Parsing

    private func parse(arguments: [String]) throws -> ProjectInitializationOptions {
        var projectRoot: URL?
        var roadmapPath: URL?
        var goal: String?
        var dryRun = true
        var applyChanges = false

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--project-root":
                index += 1
                guard index < arguments.count else { throw ProjectInitializationParseError.missingProjectRoot }
                projectRoot = URL(fileURLWithPath: arguments[index])
            case "--roadmap":
                index += 1
                guard index < arguments.count else { break }
                roadmapPath = URL(fileURLWithPath: arguments[index])
            case "--goal":
                index += 1
                guard index < arguments.count else { break }
                goal = arguments[index]
            case "--yes", "--apply":
                applyChanges = true
                dryRun = false
            case "--dry-run":
                dryRun = true
                applyChanges = false
            default:
                break
            }
            index += 1
        }

        guard let projectRoot else { throw ProjectInitializationParseError.missingProjectRoot }

        return ProjectInitializationOptions(projectRoot: projectRoot,
                                             roadmapPath: roadmapPath,
                                             goal: goal,
                                             dryRun: dryRun,
                                             applyChanges: applyChanges)
    }
}
