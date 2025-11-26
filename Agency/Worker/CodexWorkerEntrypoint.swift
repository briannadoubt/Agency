import Foundation

/// Helper the real worker target can call from its `@main` entry to share the runtime logic.
enum CodexWorkerEntrypoint {
    static func run(arguments: [String] = CommandLine.arguments) async {
        guard let runtime = CodexWorkerBootstrap.runtimeFromEnvironment(arguments: arguments) else {
            return
        }
        await runtime.run()
    }
}

