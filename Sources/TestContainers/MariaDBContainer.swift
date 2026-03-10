import Foundation

/// Configuration for creating a MariaDB container suitable for testing.
/// Provides a convenient API for MariaDB container configuration with sensible defaults.
///
/// MariaDB is compatible with MySQL protocol, so connection strings use the
/// `mysql://` scheme for compatibility with most clients.
///
/// Example:
/// ```swift
/// let request = MariaDBContainerRequest()
///     .withDatabase("myapp")
///     .withUsername("user", password: "pass")
///
/// try await withMariaDBContainer(request) { mariadb in
///     let connectionString = try await mariadb.connectionString()
///     // Use connectionString to connect with your MariaDB/MySQL client
/// }
/// ```
public struct MariaDBContainerRequest: Sendable, Hashable {
    /// Docker image to use for the MariaDB container.
    public var image: String

    /// Port for MariaDB connections (default: 3306).
    public var port: Int

    /// Optional fixed host port binding. When nil, Docker assigns a random host port.
    public var hostPort: Int?

    /// Name of the database to create on startup.
    public var database: String

    /// MariaDB root password.
    public var rootPassword: String

    /// Non-root username to create. If nil, only root user is available.
    public var username: String?

    /// Password for the non-root user.
    public var password: String?

    /// Additional environment variables for the container.
    public var environment: [String: String]

    /// Custom wait strategy. If nil, defaults to log-based wait.
    public var waitStrategy: WaitStrategy?

    /// Host address for connecting to the container.
    public var host: String

    /// Initialization script files mounted into `/docker-entrypoint-initdb.d/`.
    public var initScripts: [String]

    /// Optional custom config files mounted into `/etc/mysql/conf.d/`.
    public var configFiles: [ConfigFile]

    public struct ConfigFile: Sendable, Hashable {
        public let hostPath: String
        public let containerFilename: String

        public init(hostPath: String, containerFilename: String) {
            self.hostPath = hostPath
            self.containerFilename = containerFilename
        }
    }

    /// Creates a new MariaDB container request with default configuration.
    ///
    /// Defaults:
    /// - Image: mariadb:11.0
    /// - Database: test
    /// - Root password: test
    /// - Username: test
    /// - Password: test
    /// - Port: 3306
    ///
    /// - Parameter image: Docker image to use (default: "mariadb:11.0")
    public init(image: String = "mariadb:11.0") {
        self.image = image
        self.port = 3306
        self.hostPort = nil
        self.database = "test"
        self.rootPassword = "test"
        self.username = "test"
        self.password = "test"
        self.environment = [:]
        self.waitStrategy = nil
        self.host = "127.0.0.1"
        self.initScripts = []
        self.configFiles = []
    }

    /// Sets the database name to create on startup.
    /// - Parameter database: Database name
    public func withDatabase(_ database: String) -> Self {
        var copy = self
        copy.database = database
        return copy
    }

    /// Sets the MariaDB root password.
    /// - Parameter password: Root password
    public func withRootPassword(_ password: String) -> Self {
        var copy = self
        copy.rootPassword = password
        return copy
    }

    /// Sets the non-root username and password.
    /// - Parameters:
    ///   - username: Non-root username
    ///   - password: Password for the user
    public func withUsername(_ username: String, password: String) -> Self {
        var copy = self
        copy.username = username
        copy.password = password
        return copy
    }

    /// Disables creation of a non-root user (root-only mode).
    public func withRootOnly() -> Self {
        var copy = self
        copy.username = nil
        copy.password = nil
        return copy
    }

    /// Sets the MariaDB port.
    /// - Parameter port: Port number (default: 3306)
    public func withPort(_ port: Int) -> Self {
        var copy = self
        copy.port = port
        return copy
    }

    /// Sets the MariaDB container port.
    /// - Parameter port: Container port
    public func withContainerPort(_ port: Int) -> Self {
        withPort(port)
    }

    /// Sets a fixed host port mapping.
    /// - Parameter port: Host port
    public func withHostPort(_ port: Int) -> Self {
        var copy = self
        copy.hostPort = port
        return copy
    }

    /// Sets environment variables for the container.
    ///
    /// Note: MariaDB 10.2.38+, 10.3.29+, 10.4.19+, 10.5.10+, and all 10.6+
    /// support both MARIADB_* and MYSQL_* environment variable prefixes.
    /// This module uses MYSQL_* for maximum compatibility.
    ///
    /// - Parameter environment: Dictionary of environment variables
    public func withEnvironment(_ environment: [String: String]) -> Self {
        var copy = self
        for (key, value) in environment {
            copy.environment[key] = value
        }
        return copy
    }

    /// Sets the wait strategy for container readiness.
    /// If not specified, defaults to waiting for "ready for connections" in logs.
    /// - Parameter strategy: Wait strategy to use
    public func withWaitStrategy(_ strategy: WaitStrategy) -> Self {
        var copy = self
        copy.waitStrategy = strategy
        return copy
    }

    /// Sets the wait strategy for container readiness.
    /// Alias for `withWaitStrategy(_:)`.
    /// - Parameter strategy: Wait strategy to use
    public func waitingFor(_ strategy: WaitStrategy) -> Self {
        withWaitStrategy(strategy)
    }

    /// Sets the host address for connecting to the container.
    /// - Parameter host: Host address (default: "127.0.0.1")
    public func withHost(_ host: String) -> Self {
        var copy = self
        copy.host = host
        return copy
    }

    /// Mounts a single init script into `/docker-entrypoint-initdb.d/`.
    /// - Parameter scriptPath: Host path to `.sql`, `.sql.gz`, or `.sh` script
    public func withInitScript(_ scriptPath: String) -> Self {
        var copy = self
        copy.initScripts.append(scriptPath)
        return copy
    }

    /// Mounts multiple init scripts into `/docker-entrypoint-initdb.d/`.
    /// - Parameter scriptPaths: Host script paths
    public func withInitScripts(_ scriptPaths: [String]) -> Self {
        var copy = self
        copy.initScripts.append(contentsOf: scriptPaths)
        return copy
    }

    /// Mounts a custom MariaDB config file into `/etc/mysql/conf.d/`.
    /// - Parameters:
    ///   - configPath: Host path to config file
    ///   - filename: Optional destination filename (defaults to source basename)
    public func withConfigFile(_ configPath: String, as filename: String? = nil) -> Self {
        var copy = self
        let resolvedFilename = filename ?? URL(fileURLWithPath: configPath).lastPathComponent
        copy.configFiles.append(
            ConfigFile(hostPath: configPath, containerFilename: resolvedFilename)
        )
        return copy
    }

    /// Converts this MariaDB-specific request to a generic ContainerRequest.
    /// Sets up environment variables, port exposure, and wait strategy.
    internal func toContainerRequest() -> ContainerRequest {
        var env = self.environment

        // Configure MariaDB environment using MYSQL_* for compatibility
        env["MYSQL_ROOT_PASSWORD"] = rootPassword
        env["MYSQL_DATABASE"] = database

        if let username = username, let password = password {
            env["MYSQL_USER"] = username
            env["MYSQL_PASSWORD"] = password
        }

        var request = ContainerRequest(image: image)
            .withEnvironment(env)
            .withExposedPort(port, hostPort: hostPort)
            .withHost(host)

        // Store metadata in labels for connection string generation
        request = request
            .withLabel("testcontainers.mariadb.database", database)
            .withLabel("testcontainers.mariadb.rootPassword", rootPassword)
            .withLabel("testcontainers.mariadb.port", String(port))

        if let username = username, let password = password {
            request = request
                .withLabel("testcontainers.mariadb.username", username)
                .withLabel("testcontainers.mariadb.password", password)
        }

        for scriptPath in initScripts {
            let filename = URL(fileURLWithPath: scriptPath).lastPathComponent
            request = request.withBindMount(
                hostPath: scriptPath,
                containerPath: "/docker-entrypoint-initdb.d/\(filename)",
                readOnly: true
            )
        }

        for configFile in configFiles {
            request = request.withBindMount(
                hostPath: configFile.hostPath,
                containerPath: "/etc/mysql/conf.d/\(configFile.containerFilename)",
                readOnly: true
            )
        }

        // Apply wait strategy (default or custom)
        if let waitStrategy = waitStrategy {
            request = request.waitingFor(waitStrategy)
        } else {
            // Default: wait for MariaDB to be ready for connections
            request = request.waitingFor(.logContains("ready for connections", timeout: .seconds(60)))
        }

        return request
    }

    /// Alias for `toContainerRequest()`.
    internal func asContainerRequest() -> ContainerRequest {
        toContainerRequest()
    }

    /// Starts MariaDB for the duration of the provided operation.
    /// - Parameters:
    ///   - docker: Docker client instance
    ///   - operation: Operation to execute with running MariaDB
    /// - Returns: Operation return value
    public func withContainer<T>(
        runtime: any ContainerRuntime = DockerClient(),
        operation: @Sendable (MariaDBContainer) async throws -> T
    ) async throws -> T {
        try await withMariaDBContainer(self, runtime: runtime, operation: operation)
    }
}

/// A container running MariaDB configured for testing.
/// Provides convenient access to MariaDB connection strings and configuration.
public actor MariaDBContainer {
    private let container: Container
    private let config: MariaDBContainerRequest

    internal init(container: Container, config: MariaDBContainerRequest) {
        self.container = container
        self.config = config
    }

    /// The container ID.
    public var id: String {
        get async {
            container.id
        }
    }

    /// Returns a MariaDB connection string for the non-root user.
    ///
    /// Format: `mysql://username:password@host:port/database`
    ///
    /// Note: Uses `mysql://` scheme for compatibility with MySQL clients,
    /// as MariaDB implements the MySQL protocol.
    ///
    /// - Parameter parameters: Optional query parameters to append
    /// - Returns: A connection string for the MariaDB database
    /// - Throws: `TestContainersError.invalidInput` if no non-root user was configured
    public func connectionString(parameters: [String: String] = [:]) async throws -> String {
        guard let username = config.username, let password = config.password else {
            throw TestContainersError.invalidInput("No non-root user configured. Use rootConnectionString() or configure a user with withUsername()")
        }

        let hostPort = try await container.hostPort(config.port)
        return buildConnectionString(
            username: username,
            password: password,
            host: config.host,
            port: hostPort,
            database: config.database,
            parameters: parameters
        )
    }

    /// Returns a MariaDB connection string for the root user.
    ///
    /// Format: `mysql://root:password@host:port/database`
    ///
    /// - Parameter parameters: Optional query parameters to append
    /// - Returns: A connection string for the MariaDB database using root credentials
    public func rootConnectionString(parameters: [String: String] = [:]) async throws -> String {
        let hostPort = try await container.hostPort(config.port)
        return buildConnectionString(
            username: "root",
            password: config.rootPassword,
            host: config.host,
            port: hostPort,
            database: config.database,
            parameters: parameters
        )
    }

    /// Returns the mapped host port for the MariaDB server.
    /// - Returns: Host port number
    public func hostPort() async throws -> Int {
        try await container.hostPort(config.port)
    }

    /// Returns the host address.
    /// - Returns: Host IP or hostname
    nonisolated public func host() -> String {
        config.host
    }

    /// Returns the database name.
    nonisolated public func database() -> String {
        config.database
    }

    /// Returns the configured username (nil if root-only mode).
    nonisolated public func username() -> String? {
        config.username
    }

    /// Retrieves container logs.
    /// - Returns: Container log output
    public func logs() async throws -> String {
        try await container.logs()
    }

    /// Terminates and removes the container.
    public func terminate() async throws {
        try await container.terminate()
    }

    /// Access underlying generic Container for advanced operations.
    public var underlyingContainer: Container {
        container
    }

    private func buildConnectionString(
        username: String,
        password: String,
        host: String,
        port: Int,
        database: String,
        parameters: [String: String]
    ) -> String {
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
        var url = "mysql://\(username):\(encodedPassword)@\(host):\(port)/\(database)"

        if !parameters.isEmpty {
            let queryString = parameters
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "&")
            url += "?\(queryString)"
        }

        return url
    }
}

extension Container {
    /// Returns a MariaDB connection string for the configured non-root user.
    ///
    /// Requires labels set by `MariaDBContainerRequest.toContainerRequest()`.
    public func mariadbConnectionString(parameters: [String: String] = [:]) async throws -> String {
        guard let database = request.labels["testcontainers.mariadb.database"] else {
            throw TestContainersError.invalidInput("Missing MariaDB database label")
        }
        guard let username = request.labels["testcontainers.mariadb.username"],
              let password = request.labels["testcontainers.mariadb.password"] else {
            throw TestContainersError.invalidInput(
                "No non-root MariaDB user configured. Use mariadbRootConnectionString() or configure with withUsername()"
            )
        }

        let containerPort = Int(request.labels["testcontainers.mariadb.port"] ?? "") ?? 3306
        let mappedPort = try await hostPort(containerPort)
        return buildMariaDBLikeConnectionString(
            username: username,
            password: password,
            host: request.host,
            port: mappedPort,
            database: database,
            parameters: parameters
        )
    }

    /// Returns a MariaDB connection string for the root user.
    ///
    /// Requires labels set by `MariaDBContainerRequest.toContainerRequest()`.
    public func mariadbRootConnectionString(parameters: [String: String] = [:]) async throws -> String {
        guard let database = request.labels["testcontainers.mariadb.database"] else {
            throw TestContainersError.invalidInput("Missing MariaDB database label")
        }
        guard let rootPassword = request.labels["testcontainers.mariadb.rootPassword"] else {
            throw TestContainersError.invalidInput("Missing MariaDB root password label")
        }

        let containerPort = Int(request.labels["testcontainers.mariadb.port"] ?? "") ?? 3306
        let mappedPort = try await hostPort(containerPort)
        return buildMariaDBLikeConnectionString(
            username: "root",
            password: rootPassword,
            host: request.host,
            port: mappedPort,
            database: database,
            parameters: parameters
        )
    }

    fileprivate func buildMariaDBLikeConnectionString(
        username: String,
        password: String,
        host: String,
        port: Int,
        database: String,
        parameters: [String: String]
    ) -> String {
        let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
        var url = "mysql://\(encodedUsername):\(encodedPassword)@\(host):\(port)/\(database)"

        if !parameters.isEmpty {
            let queryString = parameters
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "&")
            url += "?\(queryString)"
        }

        return url
    }
}

/// Creates and starts a MariaDB container for testing.
/// The container is automatically cleaned up when the operation completes.
///
/// - Parameters:
///   - request: MariaDB container configuration
///   - docker: Docker client instance (default: shared client)
///   - operation: Async operation to perform with the running container
/// - Returns: Result of the operation
/// - Throws: Docker errors or operation errors
///
/// Example:
/// ```swift
/// let mariadbRequest = MariaDBContainerRequest()
///     .withDatabase("myapp")
///     .withUsername("user", password: "pass")
///
/// try await withMariaDBContainer(mariadbRequest) { mariadb in
///     let connectionString = try await mariadb.connectionString()
///     // Connect to MariaDB with connectionString
/// }
/// ```
public func withMariaDBContainer<T>(
    _ request: MariaDBContainerRequest,
    runtime: any ContainerRuntime = DockerClient(),
    operation: @Sendable (MariaDBContainer) async throws -> T
) async throws -> T {
    let containerRequest = request.toContainerRequest()
    return try await withContainer(containerRequest, runtime: runtime) { container in
        let mariadbContainer = MariaDBContainer(container: container, config: request)
        return try await operation(mariadbContainer)
    }
}
