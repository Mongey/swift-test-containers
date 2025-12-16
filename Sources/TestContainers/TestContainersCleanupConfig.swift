import Foundation

/// Configuration for test container cleanup operations.
///
/// Use the builder pattern to configure cleanup behavior:
/// ```swift
/// let config = TestContainersCleanupConfig()
///     .withAutomaticCleanup(true)
///     .withAgeThreshold(300)  // 5 minutes
///     .withVerbose(true)
/// ```
public struct TestContainersCleanupConfig: Sendable {
    /// Enable automatic cleanup on test suite initialization
    public var automaticCleanupEnabled: Bool

    /// Minimum age (in seconds) before a container is eligible for cleanup.
    /// Default is 600 seconds (10 minutes).
    public var ageThresholdSeconds: TimeInterval

    /// Include session labels (PID, UUID) on all containers
    public var sessionLabelsEnabled: Bool

    /// Custom label filters for cleanup (in addition to testcontainers.swift=true)
    public var customLabelFilters: [String: String]

    /// Dry run mode - preview cleanup without removing containers
    public var dryRun: Bool

    /// Verbose logging for cleanup operations
    public var verbose: Bool

    /// Create a new cleanup configuration with default values.
    ///
    /// Default values:
    /// - `automaticCleanupEnabled`: false
    /// - `ageThresholdSeconds`: 600 (10 minutes)
    /// - `sessionLabelsEnabled`: true
    /// - `customLabelFilters`: empty
    /// - `dryRun`: false
    /// - `verbose`: false
    public init(
        automaticCleanupEnabled: Bool = false,
        ageThresholdSeconds: TimeInterval = 600,
        sessionLabelsEnabled: Bool = true,
        customLabelFilters: [String: String] = [:],
        dryRun: Bool = false,
        verbose: Bool = false
    ) {
        self.automaticCleanupEnabled = automaticCleanupEnabled
        self.ageThresholdSeconds = ageThresholdSeconds
        self.sessionLabelsEnabled = sessionLabelsEnabled
        self.customLabelFilters = customLabelFilters
        self.dryRun = dryRun
        self.verbose = verbose
    }

    /// Load configuration from environment variables.
    ///
    /// Supported environment variables:
    /// - `TESTCONTAINERS_CLEANUP_ENABLED`: "1" or "true" to enable automatic cleanup
    /// - `TESTCONTAINERS_CLEANUP_AGE_THRESHOLD`: Age in seconds (default: 600)
    /// - `TESTCONTAINERS_CLEANUP_DRY_RUN`: "1" or "true" for dry run mode
    /// - `TESTCONTAINERS_CLEANUP_VERBOSE`: "1" or "true" for verbose logging
    public static func fromEnvironment() -> Self {
        let env = ProcessInfo.processInfo.environment

        let automaticCleanup = Self.parseBool(env["TESTCONTAINERS_CLEANUP_ENABLED"])
        let ageThreshold = Self.parseTimeInterval(env["TESTCONTAINERS_CLEANUP_AGE_THRESHOLD"]) ?? 600
        let dryRun = Self.parseBool(env["TESTCONTAINERS_CLEANUP_DRY_RUN"])
        let verbose = Self.parseBool(env["TESTCONTAINERS_CLEANUP_VERBOSE"])

        return Self(
            automaticCleanupEnabled: automaticCleanup,
            ageThresholdSeconds: ageThreshold,
            dryRun: dryRun,
            verbose: verbose
        )
    }

    /// Enable or disable automatic cleanup on startup.
    public func withAutomaticCleanup(_ enabled: Bool) -> Self {
        var copy = self
        copy.automaticCleanupEnabled = enabled
        return copy
    }

    /// Set the age threshold for cleanup eligibility.
    ///
    /// Containers must be older than this threshold (in seconds) to be
    /// eligible for cleanup. This prevents accidentally removing active
    /// containers from parallel test runs.
    public func withAgeThreshold(_ seconds: TimeInterval) -> Self {
        var copy = self
        copy.ageThresholdSeconds = seconds
        return copy
    }

    /// Enable or disable session labels on containers.
    public func withSessionLabels(_ enabled: Bool) -> Self {
        var copy = self
        copy.sessionLabelsEnabled = enabled
        return copy
    }

    /// Add a custom label filter for cleanup.
    ///
    /// Only containers matching all label filters will be cleaned up.
    /// The base filter `testcontainers.swift=true` is always applied.
    public func withCustomLabelFilter(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.customLabelFilters[key] = value
        return copy
    }

    /// Enable or disable dry run mode.
    ///
    /// In dry run mode, cleanup will list containers that would be
    /// removed but will not actually remove them.
    public func withDryRun(_ enabled: Bool) -> Self {
        var copy = self
        copy.dryRun = enabled
        return copy
    }

    /// Enable or disable verbose logging.
    ///
    /// When enabled, cleanup operations will print detailed information
    /// about containers found, removed, and any errors encountered.
    public func withVerbose(_ enabled: Bool) -> Self {
        var copy = self
        copy.verbose = enabled
        return copy
    }

    /// Build the label filters for cleanup operations.
    ///
    /// Combines the base `testcontainers.swift=true` label with
    /// any custom label filters. Custom filters can override the
    /// base label if desired.
    ///
    /// - Returns: Dictionary of label key-value pairs for filtering
    public func buildLabelFilters() -> [String: String] {
        var filters = ["testcontainers.swift": "true"]
        for (key, value) in customLabelFilters {
            filters[key] = value
        }
        return filters
    }

    // MARK: - Private Helpers

    private static func parseBool(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value == "1" || value == "true" || value == "yes"
    }

    private static func parseTimeInterval(_ value: String?) -> TimeInterval? {
        guard let value = value, let seconds = Double(value) else { return nil }
        return seconds
    }
}
