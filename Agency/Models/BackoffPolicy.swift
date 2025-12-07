import Foundation

/// Unified backoff policy for retry logic across all layers.
/// Replaces: WorkerBackoffPolicy, AgentBackoffPolicy, AgentRetryPolicy
public struct BackoffPolicy: Equatable, Sendable {
    public let baseDelay: Duration
    public let multiplier: Double
    public let jitter: Double
    public let maxDelay: Duration
    public let maxRetries: Int

    public init(baseDelay: Duration = .seconds(30),
                multiplier: Double = 2.0,
                jitter: Double = 0.1,
                maxDelay: Duration = .seconds(300),
                maxRetries: Int = 5) {
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.jitter = jitter
        self.maxDelay = maxDelay
        self.maxRetries = maxRetries
    }

    /// Convenience initializer using maxAttempts (for AgentRetryPolicy compatibility).
    public init(baseDelay: Duration,
                multiplier: Double = 2.0,
                jitter: Double = 0.1,
                maxDelay: Duration = .seconds(300),
                maxAttempts: Int) {
        self.init(baseDelay: baseDelay,
                  multiplier: multiplier,
                  jitter: jitter,
                  maxDelay: maxDelay,
                  maxRetries: maxAttempts)
    }

    /// Convenience initializer using TimeInterval (for AgentBackoffPolicy compatibility).
    public init(baseDelay: TimeInterval,
                multiplier: Double = 2.0,
                jitterFraction: Double = 0.1,
                maxDelay: TimeInterval = 300,
                maxRetries: Int = 5) {
        self.init(baseDelay: .seconds(baseDelay),
                  multiplier: multiplier,
                  jitter: jitterFraction,
                  maxDelay: .seconds(maxDelay),
                  maxRetries: maxRetries)
    }

    /// Standard policy used by default across the app.
    public static let standard = BackoffPolicy()

    /// Alias for maxRetries (for AgentRetryPolicy compatibility).
    public var maxAttempts: Int { maxRetries }

    /// Computes the delay for a given attempt number (1-based).
    /// Returns nil if attempts exceed maxRetries.
    public func delay(forAttempt attempt: Int) -> Duration? {
        guard attempt > 0, attempt <= maxRetries else { return nil }
        return delay(forAttempt: attempt, random: { Double.random(in: $0) })
    }

    /// Computes the delay for a given attempt number with a custom random function (for testing).
    public func delay(forAttempt attempt: Int,
                      random: (ClosedRange<Double>) -> Double) -> Duration? {
        guard attempt > 0, attempt <= maxRetries else { return nil }

        let baseSeconds = baseDelay.seconds
        let scaled = baseSeconds * pow(multiplier, Double(attempt - 1))
        let jitterSpan = scaled * jitter
        let delta = random(-jitterSpan...jitterSpan)
        let clampedSeconds = min(scaled + delta, maxDelay.seconds)

        return .seconds(clampedSeconds)
    }

    /// Computes the delay for a failure count (1-based).
    /// This is an alias for delay(forAttempt:) for backward compatibility.
    public func delay(forFailureCount failures: Int) -> Duration {
        delay(forAttempt: failures) ?? .zero
    }

    /// Computes the delay for a failure count, returning TimeInterval (for AgentBackoffPolicy compatibility).
    /// Returns nil if failures is 0 or exceeds maxRetries.
    public func delayInterval(forFailureCount failures: Int) -> TimeInterval? {
        guard let duration = delay(forAttempt: failures) else { return nil }
        return duration.seconds
    }

    /// Computes the delay using a custom random generator (for WorkerBackoffPolicy compatibility).
    public func delay<T: RandomNumberGenerator>(forFailureCount failures: Int,
                                                 using generator: inout T) -> Duration {
        guard failures > 0 else { return .zero }
        let cappedFailures = min(failures - 1, maxRetries)
        let exponentialSeconds = baseDelay.seconds * pow(multiplier, Double(cappedFailures))
        let jitterRange = exponentialSeconds * jitter
        let jitterOffset = Double.random(in: -jitterRange...jitterRange, using: &generator)
        let candidateSeconds = exponentialSeconds + jitterOffset
        let clampedSeconds = min(max(0, candidateSeconds), maxDelay.seconds)
        return .seconds(clampedSeconds)
    }
}

// MARK: - Backward Compatibility Typealiases

/// Typealias for gradual migration from WorkerBackoffPolicy.
public typealias WorkerBackoffPolicy = BackoffPolicy

/// Typealias for gradual migration from AgentRetryPolicy.
public typealias AgentRetryPolicy = BackoffPolicy

/// Typealias for gradual migration from AgentBackoffPolicy.
public typealias AgentBackoffPolicy = BackoffPolicy

// MARK: - Duration Extension

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
    }
}
