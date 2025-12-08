import Foundation
import Observation

/// Manages supervisor configuration persisted in UserDefaults.
@MainActor
@Observable
final class SupervisorSettings {
    static let shared = SupervisorSettings()

    private let defaults: UserDefaults

    private static let autoStartKey = "supervisorAutoStart"
    private static let maxConcurrentKey = "supervisorMaxConcurrent"
    private static let defaultPipelineKey = "supervisorDefaultPipeline"
    private static let autoMoveToStatusKey = "supervisorAutoMoveToStatus"

    /// Whether to auto-start the supervisor when a project is opened.
    var autoStart: Bool {
        didSet {
            defaults.set(autoStart, forKey: Self.autoStartKey)
        }
    }

    /// Maximum concurrent agent runs (1-4).
    var maxConcurrent: Int {
        didSet {
            let clamped = max(1, min(4, maxConcurrent))
            if clamped != maxConcurrent {
                maxConcurrent = clamped
            }
            defaults.set(clamped, forKey: Self.maxConcurrentKey)
        }
    }

    /// Default pipeline for new runs.
    var defaultPipeline: FlowPipeline {
        didSet {
            defaults.set(defaultPipeline.rawValue, forKey: Self.defaultPipelineKey)
        }
    }

    /// Whether to auto-move completed cards to the done status.
    var autoMoveToStatus: Bool {
        didSet {
            defaults.set(autoMoveToStatus, forKey: Self.autoMoveToStatusKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Initialize with defaults first
        self.autoStart = false
        self.maxConcurrent = 1
        self.defaultPipeline = .implementThenReview
        self.autoMoveToStatus = false

        // Then load from UserDefaults (without triggering didSet)
        _autoStart = defaults.bool(forKey: Self.autoStartKey)

        let storedConcurrent = defaults.integer(forKey: Self.maxConcurrentKey)
        _maxConcurrent = storedConcurrent > 0 ? max(1, min(4, storedConcurrent)) : 1

        if let pipelineRaw = defaults.string(forKey: Self.defaultPipelineKey),
           let pipeline = FlowPipeline(rawValue: pipelineRaw) {
            _defaultPipeline = pipeline
        }

        _autoMoveToStatus = defaults.bool(forKey: Self.autoMoveToStatusKey)
    }

    /// Creates an AgentSchedulerConfig from current settings.
    func makeSchedulerConfig() -> AgentSchedulerConfig {
        AgentSchedulerConfig(maxConcurrent: maxConcurrent)
    }

    /// Resets all settings to defaults.
    func resetToDefaults() {
        autoStart = false
        maxConcurrent = 1
        defaultPipeline = .implementThenReview
        autoMoveToStatus = false
    }
}
