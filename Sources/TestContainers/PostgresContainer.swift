import Foundation

/// Configuration for creating a PostgreSQL container suitable for testing.
/// Provides a convenient API for PostgreSQL container configuration with sensible defaults.
///
/// Example:
/// ```swift
/// let postgres = PostgresContainer()
///     .withDatabase("myapp")
///     .withUsername("appuser")
///     .withPassword("secret")
///
/// try await withPostgresContainer(postgres) { container in
///     let connStr = try await container.connectionString()
///     // Use with PostgresNIO, PostgresKit, etc.
/// }
/// ```
public struct PostgresContainer: Sendable, Hashable {
    /// Docker image to use for the PostgreSQL container.
    public var image: String

    /// Database name to create.
    public var database: String

    /// Username for database authentication.
    public var username: String

    /// Password for database authentication.
    public var password: String

    /// PostgreSQL port (default: 5432).
    public var port: Int

    /// Additional environment variables for the container.
    public var environment: [String: String]

    /// Custom wait strategy. If nil, defaults to pg_isready exec check.
    public var waitStrategy: WaitStrategy?

    /// Host address for connecting to the container.
    public var host: String

    /// Default PostgreSQL port.
    public static let defaultPort = 5432

    /// Default PostgreSQL image.
    public static let defaultImage = "postgres:16-alpine"

    /// Creates a new PostgreSQL container configuration with default settings.
    /// - Parameter image: Docker image to use (default: "postgres:16-alpine")
    public init(image: String = PostgresContainer.defaultImage) {
        self.image = image
        self.database = "postgres"
        self.username = "postgres"
        self.password = "postgres"
        self.port = PostgresContainer.defaultPort
        self.environment = [:]
        self.waitStrategy = nil
        self.host = "127.0.0.1"
    }

    /// Sets the database name to create.
    /// - Parameter database: Database name
    public func withDatabase(_ database: String) -> Self {
        var copy = self
        copy.database = database
        return copy
    }

    /// Sets the username for database authentication.
    /// - Parameter username: Username
    public func withUsername(_ username: String) -> Self {
        var copy = self
        copy.username = username
        return copy
    }

    /// Sets the password for database authentication.
    /// - Parameter password: Password
    public func withPassword(_ password: String) -> Self {
        var copy = self
        copy.password = password
        return copy
    }

    /// Sets the PostgreSQL port.
    /// - Parameter port: Port number (default: 5432)
    public func withPort(_ port: Int) -> Self {
        var copy = self
        copy.port = port
        return copy
    }

    /// Sets environment variables for the container.
    /// - Parameter environment: Dictionary of environment variables
    public func withEnvironment(_ environment: [String: String]) -> Self {
        var copy = self
        for (key, value) in environment {
            copy.environment[key] = value
        }
        return copy
    }

    /// Sets the wait strategy for container readiness.
    /// If not specified, defaults to pg_isready exec check.
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

    /// Converts this PostgreSQL-specific configuration to a generic ContainerRequest.
    internal func toContainerRequest() -> ContainerRequest {
        var env = self.environment

        // Set PostgreSQL environment variables
        env["POSTGRES_DB"] = database
        env["POSTGRES_USER"] = username
        env["POSTGRES_PASSWORD"] = password

        var request = ContainerRequest(image: image)
            .withEnvironment(env)
            .withExposedPort(port)
            .withHost(host)

        // Apply wait strategy (default or custom)
        if let waitStrategy = waitStrategy {
            request = request.waitingFor(waitStrategy)
        } else {
            // Default: wait for pg_isready
            request = request.waitingFor(.exec(
                ["pg_isready", "-U", username, "-d", database],
                timeout: .seconds(60),
                pollInterval: .milliseconds(500)
            ))
        }

        return request
    }

    // MARK: - Connection String Helper

    /// Builds a PostgreSQL connection string.
    /// - Parameters:
    ///   - host: Database host
    ///   - port: Database port
    ///   - database: Database name
    ///   - username: Username
    ///   - password: Password
    ///   - sslMode: SSL mode (optional)
    ///   - options: Additional connection options
    /// - Returns: Formatted connection string
    public static func buildConnectionString(
        host: String,
        port: Int,
        database: String,
        username: String,
        password: String,
        sslMode: String? = nil,
        options: [String: String] = [:]
    ) -> String {
        // URL encode username and password for special characters
        let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password

        var connStr = "postgresql://\(encodedUsername):\(encodedPassword)@\(host):\(port)/\(database)"

        // Build query parameters
        var params: [String] = []

        if let sslMode = sslMode {
            params.append("sslmode=\(sslMode)")
        }

        for (key, value) in options.sorted(by: { $0.key < $1.key }) {
            params.append("\(key)=\(value)")
        }

        if !params.isEmpty {
            connStr += "?" + params.joined(separator: "&")
        }

        return connStr
    }
}

/// A running PostgreSQL container with typed accessors.
/// Provides convenient access to connection information and database operations.
public struct RunningPostgresContainer: Sendable {
    private let container: Container
    private let config: PostgresContainer
    private let runtime: any ContainerRuntime

    internal init(container: Container, config: PostgresContainer, runtime: any ContainerRuntime) {
        self.container = container
        self.config = config
        self.runtime = runtime
    }

    /// Returns the PostgreSQL connection string.
    /// - Parameters:
    ///   - sslMode: SSL mode (default: nil, meaning no sslmode parameter)
    ///   - options: Additional connection parameters
    /// - Returns: Full PostgreSQL connection string
    public func connectionString(
        sslMode: String? = nil,
        options: [String: String] = [:]
    ) async throws -> String {
        let hostPort = try await container.hostPort(config.port)
        return PostgresContainer.buildConnectionString(
            host: config.host,
            port: hostPort,
            database: config.database,
            username: config.username,
            password: config.password,
            sslMode: sslMode,
            options: options
        )
    }

    /// Returns the mapped host port for PostgreSQL.
    /// - Returns: Host port number
    public func port() async throws -> Int {
        try await container.hostPort(config.port)
    }

    /// Returns the host address.
    /// - Returns: Host IP or hostname
    public func host() -> String {
        config.host
    }

    /// Returns the database name.
    /// - Returns: Database name
    public func database() -> String {
        config.database
    }

    /// Returns the username.
    /// - Returns: Username
    public func username() -> String {
        config.username
    }

    /// Returns the password.
    /// - Returns: Password
    public func password() -> String {
        config.password
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

/// Creates and starts a PostgreSQL container for testing.
/// The container is automatically cleaned up when the operation completes.
///
/// - Parameters:
///   - config: PostgreSQL container configuration
///   - docker: Docker client instance (default: shared client)
///   - operation: Async operation to perform with the running container
/// - Returns: Result of the operation
/// - Throws: Docker errors or operation errors
///
/// Example:
/// ```swift
/// let postgres = PostgresContainer()
///     .withDatabase("testdb")
///     .withUsername("testuser")
///     .withPassword("testpass")
///
/// try await withPostgresContainer(postgres) { container in
///     let connStr = try await container.connectionString()
///     // Use connection string with your database client
/// }
/// ```
public func withPostgresContainer<T>(
    _ config: PostgresContainer,
    runtime: any ContainerRuntime = DockerClient(),
    operation: @Sendable (RunningPostgresContainer) async throws -> T
) async throws -> T {
    let containerRequest = config.toContainerRequest()
    return try await withContainer(containerRequest, runtime: runtime) { container in
        let postgresContainer = RunningPostgresContainer(
            container: container,
            config: config,
            runtime: runtime
        )
        return try await operation(postgresContainer)
    }
}
