import Foundation

/// Configuration for applying parallel-test safety defaults to a container request.
public struct ParallelSafetyConfig: Sendable, Hashable {
    /// Whether container names should be auto-generated.
    public var autoGenerateNames: Bool

    /// Optional session identifier for cross-container grouping.
    public var sessionID: String?

    /// Whether fixed host port mappings should emit warnings.
    public var validatePortAllocation: Bool

    public init(
        autoGenerateNames: Bool = true,
        sessionID: String? = nil,
        validatePortAllocation: Bool = true
    ) {
        self.autoGenerateNames = autoGenerateNames
        self.sessionID = sessionID
        self.validatePortAllocation = validatePortAllocation
    }

    public static let `default` = ParallelSafetyConfig()

    /// Strict mode auto-generates names, validates port mappings, and adds a session label.
    public static var strict: ParallelSafetyConfig {
        ParallelSafetyConfig(
            autoGenerateNames: true,
            sessionID: ContainerNameGenerator.generateSessionID(),
            validatePortAllocation: true
        )
    }
}
