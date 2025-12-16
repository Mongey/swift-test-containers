import Foundation

/// Result of a cleanup operation with statistics.
///
/// Contains information about how many containers were found, removed,
/// and any errors that occurred during the cleanup process.
public struct CleanupResult: Sendable {
    /// Total containers found matching cleanup criteria
    public let containersFound: Int

    /// Containers successfully removed
    public let containersRemoved: Int

    /// Containers that failed to remove
    public let containersFailed: Int

    /// Detailed information about each container processed
    public let containers: [CleanupContainerInfo]

    /// Errors encountered during cleanup
    public let errors: [CleanupError]

    /// Information about a container processed during cleanup.
    public struct CleanupContainerInfo: Sendable {
        /// Container ID (short form)
        public let id: String

        /// Container name (if set)
        public let name: String?

        /// Image used by the container
        public let image: String

        /// When the container was created
        public let createdAt: Date

        /// Age of the container in seconds
        public let age: TimeInterval

        /// Labels on the container
        public let labels: [String: String]

        /// Whether the container was successfully removed
        public let removed: Bool

        /// Error message if removal failed
        public let error: String?

        public init(
            id: String,
            name: String?,
            image: String,
            createdAt: Date,
            age: TimeInterval,
            labels: [String: String],
            removed: Bool,
            error: String?
        ) {
            self.id = id
            self.name = name
            self.image = image
            self.createdAt = createdAt
            self.age = age
            self.labels = labels
            self.removed = removed
            self.error = error
        }
    }

    public init(
        containersFound: Int,
        containersRemoved: Int,
        containersFailed: Int,
        containers: [CleanupContainerInfo],
        errors: [CleanupError]
    ) {
        self.containersFound = containersFound
        self.containersRemoved = containersRemoved
        self.containersFailed = containersFailed
        self.containers = containers
        self.errors = errors
    }
}

/// Errors that can occur during cleanup operations.
public enum CleanupError: Error, CustomStringConvertible, Sendable {
    /// Docker daemon is not available
    case dockerUnavailable

    /// Failed to remove a specific container
    case containerRemovalFailed(id: String, reason: String)

    /// Failed to inspect a container
    case inspectionFailed(id: String, reason: String)

    public var description: String {
        switch self {
        case .dockerUnavailable:
            return "Docker daemon unavailable for cleanup"
        case let .containerRemovalFailed(id, reason):
            return "Failed to remove container \(id): \(reason)"
        case let .inspectionFailed(id, reason):
            return "Failed to inspect container \(id): \(reason)"
        }
    }
}
