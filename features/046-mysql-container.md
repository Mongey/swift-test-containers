# Feature 046: MySQLContainer / MariaDBContainer

**Status**: Implemented (February 13, 2026)
**Priority**: Tier 4 (Module System - Databases)
**Complexity**: Medium-High
**Estimated Effort**: 8-12 hours
**Dependencies**: None (can be implemented with current API)

---

## Summary

Implement pre-configured `MySQLContainer` and `MariaDBContainer` modules that provide typed APIs, sensible defaults, and convenience methods for testing Swift applications against MySQL and MariaDB databases. These modules will wrap the generic `ContainerRequest` API with database-specific configuration, initialization script support, and connection string helpers.

**Key Features:**
- Type-safe Swift API for MySQL 5.7, 8.0+ and MariaDB 10.x, 11.x containers
- Default configuration (database name, user, password, port)
- Initialization script support (`.sql`, `.sql.gz`, `.sh` files)
- Custom configuration file support (`my.cnf`)
- Connection string/URL helpers
- Appropriate wait strategy (log-based readiness check)
- Full compatibility with base `ContainerRequest` features

---

## Current State

### Generic Container API

Today, users must manually configure MySQL/MariaDB containers using the generic `ContainerRequest` API:

```swift
import Testing
import TestContainers

@Test func mysqlExample() async throws {
    let request = ContainerRequest(image: "mysql:8.0")
        .withExposedPort(3306)
        .withEnvironment([
            "MYSQL_ROOT_PASSWORD": "test",
            "MYSQL_DATABASE": "testdb",
            "MYSQL_USER": "user",
            "MYSQL_PASSWORD": "password"
        ])
        .waitingFor(.logContains("ready for connections", timeout: .seconds(60)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(3306)
        // Manually construct connection string
        let connectionString = "mysql://user:password@127.0.0.1:\(port)/testdb"
        // ... test code
    }
}
```

**Problems with current approach:**
1. Users must know MySQL/MariaDB environment variable names
2. No type safety for configuration options
3. Manual connection string construction is error-prone
4. No built-in support for initialization scripts
5. No guidance on appropriate wait strategies
6. Duplication across test files

### Existing Architecture

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

The `ContainerRequest` struct provides:
- Fluent builder pattern for configuration
- Environment variables (`withEnvironment(_:)`)
- Port mapping (`withExposedPort(_:hostPort:)`)
- Wait strategies (`waitingFor(_:)`)
- Labels, commands, and container naming

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

The `Container` actor provides:
- `hostPort(_:)` - Port resolution
- `endpoint(for:)` - Endpoint string construction
- `logs()` - Log retrieval
- `terminate()` - Container cleanup

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`

The `withContainer(_:operation:)` function provides:
- Scoped lifecycle management
- Automatic cleanup on success, error, and cancellation
- Wait strategy execution

---

## Requirements

### Functional Requirements

#### 1. MySQL Container Module

**Default Configuration:**
- Default image: `mysql:8.0` (latest stable major version)
- Default database: `test`
- Default root password: `test`
- Default user: `test` (in addition to root)
- Default user password: `test`
- Default port: `3306` (exposed and mapped)

**Supported MySQL Versions:**
- MySQL 5.7 (EOL but still widely used)
- MySQL 8.0 (current LTS)
- MySQL 8.4 (innovation release)
- MySQL 9.x (future versions)

**Configuration Options:**
- Custom database name
- Custom root password
- Custom non-root user and password
- Custom MySQL configuration file (`my.cnf`)
- Initialization scripts (`.sql`, `.sql.gz`, `.sh`)
- All base `ContainerRequest` options (environment, labels, etc.)

**Wait Strategy:**
- Default: `.logContains("ready for connections", timeout: .seconds(60))`
- Note: MySQL containers may show "ready for connections" twice during startup (first on port 0 during init, then on port 3306 after restart). The log wait should handle this.
- Allow override with custom wait strategy

**Connection String:**
- Format: `mysql://user:password@host:port/database`
- Support for additional parameters (e.g., `?charset=utf8mb4`)
- Helper methods for both root and non-root user connections

#### 2. MariaDB Container Module

**Default Configuration:**
- Default image: `mariadb:11.0` (latest stable major version)
- Default database: `test`
- Default root password: `test`
- Default user: `test`
- Default user password: `test`
- Default port: `3306` (exposed and mapped)

**Supported MariaDB Versions:**
- MariaDB 10.2+ (with `MARIADB_*` environment variables)
- MariaDB 10.6+ (recommended)
- MariaDB 11.x (current stable)

**Special Considerations:**
- MariaDB 10.2.38+, 10.3.29+, 10.4.19+, 10.5.10+, and all 10.6+ tags support `MARIADB_*` environment variables
- For compatibility, the module should support both `MYSQL_*` and `MARIADB_*` prefixes
- Environment variable behavior: MariaDB duplicates `MARIADB_*` vars with `MYSQL_*` prefix

**Configuration Options:**
- Same as MySQL (database, users, passwords, config files, init scripts)

**Wait Strategy:**
- Default: `.logContains("ready for connections", timeout: .seconds(60))`
- MariaDB also uses the same log message pattern as MySQL

#### 3. Initialization Scripts

**Supported Script Types:**
- `.sql` - SQL script files
- `.sql.gz` - Compressed SQL scripts
- `.sh` - Shell scripts for advanced setup

**Execution:**
- Scripts are copied to `/docker-entrypoint-initdb.d/` in the container
- Executed in alphabetical order during container initialization
- Executed before the database is marked as "ready for connections"
- NOTE: This feature requires copy-to-container support (Feature 008), so should be added in a follow-up iteration

**Use Cases:**
- DDL: Creating tables, indexes, constraints
- DML: Inserting test data
- Advanced setup: Creating stored procedures, triggers, views
- Multi-database setup via shell scripts

#### 4. Custom Configuration Files

**Purpose:**
- Override MySQL/MariaDB server configuration
- Common use cases: character set, collation, query cache, buffer sizes

**Implementation:**
- Accept path to local `my.cnf` file
- Copy to `/etc/mysql/conf.d/` in container
- NOTE: This also requires copy-to-container support (Feature 008)

**Alternative (Phase 1):**
- Use environment variables for common settings
- Document how to use base `.withEnvironment()` for advanced config

### Non-Functional Requirements

1. **Consistency**: Follow swift-test-containers patterns and conventions
2. **Type Safety**: Leverage Swift's type system for configuration
3. **Sendable**: All types must be `Sendable` for Swift concurrency
4. **Documentation**: Comprehensive DocC comments on all public APIs
5. **Testability**: Unit tests for configuration, integration tests for actual containers
6. **Backward Compatibility**: Don't break existing generic API

---

## API Design

### Module Structure

Create new Swift files in the `TestContainers` target:

```
Sources/
  TestContainers/
    Container.swift                    (existing)
    ContainerRequest.swift             (existing)
    WithContainer.swift                (existing)
    DockerClient.swift                 (existing)
    ...
    Modules/
      MySQLContainer.swift             (new)
      MariaDBContainer.swift           (new)
```

### MySQLContainer API

```swift
/// A pre-configured MySQL container for testing.
///
/// Provides a type-safe API for running MySQL containers with sensible defaults
/// and convenience methods for connection string generation.
///
/// Example:
/// ```swift
/// @Test func testMySQL() async throws {
///     let mysql = MySQLContainer()
///         .withDatabase("myapp")
///         .withUsername("myuser")
///         .withPassword("mypass")
///
///     try await mysql.withContainer { container in
///         let connectionString = try await container.connectionString()
///         // Use connectionString to connect with your MySQL client
///         // Example: mysql://myuser:mypass@127.0.0.1:32768/myapp
///     }
/// }
/// ```
public struct MySQLContainer: Sendable, Hashable {
    // MARK: - Configuration

    /// The Docker image to use for the MySQL container.
    /// Default: "mysql:8.0"
    public var image: String

    /// The name of the database to create on startup.
    /// Default: "test"
    public var database: String

    /// The MySQL root user password.
    /// Default: "test"
    public var rootPassword: String

    /// The name of a non-root user to create.
    /// If nil, only root user will be available.
    /// Default: "test"
    public var username: String?

    /// The password for the non-root user.
    /// Only used if username is set.
    /// Default: "test"
    public var password: String?

    /// Additional environment variables to pass to the container.
    public var environment: [String: String]

    /// Wait strategy for container readiness.
    /// Default: .logContains("ready for connections", timeout: .seconds(60))
    public var waitStrategy: WaitStrategy

    /// The container port MySQL listens on.
    /// Default: 3306
    public var containerPort: Int

    /// Optional host port to bind to.
    /// If nil, Docker assigns a random available port.
    /// Default: nil
    public var hostPort: Int?

    // MARK: - Initialization

    /// Creates a new MySQL container configuration with default settings.
    ///
    /// Defaults:
    /// - Image: mysql:8.0
    /// - Database: test
    /// - Root password: test
    /// - Username: test
    /// - Password: test
    /// - Port: 3306
    public init(
        image: String = "mysql:8.0",
        database: String = "test",
        rootPassword: String = "test",
        username: String? = "test",
        password: String? = "test"
    )

    // MARK: - Builder Methods

    /// Sets the MySQL Docker image.
    ///
    /// Example:
    /// ```swift
    /// MySQLContainer().withImage("mysql:5.7")
    /// ```
    public func withImage(_ image: String) -> Self

    /// Sets the database name to create on startup.
    ///
    /// Example:
    /// ```swift
    /// MySQLContainer().withDatabase("myapp_test")
    /// ```
    public func withDatabase(_ database: String) -> Self

    /// Sets the MySQL root password.
    ///
    /// Example:
    /// ```swift
    /// MySQLContainer().withRootPassword("secret")
    /// ```
    public func withRootPassword(_ password: String) -> Self

    /// Sets the non-root username and password.
    ///
    /// Example:
    /// ```swift
    /// MySQLContainer().withUsername("app_user", password: "app_pass")
    /// ```
    public func withUsername(_ username: String, password: String) -> Self

    /// Disables creation of a non-root user (root-only mode).
    ///
    /// Example:
    /// ```swift
    /// MySQLContainer().withRootOnly()
    /// ```
    public func withRootOnly() -> Self

    /// Sets additional environment variables.
    ///
    /// Example:
    /// ```swift
    /// MySQLContainer().withEnvironment(["MYSQL_INITDB_SKIP_TZINFO": "1"])
    /// ```
    public func withEnvironment(_ environment: [String: String]) -> Self

    /// Sets a custom wait strategy.
    ///
    /// Example:
    /// ```swift
    /// MySQLContainer().waitingFor(.tcpPort(3306, timeout: .seconds(30)))
    /// ```
    public func waitingFor(_ strategy: WaitStrategy) -> Self

    /// Sets the container port (advanced usage).
    ///
    /// Default is 3306. Only change if using a custom MySQL configuration
    /// that listens on a different port.
    public func withContainerPort(_ port: Int) -> Self

    /// Sets the host port to bind to (advanced usage).
    ///
    /// By default, Docker assigns a random available port. Use this to
    /// bind to a specific host port.
    ///
    /// Example:
    /// ```swift
    /// MySQLContainer().withHostPort(3306)
    /// ```
    public func withHostPort(_ port: Int) -> Self

    // MARK: - Internal Conversion

    /// Converts this MySQLContainer configuration to a ContainerRequest.
    ///
    /// This method is used internally by `withContainer(_:)`.
    func asContainerRequest() -> ContainerRequest
}

// MARK: - Container Extension

extension Container {
    /// Returns a MySQL connection string for the non-root user.
    ///
    /// Format: `mysql://username:password@host:port/database`
    ///
    /// - Parameter parameters: Optional query parameters to append to the connection string.
    ///                        Example: ["charset": "utf8mb4"]
    /// - Returns: A connection string for the MySQL database.
    /// - Throws: `TestContainersError` if the container was not created with a non-root user,
    ///          or if port mapping fails.
    ///
    /// Example:
    /// ```swift
    /// let url = try await container.mysqlConnectionString()
    /// // mysql://test:test@127.0.0.1:32768/test
    ///
    /// let urlWithParams = try await container.mysqlConnectionString(
    ///     parameters: ["charset": "utf8mb4"]
    /// )
    /// // mysql://test:test@127.0.0.1:32768/test?charset=utf8mb4
    /// ```
    public func mysqlConnectionString(
        parameters: [String: String] = [:]
    ) async throws -> String

    /// Returns a MySQL connection string for the root user.
    ///
    /// Format: `mysql://root:password@host:port/database`
    ///
    /// - Parameter parameters: Optional query parameters to append to the connection string.
    /// - Returns: A connection string for the MySQL database using root credentials.
    /// - Throws: `TestContainersError` if port mapping fails.
    ///
    /// Example:
    /// ```swift
    /// let url = try await container.mysqlRootConnectionString()
    /// // mysql://root:test@127.0.0.1:32768/test
    /// ```
    public func mysqlRootConnectionString(
        parameters: [String: String] = [:]
    ) async throws -> String
}

// MARK: - Scoped Lifecycle Helper

extension MySQLContainer {
    /// Runs a MySQL container for the duration of the operation block.
    ///
    /// The container is automatically started before the operation and cleaned up
    /// after, even if the operation throws an error or is cancelled.
    ///
    /// Example:
    /// ```swift
    /// @Test func testMyApp() async throws {
    ///     let mysql = MySQLContainer()
    ///         .withDatabase("testdb")
    ///
    ///     try await mysql.withContainer { container in
    ///         let connString = try await container.mysqlConnectionString()
    ///         // Run tests with connString
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter operation: The operation to perform with the running container.
    /// - Returns: The value returned by the operation.
    /// - Throws: Errors from container startup or the operation itself.
    public func withContainer<T>(
        docker: DockerClient = DockerClient(),
        operation: @Sendable (Container) async throws -> T
    ) async throws -> T
}
```

### MariaDBContainer API

```swift
/// A pre-configured MariaDB container for testing.
///
/// Provides a type-safe API for running MariaDB containers with sensible defaults
/// and convenience methods for connection string generation.
///
/// MariaDB is compatible with MySQL protocol, so connection strings use the
/// `mysql://` scheme for compatibility with most clients.
///
/// Example:
/// ```swift
/// @Test func testMariaDB() async throws {
///     let mariadb = MariaDBContainer()
///         .withDatabase("myapp")
///         .withUsername("myuser")
///         .withPassword("mypass")
///
///     try await mariadb.withContainer { container in
///         let connectionString = try await container.mariadbConnectionString()
///         // Use connectionString to connect with your MariaDB/MySQL client
///         // Example: mysql://myuser:mypass@127.0.0.1:32768/myapp
///     }
/// }
/// ```
public struct MariaDBContainer: Sendable, Hashable {
    // MARK: - Configuration

    /// The Docker image to use for the MariaDB container.
    /// Default: "mariadb:11.0"
    public var image: String

    /// The name of the database to create on startup.
    /// Default: "test"
    public var database: String

    /// The MariaDB root user password.
    /// Default: "test"
    public var rootPassword: String

    /// The name of a non-root user to create.
    /// If nil, only root user will be available.
    /// Default: "test"
    public var username: String?

    /// The password for the non-root user.
    /// Only used if username is set.
    /// Default: "test"
    public var password: String?

    /// Additional environment variables to pass to the container.
    public var environment: [String: String]

    /// Wait strategy for container readiness.
    /// Default: .logContains("ready for connections", timeout: .seconds(60))
    public var waitStrategy: WaitStrategy

    /// The container port MariaDB listens on.
    /// Default: 3306
    public var containerPort: Int

    /// Optional host port to bind to.
    /// If nil, Docker assigns a random available port.
    /// Default: nil
    public var hostPort: Int?

    // MARK: - Initialization

    /// Creates a new MariaDB container configuration with default settings.
    ///
    /// Defaults:
    /// - Image: mariadb:11.0
    /// - Database: test
    /// - Root password: test
    /// - Username: test
    /// - Password: test
    /// - Port: 3306
    public init(
        image: String = "mariadb:11.0",
        database: String = "test",
        rootPassword: String = "test",
        username: String? = "test",
        password: String? = "test"
    )

    // MARK: - Builder Methods

    /// Sets the MariaDB Docker image.
    ///
    /// Example:
    /// ```swift
    /// MariaDBContainer().withImage("mariadb:10.11")
    /// ```
    public func withImage(_ image: String) -> Self

    /// Sets the database name to create on startup.
    public func withDatabase(_ database: String) -> Self

    /// Sets the MariaDB root password.
    public func withRootPassword(_ password: String) -> Self

    /// Sets the non-root username and password.
    public func withUsername(_ username: String, password: String) -> Self

    /// Disables creation of a non-root user (root-only mode).
    public func withRootOnly() -> Self

    /// Sets additional environment variables.
    ///
    /// Note: MariaDB 10.2.38+, 10.3.29+, 10.4.19+, 10.5.10+, and all 10.6+
    /// support both MARIADB_* and MYSQL_* environment variable prefixes.
    /// This module uses MYSQL_* for maximum compatibility.
    public func withEnvironment(_ environment: [String: String]) -> Self

    /// Sets a custom wait strategy.
    public func waitingFor(_ strategy: WaitStrategy) -> Self

    /// Sets the container port (advanced usage).
    public func withContainerPort(_ port: Int) -> Self

    /// Sets the host port to bind to (advanced usage).
    public func withHostPort(_ port: Int) -> Self

    // MARK: - Internal Conversion

    /// Converts this MariaDBContainer configuration to a ContainerRequest.
    func asContainerRequest() -> ContainerRequest
}

// MARK: - Container Extension

extension Container {
    /// Returns a MariaDB connection string for the non-root user.
    ///
    /// Format: `mysql://username:password@host:port/database`
    ///
    /// Note: Uses `mysql://` scheme for compatibility with MySQL clients,
    /// as MariaDB implements the MySQL protocol.
    ///
    /// - Parameter parameters: Optional query parameters to append to the connection string.
    /// - Returns: A connection string for the MariaDB database.
    /// - Throws: `TestContainersError` if port mapping fails.
    public func mariadbConnectionString(
        parameters: [String: String] = [:]
    ) async throws -> String

    /// Returns a MariaDB connection string for the root user.
    ///
    /// Format: `mysql://root:password@host:port/database`
    ///
    /// - Parameter parameters: Optional query parameters to append to the connection string.
    /// - Returns: A connection string for the MariaDB database using root credentials.
    /// - Throws: `TestContainersError` if port mapping fails.
    public func mariadbRootConnectionString(
        parameters: [String: String] = [:]
    ) async throws -> String
}

// MARK: - Scoped Lifecycle Helper

extension MariaDBContainer {
    /// Runs a MariaDB container for the duration of the operation block.
    ///
    /// The container is automatically started before the operation and cleaned up
    /// after, even if the operation throws an error or is cancelled.
    ///
    /// Example:
    /// ```swift
    /// @Test func testMyApp() async throws {
    ///     let mariadb = MariaDBContainer()
    ///         .withDatabase("testdb")
    ///
    ///     try await mariadb.withContainer { container in
    ///         let connString = try await container.mariadbConnectionString()
    ///         // Run tests with connString
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter operation: The operation to perform with the running container.
    /// - Returns: The value returned by the operation.
    /// - Throws: Errors from container startup or the operation itself.
    public func withContainer<T>(
        docker: DockerClient = DockerClient(),
        operation: @Sendable (Container) async throws -> T
    ) async throws -> T
}
```

### Enhanced Error Handling

Add new error cases to `TestContainersError`:

```swift
// In TestContainersError.swift
public enum TestContainersError: Error {
    // ... existing cases ...

    /// The container was not configured with the requested user.
    ///
    /// Example: Calling `mysqlConnectionString()` on a container created
    /// with `withRootOnly()`.
    case missingUser(String)

    /// The container request is missing required metadata.
    ///
    /// Example: Connection string helpers require database name, username,
    /// and password to be stored in the container request.
    case missingMetadata(key: String, description: String)
}
```

---

## Implementation Steps

### Phase 1: Core MySQL/MariaDB Support (No File Copy)

**Step 1: Create MySQLContainer struct** (2-3 hours)
- [ ] Create `Sources/TestContainers/Modules/MySQLContainer.swift`
- [ ] Implement `MySQLContainer` struct with all properties
- [ ] Implement initializer with default values
- [ ] Implement all builder methods (`withDatabase`, `withUsername`, etc.)
- [ ] Make struct `Sendable` and `Hashable`
- [ ] Add comprehensive DocC documentation

**Step 2: Implement ContainerRequest conversion** (1 hour)
- [ ] Implement `asContainerRequest()` method
- [ ] Map all configuration to environment variables:
  - `MYSQL_ROOT_PASSWORD`
  - `MYSQL_DATABASE`
  - `MYSQL_USER`
  - `MYSQL_PASSWORD`
- [ ] Configure exposed port (3306)
- [ ] Set default wait strategy (log-based)
- [ ] Merge additional environment variables

**Step 3: Add Container extension for connection strings** (1-2 hours)
- [ ] Extend `Container` with `mysqlConnectionString()` method
- [ ] Extend `Container` with `mysqlRootConnectionString()` method
- [ ] Extract database name, username, password from container request metadata
- [ ] Implement URL encoding for special characters in credentials
- [ ] Support optional query parameters
- [ ] Handle error cases (missing user, missing metadata)

**Step 4: Add scoped lifecycle helper** (30 minutes)
- [ ] Implement `MySQLContainer.withContainer(_:operation:)` method
- [ ] Convert `self` to `ContainerRequest` using `asContainerRequest()`
- [ ] Delegate to global `withContainer(_:docker:operation:)`
- [ ] Ensure proper error propagation

**Step 5: Create MariaDBContainer** (1 hour)
- [ ] Create `Sources/TestContainers/Modules/MariaDBContainer.swift`
- [ ] Implement `MariaDBContainer` struct (similar to MySQL)
- [ ] Use `mariadb:11.0` as default image
- [ ] Use `MYSQL_*` environment variables for compatibility
- [ ] Add note in docs about `MARIADB_*` vs `MYSQL_*` variables
- [ ] Implement `mariadbConnectionString()` and `mariadbRootConnectionString()` extensions

**Step 6: Update error types** (30 minutes)
- [ ] Add `TestContainersError.missingUser(_:)` case
- [ ] Add `TestContainersError.missingMetadata(key:description:)` case
- [ ] Update error descriptions

**Step 7: Store metadata in ContainerRequest** (1 hour)
- [ ] Extend `ContainerRequest` to store typed metadata dictionary
- [ ] Add metadata keys for MySQL/MariaDB containers:
  - `"mysql.database"`
  - `"mysql.username"`
  - `"mysql.password"`
  - `"mysql.rootPassword"`
  - `"mariadb.database"`
  - etc.
- [ ] Use labels as fallback for metadata storage (if metadata dict not added)
- [ ] Document metadata keys

### Phase 2: Testing (2-3 hours)

**Step 8: Unit tests for configuration**
- [ ] Test `MySQLContainer` initialization with defaults
- [ ] Test builder methods (`withDatabase`, `withUsername`, etc.)
- [ ] Test `asContainerRequest()` output (environment variables, ports)
- [ ] Test `MariaDBContainer` configuration
- [ ] Test root-only mode
- [ ] Test custom wait strategies
- [ ] Test environment variable merging

**Step 9: Integration tests**
- [ ] Test MySQL 8.0 container startup (opt-in via env var)
- [ ] Test MySQL 5.7 container startup
- [ ] Test MariaDB 11.0 container startup
- [ ] Test MariaDB 10.6 container startup
- [ ] Test connection string generation
- [ ] Test database creation and user permissions
- [ ] Test root and non-root user access
- [ ] Verify log-based wait strategy works correctly
- [ ] Test cancellation and cleanup

**Step 10: Documentation**
- [ ] Add usage examples to DocC comments
- [ ] Update README.md with MySQL/MariaDB examples
- [ ] Update FEATURES.md to mark MySQL/MariaDB as implemented
- [ ] Add troubleshooting guide for common issues

### Phase 3: Advanced Features (Future - Depends on Feature 008)

**Step 11: Initialization scripts support**
- [ ] Add `withScripts(_:)` method to `MySQLContainer`
- [ ] Add `withScripts(_:)` method to `MariaDBContainer`
- [ ] Copy scripts to `/docker-entrypoint-initdb.d/`
- [ ] Support `.sql`, `.sql.gz`, `.sh` files
- [ ] Document execution order (alphabetical)

**Step 12: Custom configuration files**
- [ ] Add `withConfigFile(_:)` method
- [ ] Copy `my.cnf` to `/etc/mysql/conf.d/`
- [ ] Validate configuration file format
- [ ] Document common configuration options

---

## Testing Plan

### Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/MySQLContainerTests.swift`

```swift
import Testing
import TestContainers

@Suite("MySQLContainer Configuration")
struct MySQLContainerTests {
    @Test func defaultConfiguration() {
        let mysql = MySQLContainer()

        #expect(mysql.image == "mysql:8.0")
        #expect(mysql.database == "test")
        #expect(mysql.rootPassword == "test")
        #expect(mysql.username == "test")
        #expect(mysql.password == "test")
        #expect(mysql.containerPort == 3306)
        #expect(mysql.hostPort == nil)
    }

    @Test func builderMethods() {
        let mysql = MySQLContainer()
            .withImage("mysql:5.7")
            .withDatabase("myapp")
            .withUsername("myuser", password: "mypass")
            .withRootPassword("rootpass")
            .withHostPort(3306)

        #expect(mysql.image == "mysql:5.7")
        #expect(mysql.database == "myapp")
        #expect(mysql.username == "myuser")
        #expect(mysql.password == "mypass")
        #expect(mysql.rootPassword == "rootpass")
        #expect(mysql.hostPort == 3306)
    }

    @Test func rootOnlyMode() {
        let mysql = MySQLContainer().withRootOnly()

        #expect(mysql.username == nil)
        #expect(mysql.password == nil)
    }

    @Test func asContainerRequest() {
        let mysql = MySQLContainer()
            .withDatabase("testdb")
            .withUsername("user", password: "pass")
            .withRootPassword("root")

        let request = mysql.asContainerRequest()

        #expect(request.image == "mysql:8.0")
        #expect(request.environment["MYSQL_DATABASE"] == "testdb")
        #expect(request.environment["MYSQL_USER"] == "user")
        #expect(request.environment["MYSQL_PASSWORD"] == "pass")
        #expect(request.environment["MYSQL_ROOT_PASSWORD"] == "root")
        #expect(request.ports.contains(where: { $0.containerPort == 3306 }))
    }

    @Test func customWaitStrategy() {
        let mysql = MySQLContainer()
            .waitingFor(.tcpPort(3306, timeout: .seconds(30)))

        let request = mysql.asContainerRequest()

        #expect(request.waitStrategy == .tcpPort(3306, timeout: .seconds(30)))
    }
}

@Suite("MariaDBContainer Configuration")
struct MariaDBContainerTests {
    @Test func defaultConfiguration() {
        let mariadb = MariaDBContainer()

        #expect(mariadb.image == "mariadb:11.0")
        #expect(mariadb.database == "test")
        #expect(mariadb.rootPassword == "test")
        #expect(mariadb.username == "test")
        #expect(mariadb.password == "test")
    }

    @Test func asContainerRequest() {
        let mariadb = MariaDBContainer()
            .withDatabase("testdb")

        let request = mariadb.asContainerRequest()

        #expect(request.image == "mariadb:11.0")
        #expect(request.environment["MYSQL_DATABASE"] == "testdb")
    }
}
```

### Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/MySQLIntegrationTests.swift`

```swift
import Testing
import TestContainers

@Suite("MySQL Integration Tests")
struct MySQLIntegrationTests {
    @Test func canStartMySQL80Container() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let mysql = MySQLContainer()

        try await mysql.withContainer { container in
            let port = try await container.hostPort(3306)
            #expect(port > 0)

            let connString = try await container.mysqlConnectionString()
            #expect(connString.hasPrefix("mysql://test:test@"))
            #expect(connString.contains("/test"))

            let rootConnString = try await container.mysqlRootConnectionString()
            #expect(rootConnString.hasPrefix("mysql://root:test@"))
        }
    }

    @Test func canStartMySQL57Container() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let mysql = MySQLContainer()
            .withImage("mysql:5.7")

        try await mysql.withContainer { container in
            let port = try await container.hostPort(3306)
            #expect(port > 0)
        }
    }

    @Test func customDatabaseAndUser() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let mysql = MySQLContainer()
            .withDatabase("myapp")
            .withUsername("appuser", password: "apppass")

        try await mysql.withContainer { container in
            let connString = try await container.mysqlConnectionString()
            #expect(connString.contains("appuser:apppass"))
            #expect(connString.hasSuffix("/myapp"))
        }
    }

    @Test func connectionStringWithParameters() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let mysql = MySQLContainer()

        try await mysql.withContainer { container in
            let connString = try await container.mysqlConnectionString(
                parameters: ["charset": "utf8mb4", "parseTime": "true"]
            )
            #expect(connString.contains("charset=utf8mb4"))
            #expect(connString.contains("parseTime=true"))
        }
    }

    @Test func rootOnlyMode() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let mysql = MySQLContainer()
            .withRootOnly()

        try await mysql.withContainer { container in
            // Should fail because no non-root user was created
            await #expect(throws: TestContainersError.self) {
                _ = try await container.mysqlConnectionString()
            }

            // But root connection string should work
            let rootConnString = try await container.mysqlRootConnectionString()
            #expect(rootConnString.hasPrefix("mysql://root:"))
        }
    }
}

@Suite("MariaDB Integration Tests")
struct MariaDBIntegrationTests {
    @Test func canStartMariaDB11Container() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let mariadb = MariaDBContainer()

        try await mariadb.withContainer { container in
            let port = try await container.hostPort(3306)
            #expect(port > 0)

            let connString = try await container.mariadbConnectionString()
            #expect(connString.hasPrefix("mysql://test:test@"))
            #expect(connString.contains("/test"))
        }
    }

    @Test func canStartMariaDB106Container() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let mariadb = MariaDBContainer()
            .withImage("mariadb:10.6")

        try await mariadb.withContainer { container in
            let port = try await container.hostPort(3306)
            #expect(port > 0)
        }
    }
}
```

---

## Acceptance Criteria

### Must Have

- [x] **MySQLContainer API**
  - [x] Struct with typed configuration properties
  - [x] Default configuration (image: mysql:8.0, database: test, user: test, password: test)
  - [x] Builder methods for all configuration options
  - [x] Conversion to `ContainerRequest` with correct environment variables
  - [x] `Sendable` and `Hashable` conformance

- [x] **MariaDBContainer API**
  - [x] Struct with typed configuration properties
  - [x] Default configuration (image: mariadb:11)
  - [x] Builder methods matching MySQL container
  - [x] Uses `MYSQL_*` environment variables for compatibility

- [x] **Connection String Helpers**
  - [x] `connectionString(parameters:)` for non-root user
  - [x] `rootConnectionString(parameters:)` for root user
  - [x] Support for query parameters
  - [x] URL encoding for special characters

- [x] **Scoped Lifecycle**
  - [x] `withMySQLContainer(_:operation:)` helper
  - [x] `withMariaDBContainer(_:operation:)` helper
  - [x] Automatic cleanup on success, error, and cancellation

- [x] **Wait Strategy**
  - [x] Default log-based wait: `.logContains("ready for connections")`
  - [x] Ability to override with custom wait strategy

- [x] **Documentation**
  - [x] DocC comments on all public APIs
  - [x] Usage examples in comments
  - [ ] README.md updated with MySQL/MariaDB examples

- [x] **Tests**
  - [x] Unit tests for configuration and builder methods (44 tests)
  - [x] Integration tests for MySQL 8.0 (10 tests)
  - [x] Integration tests for MariaDB 11 (10 tests)
  - [x] Integration tests for connection string generation
  - [x] Integration tests for root-only mode

### Should Have

- [x] **Error Handling**
  - [x] `TestContainersError.invalidInput` for root-only containers
  - [x] Descriptive error messages

- [x] **Metadata Storage**
  - [x] Store database name, username, password in container labels
  - [x] Use config for connection string generation

- [x] **Version Support**
  - [x] MySQL 8.0 (tested)
  - [x] MariaDB 11 (tested)

### Nice to Have (Future Iterations)

- [ ] **Initialization Scripts** (requires Feature 008: Copy files to container)
  - [ ] `withScripts(_:)` method
  - [ ] Support for `.sql`, `.sql.gz`, `.sh` files
  - [ ] Copy to `/docker-entrypoint-initdb.d/`

- [ ] **Custom Configuration** (requires Feature 008)
  - [ ] `withConfigFile(_:)` method
  - [ ] Copy `my.cnf` to `/etc/mysql/conf.d/`

- [ ] **Health Check Wait Strategy** (requires Feature 004)
  - [ ] Use Docker HEALTHCHECK instead of log-based wait

- [ ] **Exec-based Ready Check** (requires Feature 007)
  - [ ] Use `mysqladmin ping` to verify readiness

---

## Open Questions

1. **Metadata storage**: Should we add a typed metadata dictionary to `ContainerRequest`, or use labels with a known prefix (e.g., `testcontainers.swift.mysql.database`)?
   - **Recommendation**: Use labels for now as it requires no changes to `ContainerRequest`. Add typed metadata in a future iteration if needed.

2. **Connection string format**: Should we support other formats like JDBC-style URLs or DSN strings?
   - **Recommendation**: Start with simple `mysql://user:pass@host:port/db` format. Add other formats if users request them.

3. **Default wait strategy**: Should we use log-based or TCP-based wait?
   - **Recommendation**: Use log-based (`.logContains("ready for connections")`) as it's more accurate. TCP port may be open before MySQL is ready to accept queries.

4. **MySQL "double startup" issue**: Should we handle the case where MySQL logs "ready for connections" twice?
   - **Recommendation**: The current `.logContains()` wait strategy will succeed on the first occurrence. If this causes issues, we can add a more sophisticated wait strategy later (e.g., wait for the second occurrence, or use exec-based `mysqladmin ping`).

5. **Package structure**: Should modules be in a separate `Modules` subdirectory or at the top level?
   - **Recommendation**: Use `Sources/TestContainers/Modules/` subdirectory for better organization as more modules are added.

6. **Public/Internal API boundary**: Should `asContainerRequest()` be public or internal?
   - **Recommendation**: Keep it internal. Users should use `withContainer(_:)`, not the low-level conversion.

---

## References

- [Testcontainers for Go - MySQL Module](https://golang.testcontainers.org/modules/mysql/)
- [Testcontainers for Go - MariaDB Module](https://golang.testcontainers.org/modules/mariadb/)
- [MySQL Docker Official Image](https://hub.docker.com/_/mysql)
- [MariaDB Docker Official Image](https://hub.docker.com/_/mariadb)
- [MySQL Environment Variables](https://hub.docker.com/_/mysql#environment-variables)
- [MariaDB Environment Variables](https://mariadb.com/kb/en/mariadb-docker-environment-variables/)
- Feature 007: Container Exec (for `mysqladmin ping` readiness check)
- Feature 008: Copy Files to Container (for init scripts and config files)

---

## Related Features

- **Feature 007 (Container Exec)**: Could enable `mysqladmin ping` for more reliable readiness checks
- **Feature 008 (Copy Files to Container)**: Required for initialization scripts and custom configuration files
- **Feature 004 (Health Check Wait)**: Could use Docker HEALTHCHECK for readiness detection
- **PostgresContainer (Future)**: Similar module for PostgreSQL
- **RedisContainer (Future)**: Similar module for Redis

---

## Notes

- This feature can be implemented entirely with the current API (no new wait strategies or file copy needed)
- Initialization scripts and custom config files are deferred to Phase 3 (requires Feature 008)
- The implementation follows testcontainers-go patterns adapted to Swift idioms
- Both MySQL and MariaDB modules use the `mysql://` connection string scheme for client compatibility
- MariaDB uses `MYSQL_*` environment variables for maximum compatibility with older images
