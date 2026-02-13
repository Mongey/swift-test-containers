# Feature: MongoDBContainer Module

## Summary

Implement a pre-configured `MongoDBContainer` module for swift-test-containers that provides a type-safe, ergonomic API for running MongoDB containers in tests. This module will abstract away common MongoDB container configuration, provide helpers for connection strings and authentication, support replica set mode, and use appropriate wait strategies out of the box.

The `MongoDBContainer` will be the first module implementation in the Tier 4 roadmap (Service-Specific Helpers), serving as a reference pattern for future database modules like `PostgresContainer` and `RedisContainer`.

## Current State

### Generic Container API

Today, developers use the generic `ContainerRequest` API to run MongoDB:

```swift
import Testing
import TestContainers

@Test func mongoDBExample() async throws {
    let request = ContainerRequest(image: "mongo:7")
        .withExposedPort(27017)
        .withEnvironment([
            "MONGO_INITDB_ROOT_USERNAME": "admin",
            "MONGO_INITDB_ROOT_PASSWORD": "password"
        ])
        .waitingFor(.tcpPort(27017, timeout: .seconds(30)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(27017)
        let connectionString = "mongodb://admin:password@127.0.0.1:\(port)/?directConnection=true"
        // ... use connection string with MongoDB driver
    }
}
```

### Problems with Current Approach

1. **Manual configuration**: Developers must know MongoDB-specific environment variables (`MONGO_INITDB_ROOT_USERNAME`, `MONGO_INITDB_ROOT_PASSWORD`)
2. **Port hardcoding**: MongoDB port (27017) repeated multiple times
3. **Connection string assembly**: Manual string interpolation is error-prone and doesn't account for special characters, authentication modes, or replica sets
4. **Wait strategy**: TCP port check doesn't guarantee MongoDB is ready to accept commands
5. **No type safety**: No compile-time guarantees about configuration validity
6. **Replica set complexity**: Setting up single-node replica sets (required for transactions) requires deep MongoDB knowledge

### Existing Architecture

The current container architecture (see `/Sources/TestContainers/`):

- **ContainerRequest**: Fluent builder for generic containers
- **Container**: Actor representing a running container with lifecycle management
- **WaitStrategy**: Enum of wait conditions (none, tcpPort, logContains)
- **withContainer(_:_:)**: Scoped resource management ensuring cleanup

Module containers will build on top of these primitives while providing domain-specific APIs.

## Requirements

### Functional Requirements

1. **Default Image**: Use `mongo:7` as the default image (latest stable version), allow override
2. **Authentication Configuration**:
   - Support username/password authentication via `withUsername(_:)` and `withPassword(_:)`
   - Default to no authentication if not specified
   - Properly escape credentials in connection strings
3. **Replica Set Support**:
   - Provide `withReplicaSet()` option to enable single-node replica set mode
   - Replica set name should default to `"rs"` but be configurable
   - Container should wait until replica set is initialized and ready
4. **Connection String Helper**:
   - `connectionString() async throws -> String` method returning MongoDB connection URI
   - Format: `mongodb://[username:password@]host:port[/database][?options]`
   - Include `directConnection=true` for standalone, appropriate options for replica sets
   - Handle URL encoding of credentials
5. **Appropriate Wait Strategy**:
   - For standalone: Wait for log message indicating MongoDB is ready (e.g., "Waiting for connections")
   - For replica set: Wait for log indicating replica set initialization complete
   - Fallback to TCP port check if log wait not available yet (see Tier 1 dependencies)
6. **Port Management**: Expose standard MongoDB port 27017 automatically
7. **Database Selection**: Optional `withDatabase(_:)` to specify default database in connection string

### Non-Functional Requirements

1. **API Consistency**: Follow Swift naming conventions and builder pattern established by `ContainerRequest`
2. **Sendable**: All types must be `Sendable` for safe concurrency
3. **Error Handling**: Use typed errors, fail fast with clear messages
4. **Documentation**: Comprehensive DocC comments with code examples
5. **Testability**: Unit tests for configuration building, integration tests with real MongoDB
6. **Zero Dependencies**: No MongoDB driver dependency; module only provides containers

### Feature Parity

Reference implementation: [testcontainers-go MongoDB module](https://golang.testcontainers.org/modules/mongodb/)

Core features to match:
- ✅ Default image with version override
- ✅ Username/password configuration
- ✅ Replica set mode
- ✅ Connection string helper
- ✅ Automatic wait strategy

## API Design

### Proposed Swift API

```swift
import Foundation

/// A pre-configured MongoDB container with typed configuration and connection helpers.
///
/// MongoDBContainer simplifies running MongoDB in tests by providing:
/// - Sensible defaults (mongo:7 image, port 27017)
/// - Type-safe authentication configuration
/// - Automatic connection string generation
/// - Single-node replica set support for testing transactions
///
/// Example - Basic usage:
/// ```swift
/// let mongo = MongoDBContainer()
///     .withUsername("testuser")
///     .withPassword("testpass")
///
/// try await mongo.start()
/// let connectionString = try await mongo.connectionString()
/// // mongodb://testuser:testpass@127.0.0.1:55432/?directConnection=true
/// ```
///
/// Example - Replica set for transactions:
/// ```swift
/// let mongo = MongoDBContainer()
///     .withReplicaSet()
///
/// try await mongo.start()
/// let connectionString = try await mongo.connectionString()
/// // mongodb://127.0.0.1:55432/?replicaSet=rs&directConnection=true
/// ```
public struct MongoDBContainer: Sendable {
    /// Default MongoDB Docker image
    public static let defaultImage = "mongo:7"

    /// Default MongoDB port
    public static let defaultPort = 27017

    private let image: String
    private let username: String?
    private let password: String?
    private let database: String?
    private let replicaSet: ReplicaSetConfig?
    private let host: String

    /// Configuration for single-node replica set mode
    public struct ReplicaSetConfig: Sendable, Hashable {
        public let name: String

        public init(name: String = "rs") {
            self.name = name
        }
    }

    /// Creates a MongoDB container with default configuration (mongo:7, no auth, standalone mode).
    public init(image: String = MongoDBContainer.defaultImage) {
        self.image = image
        self.username = nil
        self.password = nil
        self.database = nil
        self.replicaSet = nil
        self.host = "127.0.0.1"
    }

    /// Configures authentication with the specified username.
    ///
    /// Must be paired with `withPassword(_:)`. Creates a superuser account with the given credentials.
    ///
    /// - Parameter username: MongoDB root username
    /// - Returns: A new container configuration with authentication enabled
    public func withUsername(_ username: String) -> Self {
        var copy = self
        copy.username = username
        return copy
    }

    /// Configures authentication with the specified password.
    ///
    /// Must be paired with `withUsername(_:)`. Sets the password for the superuser account.
    ///
    /// - Parameter password: MongoDB root password
    /// - Returns: A new container configuration with authentication enabled
    public func withPassword(_ password: String) -> Self {
        var copy = self
        copy.password = password
        return copy
    }

    /// Specifies the default database in the connection string.
    ///
    /// - Parameter database: Database name to include in connection URI
    /// - Returns: A new container configuration with default database
    public func withDatabase(_ database: String) -> Self {
        var copy = self
        copy.database = database
        return copy
    }

    /// Enables single-node replica set mode.
    ///
    /// This is required for testing MongoDB transactions and change streams.
    /// The container will initialize a replica set named "rs" (or custom name) and wait for it to be ready.
    ///
    /// - Parameter name: Replica set name (defaults to "rs")
    /// - Returns: A new container configuration in replica set mode
    public func withReplicaSet(name: String = "rs") -> Self {
        var copy = self
        copy.replicaSet = ReplicaSetConfig(name: name)
        return copy
    }

    /// Overrides the default host (127.0.0.1) used in connection strings.
    ///
    /// - Parameter host: Host address to use
    /// - Returns: A new container configuration with custom host
    public func withHost(_ host: String) -> Self {
        var copy = self
        copy.host = host
        return copy
    }

    /// Converts this MongoDB container configuration to a generic ContainerRequest.
    ///
    /// This method builds the Docker run configuration with appropriate environment variables,
    /// port mappings, and wait strategies based on authentication and replica set settings.
    ///
    /// - Returns: A ContainerRequest ready to be started
    public func asContainerRequest() -> ContainerRequest {
        var request = ContainerRequest(image: image)
            .withExposedPort(MongoDBContainer.defaultPort)
            .withHost(host)

        // Configure authentication if both username and password provided
        if let username = username, let password = password {
            request = request.withEnvironment([
                "MONGO_INITDB_ROOT_USERNAME": username,
                "MONGO_INITDB_ROOT_PASSWORD": password
            ])
        }

        // Configure replica set mode
        if let replicaSet = replicaSet {
            request = request
                .withCommand(["--replSet", replicaSet.name])
                // TODO: Add .logContains wait strategy once implemented (Tier 1)
                // For now, rely on TCP + manual sleep or external validation
                .waitingFor(.tcpPort(MongoDBContainer.defaultPort, timeout: .seconds(30)))
        } else {
            // Standalone mode: wait for TCP port
            request = request.waitingFor(.tcpPort(MongoDBContainer.defaultPort, timeout: .seconds(30)))
        }

        return request
    }
}

/// Extension providing connection string helpers
extension MongoDBContainer {
    /// Returns a MongoDB connection string for the running container.
    ///
    /// The format depends on configuration:
    /// - Standalone with auth: `mongodb://user:pass@host:port/?directConnection=true`
    /// - Standalone without auth: `mongodb://host:port/?directConnection=true`
    /// - Replica set with auth: `mongodb://user:pass@host:port/?replicaSet=rs&directConnection=true`
    /// - Replica set without auth: `mongodb://host:port/?replicaSet=rs&directConnection=true`
    ///
    /// Credentials are URL-encoded to handle special characters.
    ///
    /// - Parameter container: The running container instance
    /// - Returns: MongoDB connection URI string
    /// - Throws: If port cannot be resolved or container is not running
    public func connectionString(for container: Container) async throws -> String {
        let port = try await container.hostPort(MongoDBContainer.defaultPort)

        var components = URLComponents()
        components.scheme = "mongodb"

        // Add authentication
        if let username = username, let password = password {
            components.user = username
            components.password = password
        }

        components.host = host
        components.port = port

        // Add database path if specified
        if let database = database {
            components.path = "/\(database)"
        }

        // Add query parameters
        var queryItems: [URLQueryItem] = []

        if let replicaSet = replicaSet {
            queryItems.append(URLQueryItem(name: "replicaSet", value: replicaSet.name))
        }

        queryItems.append(URLQueryItem(name: "directConnection", value: "true"))
        components.queryItems = queryItems

        guard let url = components.url?.absoluteString else {
            throw TestContainersError.invalidConfiguration("Failed to build MongoDB connection string")
        }

        return url
    }
}

/// Convenience function for scoped MongoDB container lifecycle
///
/// Example:
/// ```swift
/// let mongo = MongoDBContainer()
///     .withUsername("admin")
///     .withPassword("secret")
///     .withReplicaSet()
///
/// try await withMongoDBContainer(mongo) { container, connectionString in
///     // Use connectionString to connect with MongoDB driver
///     // Container automatically cleaned up on exit
/// }
/// ```
public func withMongoDBContainer<T>(
    _ config: MongoDBContainer,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container, String) async throws -> T
) async throws -> T {
    let request = config.asContainerRequest()

    return try await withContainer(request, docker: docker) { container in
        // For replica set mode, need to initialize the replica set
        if let replicaSet = config.replicaSet {
            // TODO: Implement replica set initialization once exec() is available (Tier 1)
            // This would run: db.adminCommand({ replSetInitiate: { _id: "rs", members: [{ _id: 0, host: "localhost:27017" }] } })
            // For now, document manual initialization or require external setup
        }

        let connectionString = try await config.connectionString(for: container)
        return try await operation(container, connectionString)
    }
}
```

### Alternative Designs Considered

**Option 1: Subclass Container**
```swift
public actor MongoDBContainer: Container {
    public func connectionString() async throws -> String { ... }
}
```
❌ Rejected: Swift actors can't inherit, and mixing actor + class is complex

**Option 2: Wrapper with Container Property**
```swift
public actor MongoDBContainer {
    private let container: Container
    public func connectionString() async throws -> String { ... }
}
```
❌ Rejected: Breaks scoped lifecycle pattern, requires manual cleanup

**Option 3: Configuration Struct + Extension (Chosen)**
```swift
public struct MongoDBContainer {
    func asContainerRequest() -> ContainerRequest { ... }
}
extension MongoDBContainer {
    func connectionString(for container: Container) async throws -> String { ... }
}
```
✅ Accepted: Maintains builder pattern, works with existing lifecycle, Sendable by default

## Implementation Steps

### Phase 1: Core Structure (Estimated: 2-3 hours)

1. **Create module structure**
   - [ ] Create `/Sources/TestContainers/Modules/MongoDBContainer.swift`
   - [ ] Add `MongoDBContainer` struct with basic fields (image, username, password, database, replicaSet, host)
   - [ ] Implement builder methods: `withUsername(_:)`, `withPassword(_:)`, `withDatabase(_:)`, `withReplicaSet(name:)`, `withHost(_:)`
   - [ ] Add `ReplicaSetConfig` nested struct

2. **Implement container request conversion**
   - [ ] Implement `asContainerRequest()` method
   - [ ] Map authentication fields to `MONGO_INITDB_ROOT_USERNAME` / `MONGO_INITDB_ROOT_PASSWORD`
   - [ ] Add replica set command args: `["--replSet", name]`
   - [ ] Configure appropriate wait strategy (TCP port for now)
   - [ ] Set default port exposure (27017)

### Phase 2: Connection String Helper (Estimated: 1-2 hours)

3. **Implement connection string generation**
   - [ ] Add `connectionString(for:)` extension method
   - [ ] Build MongoDB URI using `URLComponents` for proper encoding
   - [ ] Handle auth credentials (username:password@)
   - [ ] Handle database path (/database)
   - [ ] Add query parameters: `directConnection=true`, `replicaSet=name` (if enabled)
   - [ ] Add error handling for invalid configurations

4. **Add convenience wrapper**
   - [ ] Implement `withMongoDBContainer(_:docker:operation:)` function
   - [ ] Pass both Container and connectionString to operation block
   - [ ] Document replica set initialization limitation (needs exec support)

### Phase 3: Documentation (Estimated: 1 hour)

5. **Write comprehensive DocC comments**
   - [ ] Document `MongoDBContainer` struct with overview and examples
   - [ ] Document each builder method with parameters and return values
   - [ ] Document `connectionString(for:)` with format specification
   - [ ] Document `withMongoDBContainer` with usage examples
   - [ ] Add code examples for common scenarios: basic auth, replica sets, no auth

6. **Add module to exports**
   - [ ] Ensure `MongoDBContainer` is public and properly exported
   - [ ] Update `/Sources/TestContainers/TestContainers.swift` if needed

### Phase 4: Testing (Estimated: 3-4 hours)

7. **Unit tests** (see Testing Plan section)
   - [ ] Test builder pattern methods return new instances
   - [ ] Test `asContainerRequest()` builds correct ContainerRequest
   - [ ] Test connection string generation for all configuration combinations
   - [ ] Test URL encoding of special characters in credentials

8. **Integration tests** (see Testing Plan section)
   - [ ] Test basic container lifecycle (start, connect, stop)
   - [ ] Test authentication with username/password
   - [ ] Test standalone mode connection
   - [ ] Test replica set mode initialization (manual validation for now)
   - [ ] Test connection string works with MongoDB Swift driver (if available as dev dependency)

### Phase 5: Documentation & Examples (Estimated: 1 hour)

9. **Update project documentation**
   - [ ] Add MongoDB example to README.md
   - [ ] Update FEATURES.md to mark `MongoDBContainer` as implemented
   - [ ] Add migration guide from generic ContainerRequest to MongoDBContainer
   - [ ] Document known limitations (replica set requires manual init until exec is implemented)

## Testing Plan

### Unit Tests

Create `/Tests/TestContainersTests/MongoDBContainerTests.swift`:

```swift
import Testing
import TestContainers

@Suite("MongoDBContainer Configuration")
struct MongoDBContainerConfigTests {

    @Test("Default configuration uses mongo:7")
    func defaultImage() {
        let mongo = MongoDBContainer()
        let request = mongo.asContainerRequest()
        #expect(request.image == "mongo:7")
    }

    @Test("Custom image overrides default")
    func customImage() {
        let mongo = MongoDBContainer(image: "mongo:6")
        let request = mongo.asContainerRequest()
        #expect(request.image == "mongo:6")
    }

    @Test("Builder methods are immutable")
    func builderImmutability() {
        let mongo1 = MongoDBContainer()
        let mongo2 = mongo1.withUsername("user")
        let mongo3 = mongo2.withPassword("pass")

        // Original unchanged
        #expect(mongo1.asContainerRequest().environment.isEmpty)
        // Each step creates new instance
        #expect(mongo2.asContainerRequest().environment["MONGO_INITDB_ROOT_USERNAME"] == "user")
        #expect(mongo3.asContainerRequest().environment["MONGO_INITDB_ROOT_PASSWORD"] == "pass")
    }

    @Test("Authentication configures environment variables")
    func authenticationConfig() {
        let mongo = MongoDBContainer()
            .withUsername("admin")
            .withPassword("secret")

        let request = mongo.asContainerRequest()
        #expect(request.environment["MONGO_INITDB_ROOT_USERNAME"] == "admin")
        #expect(request.environment["MONGO_INITDB_ROOT_PASSWORD"] == "secret")
    }

    @Test("Replica set configures command args")
    func replicaSetConfig() {
        let mongo = MongoDBContainer()
            .withReplicaSet(name: "testrs")

        let request = mongo.asContainerRequest()
        #expect(request.command.contains("--replSet"))
        #expect(request.command.contains("testrs"))
    }

    @Test("Port 27017 is exposed by default")
    func defaultPort() {
        let mongo = MongoDBContainer()
        let request = mongo.asContainerRequest()

        let portMappings = request.ports.map { $0.containerPort }
        #expect(portMappings.contains(27017))
    }

    @Test("Wait strategy is TCP port by default")
    func defaultWaitStrategy() {
        let mongo = MongoDBContainer()
        let request = mongo.asContainerRequest()

        if case .tcpPort(let port, _, _) = request.waitStrategy {
            #expect(port == 27017)
        } else {
            Issue.record("Expected TCP port wait strategy")
        }
    }
}

@Suite("MongoDBContainer Connection Strings")
struct MongoDBConnectionStringTests {

    @Test("Connection string without auth")
    func noAuth() async throws {
        let mongo = MongoDBContainer()
        // Mock container with known port
        // This would require a test double or integration test
        // For now, test URL building logic in isolation

        let components = URLComponents()
        components.scheme = "mongodb"
        components.host = "127.0.0.1"
        components.port = 55432
        components.queryItems = [URLQueryItem(name: "directConnection", value: "true")]

        let expected = "mongodb://127.0.0.1:55432/?directConnection=true"
        #expect(components.url?.absoluteString == expected)
    }

    @Test("Connection string with auth")
    func withAuth() {
        let mongo = MongoDBContainer()
            .withUsername("admin")
            .withPassword("secret")

        var components = URLComponents()
        components.scheme = "mongodb"
        components.user = "admin"
        components.password = "secret"
        components.host = "127.0.0.1"
        components.port = 55432
        components.queryItems = [URLQueryItem(name: "directConnection", value: "true")]

        let result = components.url?.absoluteString ?? ""
        #expect(result.contains("admin:secret@"))
    }

    @Test("Connection string with database")
    func withDatabase() {
        var components = URLComponents()
        components.scheme = "mongodb"
        components.host = "127.0.0.1"
        components.port = 27017
        components.path = "/mydb"
        components.queryItems = [URLQueryItem(name: "directConnection", value: "true")]

        let result = components.url?.absoluteString ?? ""
        #expect(result.contains("/mydb"))
    }

    @Test("Connection string with replica set")
    func withReplicaSet() {
        var components = URLComponents()
        components.scheme = "mongodb"
        components.host = "127.0.0.1"
        components.port = 27017
        components.queryItems = [
            URLQueryItem(name: "replicaSet", value: "rs"),
            URLQueryItem(name: "directConnection", value: "true")
        ]

        let result = components.url?.absoluteString ?? ""
        #expect(result.contains("replicaSet=rs"))
    }

    @Test("Special characters in credentials are URL encoded")
    func urlEncoding() {
        var components = URLComponents()
        components.scheme = "mongodb"
        components.user = "user@domain"
        components.password = "p@ss:word!"
        components.host = "127.0.0.1"
        components.port = 27017

        let result = components.url?.absoluteString ?? ""
        // URLComponents automatically encodes these
        #expect(!result.contains("@ss")) // @ should be encoded in password
        #expect(result.contains("user%40domain")) // @ encoded in username
    }
}
```

### Integration Tests

Create `/Tests/TestContainersTests/MongoDBContainerIntegrationTests.swift`:

```swift
import Testing
import TestContainers

@Suite("MongoDBContainer Integration Tests")
struct MongoDBContainerIntegrationTests {

    @Test("Can start MongoDB container without auth")
    func startWithoutAuth() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let mongo = MongoDBContainer()

        try await withMongoDBContainer(mongo) { container, connectionString in
            #expect(connectionString.hasPrefix("mongodb://"))
            #expect(connectionString.contains("127.0.0.1"))
            #expect(!connectionString.contains("@")) // No auth

            let port = try await container.hostPort(27017)
            #expect(port > 0)
        }
    }

    @Test("Can start MongoDB container with authentication")
    func startWithAuth() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let mongo = MongoDBContainer()
            .withUsername("testuser")
            .withPassword("testpass")

        try await withMongoDBContainer(mongo) { container, connectionString in
            #expect(connectionString.contains("testuser:testpass@"))

            // Verify logs show authentication enabled
            let logs = try await container.logs()
            // MongoDB logs would show authentication requirement
            #expect(!logs.isEmpty)
        }
    }

    @Test("Can start MongoDB in replica set mode")
    func startWithReplicaSet() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let mongo = MongoDBContainer()
            .withReplicaSet(name: "testrs")

        try await withMongoDBContainer(mongo) { container, connectionString in
            #expect(connectionString.contains("replicaSet=testrs"))

            // Verify replica set is configured (check logs for now)
            let logs = try await container.logs()
            // TODO: Once exec() is implemented, run rs.status() to verify
            #expect(logs.contains("replSet") || logs.contains("replica set"))
        }
    }

    @Test("Connection string works with custom host")
    func customHost() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let mongo = MongoDBContainer()
            .withHost("localhost")

        try await withMongoDBContainer(mongo) { container, connectionString in
            #expect(connectionString.contains("localhost"))
            #expect(!connectionString.contains("127.0.0.1"))
        }
    }

    // If MongoDB Swift driver is available as dev dependency:
    @Test("Connection string works with real MongoDB driver")
    func realDriverConnection() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        // This test would be optional, only if we add MongoDB driver as dev dependency
        // let mongo = MongoDBContainer()
        //     .withUsername("admin")
        //     .withPassword("password")
        //
        // try await withMongoDBContainer(mongo) { container, connectionString in
        //     let client = MongoClient(connectionString)
        //     try await client.db("test").collection("test").insertOne(["key": "value"])
        // }
    }
}
```

### Manual Testing Checklist

- [ ] Start container without auth and connect with `mongosh`
- [ ] Start container with auth and verify credentials work
- [ ] Start container in replica set mode and run `rs.status()`
- [ ] Test with different MongoDB versions (6, 7, 8)
- [ ] Verify container cleanup on success, error, and cancellation
- [ ] Test parallel container execution (multiple MongoDB containers)
- [ ] Verify connection string format with MongoDB Compass
- [ ] Test special characters in credentials (@, :, /, ?)

## Acceptance Criteria

### Must Have

- [ ] `MongoDBContainer` struct with builder pattern API
- [ ] `withUsername(_:)` and `withPassword(_:)` configure authentication
- [ ] `withReplicaSet(name:)` enables single-node replica set mode
- [ ] `withDatabase(_:)` sets default database in connection string
- [ ] `asContainerRequest()` converts to generic ContainerRequest
- [ ] `connectionString(for:)` generates valid MongoDB URIs
- [ ] `withMongoDBContainer(_:docker:operation:)` scoped lifecycle helper
- [ ] Default image is `mongo:7`
- [ ] Port 27017 automatically exposed
- [ ] TCP port wait strategy by default
- [ ] Credentials URL-encoded in connection string
- [ ] Unit tests for all builder methods and connection string generation
- [ ] Integration tests for standalone and replica set modes
- [ ] DocC documentation for all public APIs with examples

### Should Have

- [ ] Example in README.md showing migration from generic API
- [ ] FEATURES.md updated to mark MongoDBContainer as implemented
- [ ] Support for custom MongoDB images (mongo:6, mongo:5, etc.)
- [ ] Connection string includes `directConnection=true`
- [ ] Connection string includes `replicaSet=name` when in replica set mode

### Could Have (Future Enhancements)

- [ ] Automatic replica set initialization using `exec()` (blocked on Tier 1 feature)
- [ ] Better wait strategy using log pattern matching (blocked on Tier 1 feature)
- [ ] Support for init scripts via bind mounts (blocked on Tier 2 feature)
- [ ] Support for custom MongoDB config files (blocked on Tier 2 feature)
- [ ] TLS/SSL configuration
- [ ] Multiple user creation beyond root user
- [ ] MongoDB Atlas local testing mode

### Won't Have (Out of Scope)

- [ ] MongoDB driver as dependency (users bring their own)
- [ ] Multi-node replica set support (requires networking, Tier 2)
- [ ] Sharded cluster support (too complex for testing)
- [ ] Oplog access configuration (niche use case)

## Dependencies

### Blocks On (Required Before Implementation)

None - can be implemented with current API

### Blocked By (Limits Full Functionality)

1. **HTTP/HTTPS Wait Strategy** (Feature 001)
   - Could use `mongosh --eval "db.adminCommand('ping')"` as HTTP-like health check
   - Workaround: Use TCP port + sleep or manual validation

2. **Regex Log Wait** (Feature 002)
   - Better detection of "ready for connections" in MongoDB logs
   - Workaround: Use `.logContains("Waiting for connections")`

3. **Container Exec** (Feature 007)
   - Required for automatic replica set initialization: `mongosh --eval "rs.initiate(...)"`
   - Workaround: Document manual initialization or require external setup

4. **Bind Mounts** (Tier 2)
   - Needed for init scripts and custom config files
   - Workaround: Users can extend ContainerRequest manually

### Enables (Unblocks These Features)

1. Pattern for other database modules (`PostgresContainer`, `RedisContainer`, `MySQLContainer`)
2. Module testing best practices
3. Multi-container test patterns (app + MongoDB)

## Migration Path

### From Generic ContainerRequest

**Before:**
```swift
let request = ContainerRequest(image: "mongo:7")
    .withExposedPort(27017)
    .withEnvironment([
        "MONGO_INITDB_ROOT_USERNAME": "admin",
        "MONGO_INITDB_ROOT_PASSWORD": "password"
    ])
    .waitingFor(.tcpPort(27017))

try await withContainer(request) { container in
    let port = try await container.hostPort(27017)
    let connectionString = "mongodb://admin:password@127.0.0.1:\(port)"
    // ...
}
```

**After:**
```swift
let mongo = MongoDBContainer()
    .withUsername("admin")
    .withPassword("password")

try await withMongoDBContainer(mongo) { container, connectionString in
    // connectionString already built and ready to use
    // ...
}
```

### Backward Compatibility

- Generic `ContainerRequest` API remains unchanged
- MongoDBContainer is pure addition, no breaking changes
- Users can continue using generic API if preferred
- MongoDBContainer can convert to ContainerRequest for advanced customization

## Security Considerations

1. **Credential Handling**
   - Credentials passed via environment variables (standard Docker practice)
   - URL encoding prevents injection in connection strings
   - No credentials logged or exposed in error messages

2. **Network Exposure**
   - Containers only expose ports to localhost by default
   - No external network access unless explicitly configured
   - Replica set mode uses localhost-only communication

3. **Container Isolation**
   - Each test gets isolated container
   - No shared state between tests
   - Automatic cleanup prevents resource leaks

## Performance Considerations

1. **Startup Time**
   - MongoDB typically starts in 2-5 seconds
   - Replica set adds 1-2 seconds for initialization
   - Wait strategy timeout default: 30 seconds

2. **Resource Usage**
   - Default MongoDB container: ~400MB memory
   - Minimal CPU usage for test workloads
   - Disk I/O minimal without persistence

3. **Parallel Testing**
   - Each container uses dynamic port allocation
   - Multiple containers can run simultaneously
   - Limited by Docker daemon and system resources

## Documentation Requirements

1. **API Documentation (DocC)**
   - All public types, methods, and properties
   - Code examples for common scenarios
   - Parameter descriptions and return values
   - Thrown errors documented

2. **User Guide (README.md)**
   - Quick start example
   - Migration from generic API
   - Replica set setup guide
   - Troubleshooting common issues

3. **Feature Documentation (FEATURES.md)**
   - Mark MongoDBContainer as implemented
   - Link to this feature ticket
   - List known limitations

4. **Code Comments**
   - Implementation notes for complex logic
   - TODO markers for future enhancements
   - References to blocked features

## Future Enhancements

### Automatic Replica Set Initialization

Once `exec()` is available (Feature 007), enhance `withMongoDBContainer`:

```swift
if let replicaSet = config.replicaSet {
    let initScript = """
    db = db.getSiblingDB('admin');
    rs.initiate({
        _id: '\(replicaSet.name)',
        members: [{ _id: 0, host: 'localhost:27017' }]
    });
    """
    try await container.exec(["mongosh", "--eval", initScript])

    // Wait for replica set to be ready
    try await Waiter.wait(timeout: .seconds(10), pollInterval: .milliseconds(500),
                         description: "replica set to become ready") {
        let status = try await container.exec(["mongosh", "--quiet", "--eval", "rs.status().ok"])
        return status.stdout.contains("1")
    }
}
```

### Enhanced Wait Strategy

Once log pattern matching is available (Feature 002):

```swift
if let replicaSet = replicaSet {
    request = request.waitingFor(
        .logMatches("waiting for connections.*port 27017", timeout: .seconds(30))
    )
} else {
    request = request.waitingFor(
        .logMatches("Waiting for connections", timeout: .seconds(30))
    )
}
```

### Init Scripts Support

Once bind mounts are available (Tier 2):

```swift
public func withInitScript(_ scriptPath: String) -> Self {
    var copy = self
    copy.initScriptPath = scriptPath
    return copy
}

// In asContainerRequest():
if let script = initScriptPath {
    request = request.withBindMount(script, to: "/docker-entrypoint-initdb.d/init.js")
}
```

## References

- [Testcontainers for Go - MongoDB Module](https://golang.testcontainers.org/modules/mongodb/)
- [MongoDB Docker Official Image](https://hub.docker.com/_/mongo)
- [MongoDB Connection String Format](https://www.mongodb.com/docs/manual/reference/connection-string/)
- [swift-test-containers Architecture](/Sources/TestContainers/)
- [swift-test-containers Features Roadmap](/FEATURES.md)

## Related Features

- **Feature 001**: HTTP Wait Strategy - Better readiness detection
- **Feature 002**: Regex Log Wait - Precise log-based waiting
- **Feature 007**: Container Exec - Replica set auto-initialization
- **Feature 012**: Volume Mounts - Init scripts and custom configs
- **Future**: `PostgresContainer` - Similar database module pattern
- **Future**: `RedisContainer` - Similar database module pattern

---

**Feature Status**: 📋 Planned (Not Started)

**Estimated Effort**: 8-12 hours (2-3 hours core + 1-2 hours connection strings + 1 hour docs + 3-4 hours testing + 1 hour integration)

**Priority**: High (First module implementation, establishes pattern)

**Target Milestone**: MVP+ Modules (First Set)
