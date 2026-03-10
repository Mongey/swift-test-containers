import Foundation

/// Configuration for creating a RabbitMQ container suitable for testing.
/// Provides a convenient API for RabbitMQ container configuration with sensible defaults,
/// including the management plugin for debugging and monitoring.
///
/// Example:
/// ```swift
/// let rabbitmq = RabbitMQContainer()
///     .withAdminUsername("admin")
///     .withAdminPassword("secret")
///
/// try await withRabbitMQContainer(rabbitmq) { container in
///     let amqpURL = try await container.amqpURL()
///     // Use with your AMQP client
/// }
/// ```
public struct RabbitMQContainer: Sendable, Hashable {
    /// Docker image to use for the RabbitMQ container.
    public var image: String

    /// Admin username for RabbitMQ authentication.
    public var adminUsername: String

    /// Admin password for RabbitMQ authentication.
    public var adminPassword: String

    /// Virtual host path (default: "/").
    public var virtualHost: String

    /// Whether SSL/TLS is enabled.
    public var enableSSL: Bool

    /// Host address for connecting to the container.
    public var host: String

    /// Custom wait strategy. If nil, defaults to TCP wait on AMQP port.
    public var waitStrategy: WaitStrategy?

    /// Default RabbitMQ image with management plugin.
    public static let defaultImage = "rabbitmq:3.13-management-alpine"

    /// Default AMQP port.
    public static let amqpPort = 5672

    /// Default management UI port.
    public static let managementPort = 15672

    /// Default AMQPS (secure) port.
    public static let amqpsPort = 5671

    /// Creates a new RabbitMQ container configuration with default settings.
    /// - Parameter image: Docker image to use (default: "rabbitmq:3.13-management-alpine")
    public init(image: String = RabbitMQContainer.defaultImage) {
        self.image = image
        self.adminUsername = "guest"
        self.adminPassword = "guest"
        self.virtualHost = "/"
        self.enableSSL = false
        self.host = "127.0.0.1"
        self.waitStrategy = nil
    }

    /// Sets the admin username for RabbitMQ authentication.
    /// - Parameter username: Admin username
    public func withAdminUsername(_ username: String) -> Self {
        var copy = self
        copy.adminUsername = username
        return copy
    }

    /// Sets the admin password for RabbitMQ authentication.
    /// - Parameter password: Admin password
    public func withAdminPassword(_ password: String) -> Self {
        var copy = self
        copy.adminPassword = password
        return copy
    }

    /// Sets the virtual host for RabbitMQ.
    /// - Parameter vhost: Virtual host path (e.g., "/test-vhost")
    public func withVirtualHost(_ vhost: String) -> Self {
        var copy = self
        copy.virtualHost = vhost
        return copy
    }

    /// Enables SSL/TLS and exposes the AMQPS port (5671).
    public func withSSL() -> Self {
        var copy = self
        copy.enableSSL = true
        return copy
    }

    /// Sets the wait strategy for container readiness.
    /// If not specified, defaults to TCP wait on AMQP port 5672.
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

    /// Converts this RabbitMQ-specific configuration to a generic ContainerRequest.
    internal func toContainerRequest() -> ContainerRequest {
        var request = ContainerRequest(image: image)
            .withExposedPort(RabbitMQContainer.amqpPort)
            .withExposedPort(RabbitMQContainer.managementPort)
            .withHost(host)
            .withEnvironment([
                "RABBITMQ_DEFAULT_USER": adminUsername,
                "RABBITMQ_DEFAULT_PASS": adminPassword,
            ])

        if enableSSL {
            request = request.withExposedPort(RabbitMQContainer.amqpsPort)
        }

        if let waitStrategy = waitStrategy {
            request = request.waitingFor(waitStrategy)
        } else {
            request = request.waitingFor(.tcpPort(
                RabbitMQContainer.amqpPort,
                timeout: .seconds(60)
            ))
        }

        return request
    }

    // MARK: - Connection String Helpers

    /// Builds an AMQP connection URL.
    /// - Parameters:
    ///   - host: RabbitMQ host
    ///   - port: AMQP port
    ///   - username: Admin username
    ///   - password: Admin password
    ///   - virtualHost: Virtual host path
    /// - Returns: Formatted AMQP URL (e.g., `amqp://guest:guest@localhost:5672/`)
    public static func buildAmqpURL(
        host: String,
        port: Int,
        username: String,
        password: String,
        virtualHost: String
    ) -> String {
        let encodedUsername = username.addingPercentEncoding(
            withAllowedCharacters: .amqpCredentialAllowed
        ) ?? username
        let encodedPassword = password.addingPercentEncoding(
            withAllowedCharacters: .amqpCredentialAllowed
        ) ?? password

        let vhost = virtualHost == "/" ? "" : String(virtualHost.dropFirst())
        return "amqp://\(encodedUsername):\(encodedPassword)@\(host):\(port)/\(vhost)"
    }

    /// Builds an AMQPS (secure) connection URL.
    /// - Parameters:
    ///   - host: RabbitMQ host
    ///   - port: AMQPS port
    ///   - username: Admin username
    ///   - password: Admin password
    ///   - virtualHost: Virtual host path
    /// - Returns: Formatted AMQPS URL (e.g., `amqps://guest:guest@localhost:5671/`)
    public static func buildAmqpsURL(
        host: String,
        port: Int,
        username: String,
        password: String,
        virtualHost: String
    ) -> String {
        let encodedUsername = username.addingPercentEncoding(
            withAllowedCharacters: .amqpCredentialAllowed
        ) ?? username
        let encodedPassword = password.addingPercentEncoding(
            withAllowedCharacters: .amqpCredentialAllowed
        ) ?? password

        let vhost = virtualHost == "/" ? "" : String(virtualHost.dropFirst())
        return "amqps://\(encodedUsername):\(encodedPassword)@\(host):\(port)/\(vhost)"
    }

    /// Builds a management UI HTTP URL.
    /// - Parameters:
    ///   - host: RabbitMQ host
    ///   - port: Management port
    /// - Returns: Formatted management URL (e.g., `http://localhost:15672`)
    public static func buildManagementURL(
        host: String,
        port: Int
    ) -> String {
        "http://\(host):\(port)"
    }
}

private extension CharacterSet {
    /// Characters allowed in AMQP credential encoding.
    static let amqpCredentialAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=")
        return allowed
    }()
}

/// A running RabbitMQ container with typed accessors.
/// Provides convenient access to AMQP connection information and management UI.
public struct RunningRabbitMQContainer: Sendable {
    private let container: Container
    private let config: RabbitMQContainer
    private let runtime: any ContainerRuntime

    internal init(container: Container, config: RabbitMQContainer, runtime: any ContainerRuntime) {
        self.container = container
        self.config = config
        self.runtime = runtime
    }

    /// Returns the AMQP connection URL.
    /// - Returns: Full AMQP URL (e.g., `amqp://guest:guest@127.0.0.1:5672/`)
    public func amqpURL() async throws -> String {
        let hostPort = try await container.hostPort(RabbitMQContainer.amqpPort)
        return RabbitMQContainer.buildAmqpURL(
            host: config.host,
            port: hostPort,
            username: config.adminUsername,
            password: config.adminPassword,
            virtualHost: config.virtualHost
        )
    }

    /// Returns the AMQP connection URL with a custom virtual host.
    /// - Parameter virtualHost: Virtual host path
    /// - Returns: Full AMQP URL with the specified virtual host
    public func amqpURL(virtualHost: String) async throws -> String {
        let hostPort = try await container.hostPort(RabbitMQContainer.amqpPort)
        return RabbitMQContainer.buildAmqpURL(
            host: config.host,
            port: hostPort,
            username: config.adminUsername,
            password: config.adminPassword,
            virtualHost: virtualHost
        )
    }

    /// Returns the AMQPS (secure) connection URL.
    /// - Returns: Full AMQPS URL
    /// - Throws: `TestContainersError.invalidInput` if SSL is not enabled
    public func amqpsURL() async throws -> String {
        guard config.enableSSL else {
            throw TestContainersError.invalidInput(
                "SSL not enabled. Use .withSSL() on RabbitMQContainer"
            )
        }
        let hostPort = try await container.hostPort(RabbitMQContainer.amqpsPort)
        return RabbitMQContainer.buildAmqpsURL(
            host: config.host,
            port: hostPort,
            username: config.adminUsername,
            password: config.adminPassword,
            virtualHost: config.virtualHost
        )
    }

    /// Returns the management UI HTTP URL.
    /// - Returns: Management URL (e.g., `http://127.0.0.1:15672`)
    public func managementURL() async throws -> String {
        let hostPort = try await container.hostPort(RabbitMQContainer.managementPort)
        return RabbitMQContainer.buildManagementURL(
            host: config.host,
            port: hostPort
        )
    }

    /// Returns the mapped host port for AMQP.
    /// - Returns: Host port number
    public func amqpPort() async throws -> Int {
        try await container.hostPort(RabbitMQContainer.amqpPort)
    }

    /// Returns the mapped host port for the management UI.
    /// - Returns: Host port number
    public func managementPort() async throws -> Int {
        try await container.hostPort(RabbitMQContainer.managementPort)
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

/// Creates and starts a RabbitMQ container for testing.
/// The container is automatically cleaned up when the operation completes.
///
/// - Parameters:
///   - config: RabbitMQ container configuration
///   - docker: Docker client instance (default: shared client)
///   - operation: Async operation to perform with the running container
/// - Returns: Result of the operation
/// - Throws: Docker errors or operation errors
///
/// Example:
/// ```swift
/// let rabbitmq = RabbitMQContainer()
///     .withAdminUsername("admin")
///     .withAdminPassword("secret")
///
/// try await withRabbitMQContainer(rabbitmq) { container in
///     let amqpURL = try await container.amqpURL()
///     // Use AMQP URL with your client
/// }
/// ```
public func withRabbitMQContainer<T>(
    _ config: RabbitMQContainer,
    runtime: any ContainerRuntime = DockerClient(),
    operation: @Sendable (RunningRabbitMQContainer) async throws -> T
) async throws -> T {
    let containerRequest = config.toContainerRequest()
    return try await withContainer(containerRequest, runtime: runtime) { container in
        let rabbitmqContainer = RunningRabbitMQContainer(
            container: container,
            config: config,
            runtime: runtime
        )
        return try await operation(rabbitmqContainer)
    }
}
