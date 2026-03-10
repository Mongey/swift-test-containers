import Foundation

/// Configuration for creating a Memcached container suitable for testing.
/// Provides a convenient API for Memcached container configuration with sensible defaults.
///
/// Example:
/// ```swift
/// let memcached = MemcachedContainer()
///     .withMemory(megabytes: 128)
///     .withMaxConnections(2048)
///
/// try await withMemcachedContainer(memcached) { container in
///     let connStr = try await container.connectionString()
///     // Use with your Memcached client
/// }
/// ```
public struct MemcachedContainer: Sendable, Hashable {
    /// Docker image to use for the Memcached container.
    public var image: String

    /// Memcached port (default: 11211).
    public var port: Int

    /// Memory limit in megabytes. Nil uses Memcached's default (64 MB).
    public var memoryMB: Int?

    /// Maximum number of simultaneous connections. Nil uses Memcached's default (1024).
    public var maxConnections: Int?

    /// Number of threads. Nil uses Memcached's default (4).
    public var threads: Int?

    /// Enable verbose output.
    public var verbose: Bool

    /// Custom wait strategy. If nil, defaults to TCP port check.
    public var waitStrategy: WaitStrategy?

    /// Host address for connecting to the container.
    public var host: String

    /// Default Memcached port.
    public static let defaultPort = 11211

    /// Default Memcached image.
    public static let defaultImage = "memcached:1.6"

    /// Creates a new Memcached container configuration with default settings.
    /// - Parameter image: Docker image to use (default: "memcached:1.6")
    public init(image: String = MemcachedContainer.defaultImage) {
        self.image = image
        self.port = MemcachedContainer.defaultPort
        self.memoryMB = nil
        self.maxConnections = nil
        self.threads = nil
        self.verbose = false
        self.waitStrategy = nil
        self.host = "127.0.0.1"
    }

    /// Sets the Memcached port.
    public func withPort(_ port: Int) -> Self {
        var copy = self
        copy.port = port
        return copy
    }

    /// Sets the memory limit in megabytes.
    /// Maps to the `-m` flag.
    public func withMemory(megabytes: Int) -> Self {
        var copy = self
        copy.memoryMB = megabytes
        return copy
    }

    /// Sets the maximum number of simultaneous connections.
    /// Maps to the `-c` flag.
    public func withMaxConnections(_ maxConnections: Int) -> Self {
        var copy = self
        copy.maxConnections = maxConnections
        return copy
    }

    /// Sets the number of threads.
    /// Maps to the `-t` flag.
    public func withThreads(_ threads: Int) -> Self {
        var copy = self
        copy.threads = threads
        return copy
    }

    /// Enables verbose output.
    /// Maps to the `-v` flag.
    public func withVerbose() -> Self {
        var copy = self
        copy.verbose = true
        return copy
    }

    /// Sets the wait strategy for container readiness.
    /// If not specified, defaults to TCP port check on the Memcached port.
    public func waitingFor(_ strategy: WaitStrategy) -> Self {
        var copy = self
        copy.waitStrategy = strategy
        return copy
    }

    /// Sets the host address for connecting to the container.
    public func withHost(_ host: String) -> Self {
        var copy = self
        copy.host = host
        return copy
    }

    /// Converts this Memcached-specific configuration to a generic ContainerRequest.
    internal func toContainerRequest() -> ContainerRequest {
        var request = ContainerRequest(image: image)
            .withExposedPort(port)
            .withHost(host)

        // Build command arguments only if options are configured
        var args: [String] = []

        if let memoryMB = memoryMB {
            args.append("-m")
            args.append("\(memoryMB)")
        }

        if let maxConnections = maxConnections {
            args.append("-c")
            args.append("\(maxConnections)")
        }

        if let threads = threads {
            args.append("-t")
            args.append("\(threads)")
        }

        if verbose {
            args.append("-v")
        }

        if !args.isEmpty {
            request = request.withCommand(args)
        }

        // Apply wait strategy (default to TCP port check)
        if let waitStrategy = waitStrategy {
            request = request.waitingFor(waitStrategy)
        } else {
            request = request.waitingFor(.tcpPort(
                port,
                timeout: .seconds(60),
                pollInterval: .milliseconds(500)
            ))
        }

        return request
    }

    // MARK: - Connection String Helper

    /// Builds a Memcached connection string.
    /// - Parameters:
    ///   - host: Memcached host
    ///   - port: Memcached port
    /// - Returns: Formatted connection string (e.g., `host:port`)
    public static func buildConnectionString(
        host: String,
        port: Int
    ) -> String {
        "\(host):\(port)"
    }
}

/// A running Memcached container with typed accessors.
public struct RunningMemcachedContainer: Sendable {
    private let container: Container
    private let config: MemcachedContainer
    private let runtime: any ContainerRuntime

    internal init(container: Container, config: MemcachedContainer, runtime: any ContainerRuntime) {
        self.container = container
        self.config = config
        self.runtime = runtime
    }

    /// Returns the Memcached connection string.
    /// - Returns: Connection string (e.g., `127.0.0.1:32768`)
    public func connectionString() async throws -> String {
        let hostPort = try await container.hostPort(config.port)
        return MemcachedContainer.buildConnectionString(
            host: config.host,
            port: hostPort
        )
    }

    /// Returns the mapped host port for Memcached.
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
    public func exec(_ command: [String]) async throws -> ExecResult {
        try await runtime.exec(id: container.id, command: command, options: ExecOptions())
    }

    /// Access underlying generic Container for advanced operations.
    public var underlyingContainer: Container {
        container
    }
}

/// Creates and starts a Memcached container for testing.
/// The container is automatically cleaned up when the operation completes.
///
/// Example:
/// ```swift
/// let memcached = MemcachedContainer()
///     .withMemory(megabytes: 128)
///
/// try await withMemcachedContainer(memcached) { container in
///     let connStr = try await container.connectionString()
///     // Use connection string with your Memcached client
/// }
/// ```
public func withMemcachedContainer<T>(
    _ config: MemcachedContainer,
    runtime: any ContainerRuntime = DockerClient(),
    operation: @Sendable (RunningMemcachedContainer) async throws -> T
) async throws -> T {
    let containerRequest = config.toContainerRequest()
    return try await withContainer(containerRequest, runtime: runtime) { container in
        let memcachedContainer = RunningMemcachedContainer(
            container: container,
            config: config,
            runtime: runtime
        )
        return try await operation(memcachedContainer)
    }
}
