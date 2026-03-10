import Foundation

/// Redis log levels matching the Redis `loglevel` configuration directive.
public enum RedisLogLevel: String, Sendable, Hashable {
    case debug = "debug"
    case verbose = "verbose"
    case notice = "notice"
    case warning = "warning"
}

/// Redis persistence configuration for RDB snapshotting.
/// Maps to the Redis `save` directive: `save <seconds> <changes>`.
public struct RedisSnapshotting: Sendable, Hashable, Equatable {
    public let seconds: Int
    public let changes: Int

    public init(seconds: Int, changes: Int) {
        self.seconds = seconds
        self.changes = changes
    }
}

/// Configuration for creating a Redis container suitable for testing.
/// Provides a convenient API for Redis container configuration with sensible defaults.
///
/// Example:
/// ```swift
/// let redis = RedisContainer()
///     .withPassword("secret")
///     .withDatabase(2)
///
/// try await withRedisContainer(redis) { container in
///     let connStr = try await container.connectionString()
///     // Use with RediStack, etc.
/// }
/// ```
public struct RedisContainer: Sendable, Hashable {
    /// Docker image to use for the Redis container.
    public var image: String

    /// Redis port (default: 6379).
    public var port: Int

    /// Optional password for Redis authentication.
    public var password: String?

    /// Redis database number (default: 0).
    public var database: Int

    /// Optional log level configuration.
    public var logLevel: RedisLogLevel?

    /// Optional persistence configuration.
    public var snapshotting: RedisSnapshotting?

    /// Custom wait strategy. If nil, defaults to log-based wait.
    public var waitStrategy: WaitStrategy?

    /// Host address for connecting to the container.
    public var host: String

    /// Default Redis port.
    public static let defaultPort = 6379

    /// Default Redis image.
    public static let defaultImage = "redis:7"

    /// Creates a new Redis container configuration with default settings.
    /// - Parameter image: Docker image to use (default: "redis:7")
    public init(image: String = RedisContainer.defaultImage) {
        self.image = image
        self.port = RedisContainer.defaultPort
        self.password = nil
        self.database = 0
        self.logLevel = nil
        self.snapshotting = nil
        self.waitStrategy = nil
        self.host = "127.0.0.1"
    }

    /// Sets the Redis port.
    /// - Parameter port: Port number (default: 6379)
    public func withPort(_ port: Int) -> Self {
        var copy = self
        copy.port = port
        return copy
    }

    /// Sets the password for Redis authentication.
    /// - Parameter password: Password string
    public func withPassword(_ password: String) -> Self {
        var copy = self
        copy.password = password
        return copy
    }

    /// Sets the Redis database number.
    /// - Parameter database: Database index (default: 0)
    public func withDatabase(_ database: Int) -> Self {
        var copy = self
        copy.database = database
        return copy
    }

    /// Sets the Redis log level.
    /// - Parameter level: Log level (debug, verbose, notice, warning)
    public func withLogLevel(_ level: RedisLogLevel) -> Self {
        var copy = self
        copy.logLevel = level
        return copy
    }

    /// Enables RDB snapshotting persistence.
    /// - Parameters:
    ///   - seconds: Save interval in seconds
    ///   - changes: Minimum number of key changes to trigger save
    public func withSnapshotting(seconds: Int, changes: Int) -> Self {
        var copy = self
        copy.snapshotting = RedisSnapshotting(seconds: seconds, changes: changes)
        return copy
    }

    /// Sets the wait strategy for container readiness.
    /// If not specified, defaults to log-based wait for "Ready to accept connections".
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

    /// Converts this Redis-specific configuration to a generic ContainerRequest.
    internal func toContainerRequest() -> ContainerRequest {
        var request = ContainerRequest(image: image)
            .withExposedPort(port)
            .withHost(host)

        // Build redis-server command arguments
        var args: [String] = ["redis-server"]

        if let password = password {
            args.append("--requirepass")
            args.append(password)
        }

        if let logLevel = logLevel {
            args.append("--loglevel")
            args.append(logLevel.rawValue)
        }

        if let snapshotting = snapshotting {
            args.append("--save")
            args.append("\(snapshotting.seconds) \(snapshotting.changes)")
        } else {
            // Disable persistence for testing (faster startup)
            args.append("--save")
            args.append("")
        }

        request = request.withCommand(args)

        // Apply wait strategy (default or custom)
        if let waitStrategy = waitStrategy {
            request = request.waitingFor(waitStrategy)
        } else {
            request = request.waitingFor(.logContains(
                "Ready to accept connections",
                timeout: .seconds(60),
                pollInterval: .milliseconds(500)
            ))
        }

        return request
    }

    // MARK: - Connection String Helper

    /// Builds a Redis connection string.
    /// - Parameters:
    ///   - host: Redis host
    ///   - port: Redis port
    ///   - password: Optional password
    ///   - database: Database index (0 is omitted from URL)
    /// - Returns: Formatted connection string (e.g., `redis://:password@host:port/db`)
    public static func buildConnectionString(
        host: String,
        port: Int,
        password: String? = nil,
        database: Int = 0
    ) -> String {
        var connStr = "redis://"

        if let password = password {
            let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
            connStr += ":\(encodedPassword)@"
        }

        connStr += "\(host):\(port)"

        if database != 0 {
            connStr += "/\(database)"
        }

        return connStr
    }
}

/// A running Redis container with typed accessors.
/// Provides convenient access to connection information and Redis operations.
public struct RunningRedisContainer: Sendable {
    private let container: Container
    private let config: RedisContainer
    private let runtime: any ContainerRuntime

    internal init(container: Container, config: RedisContainer, runtime: any ContainerRuntime) {
        self.container = container
        self.config = config
        self.runtime = runtime
    }

    /// Returns the Redis connection string.
    /// - Returns: Full Redis connection string (e.g., `redis://:password@host:port/db`)
    public func connectionString() async throws -> String {
        let hostPort = try await container.hostPort(config.port)
        return RedisContainer.buildConnectionString(
            host: config.host,
            port: hostPort,
            password: config.password,
            database: config.database
        )
    }

    /// Returns the mapped host port for Redis.
    /// - Returns: Host port number
    public func port() async throws -> Int {
        try await container.hostPort(config.port)
    }

    /// Returns the host address.
    /// - Returns: Host IP or hostname
    public func host() -> String {
        config.host
    }

    /// Returns the configured password, if any.
    /// - Returns: Password or nil
    public func password() -> String? {
        config.password
    }

    /// Returns the configured database index.
    /// - Returns: Database number
    public func database() -> Int {
        config.database
    }

    /// Retrieves container logs.
    /// - Returns: Container log output
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

/// Creates and starts a Redis container for testing.
/// The container is automatically cleaned up when the operation completes.
///
/// - Parameters:
///   - config: Redis container configuration
///   - docker: Docker client instance (default: shared client)
///   - operation: Async operation to perform with the running container
/// - Returns: Result of the operation
/// - Throws: Docker errors or operation errors
///
/// Example:
/// ```swift
/// let redis = RedisContainer()
///     .withPassword("secret")
///
/// try await withRedisContainer(redis) { container in
///     let connStr = try await container.connectionString()
///     // Use connection string with your Redis client
/// }
/// ```
public func withRedisContainer<T>(
    _ config: RedisContainer,
    runtime: any ContainerRuntime = DockerClient(),
    operation: @Sendable (RunningRedisContainer) async throws -> T
) async throws -> T {
    let containerRequest = config.toContainerRequest()
    return try await withContainer(containerRequest, runtime: runtime) { container in
        let redisContainer = RunningRedisContainer(
            container: container,
            config: config,
            runtime: runtime
        )
        return try await operation(redisContainer)
    }
}
