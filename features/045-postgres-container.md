# Feature 045: PostgresContainer Module

**Status**: Implemented
**Priority**: Tier 4 (Module System - Service-Specific Helpers)
**Estimated Complexity**: Medium

---

## Summary

Implement a pre-configured PostgreSQL container module with typed API for swift-test-containers. This module provides a specialized container abstraction with PostgreSQL-specific configuration options, sensible defaults, and a connection string helper method. This is the first service-specific module in the library, establishing patterns for future database and service modules.

## Current State

### Generic Container API

The current library provides a generic container API that works for any Docker image:

```swift
// Current approach - generic container
let request = ContainerRequest(image: "postgres:16")
    .withEnvironment([
        "POSTGRES_USER": "test",
        "POSTGRES_PASSWORD": "test",
        "POSTGRES_DB": "testdb"
    ])
    .withExposedPort(5432)
    .waitingFor(.tcpPort(5432))

try await withContainer(request) { container in
    let port = try await container.hostPort(5432)
    let host = container.host()
    // Manually construct connection string
    let connStr = "postgresql://test:test@\(host):\(port)/testdb"
    // ... use connection string
}
```

### Limitations of Current Approach

1. **No Type Safety**: No compile-time guarantee that required environment variables are set
2. **Manual Configuration**: Users must know PostgreSQL-specific environment variables
3. **No Connection String Helper**: Users must manually construct connection strings
4. **Inadequate Wait Strategy**: TCP port check doesn't guarantee PostgreSQL is ready
5. **No Init Script Support**: No built-in way to run initialization scripts
6. **Boilerplate Heavy**: Repeated configuration code across tests

### Current Architecture

The library uses a builder pattern with immutable value types:

**Files**:
- `/Sources/TestContainers/ContainerRequest.swift` - Generic container configuration
- `/Sources/TestContainers/Container.swift` - Running container handle (actor)
- `/Sources/TestContainers/WithContainer.swift` - Scoped lifecycle helper
- `/Sources/TestContainers/DockerClient.swift` - Docker CLI interactions

**Patterns**:
- Builder methods returning `Self` for fluent chaining
- `Sendable` and `Hashable` conformance for concurrency
- `async throws` for all container operations
- Actor isolation for container state

## Requirements

### Core Functionality

1. **Default Configuration**
   - Default image: `postgres:16-alpine` (latest stable, minimal size)
   - Default username: `postgres`
   - Default password: `postgres`
   - Default database: `postgres`
   - Default port: 5432

2. **Customization Options**
   - Custom PostgreSQL image and tag
   - Custom database name
   - Custom username and password
   - Custom PostgreSQL configuration parameters
   - Environment variable overrides
   - Port mapping (explicit host port if needed)

3. **Initialization Support**
   - Init scripts (SQL, shell scripts) run on first startup
   - Support for multiple init scripts (executed in order)
   - Scripts placed in `/docker-entrypoint-initdb.d/`
   - Both local file paths and inline SQL support

4. **Connection String Helper**
   - Primary method: `connectionString(sslMode:options:)` returning full PostgreSQL connection string
   - Support for additional connection parameters (sslmode, application_name, etc.)
   - Format: `postgresql://user:password@host:port/database?params`
   - URL encoding for special characters in credentials

5. **Wait Strategies**
   - Default: Combined wait strategy
     - Wait for log message: "database system is ready to accept connections" (occurs twice due to PostgreSQL restart)
     - Wait for port 5432 to be accessible
     - Execute `pg_isready` command to verify database accepts connections
   - Configurable timeout (default: 60 seconds)
   - Fallback to TCP wait if exec not available yet

6. **Container Operations**
   - All standard container operations (logs, terminate, etc.)
   - Inherit from base `Container` functionality
   - Database-specific helpers (connection info, JDBC string if needed)

### Non-Functional Requirements

1. **Usability**
   - Reduce boilerplate by 80% compared to generic container
   - Clear, discoverable API following Swift conventions
   - Excellent error messages for common issues
   - Default configuration works for 90% of use cases

2. **Compatibility**
   - Support PostgreSQL 12, 13, 14, 15, 16, 17
   - Work with official `postgres` images (both full and alpine)
   - Cross-platform (macOS, Linux)
   - Compatible with Swift Concurrency

3. **Performance**
   - Fast startup with alpine images
   - Efficient wait strategy (not too aggressive polling)
   - Minimal overhead vs generic container

4. **Maintainability**
   - Follow existing code patterns and architecture
   - Reuse existing infrastructure (DockerClient, Waiter, etc.)
   - Well-documented code
   - Clear separation of concerns

## API Design

### Proposed Swift API

```swift
// New PostgresContainer class (or struct depending on architecture)
public final class PostgresContainer: Sendable {
    // Container handle for low-level operations
    private let container: Container

    // Configuration
    private let config: PostgresConfig

    // Factory method - primary API
    public static func run(
        _ config: PostgresConfig = PostgresConfig(),
        docker: DockerClient = DockerClient()
    ) async throws -> PostgresContainer

    // Connection information
    public func connectionString(
        sslMode: String = "disable",
        options: [String: String] = [:]
    ) async throws -> String

    public func host() -> String
    public func port() async throws -> Int
    public func database() -> String
    public func username() -> String
    public func password() -> String

    // Container operations
    public func logs() async throws -> String
    public func terminate() async throws

    // Low-level access if needed
    public func container() -> Container
}

// Configuration with builder pattern
public struct PostgresConfig: Sendable, Hashable {
    public var image: String
    public var database: String
    public var username: String
    public var password: String
    public var initScripts: [InitScript]
    public var configFile: String?
    public var environment: [String: String]
    public var timeout: Duration

    public init(
        image: String = "postgres:16-alpine",
        database: String = "postgres",
        username: String = "postgres",
        password: String = "postgres"
    ) {
        self.image = image
        self.database = database
        self.username = username
        self.password = password
        self.initScripts = []
        self.configFile = nil
        self.environment = [:]
        self.timeout = .seconds(60)
    }

    // Builder methods
    public func withImage(_ image: String) -> Self
    public func withDatabase(_ database: String) -> Self
    public func withUsername(_ username: String) -> Self
    public func withPassword(_ password: String) -> Self
    public func withInitScript(_ script: InitScript) -> Self
    public func withInitScripts(_ scripts: [InitScript]) -> Self
    public func withConfigFile(_ path: String) -> Self
    public func withEnvironment(_ env: [String: String]) -> Self
    public func withTimeout(_ timeout: Duration) -> Self
}

// Init script support
public enum InitScript: Sendable, Hashable {
    case file(String)           // Path to local SQL or shell script
    case sql(String)            // Inline SQL content

    var filename: String { get }
    var content: String { get }
}

// Convenience helper for scoped lifecycle
public func withPostgresContainer<T>(
    _ config: PostgresConfig = PostgresConfig(),
    docker: DockerClient = DockerClient(),
    operation: @Sendable (PostgresContainer) async throws -> T
) async throws -> T
```

### Usage Examples

```swift
import Testing
import TestContainers

// Example 1: Simplest usage - all defaults
@Test func simplePostgres() async throws {
    try await withPostgresContainer { postgres in
        let connStr = try await postgres.connectionString()
        // connStr = "postgresql://postgres:postgres@127.0.0.1:xxxxx/postgres?sslmode=disable"

        // Use connection string with PostgresNIO, PostgresKit, etc.
        #expect(connStr.contains("postgresql://"))
    }
}

// Example 2: Custom database and credentials
@Test func customDatabase() async throws {
    let config = PostgresConfig()
        .withDatabase("myapp")
        .withUsername("appuser")
        .withPassword("secret123")

    try await withPostgresContainer(config) { postgres in
        let connStr = try await postgres.connectionString()
        #expect(connStr.contains("myapp"))
    }
}

// Example 3: With initialization scripts
@Test func withInitScripts() async throws {
    let config = PostgresConfig()
        .withDatabase("testdb")
        .withInitScripts([
            .sql("""
                CREATE TABLE users (
                    id SERIAL PRIMARY KEY,
                    name VARCHAR(100) NOT NULL
                );
                INSERT INTO users (name) VALUES ('Alice'), ('Bob');
                """),
            .file("testdata/seed.sql")
        ])

    try await withPostgresContainer(config) { postgres in
        let connStr = try await postgres.connectionString()
        // Database now has users table with seed data
    }
}

// Example 4: Different PostgreSQL version
@Test func postgresVersion15() async throws {
    let config = PostgresConfig(image: "postgres:15-alpine")
        .withDatabase("testdb")

    try await withPostgresContainer(config) { postgres in
        let connStr = try await postgres.connectionString()
        #expect(!connStr.isEmpty)
    }
}

// Example 5: With custom connection parameters
@Test func customConnectionParams() async throws {
    try await withPostgresContainer { postgres in
        let connStr = try await postgres.connectionString(
            sslMode: "require",
            options: [
                "application_name": "myapp",
                "connect_timeout": "10"
            ]
        )
        #expect(connStr.contains("sslmode=require"))
        #expect(connStr.contains("application_name=myapp"))
    }
}

// Example 6: Manual lifecycle (not scoped)
@Test func manualLifecycle() async throws {
    let postgres = try await PostgresContainer.run()
    defer { Task { try? await postgres.terminate() } }

    let host = postgres.host()
    let port = try await postgres.port()
    let database = postgres.database()

    #expect(host == "127.0.0.1")
    #expect(port > 0)
    #expect(database == "postgres")
}

// Example 7: Access to underlying container
@Test func lowLevelAccess() async throws {
    try await withPostgresContainer { postgres in
        let container = postgres.container()
        let logs = try await container.logs()
        #expect(logs.contains("database system is ready"))
    }
}
```

### Alternative: Protocol-Based Design

For future extensibility with other database modules:

```swift
// Shared protocol for database containers
public protocol DatabaseContainer: Sendable {
    func connectionString(options: [String: String]) async throws -> String
    func host() -> String
    func port() async throws -> Int
    func database() -> String
    func terminate() async throws
}

// PostgresContainer conforms to DatabaseContainer
extension PostgresContainer: DatabaseContainer {
    // Implementation...
}
```

## Implementation Steps

### 1. Create PostgresConfig Module

**File**: `/Sources/TestContainers/PostgresConfig.swift`

- Define `PostgresConfig` struct with all configuration options
- Implement builder pattern methods (withDatabase, withUsername, etc.)
- Add `Sendable` and `Hashable` conformance
- Validate configuration (e.g., non-empty database name)
- Define `InitScript` enum with file and inline SQL support
- Add comprehensive documentation

**Key considerations**:
- Default values should match PostgreSQL official image defaults
- Validation should fail fast with clear error messages
- Builder pattern should be consistent with `ContainerRequest`

### 2. Create PostgresContainer Class

**File**: `/Sources/TestContainers/PostgresContainer.swift`

- Define `PostgresContainer` class (or struct if stateless enough)
- Implement `run()` factory method that:
  - Builds `ContainerRequest` from `PostgresConfig`
  - Sets required environment variables (POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB)
  - Handles init scripts (copy to container or mount)
  - Configures wait strategy (multi-stage)
  - Calls `withContainer` internally
  - Returns `PostgresContainer` handle
- Implement `connectionString()` helper:
  - Get host port mapping
  - Build properly formatted PostgreSQL connection string
  - URL encode credentials
  - Add optional parameters
- Implement convenience accessors (host, port, database, username, password)
- Implement `terminate()` delegation to underlying container

**Key considerations**:
- Decide if class or struct (actor if mutable state needed)
- Handle init scripts via volume mounts or docker cp (volume mounts preferred)
- Connection string must be URL-safe and properly formatted
- Consider password exposure in logs (mask in debug output)

### 3. Implement Advanced Wait Strategy

**Approach 1**: Extend existing wait strategies

**File**: `/Sources/TestContainers/ContainerRequest.swift`

- Add `.postgresReady` wait strategy that combines:
  - Log wait for "database system is ready to accept connections" (occurrence: 2)
  - TCP port wait for 5432
  - Exec wait for `pg_isready -U <user>` (if exec feature available)

**Approach 2**: Implement custom wait logic in PostgresContainer

- Override or supplement default wait behavior
- Execute multi-stage wait internally
- Provide better error messages for PostgreSQL-specific failures

**Recommended**: Start with Approach 2 (simpler, isolated), migrate to Approach 1 later

### 4. Handle Init Scripts

**Options**:

**Option A**: Volume mounts (preferred, requires volume mount feature)
- Mount local script directory to `/docker-entrypoint-initdb.d/`
- PostgreSQL automatically executes scripts in alphabetical order
- Pro: Clean, uses PostgreSQL's built-in mechanism
- Con: Requires volume mount support (Tier 2 feature)

**Option B**: Docker cp (available now with exec feature)
- Copy scripts into running container before startup
- Con: Requires container to be created but not started (complicates lifecycle)

**Option C**: Inline via environment variable
- For SQL-only scripts, inject via POSTGRES_INIT_SCRIPT env var
- Con: Limited, not standard PostgreSQL approach

**Recommended**: Implement Option C for MVP (inline SQL only), add Option A when volume mounts available

### 5. Add Scoped Lifecycle Helper

**File**: `/Sources/TestContainers/PostgresContainer.swift`

- Implement `withPostgresContainer` function similar to `withContainer`
- Ensures cleanup on success, failure, and cancellation
- Follows same pattern as existing scoped helpers

```swift
public func withPostgresContainer<T>(
    _ config: PostgresConfig = PostgresConfig(),
    docker: DockerClient = DockerClient(),
    operation: @Sendable (PostgresContainer) async throws -> T
) async throws -> T {
    let postgres = try await PostgresContainer.run(config, docker: docker)

    return try await withTaskCancellationHandler {
        do {
            let result = try await operation(postgres)
            try await postgres.terminate()
            return result
        } catch {
            try? await postgres.terminate()
            throw error
        }
    } onCancel: {
        Task { try? await postgres.terminate() }
    }
}
```

### 6. Add Unit Tests

**File**: `/Tests/TestContainersTests/PostgresConfigTests.swift`

- Test `PostgresConfig` builder pattern
- Test default values
- Test all builder methods
- Test `Hashable` conformance
- Test configuration validation
- Test init script handling (file and inline)

**Example tests**:
```swift
@Test func defaultConfig() {
    let config = PostgresConfig()
    #expect(config.image == "postgres:16-alpine")
    #expect(config.database == "postgres")
    #expect(config.username == "postgres")
    #expect(config.password == "postgres")
}

@Test func customConfig() {
    let config = PostgresConfig()
        .withDatabase("mydb")
        .withUsername("user")
        .withPassword("pass")

    #expect(config.database == "mydb")
    #expect(config.username == "user")
    #expect(config.password == "pass")
}

@Test func initScripts() {
    let config = PostgresConfig()
        .withInitScript(.sql("CREATE TABLE test (id INT);"))
        .withInitScript(.file("path/to/init.sql"))

    #expect(config.initScripts.count == 2)
}
```

### 7. Add Integration Tests

**File**: `/Tests/TestContainersTests/PostgresContainerIntegrationTests.swift`

- Test basic container startup with defaults
- Test custom configuration (database, user, password)
- Test connection string generation
- Test with different PostgreSQL versions
- Test with init scripts (if implemented)
- Test wait strategy (verify database is actually ready)
- Test connection with actual PostgreSQL client library (if available)
- Test failure scenarios (invalid image, timeout)

**Example tests**:
```swift
@Test func basicPostgresContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withPostgresContainer { postgres in
        let connStr = try await postgres.connectionString()

        #expect(connStr.contains("postgresql://"))
        #expect(connStr.contains("postgres"))
        #expect(connStr.contains(postgres.host()))

        let port = try await postgres.port()
        #expect(port > 0)
    }
}

@Test func customDatabaseName() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = PostgresConfig()
        .withDatabase("testdb")
        .withUsername("testuser")
        .withPassword("testpass")

    try await withPostgresContainer(config) { postgres in
        let connStr = try await postgres.connectionString()

        #expect(connStr.contains("testdb"))
        #expect(connStr.contains("testuser"))
        #expect(connStr.contains("testpass"))
    }
}

@Test func connectionStringWithOptions() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withPostgresContainer { postgres in
        let connStr = try await postgres.connectionString(
            sslMode: "require",
            options: ["application_name": "test"]
        )

        #expect(connStr.contains("sslmode=require"))
        #expect(connStr.contains("application_name=test"))
    }
}

@Test func differentPostgresVersions() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    for version in ["12-alpine", "13-alpine", "14-alpine", "15-alpine", "16-alpine"] {
        let config = PostgresConfig(image: "postgres:\(version)")

        try await withPostgresContainer(config) { postgres in
            let connStr = try await postgres.connectionString()
            #expect(!connStr.isEmpty)
        }
    }
}
```

### 8. Update Package Structure

**File**: `/Sources/TestContainers/TestContainers.swift` (if exists, or create)

- Export public API from PostgresContainer module
- Ensure all types are accessible

### 9. Documentation

**File**: `README.md`

- Add PostgresContainer example to Quick Start or Examples section
- Show basic usage
- Show advanced usage with init scripts
- Link to API documentation

**Inline documentation**:
- Add doc comments to all public APIs
- Include usage examples in doc comments
- Document common pitfalls
- Add code snippets

**Example README section**:
```markdown
### PostgreSQL Container

The library includes a specialized PostgreSQL container with sensible defaults and convenience methods:

swift
import Testing
import TestContainers

@Test func postgresExample() async throws {
    try await withPostgresContainer { postgres in
        let connStr = try await postgres.connectionString()
        // Use with your favorite PostgreSQL client library
        // connStr = "postgresql://postgres:postgres@127.0.0.1:xxxxx/postgres?sslmode=disable"
    }
}


Customize database name, credentials, and more:

swift
let config = PostgresConfig()
    .withDatabase("myapp")
    .withUsername("appuser")
    .withPassword("secret")
    .withInitScript(.sql("CREATE TABLE users (id SERIAL, name TEXT);"))

try await withPostgresContainer(config) { postgres in
    let connStr = try await postgres.connectionString()
    // Database is ready with users table
}

```

## Testing Plan

### Unit Tests

1. **PostgresConfig Tests**
   - Default configuration values
   - Builder pattern methods (all `with*` methods)
   - Immutability (builder returns new instance)
   - Hashable conformance
   - InitScript enum (file and sql cases)
   - Edge cases (empty strings, special characters)

2. **PostgresContainer Tests** (with mocks if possible)
   - Configuration to ContainerRequest mapping
   - Environment variable setup
   - Connection string construction
   - URL encoding of special characters in credentials
   - Optional parameters in connection string
   - Port mapping

### Integration Tests

1. **Basic Functionality**
   - Start container with defaults
   - Verify container starts successfully
   - Verify connection string format
   - Verify database is accessible
   - Verify cleanup on success

2. **Custom Configuration**
   - Custom database name
   - Custom username and password
   - Custom image versions (12, 13, 14, 15, 16, 17)
   - Custom timeout settings

3. **Connection String**
   - Basic connection string
   - Connection string with sslmode
   - Connection string with multiple options
   - Special characters in credentials (URL encoding)
   - Verify format matches PostgreSQL expectations

4. **Init Scripts** (if implemented)
   - Single SQL script
   - Multiple SQL scripts (execution order)
   - File-based scripts
   - Verify scripts executed successfully
   - Verify data created by scripts

5. **Wait Strategy**
   - Verify container waits for PostgreSQL readiness
   - Verify timeout works correctly
   - Verify failure on non-starting container
   - Performance test (startup time)

6. **Lifecycle Management**
   - Scoped lifecycle (withPostgresContainer)
   - Manual lifecycle (run + terminate)
   - Cleanup on error
   - Cleanup on cancellation
   - Multiple containers in parallel

7. **Real Database Operations** (if PostgreSQL client library available)
   - Connect using connection string
   - Execute simple query
   - Create table
   - Insert and query data
   - Verify init scripts work

8. **Error Scenarios**
   - Invalid image name
   - Container fails to start
   - Timeout waiting for readiness
   - Verify error messages are helpful

### Manual Testing Checklist

- [ ] Test with PostgresNIO (if available)
- [ ] Test with PostgresKit (if available)
- [ ] Test with raw psql command-line client
- [ ] Test on macOS
- [ ] Test on Linux (if CI available)
- [ ] Test with slow network (artificial delay)
- [ ] Test with multiple containers simultaneously
- [ ] Verify no resource leaks (containers are cleaned up)
- [ ] Performance: measure startup time
- [ ] Verify logs don't expose passwords

## Acceptance Criteria

### Must Have

- [x] `PostgresContainer` struct with builder pattern (combined config and request into single struct)
- [x] Default configuration (postgres:16-alpine, postgres/postgres/postgres)
- [x] Builder methods: withDatabase, withUsername, withPassword, withPort, withHost
- [x] `withPostgresContainer()` scoped lifecycle helper (factory pattern)
- [x] `connectionString()` method returns properly formatted string
- [x] Connection string includes: scheme, user, password, host, port, database
- [x] Connection string supports optional parameters (sslmode, etc.)
- [x] Special characters in credentials are URL-encoded
- [x] `host()`, `port()`, `database()`, `username()`, `password()` accessors
- [x] Automatic cleanup via withPostgresContainer scoped helper
- [x] `withPostgresContainer()` scoped helper function
- [x] Wait strategy: pg_isready exec check (more reliable than log wait)
- [x] Unit tests with >80% code coverage
- [x] Integration tests with real PostgreSQL container
- [x] Tests for multiple PostgreSQL versions (15, 16)
- [x] Documentation in code (doc comments on all public APIs)
- [ ] README updated with examples
- [x] All tests passing (32 tests)
- [x] No regressions in existing functionality

### Should Have

- [ ] Init script support (inline SQL at minimum)
- [ ] `InitScript` enum with `.sql()` case
- [ ] Builder method: withInitScript, withInitScripts
- [x] pg_isready exec wait (default wait strategy)
- [x] Custom environment variable support (withEnvironment)
- [ ] Configuration validation with helpful errors
- [x] Performance optimization (alpine image default)
- [ ] Password masking in debug output/logs
- [ ] Error messages include context (container ID, image, config)

### Nice to Have

- [ ] Init script support for file-based scripts (.sql files)
- [ ] Custom PostgreSQL configuration file support (postgres.conf)
- [ ] Support for PostgreSQL extensions
- [ ] JDBC-style connection string method (for compatibility)
- [ ] Migration from generic container helper
- [ ] Performance metrics (startup time measurement)
- [ ] Example integration with PostgresNIO/PostgresKit
- [ ] Migration guide from generic container
- [ ] Troubleshooting guide

### Definition of Done

- All "Must Have" criteria completed
- All "Should Have" criteria completed (or explicitly deferred with justification)
- All tests passing on CI (macOS minimum, Linux if available)
- Code review completed
- Documentation reviewed and accurate
- Manually tested with at least 2 PostgreSQL client libraries
- No password exposure in logs verified
- Startup performance acceptable (<5 seconds for alpine image)
- API is consistent with existing library patterns
- Follows Swift API design guidelines
- All public APIs have comprehensive doc comments
- README examples are tested and working
- Feature integrated into main branch
- FEATURES.md updated to mark PostgresContainer as implemented

## References

### Related Files

- `/Sources/TestContainers/ContainerRequest.swift` - Generic container configuration
- `/Sources/TestContainers/Container.swift` - Container actor
- `/Sources/TestContainers/WithContainer.swift` - Scoped lifecycle helper
- `/Sources/TestContainers/DockerClient.swift` - Docker operations
- `/Sources/TestContainers/Waiter.swift` - Polling mechanism
- `/Sources/TestContainers/TestContainersError.swift` - Error types

### Similar Implementations

- **Testcontainers Go**: `postgres.Run()` with `WithDatabase()`, `WithUsername()`, `WithPassword()`, `WithInitScripts()`, `ConnectionString()`
- **Testcontainers Java**: `PostgreSQLContainer` with similar builder pattern
- **Testcontainers Node**: `PostgreSqlContainer` with connection URI helper

### PostgreSQL Documentation

- Official Docker image: https://hub.docker.com/_/postgres
- PostgreSQL connection strings: https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNSTRING
- Initialization scripts: Docker entrypoint runs scripts in `/docker-entrypoint-initdb.d/`
- Environment variables: POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD

### Swift PostgreSQL Libraries

- PostgresNIO: https://github.com/vapor/postgres-nio
- PostgresKit: https://github.com/vapor/postgres-kit
- PostgresClientKit: https://github.com/codewinsdotcom/PostgresClientKit

## Future Enhancements

After initial implementation, consider:

1. **Advanced Init Scripts**
   - Volume mount support for script directories
   - Script ordering control
   - Shell script support (.sh files)
   - Compressed script support (.sql.gz)

2. **Connection Pooling**
   - Helper for connection pool configuration
   - Integration with pooling libraries

3. **Extensions**
   - Pre-configured containers with common extensions (PostGIS, pg_trgm, etc.)
   - Extension installation helpers

4. **Replication**
   - Primary/replica setup helper
   - Multi-container orchestration

5. **Backup/Restore**
   - Helpers for pg_dump/pg_restore
   - Snapshot support for test data

6. **Metrics**
   - Query performance tracking
   - Container resource usage
   - Startup time optimization

## Migration Path

For users currently using generic containers:

```swift
// Old way (generic container)
let request = ContainerRequest(image: "postgres:16")
    .withEnvironment(["POSTGRES_DB": "testdb", "POSTGRES_USER": "user", "POSTGRES_PASSWORD": "pass"])
    .withExposedPort(5432)
    .waitingFor(.tcpPort(5432))

try await withContainer(request) { container in
    let port = try await container.hostPort(5432)
    let connStr = "postgresql://user:pass@127.0.0.1:\(port)/testdb"
    // ...
}

// New way (PostgresContainer)
let config = PostgresConfig()
    .withDatabase("testdb")
    .withUsername("user")
    .withPassword("pass")

try await withPostgresContainer(config) { postgres in
    let connStr = try await postgres.connectionString()
    // ...
}
```

Benefits:
- 50% less code
- Type-safe configuration
- Automatic connection string generation
- Better wait strategy (pg_isready)
- Support for init scripts
