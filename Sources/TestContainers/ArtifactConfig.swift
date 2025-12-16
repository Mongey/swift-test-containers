import Foundation

/// Configuration for test artifact collection.
///
/// Use the builder pattern to configure artifact behavior:
/// ```swift
/// let config = ArtifactConfig()
///     .withOutputDirectory("/tmp/test-artifacts")
///     .withTrigger(.always)
///     .withRetentionPolicy(.keepLast(5))
/// ```
public struct ArtifactConfig: Sendable, Hashable {
    /// Enable or disable artifact collection
    public var enabled: Bool

    /// Base directory for artifacts (default: ./.testcontainers-artifacts)
    public var outputDirectory: String

    /// Whether to collect container logs
    public var collectLogs: Bool

    /// Whether to collect container metadata (inspect JSON)
    public var collectMetadata: Bool

    /// Whether to collect the original ContainerRequest
    public var collectRequest: Bool

    /// When to collect artifacts
    public var trigger: CollectionTrigger

    /// How long to keep artifacts
    public var retentionPolicy: RetentionPolicy

    /// When to collect artifacts.
    public enum CollectionTrigger: Sendable, Hashable {
        /// Only collect on test failure (default)
        case onFailure
        /// Always collect (even on success)
        case always
        /// Only collect on wait strategy timeout
        case onTimeout
    }

    /// How long to keep artifacts.
    public enum RetentionPolicy: Sendable, Hashable {
        /// Keep all artifacts forever
        case keepAll
        /// Keep only the last N artifact directories
        case keepLast(Int)
        /// Keep artifacts for N days
        case keepForDays(Int)
    }

    /// Create a new artifact configuration with default values.
    ///
    /// Default values:
    /// - `enabled`: true
    /// - `outputDirectory`: ".testcontainers-artifacts"
    /// - `collectLogs`: true
    /// - `collectMetadata`: true
    /// - `collectRequest`: true
    /// - `trigger`: .onFailure
    /// - `retentionPolicy`: .keepLast(10)
    public init(
        enabled: Bool = true,
        outputDirectory: String = ".testcontainers-artifacts",
        collectLogs: Bool = true,
        collectMetadata: Bool = true,
        collectRequest: Bool = true,
        trigger: CollectionTrigger = .onFailure,
        retentionPolicy: RetentionPolicy = .keepLast(10)
    ) {
        self.enabled = enabled
        self.outputDirectory = outputDirectory
        self.collectLogs = collectLogs
        self.collectMetadata = collectMetadata
        self.collectRequest = collectRequest
        self.trigger = trigger
        self.retentionPolicy = retentionPolicy
    }

    /// Default configuration (enabled, collect on failure).
    public static let `default` = ArtifactConfig()

    /// Disabled artifact collection.
    public static let disabled = ArtifactConfig(enabled: false)

    // MARK: - Builder Methods

    /// Enable or disable artifact collection.
    public func withEnabled(_ enabled: Bool) -> Self {
        var copy = self
        copy.enabled = enabled
        return copy
    }

    /// Set the output directory for artifacts.
    public func withOutputDirectory(_ directory: String) -> Self {
        var copy = self
        copy.outputDirectory = directory
        return copy
    }

    /// Enable or disable log collection.
    public func withCollectLogs(_ collect: Bool) -> Self {
        var copy = self
        copy.collectLogs = collect
        return copy
    }

    /// Enable or disable metadata collection.
    public func withCollectMetadata(_ collect: Bool) -> Self {
        var copy = self
        copy.collectMetadata = collect
        return copy
    }

    /// Enable or disable request collection.
    public func withCollectRequest(_ collect: Bool) -> Self {
        var copy = self
        copy.collectRequest = collect
        return copy
    }

    /// Set the collection trigger.
    public func withTrigger(_ trigger: CollectionTrigger) -> Self {
        var copy = self
        copy.trigger = trigger
        return copy
    }

    /// Set the retention policy.
    public func withRetentionPolicy(_ policy: RetentionPolicy) -> Self {
        var copy = self
        copy.retentionPolicy = policy
        return copy
    }
}
