import Foundation

/// Container metadata captured for artifacts.
///
/// Contains information about the container state at the time of capture,
/// including configuration, state, and the raw docker inspect output.
public struct ContainerArtifact: Sendable, Codable {
    /// Container ID (short form)
    public let containerId: String

    /// Image name used by the container
    public let imageName: String

    /// Container name (if set)
    public let containerName: String?

    /// When the artifact was captured
    public let captureTime: Date

    /// Container state at capture time (running, exited, etc.)
    public let containerState: String

    /// Exit code if container has exited
    public let exitCode: Int?

    /// Environment variables configured for the container
    public let environment: [String: String]

    /// Labels on the container
    public let labels: [String: String]

    /// Port mappings (e.g., "6379/tcp -> 0.0.0.0:54321")
    public let ports: [String]

    /// Raw docker inspect JSON output (if available)
    public let inspectJSON: String?

    public init(
        containerId: String,
        imageName: String,
        containerName: String?,
        captureTime: Date,
        containerState: String,
        exitCode: Int?,
        environment: [String: String],
        labels: [String: String],
        ports: [String],
        inspectJSON: String?
    ) {
        self.containerId = containerId
        self.imageName = imageName
        self.containerName = containerName
        self.captureTime = captureTime
        self.containerState = containerState
        self.exitCode = exitCode
        self.environment = environment
        self.labels = labels
        self.ports = ports
        self.inspectJSON = inspectJSON
    }
}

/// Result of artifact collection.
///
/// Contains paths to the collected artifact files.
public struct ArtifactCollection: Sendable {
    /// Directory containing all artifacts for this container
    public let artifactDirectory: String

    /// Path to logs.txt file (if collected)
    public let logsFile: String?

    /// Path to metadata.json file (if collected)
    public let metadataFile: String?

    /// Path to request.json file (if collected)
    public let requestFile: String?

    /// Path to error.txt file (if error occurred)
    public let errorFile: String?

    /// Whether no artifacts were collected.
    public var isEmpty: Bool {
        logsFile == nil && metadataFile == nil && requestFile == nil && errorFile == nil
    }

    public init(
        artifactDirectory: String,
        logsFile: String?,
        metadataFile: String?,
        requestFile: String?,
        errorFile: String?
    ) {
        self.artifactDirectory = artifactDirectory
        self.logsFile = logsFile
        self.metadataFile = metadataFile
        self.requestFile = requestFile
        self.errorFile = errorFile
    }
}
