import Foundation

/// Configuration for creating a NATS container suitable for testing.
/// Provides a convenient API for NATS container configuration with sensible defaults,
/// including JetStream support enabled by default.
///
/// Example:
/// ```swift
/// let nats = NATSContainer()
///     .withCredentials(username: "admin", password: "secret")
///
/// try await withNATSContainer(nats) { container in
///     let url = try await container.connectionString()
///     // Use with your NATS client
/// }
/// ```
public struct NATSContainer: Sendable, Hashable {
    /// Docker image to use for the NATS container.
    public var image: String

    /// Whether JetStream is enabled (default: true).
    public var jetStreamEnabled: Bool

    /// JetStream storage directory (nil uses container default).
    public var jetStreamStorageDir: String?

    /// Optional username for authentication.
    public var username: String?

    /// Optional password for authentication.
    public var password: String?

    /// Optional token for authentication.
    public var token: String?

    /// Cluster name for cluster mode.
    public var clusterName: String?

    /// Node name within a cluster.
    public var nodeName: String?

    /// Cluster routes for inter-node communication.
    public var routes: [String]

    /// Additional command-line arguments for the NATS server.
    public var customArgs: [String]

    /// Host address for connecting to the container.
    public var host: String

    /// Custom wait strategy. If nil, defaults to TCP wait on client port.
    public var waitStrategy: WaitStrategy?

    /// Default NATS image (Alpine variant for smaller size).
    public static let defaultImage = "nats:2.12-alpine"

    /// Default NATS client port.
    public static let clientPort = 4222

    /// Default NATS HTTP monitoring port.
    public static let monitoringPort = 8222

    /// Default NATS routing port (for clusters).
    public static let routingPort = 6222

    /// Creates a new NATS container configuration with default settings.
    /// JetStream is enabled by default.
    /// - Parameter image: Docker image to use (default: "nats:2.12-alpine")
    public init(image: String = NATSContainer.defaultImage) {
        self.image = image
        self.jetStreamEnabled = true
        self.jetStreamStorageDir = nil
        self.username = nil
        self.password = nil
        self.token = nil
        self.clusterName = nil
        self.nodeName = nil
        self.routes = []
        self.customArgs = []
        self.host = "127.0.0.1"
        self.waitStrategy = nil
    }

    /// Enables or disables JetStream.
    /// - Parameter enabled: Whether JetStream should be enabled
    public func withJetStream(_ enabled: Bool) -> Self {
        var copy = self
        copy.jetStreamEnabled = enabled
        return copy
    }

    /// Sets the JetStream storage directory.
    /// - Parameter dir: Storage directory path inside the container
    public func withJetStreamStorageDir(_ dir: String) -> Self {
        var copy = self
        copy.jetStreamStorageDir = dir
        return copy
    }

    /// Sets the username for authentication.
    /// - Parameter username: Username string
    public func withUsername(_ username: String) -> Self {
        var copy = self
        copy.username = username
        return copy
    }

    /// Sets the password for authentication.
    /// - Parameter password: Password string
    public func withPassword(_ password: String) -> Self {
        var copy = self
        copy.password = password
        return copy
    }

    /// Sets both username and password for authentication.
    /// - Parameters:
    ///   - username: Username string
    ///   - password: Password string
    public func withCredentials(username: String, password: String) -> Self {
        var copy = self
        copy.username = username
        copy.password = password
        return copy
    }

    /// Sets the token for token-based authentication.
    /// - Parameter token: Authentication token
    public func withToken(_ token: String) -> Self {
        var copy = self
        copy.token = token
        return copy
    }

    /// Configures cluster mode.
    /// - Parameters:
    ///   - name: Cluster name
    ///   - nodeName: Optional node name within the cluster
    public func withCluster(name: String, nodeName: String? = nil) -> Self {
        var copy = self
        copy.clusterName = name
        copy.nodeName = nodeName
        return copy
    }

    /// Adds a cluster route for inter-node communication.
    /// - Parameter route: Route URL (e.g., "nats://node1:6222")
    public func withRoute(_ route: String) -> Self {
        var copy = self
        copy.routes.append(route)
        return copy
    }

    /// Sets cluster routes, replacing any existing routes.
    /// - Parameter routes: Array of route URLs
    public func withRoutes(_ routes: [String]) -> Self {
        var copy = self
        copy.routes = routes
        return copy
    }

    /// Adds a custom command-line argument for the NATS server.
    /// - Parameter arg: Argument string
    public func withArgument(_ arg: String) -> Self {
        var copy = self
        copy.customArgs.append(arg)
        return copy
    }

    /// Adds multiple custom command-line arguments for the NATS server.
    /// - Parameter args: Array of argument strings
    public func withArguments(_ args: [String]) -> Self {
        var copy = self
        copy.customArgs.append(contentsOf: args)
        return copy
    }

    /// Sets the host address for connecting to the container.
    /// - Parameter host: Host address (default: "127.0.0.1")
    public func withHost(_ host: String) -> Self {
        var copy = self
        copy.host = host
        return copy
    }

    /// Sets the wait strategy for container readiness.
    /// If not specified, defaults to TCP wait on client port 4222.
    /// - Parameter strategy: Wait strategy to use
    public func waitingFor(_ strategy: WaitStrategy) -> Self {
        var copy = self
        copy.waitStrategy = strategy
        return copy
    }

    /// Converts this NATS-specific configuration to a generic ContainerRequest.
    internal func toContainerRequest() -> ContainerRequest {
        var command = [String]()

        if jetStreamEnabled {
            command.append("-js")
        }

        if let storageDir = jetStreamStorageDir {
            command.append("--store_dir")
            command.append(storageDir)
        }

        if let username = username {
            command.append("--user")
            command.append(username)
        }
        if let password = password {
            command.append("--pass")
            command.append(password)
        }

        if let token = token {
            command.append("--auth")
            command.append(token)
        }

        if let clusterName = clusterName {
            command.append("--cluster_name")
            command.append(clusterName)
        }
        if let nodeName = nodeName {
            command.append("--name")
            command.append(nodeName)
        }
        for route in routes {
            command.append("--routes")
            command.append(route)
        }

        command.append(contentsOf: customArgs)

        var request = ContainerRequest(image: image)
            .withExposedPort(NATSContainer.clientPort)
            .withExposedPort(NATSContainer.monitoringPort)
            .withExposedPort(NATSContainer.routingPort)
            .withHost(host)

        if !command.isEmpty {
            request = request.withCommand(command)
        }

        if let waitStrategy = waitStrategy {
            request = request.waitingFor(waitStrategy)
        } else {
            request = request.waitingFor(.tcpPort(
                NATSContainer.clientPort,
                timeout: .seconds(60)
            ))
        }

        return request
    }

    // MARK: - Connection String Helpers

    /// Builds a NATS connection URL.
    /// - Parameters:
    ///   - host: NATS host
    ///   - port: NATS client port
    ///   - username: Optional username
    ///   - password: Optional password
    ///   - token: Optional authentication token
    /// - Returns: Formatted NATS URL (e.g., `nats://host:port` or `nats://user:pass@host:port`)
    public static func buildConnectionString(
        host: String,
        port: Int,
        username: String? = nil,
        password: String? = nil,
        token: String? = nil
    ) -> String {
        if let username = username, let password = password {
            return "nats://\(username):\(password)@\(host):\(port)"
        } else if let token = token {
            return "nats://\(token)@\(host):\(port)"
        } else {
            return "nats://\(host):\(port)"
        }
    }

    /// Builds a NATS HTTP monitoring URL.
    /// - Parameters:
    ///   - host: NATS host
    ///   - port: HTTP monitoring port
    /// - Returns: Formatted monitoring URL (e.g., `http://host:port`)
    public static func buildMonitoringURL(
        host: String,
        port: Int
    ) -> String {
        "http://\(host):\(port)"
    }
}

/// A running NATS container with typed accessors.
/// Provides convenient access to connection information and NATS operations.
public struct RunningNATSContainer: Sendable {
    private let container: Container
    private let config: NATSContainer
    private let runtime: any ContainerRuntime

    internal init(container: Container, config: NATSContainer, runtime: any ContainerRuntime) {
        self.container = container
        self.config = config
        self.runtime = runtime
    }

    /// Returns the NATS connection string.
    /// - Returns: Full NATS connection URL (e.g., `nats://127.0.0.1:4222`)
    public func connectionString() async throws -> String {
        let hostPort = try await container.hostPort(NATSContainer.clientPort)
        return NATSContainer.buildConnectionString(
            host: config.host,
            port: hostPort,
            username: config.username,
            password: config.password,
            token: config.token
        )
    }

    /// Returns the mapped host port for NATS client connections.
    /// - Returns: Host port number
    public func clientPort() async throws -> Int {
        try await container.hostPort(NATSContainer.clientPort)
    }

    /// Returns the mapped host port for the HTTP monitoring endpoint.
    /// - Returns: Host port number
    public func monitoringPort() async throws -> Int {
        try await container.hostPort(NATSContainer.monitoringPort)
    }

    /// Returns the mapped host port for cluster routing.
    /// - Returns: Host port number
    public func routingPort() async throws -> Int {
        try await container.hostPort(NATSContainer.routingPort)
    }

    /// Returns the monitoring endpoint URL.
    /// - Returns: HTTP URL for the monitoring endpoint
    public func monitoringURL() async throws -> String {
        let hostPort = try await monitoringPort()
        return NATSContainer.buildMonitoringURL(
            host: config.host,
            port: hostPort
        )
    }

    /// Returns the host address.
    /// - Returns: Host IP or hostname
    public func host() -> String {
        config.host
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

/// Creates and starts a NATS container for testing.
/// The container is automatically cleaned up when the operation completes.
///
/// - Parameters:
///   - config: NATS container configuration
///   - docker: Docker client instance (default: shared client)
///   - operation: Async operation to perform with the running container
/// - Returns: Result of the operation
/// - Throws: Docker errors or operation errors
///
/// Example:
/// ```swift
/// let nats = NATSContainer()
///     .withCredentials(username: "admin", password: "secret")
///
/// try await withNATSContainer(nats) { container in
///     let url = try await container.connectionString()
///     // Use NATS URL with your client
/// }
/// ```
public func withNATSContainer<T>(
    _ config: NATSContainer,
    runtime: any ContainerRuntime = DockerClient(),
    operation: @Sendable (RunningNATSContainer) async throws -> T
) async throws -> T {
    let containerRequest = config.toContainerRequest()
    return try await withContainer(containerRequest, runtime: runtime) { container in
        let natsContainer = RunningNATSContainer(
            container: container,
            config: config,
            runtime: runtime
        )
        return try await operation(natsContainer)
    }
}
