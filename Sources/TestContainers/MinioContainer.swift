import Foundation

/// Configuration for creating a MinIO (S3-compatible) container suitable for testing.
/// Provides a convenient API for MinIO container configuration with sensible defaults.
///
/// Example:
/// ```swift
/// let minio = MinioContainer()
///     .withCredentials(accessKey: "myuser", secretKey: "mypassword123")
///     .withBucket("test-bucket")
///
/// try await withMinioContainer(minio) { container in
///     let endpoint = try await container.s3Endpoint()
///     // Use with AWS SDK, Soto, etc.
/// }
/// ```
public struct MinioContainer: Sendable, Hashable {
    /// Docker image to use for the MinIO container.
    public var image: String

    /// S3 API port (default: 9000).
    public var port: Int

    /// Console/Web UI port (default: 9001).
    public var consolePort: Int

    /// Access key (username) for MinIO authentication.
    public var accessKey: String

    /// Secret key (password) for MinIO authentication.
    public var secretKey: String

    /// Whether to expose the console/web UI port.
    public var consoleEnabled: Bool

    /// Buckets to create on startup.
    public var buckets: [String]

    /// Custom wait strategy. If nil, defaults to HTTP health check.
    public var waitStrategy: WaitStrategy?

    /// Host address for connecting to the container.
    public var host: String

    /// Default MinIO image.
    public static let defaultImage = "minio/minio:latest"

    /// Default S3 API port.
    public static let defaultPort = 9000

    /// Default Console port.
    public static let defaultConsolePort = 9001

    /// Default access key.
    public static let defaultAccessKey = "minioadmin"

    /// Default secret key.
    public static let defaultSecretKey = "minioadmin"

    /// Creates a new MinIO container configuration with default settings.
    /// - Parameter image: Docker image to use (default: "minio/minio:latest")
    public init(image: String = MinioContainer.defaultImage) {
        self.image = image
        self.port = MinioContainer.defaultPort
        self.consolePort = MinioContainer.defaultConsolePort
        self.accessKey = MinioContainer.defaultAccessKey
        self.secretKey = MinioContainer.defaultSecretKey
        self.consoleEnabled = true
        self.buckets = []
        self.waitStrategy = nil
        self.host = "127.0.0.1"
    }

    /// Sets both access key and secret key for MinIO authentication.
    /// - Parameters:
    ///   - accessKey: Access key (username)
    ///   - secretKey: Secret key (password)
    public func withCredentials(accessKey: String, secretKey: String) -> Self {
        var copy = self
        copy.accessKey = accessKey
        copy.secretKey = secretKey
        return copy
    }

    /// Sets the access key (username) for MinIO authentication.
    /// - Parameter accessKey: Access key string
    public func withAccessKey(_ accessKey: String) -> Self {
        var copy = self
        copy.accessKey = accessKey
        return copy
    }

    /// Sets the secret key (password) for MinIO authentication.
    /// - Parameter secretKey: Secret key string
    public func withSecretKey(_ secretKey: String) -> Self {
        var copy = self
        copy.secretKey = secretKey
        return copy
    }

    /// Enables or disables the console/web UI port exposure.
    /// - Parameter enabled: Whether to expose the console port (default: true)
    public func withConsole(_ enabled: Bool) -> Self {
        var copy = self
        copy.consoleEnabled = enabled
        return copy
    }

    /// Adds a bucket to create on startup.
    /// - Parameter bucket: Bucket name
    public func withBucket(_ bucket: String) -> Self {
        var copy = self
        copy.buckets.append(bucket)
        return copy
    }

    /// Sets the buckets to create on startup.
    /// - Parameter buckets: Array of bucket names
    public func withBuckets(_ buckets: [String]) -> Self {
        var copy = self
        copy.buckets = buckets
        return copy
    }

    /// Sets the wait strategy for container readiness.
    /// If not specified, defaults to HTTP health check on `/minio/health/ready`.
    /// - Parameter strategy: Wait strategy to use
    public func waitingFor(_ strategy: WaitStrategy) -> Self {
        var copy = self
        copy.waitStrategy = strategy
        return copy
    }

    /// Sets the host address for connecting to the container.
    /// - Parameter host: Host address (default: "127.0.0.1")
    public func withHost(_ host: String) -> Self {
        var copy = self
        copy.host = host
        return copy
    }

    /// Converts this MinIO-specific configuration to a generic ContainerRequest.
    internal func toContainerRequest() -> ContainerRequest {
        var request = ContainerRequest(image: image)
            .withExposedPort(port)
            .withHost(host)
            .withEnvironment([
                "MINIO_ROOT_USER": accessKey,
                "MINIO_ROOT_PASSWORD": secretKey,
            ])
            .withCommand(["server", "/data", "--console-address", ":\(consolePort)"])

        if consoleEnabled {
            request = request.withExposedPort(consolePort)
        }

        if let waitStrategy = waitStrategy {
            request = request.waitingFor(waitStrategy)
        } else {
            request = request.waitingFor(.http(
                HTTPWaitConfig(port: port)
                    .withPath("/minio/health/ready")
            ))
        }

        return request
    }

    // MARK: - Endpoint Helpers

    /// Builds an S3 endpoint URL from host and port.
    /// - Parameters:
    ///   - host: MinIO host
    ///   - port: MinIO S3 API port
    /// - Returns: Formatted endpoint URL (e.g., `http://host:port`)
    public static func buildS3Endpoint(host: String, port: Int) -> String {
        "http://\(host):\(port)"
    }
}

/// A running MinIO container with typed accessors.
/// Provides convenient access to S3 endpoint, console endpoint, and credentials.
public struct RunningMinioContainer: Sendable {
    private let container: Container
    private let config: MinioContainer
    private let runtime: any ContainerRuntime

    internal init(container: Container, config: MinioContainer, runtime: any ContainerRuntime) {
        self.container = container
        self.config = config
        self.runtime = runtime
    }

    /// Returns the S3 API endpoint URL (e.g., `http://127.0.0.1:49152`).
    public func s3Endpoint() async throws -> String {
        let hostPort = try await container.hostPort(config.port)
        return MinioContainer.buildS3Endpoint(host: config.host, port: hostPort)
    }

    /// Returns the Console/Web UI endpoint URL (e.g., `http://127.0.0.1:49153`).
    /// - Throws: If the console was not enabled in the configuration.
    public func consoleEndpoint() async throws -> String {
        guard config.consoleEnabled else {
            throw TestContainersError.invalidInput("Console port is not enabled. Use .withConsole(true) to enable it.")
        }
        let hostPort = try await container.hostPort(config.consolePort)
        return "http://\(config.host):\(hostPort)"
    }

    /// Alias for `s3Endpoint()` for compatibility with testcontainers-go.
    public func connectionString() async throws -> String {
        try await s3Endpoint()
    }

    /// Returns the access key (username) for this MinIO instance.
    public func accessKey() -> String {
        config.accessKey
    }

    /// Returns the secret key (password) for this MinIO instance.
    public func secretKey() -> String {
        config.secretKey
    }

    /// Returns the mapped host port for the S3 API.
    public func port() async throws -> Int {
        try await container.hostPort(config.port)
    }

    /// Returns the host address.
    public func host() -> String {
        config.host
    }

    /// Retrieves container logs.
    public func logs() async throws -> String {
        try await container.logs()
    }

    /// Executes a command inside the container.
    /// - Parameter command: Command and arguments to execute
    /// - Returns: ExecResult with exit code, stdout, and stderr
    public func exec(_ command: [String]) async throws -> ExecResult {
        try await runtime.exec(id: container.id, command: command, options: ExecOptions())
    }

    /// Access underlying generic Container for advanced operations.
    public var underlyingContainer: Container {
        container
    }
}

/// Creates and starts a MinIO container for testing.
/// The container is automatically cleaned up when the operation completes.
///
/// If buckets are specified in the configuration, they will be created after
/// the container starts using the MinIO client (`mc`) bundled in the image.
///
/// - Parameters:
///   - config: MinIO container configuration
///   - docker: Docker client instance (default: shared client)
///   - operation: Async operation to perform with the running container
/// - Returns: Result of the operation
/// - Throws: Docker errors or operation errors
///
/// Example:
/// ```swift
/// let minio = MinioContainer()
///     .withBucket("test-bucket")
///
/// try await withMinioContainer(minio) { container in
///     let endpoint = try await container.s3Endpoint()
///     // Use endpoint with your S3 client
/// }
/// ```
public func withMinioContainer<T>(
    _ config: MinioContainer = MinioContainer(),
    runtime: any ContainerRuntime = DockerClient(),
    operation: @Sendable (RunningMinioContainer) async throws -> T
) async throws -> T {
    let containerRequest = config.toContainerRequest()
    return try await withContainer(containerRequest, runtime: runtime) { container in
        let minioContainer = RunningMinioContainer(
            container: container,
            config: config,
            runtime: runtime
        )

        // Create initial buckets if specified
        for bucket in config.buckets {
            // Configure mc alias pointing to local MinIO
            _ = try await runtime.exec(
                id: container.id,
                command: ["mc", "alias", "set", "local", "http://localhost:\(config.port)", config.accessKey, config.secretKey],
                options: ExecOptions()
            )
            // Create the bucket
            let result = try await runtime.exec(
                id: container.id,
                command: ["mc", "mb", "local/\(bucket)"],
                options: ExecOptions()
            )
            if result.exitCode != 0 {
                throw TestContainersError.invalidInput(
                    "Failed to create bucket '\(bucket)': \(result.stderr)"
                )
            }
        }

        return try await operation(minioContainer)
    }
}
