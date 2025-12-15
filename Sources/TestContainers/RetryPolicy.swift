import Foundation

/// Configuration for automatic container startup retries with exponential backoff and jitter.
///
/// When a container fails to start or satisfy its wait strategy, the system will
/// automatically retry with increasing delays between attempts. This improves reliability
/// in environments with transient failures (network issues, image pull delays, resource contention).
///
/// Example:
/// ```swift
/// let request = ContainerRequest(image: "postgres:15")
///     .withExposedPort(5432)
///     .waitingFor(.tcpPort(5432))
///     .withRetry()  // Uses default policy: 3 attempts, exponential backoff
/// ```
public struct RetryPolicy: Sendable, Hashable {
    /// Maximum number of retry attempts (excluding initial attempt).
    /// For example, `maxAttempts: 3` means up to 4 total attempts (1 initial + 3 retries).
    public var maxAttempts: Int

    /// Initial delay before first retry.
    public var initialDelay: Duration

    /// Maximum delay cap for exponential backoff.
    public var maxDelay: Duration

    /// Multiplier for exponential backoff (delay *= multiplier per attempt).
    public var backoffMultiplier: Double

    /// Jitter factor for randomizing delays (0.0 = no jitter, 0.5 = +/- 50%).
    public var jitter: Double

    /// Default retry policy: 3 attempts, 1s initial, 30s max, 2x backoff, 10% jitter.
    public static let `default` = RetryPolicy(
        maxAttempts: 3,
        initialDelay: .seconds(1),
        maxDelay: .seconds(30),
        backoffMultiplier: 2.0,
        jitter: 0.1
    )

    /// Aggressive retry policy: 5 attempts, 500ms initial, 10s max.
    /// Useful for flaky CI environments where quick retries are preferred.
    public static let aggressive = RetryPolicy(
        maxAttempts: 5,
        initialDelay: .milliseconds(500),
        maxDelay: .seconds(10),
        backoffMultiplier: 2.0,
        jitter: 0.1
    )

    /// Conservative retry policy: 2 attempts, 2s initial, 60s max, 15% jitter.
    /// Useful when you want fewer retries with longer delays.
    public static let conservative = RetryPolicy(
        maxAttempts: 2,
        initialDelay: .seconds(2),
        maxDelay: .seconds(60),
        backoffMultiplier: 2.0,
        jitter: 0.15
    )

    /// Creates a custom retry policy.
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum number of retry attempts (must be positive)
    ///   - initialDelay: Initial delay before first retry (must be positive)
    ///   - maxDelay: Maximum delay cap (must be >= initialDelay)
    ///   - backoffMultiplier: Multiplier for exponential backoff (must be > 1.0)
    ///   - jitter: Jitter factor for randomization (must be in [0.0, 1.0])
    public init(
        maxAttempts: Int,
        initialDelay: Duration,
        maxDelay: Duration,
        backoffMultiplier: Double,
        jitter: Double
    ) {
        precondition(maxAttempts > 0, "maxAttempts must be positive")
        precondition(initialDelay > .zero, "initialDelay must be positive")
        precondition(maxDelay >= initialDelay, "maxDelay must be >= initialDelay")
        precondition(backoffMultiplier > 1.0, "backoffMultiplier must be > 1.0")
        precondition(jitter >= 0.0 && jitter <= 1.0, "jitter must be in [0.0, 1.0]")

        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
        self.jitter = jitter
    }

    /// Calculate delay for a specific attempt (0-indexed).
    ///
    /// - Parameter attempt: The attempt number (0 = initial attempt, no delay)
    /// - Returns: The duration to wait before this attempt
    ///
    /// The delay is calculated using exponential backoff with jitter:
    /// `delay = min(initialDelay * (multiplier ^ attempt), maxDelay) * (1 +/- jitter)`
    public func delay(for attempt: Int) -> Duration {
        guard attempt > 0 else { return .zero }

        // Convert initial delay to seconds for calculation
        let initialSeconds = Double(initialDelay.components.seconds)
            + Double(initialDelay.components.attoseconds) / 1e18

        // Exponential backoff: initialDelay * (multiplier ^ attempt)
        let baseDelay = initialSeconds * pow(backoffMultiplier, Double(attempt))

        // Cap at maxDelay
        let maxSeconds = Double(maxDelay.components.seconds)
            + Double(maxDelay.components.attoseconds) / 1e18
        let cappedDelay = min(baseDelay, maxSeconds)

        // Apply jitter: +/- (jitter * 100)%
        let jitterFactor = 1.0 + Double.random(in: -jitter...jitter)
        let finalDelay = cappedDelay * jitterFactor

        // Convert back to Duration
        let wholeSeconds = Int64(finalDelay)
        let attoseconds = Int64((finalDelay - Double(wholeSeconds)) * 1e18)
        return Duration(secondsComponent: wholeSeconds, attosecondsComponent: attoseconds)
    }
}
