import Foundation

/// Configuration for creating a MongoDB container suitable for testing.
/// Provides a convenient API for MongoDB container configuration with sensible defaults.
///
/// Example:
/// ```swift
/// let mongo = MongoDBContainer()
///     .withUsername("admin")
///     .withPassword("secret")
///
/// try await withMongoDBContainer(mongo) { container in
///     let connStr = try await container.connectionString()
///     // Use with MongoSwift, etc.
/// }
/// ```
public struct MongoDBContainer: Sendable, Hashable {
    /// Docker image to use for the MongoDB container.
    public var image: String

    /// MongoDB port (default: 27017).
    public var port: Int

    /// Optional root username for authentication.
    public var username: String?

    /// Optional root password for authentication.
    public var password: String?

    /// Optional default database name.
    public var database: String?

    /// Optional replica set configuration.
    public var replicaSet: ReplicaSetConfig?

    /// Host address for connecting to the container.
    public var host: String

    /// Default MongoDB port.
    public static let defaultPort = 27017

    /// Default MongoDB image.
    public static let defaultImage = "mongo:7"

    /// Configuration for single-node replica set mode.
    public struct ReplicaSetConfig: Sendable, Hashable {
        public let name: String

        public init(name: String = "rs") {
            self.name = name
        }
    }

    /// Creates a new MongoDB container configuration with default settings.
    /// - Parameter image: Docker image to use (default: "mongo:7")
    public init(image: String = MongoDBContainer.defaultImage) {
        self.image = image
        self.port = MongoDBContainer.defaultPort
        self.username = nil
        self.password = nil
        self.database = nil
        self.replicaSet = nil
        self.host = "127.0.0.1"
    }

    /// Sets the root username for MongoDB authentication.
    /// Must be paired with `withPassword(_:)`.
    /// - Parameter username: MongoDB root username
    public func withUsername(_ username: String) -> Self {
        var copy = self
        copy.username = username
        return copy
    }

    /// Sets the root password for MongoDB authentication.
    /// Must be paired with `withUsername(_:)`.
    /// - Parameter password: MongoDB root password
    public func withPassword(_ password: String) -> Self {
        var copy = self
        copy.password = password
        return copy
    }

    /// Sets the default database name.
    /// - Parameter database: Database name
    public func withDatabase(_ database: String) -> Self {
        var copy = self
        copy.database = database
        return copy
    }

    /// Enables single-node replica set mode.
    /// Required for testing MongoDB transactions and change streams.
    /// - Parameter name: Replica set name (defaults to "rs")
    public func withReplicaSet(name: String = "rs") -> Self {
        var copy = self
        copy.replicaSet = ReplicaSetConfig(name: name)
        return copy
    }

    /// Sets the host address for connecting to the container.
    /// - Parameter host: Host address (default: "127.0.0.1")
    public func withHost(_ host: String) -> Self {
        var copy = self
        copy.host = host
        return copy
    }

    /// Converts this MongoDB-specific configuration to a generic ContainerRequest.
    internal func toContainerRequest() -> ContainerRequest {
        var request = ContainerRequest(image: image)
            .withExposedPort(port)
            .withHost(host)

        // Configure authentication if both username and password provided
        if let username = username, let password = password {
            request = request.withEnvironment([
                "MONGO_INITDB_ROOT_USERNAME": username,
                "MONGO_INITDB_ROOT_PASSWORD": password,
            ])
        }

        // Configure init database
        if let database = database {
            request = request.withEnvironment(["MONGO_INITDB_DATABASE": database])
        }

        // Configure replica set mode
        if let replicaSet = replicaSet {
            request = request.withCommand(["--replSet", replicaSet.name])
        }

        // Wait for MongoDB to be ready
        request = request.waitingFor(.logContains(
            "Waiting for connections",
            timeout: .seconds(60),
            pollInterval: .milliseconds(500)
        ))

        return request
    }

    // MARK: - Connection String Helper

    /// Builds a MongoDB connection string.
    /// - Parameters:
    ///   - host: MongoDB host
    ///   - port: MongoDB port
    ///   - username: Optional username
    ///   - password: Optional password
    ///   - database: Optional database name
    ///   - replicaSet: Optional replica set name
    /// - Returns: Formatted connection string
    public static func buildConnectionString(
        host: String,
        port: Int,
        username: String? = nil,
        password: String? = nil,
        database: String? = nil,
        replicaSet: String? = nil
    ) -> String {
        var connStr = "mongodb://"

        if let username = username, let password = password {
            let encodedUsername = username.addingPercentEncoding(
                withAllowedCharacters: .mongoCredentialAllowed
            ) ?? username
            let encodedPassword = password.addingPercentEncoding(
                withAllowedCharacters: .mongoCredentialAllowed
            ) ?? password
            connStr += "\(encodedUsername):\(encodedPassword)@"
        }

        connStr += "\(host):\(port)"

        if let database = database {
            connStr += "/\(database)"
        } else {
            connStr += "/"
        }

        var queryParams: [String] = []
        queryParams.append("directConnection=true")

        if let replicaSet = replicaSet {
            queryParams.append("replicaSet=\(replicaSet)")
        }

        connStr += "?\(queryParams.joined(separator: "&"))"

        return connStr
    }
}

private extension CharacterSet {
    /// Characters allowed in MongoDB credential encoding.
    /// MongoDB connection strings use percent-encoding for username and password.
    static let mongoCredentialAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=")
        return allowed
    }()
}

/// A running MongoDB container with typed accessors.
public struct RunningMongoDBContainer: Sendable {
    private let container: Container
    private let config: MongoDBContainer
    private let runtime: any ContainerRuntime

    internal init(container: Container, config: MongoDBContainer, runtime: any ContainerRuntime) {
        self.container = container
        self.config = config
        self.runtime = runtime
    }

    /// Returns the MongoDB connection string.
    public func connectionString() async throws -> String {
        let hostPort = try await container.hostPort(config.port)
        return MongoDBContainer.buildConnectionString(
            host: config.host,
            port: hostPort,
            username: config.username,
            password: config.password,
            database: config.database,
            replicaSet: config.replicaSet?.name
        )
    }

    /// Returns the mapped host port for MongoDB.
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

/// Creates and starts a MongoDB container for testing.
/// The container is automatically cleaned up when the operation completes.
///
/// For replica set mode, the replica set is automatically initialized.
///
/// - Parameters:
///   - config: MongoDB container configuration
///   - docker: Docker client instance
///   - operation: Async operation to perform with the running container
/// - Returns: Result of the operation
public func withMongoDBContainer<T>(
    _ config: MongoDBContainer,
    runtime: any ContainerRuntime = DockerClient(),
    operation: @Sendable (RunningMongoDBContainer) async throws -> T
) async throws -> T {
    let containerRequest = config.toContainerRequest()
    return try await withContainer(containerRequest, runtime: runtime) { container in
        let mongoContainer = RunningMongoDBContainer(
            container: container,
            config: config,
            runtime: runtime
        )

        // Initialize replica set if configured
        if let replicaSet = config.replicaSet {
            let initScript = """
            rs.initiate({
                _id: '\(replicaSet.name)',
                members: [{ _id: 0, host: 'localhost:27017' }]
            })
            """
            _ = try await runtime.exec(
                id: container.id,
                command: ["mongosh", "--quiet", "--eval", initScript],
                options: ExecOptions()
            )

            // Wait for replica set to become ready
            try await Waiter.wait(
                timeout: .seconds(30),
                pollInterval: .milliseconds(500),
                description: "replica set '\(replicaSet.name)' to become ready"
            ) {
                let result = try await runtime.exec(
                    id: container.id,
                    command: ["mongosh", "--quiet", "--eval", "rs.status().ok"],
                    options: ExecOptions()
                )
                return result.exitCode == 0 && result.stdout.contains("1")
            }
        }

        return try await operation(mongoContainer)
    }
}
