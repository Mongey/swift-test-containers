# Feature 048: RedisContainer Module

## Summary

Implement a pre-configured `RedisContainer` module for swift-test-containers that provides a typed Swift API for running Redis containers with sensible defaults, connection string helpers, password authentication, TLS support, and appropriate wait strategies. This module simplifies Redis testing by eliminating boilerplate configuration while maintaining the flexibility to customize advanced settings.

## Current State

### Generic Container API

Currently, users must manually configure Redis containers using the generic `ContainerRequest` API (`/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`):

```swift
import Testing
import TestContainers

@Test func redisExample() async throws {
    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        let endpoint = try await container.endpoint(for: 6379)
        // Manual connection string construction: "redis://localhost:\(port)"
    }
}
```

### Limitations of Current Approach

1. **Boilerplate Configuration**: Users must remember Redis defaults (port 6379, image names, wait strategies)
2. **No Connection String Helper**: Manual construction of connection URLs
3. **No Password Support**: No typed API for Redis authentication
4. **No TLS Configuration**: No built-in support for secure Redis connections (rediss://)
5. **Inconsistent Wait Strategy**: Users may choose suboptimal wait strategies
6. **No Configuration File Support**: No helper for custom redis.conf files
7. **No Typed API**: Generic container doesn't expose Redis-specific operations

### Existing Architecture

The library uses a fluent builder pattern with struct-based configuration:

- `ContainerRequest` - Immutable struct with builder methods (`withExposedPort`, `withEnvironment`, etc.)
- `Container` - Actor providing runtime operations (`hostPort`, `endpoint`, `logs`, `terminate`)
- `WaitStrategy` - Enum with cases for different readiness checks (`.none`, `.tcpPort`, `.logContains`)
- `withContainer(_:operation:)` - RAII-style lifecycle management

## Requirements

### Core Functionality

1. **Default Configuration**
   - Default image: `redis:7` (latest stable major version)
   - Default port: 6379
   - Default wait strategy: Log-based wait for "Ready to accept connections"
   - Sensible defaults for testing (no persistence unless requested)

2. **Connection String Helper**
   - Method to get Redis connection URL: `redis://host:port`
   - Support for password in URL: `redis://:password@host:port`
   - Support for TLS URLs: `rediss://host:port` or `rediss://:password@host:port`
   - Support for database selection: `redis://host:port/db`

3. **Password Authentication**
   - Optional password configuration via `withPassword(_:)` builder method
   - Automatically adds `--requirepass` command argument
   - Includes password in connection string when configured

4. **TLS Support**
   - Optional TLS enablement via `withTLS()` builder method
   - Change default port to 6380 when TLS enabled
   - Use `rediss://` scheme in connection URLs
   - Support for `allowInsecureTLS` option (for self-signed certs in testing)
   - Auto-generation or provision of certificates (future enhancement)

5. **Configuration File Support**
   - Optional custom redis.conf via `withConfigFile(_:)` builder method
   - Copy file into container at startup
   - Override command to use custom config: `redis-server /etc/redis/redis.conf`

6. **Snapshotting Configuration**
   - Optional persistence configuration via `withSnapshotting(seconds:changes:)`
   - Maps to Redis `save` directive: `save <seconds> <changes>`
   - Default: No snapshotting (empty RDB for testing)

7. **Log Level Configuration**
   - Optional log level via `withLogLevel(_:)` builder method
   - Support levels: `.debug`, `.verbose`, `.notice`, `.warning`
   - Maps to Redis `loglevel` config directive

8. **Database Selection**
   - Optional database number via `withDatabase(_:)` builder method
   - Included in connection string: `/db`

9. **Wait Strategy**
   - Default: `.logContains("Ready to accept connections")`
   - Allow override via existing `.waitingFor(_:)` pattern
   - Consider composite wait (TCP + log) when available

### Non-Functional Requirements

1. **API Consistency**
   - Follow existing builder pattern conventions
   - Maintain immutability with copy-on-write semantics
   - Use `Sendable` and `Hashable` conformance
   - Use Swift Concurrency (async/await)

2. **Testability**
   - Unit tests for configuration builder
   - Integration tests with real Redis containers
   - Test authentication scenarios
   - Test TLS connections (if feasible)

3. **Documentation**
   - Inline documentation for all public APIs
   - README examples showing common patterns
   - Migration guide from generic ContainerRequest

4. **Performance**
   - Minimal overhead over generic container
   - Fast startup with optimized wait strategy
   - Efficient connection string generation

## API Design

### Proposed Swift API

```swift
// File: /Sources/TestContainers/Modules/RedisContainer.swift

/// Pre-configured Redis container with typed API and sensible defaults
public struct RedisContainer: Sendable, Hashable {
    /// Default Redis image (redis:7)
    public static let defaultImage = "redis:7"

    /// Default Redis port (6379 for non-TLS, 6380 for TLS)
    public static let defaultPort = 6379
    public static let defaultTLSPort = 6380

    // Configuration
    public var image: String
    public var port: Int
    public var password: String?
    public var database: Int
    public var logLevel: RedisLogLevel?
    public var snapshotting: RedisSnapshotting?
    public var configFile: String?
    public var tlsEnabled: Bool
    public var allowInsecureTLS: Bool
    public var waitStrategy: WaitStrategy
    public var host: String

    /// Create a new Redis container configuration with default settings
    public init(image: String = RedisContainer.defaultImage) {
        self.image = image
        self.port = RedisContainer.defaultPort
        self.password = nil
        self.database = 0
        self.logLevel = nil
        self.snapshotting = nil
        self.configFile = nil
        self.tlsEnabled = false
        self.allowInsecureTLS = false
        self.waitStrategy = .logContains("Ready to accept connections", timeout: .seconds(60))
        self.host = "127.0.0.1"
    }

    // Builder methods
    public func withImage(_ image: String) -> Self
    public func withPort(_ port: Int) -> Self
    public func withPassword(_ password: String) -> Self
    public func withDatabase(_ database: Int) -> Self
    public func withLogLevel(_ level: RedisLogLevel) -> Self
    public func withSnapshotting(seconds: Int, changes: Int) -> Self
    public func withConfigFile(_ path: String) -> Self
    public func withTLS(allowInsecure: Bool = false) -> Self
    public func waitingFor(_ strategy: WaitStrategy) -> Self
    public func withHost(_ host: String) -> Self

    /// Convert Redis container configuration to generic ContainerRequest
    public func asContainerRequest() -> ContainerRequest

    /// Get Redis connection string (called after container starts)
    public func connectionString(host: String, port: Int) -> String
}

/// Redis log levels
public enum RedisLogLevel: String, Sendable, Hashable {
    case debug = "debug"
    case verbose = "verbose"
    case notice = "notice"
    case warning = "warning"
}

/// Redis persistence configuration
public struct RedisSnapshotting: Sendable, Hashable {
    public let seconds: Int
    public let changes: Int

    public init(seconds: Int, changes: Int) {
        self.seconds = seconds
        self.changes = changes
    }
}

// Extension to Container for Redis-specific helpers
extension Container {
    /// Get Redis connection string for this container
    /// - Parameter config: The RedisContainer configuration used to create this container
    /// - Returns: Connection string in format: redis://[:password@]host:port[/db]
    public func redisConnectionString(for config: RedisContainer) async throws -> String {
        let port = try await hostPort(config.port)
        let host = self.host()
        return config.connectionString(host: host, port: port)
    }
}

// Convenience function for scoped Redis container lifecycle
public func withRedisContainer<T>(
    _ config: RedisContainer = RedisContainer(),
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    try await withContainer(config.asContainerRequest(), docker: docker, operation: operation)
}
```

### Usage Examples

#### Basic Redis Container

```swift
import Testing
import TestContainers

@Test func basicRedis() async throws {
    try await withRedisContainer { container in
        let connectionString = try await container.redisConnectionString(for: RedisContainer())
        // connectionString: "redis://127.0.0.1:55432"

        // Use with your Redis client
        // let client = RedisClient(url: connectionString)
        // ...
    }
}
```

#### Redis with Password Authentication

```swift
@Test func redisWithPassword() async throws {
    let config = RedisContainer()
        .withPassword("my-secret-password")

    try await withRedisContainer(config) { container in
        let connectionString = try await container.redisConnectionString(for: config)
        // connectionString: "redis://:my-secret-password@127.0.0.1:55432"
    }
}
```

#### Redis with Custom Database

```swift
@Test func redisWithDatabase() async throws {
    let config = RedisContainer()
        .withPassword("secret")
        .withDatabase(2)

    try await withRedisContainer(config) { container in
        let connectionString = try await container.redisConnectionString(for: config)
        // connectionString: "redis://:secret@127.0.0.1:55432/2"
    }
}
```

#### Redis with TLS

```swift
@Test func redisWithTLS() async throws {
    let config = RedisContainer()
        .withTLS(allowInsecure: true)
        .withPassword("secure-password")

    try await withRedisContainer(config) { container in
        let connectionString = try await container.redisConnectionString(for: config)
        // connectionString: "rediss://:secure-password@127.0.0.1:55433"
        // Note: Port changes to 6380 by default when TLS is enabled
    }
}
```

#### Redis with Persistence

```swift
@Test func redisWithSnapshotting() async throws {
    let config = RedisContainer()
        .withSnapshotting(seconds: 10, changes: 1)
        .withLogLevel(.verbose)

    try await withRedisContainer(config) { container in
        // Redis will save DB every 10 seconds if at least 1 key changed
        let connectionString = try await container.redisConnectionString(for: config)
    }
}
```

#### Redis with Custom Configuration File

```swift
@Test func redisWithConfigFile() async throws {
    let config = RedisContainer()
        .withConfigFile("/path/to/redis.conf")

    try await withRedisContainer(config) { container in
        let connectionString = try await container.redisConnectionString(for: config)
        // Container starts with: redis-server /etc/redis/redis.conf
    }
}
```

#### Redis with Custom Image and Wait Strategy

```swift
@Test func redisCustomImage() async throws {
    let config = RedisContainer(image: "redis:6-alpine")
        .withPort(7000)
        .waitingFor(.tcpPort(7000, timeout: .seconds(30)))

    try await withRedisContainer(config) { container in
        let connectionString = try await container.redisConnectionString(for: config)
    }
}
```

## Implementation Steps

### 1. Create RedisContainer Module File

**File**: `/Sources/TestContainers/Modules/RedisContainer.swift`

**Tasks**:
- Define `RedisContainer` struct with all configuration properties
- Implement `init(image:)` with sensible defaults
- Implement all builder methods (`withPassword`, `withTLS`, etc.)
- Implement `asContainerRequest()` to convert to generic `ContainerRequest`
- Implement `connectionString(host:port:)` helper
- Define `RedisLogLevel` enum
- Define `RedisSnapshotting` struct
- Add `Sendable` and `Hashable` conformance
- Add comprehensive documentation comments

**Key Logic for `asContainerRequest()`**:
```swift
public func asContainerRequest() -> ContainerRequest {
    var request = ContainerRequest(image: image)
        .withExposedPort(port)
        .waitingFor(waitStrategy)
        .withHost(host)

    // Build command arguments
    var args: [String] = ["redis-server"]

    // Add config file if specified
    if let configFile = configFile {
        args.append(configFile)
        // Note: Config file copying would need copy-to-container support (future feature)
    }

    // Add password if specified
    if let password = password {
        args.append("--requirepass")
        args.append(password)
    }

    // Add log level if specified
    if let logLevel = logLevel {
        args.append("--loglevel")
        args.append(logLevel.rawValue)
    }

    // Add snapshotting if specified
    if let snapshotting = snapshotting {
        args.append("--save")
        args.append("\(snapshotting.seconds) \(snapshotting.changes)")
    } else {
        // Disable persistence for testing (faster startup)
        args.append("--save")
        args.append("")
    }

    // Add TLS configuration if enabled
    if tlsEnabled {
        args.append("--tls-port")
        args.append(String(port))
        args.append("--port")
        args.append("0")
        // TLS cert configuration would be added here (future enhancement)
    }

    if args.count > 1 {
        request = request.withCommand(args)
    }

    return request
}
```

**Key Logic for `connectionString(host:port:)`**:
```swift
public func connectionString(host: String, port: Int) -> String {
    let scheme = tlsEnabled ? "rediss" : "redis"
    var url = "\(scheme)://"

    // Add password if configured
    if let password = password {
        url += ":\(password)@"
    }

    url += "\(host):\(port)"

    // Add database if non-zero
    if database != 0 {
        url += "/\(database)"
    }

    return url
}
```

### 2. Add Container Extension for Redis Helper

**File**: `/Sources/TestContainers/Container.swift`

**Tasks**:
- Add extension to `Container` actor
- Implement `redisConnectionString(for:)` method
- Use existing `hostPort(_:)` and `host()` methods

**Implementation**:
```swift
// Add to Container.swift
extension Container {
    /// Get Redis connection string for this container
    public func redisConnectionString(for config: RedisContainer) async throws -> String {
        let port = try await hostPort(config.port)
        let host = self.host()
        return config.connectionString(host: host, port: port)
    }
}
```

### 3. Add Convenience Function for Scoped Usage

**File**: `/Sources/TestContainers/Modules/RedisContainer.swift` (continued)

**Tasks**:
- Implement `withRedisContainer(_:docker:operation:)` function
- Follow same pattern as `withContainer`
- Delegate to `withContainer` with converted request

**Implementation**:
```swift
public func withRedisContainer<T>(
    _ config: RedisContainer = RedisContainer(),
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    try await withContainer(config.asContainerRequest(), docker: docker, operation: operation)
}
```

### 4. Create Unit Tests

**File**: `/Tests/TestContainersTests/RedisContainerTests.swift`

**Test Cases**:
- Test default configuration values
- Test all builder methods (immutability, value setting)
- Test `asContainerRequest()` conversion with various configs
- Test `connectionString()` generation with various configs
- Test `Hashable` conformance
- Test password in command args
- Test log level in command args
- Test snapshotting in command args
- Test TLS port configuration
- Test custom port and image

**Example Tests**:
```swift
import Testing
@testable import TestContainers

struct RedisContainerTests {
    @Test func defaultConfiguration() {
        let config = RedisContainer()
        #expect(config.image == "redis:7")
        #expect(config.port == 6379)
        #expect(config.password == nil)
        #expect(config.database == 0)
        #expect(config.tlsEnabled == false)
    }

    @Test func builderImmutability() {
        let config1 = RedisContainer()
        let config2 = config1.withPassword("secret")

        #expect(config1.password == nil)
        #expect(config2.password == "secret")
    }

    @Test func connectionStringBasic() {
        let config = RedisContainer()
        let connStr = config.connectionString(host: "localhost", port: 6379)
        #expect(connStr == "redis://localhost:6379")
    }

    @Test func connectionStringWithPassword() {
        let config = RedisContainer()
            .withPassword("my-password")
        let connStr = config.connectionString(host: "localhost", port: 6379)
        #expect(connStr == "redis://:my-password@localhost:6379")
    }

    @Test func connectionStringWithDatabase() {
        let config = RedisContainer()
            .withDatabase(2)
        let connStr = config.connectionString(host: "localhost", port: 6379)
        #expect(connStr == "redis://localhost:6379/2")
    }

    @Test func connectionStringWithTLS() {
        let config = RedisContainer()
            .withTLS()
            .withPassword("secret")
        let connStr = config.connectionString(host: "localhost", port: 6380)
        #expect(connStr == "rediss://:secret@localhost:6380")
    }

    @Test func asContainerRequestBasic() {
        let config = RedisContainer()
        let request = config.asContainerRequest()

        #expect(request.image == "redis:7")
        #expect(request.ports.contains { $0.containerPort == 6379 })
    }

    @Test func asContainerRequestWithPassword() {
        let config = RedisContainer()
            .withPassword("test-password")
        let request = config.asContainerRequest()

        #expect(request.command.contains("--requirepass"))
        #expect(request.command.contains("test-password"))
    }

    @Test func asContainerRequestWithLogLevel() {
        let config = RedisContainer()
            .withLogLevel(.verbose)
        let request = config.asContainerRequest()

        #expect(request.command.contains("--loglevel"))
        #expect(request.command.contains("verbose"))
    }

    @Test func asContainerRequestWithSnapshotting() {
        let config = RedisContainer()
            .withSnapshotting(seconds: 10, changes: 1)
        let request = config.asContainerRequest()

        #expect(request.command.contains("--save"))
        #expect(request.command.contains("10 1"))
    }
}
```

### 5. Create Integration Tests

**File**: `/Tests/TestContainersTests/RedisContainerIntegrationTests.swift`

**Test Cases**:
- Test basic Redis container startup and connection
- Test Redis with password authentication
- Test Redis with different database
- Test Redis with custom image (redis:6-alpine)
- Test connection string format
- Test wait strategy effectiveness
- Test log level configuration
- Test snapshotting configuration

**Example Tests**:
```swift
import Testing
@testable import TestContainers

struct RedisContainerIntegrationTests {
    @Test func basicRedisContainer() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        try await withRedisContainer { container in
            let connectionString = try await container.redisConnectionString(for: RedisContainer())
            #expect(connectionString.starts(with: "redis://127.0.0.1:"))

            let port = try await container.hostPort(6379)
            #expect(port > 0)
        }
    }

    @Test func redisWithPassword() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let config = RedisContainer()
            .withPassword("test-password")

        try await withRedisContainer(config) { container in
            let connectionString = try await container.redisConnectionString(for: config)
            #expect(connectionString.contains(":test-password@"))

            // TODO: When Redis client support is added, test actual authentication
        }
    }

    @Test func redisWithDatabase() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let config = RedisContainer()
            .withDatabase(5)

        try await withRedisContainer(config) { container in
            let connectionString = try await container.redisConnectionString(for: config)
            #expect(connectionString.hasSuffix("/5"))
        }
    }

    @Test func redisCustomImage() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let config = RedisContainer(image: "redis:6-alpine")

        try await withRedisContainer(config) { container in
            let logs = try await container.logs()
            #expect(logs.contains("Ready to accept connections"))
        }
    }

    @Test func redisWithLogLevel() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let config = RedisContainer()
            .withLogLevel(.verbose)

        try await withRedisContainer(config) { container in
            let logs = try await container.logs()
            // Verify verbose logging is enabled
            #expect(!logs.isEmpty)
        }
    }

    @Test func redisWaitStrategyEffective() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let config = RedisContainer()

        // Should not timeout with default wait strategy
        try await withRedisContainer(config) { container in
            let logs = try await container.logs()
            #expect(logs.contains("Ready to accept connections"))
        }
    }
}
```

### 6. Update Documentation

**Files to Update**:
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/README.md`
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md`

**README.md Updates**:
- Add RedisContainer example to Quick Start section
- Add dedicated section for Module System
- Show comparison between generic and module approach

**Example Addition to README.md**:
```markdown
## Using Pre-configured Modules

For common services, swift-test-containers provides pre-configured modules with sensible defaults:

### RedisContainer

```swift
import Testing
import TestContainers

@Test func redisExample() async throws {
    try await withRedisContainer { container in
        let connectionString = try await container.redisConnectionString(for: RedisContainer())
        // Use with your Redis client: redis://127.0.0.1:55432
    }
}

// With password and custom database
@Test func redisWithAuth() async throws {
    let config = RedisContainer()
        .withPassword("my-secret")
        .withDatabase(2)

    try await withRedisContainer(config) { container in
        let connectionString = try await container.redisConnectionString(for: config)
        // redis://:my-secret@127.0.0.1:55432/2
    }
}
```

Available modules:
- `RedisContainer` - Redis with connection string, password auth, TLS support
```

**FEATURES.md Updates**:
- Update Tier 4 section to mark RedisContainer as implemented
- Add to "Implemented" section

### 7. Optional Enhancements (Future)

**Not required for initial implementation, but nice to have**:

1. **Copy Config File Support**: When file copy feature (#008) is implemented
2. **TLS Certificate Generation**: Auto-generate or mount certificates for TLS
3. **Redis Client Integration**: Example integration with popular Swift Redis clients
4. **Health Check Support**: Use Redis PING command when exec support (#007) is available
5. **Cluster Mode Support**: Multi-node Redis cluster configuration
6. **Sentinel Support**: Redis Sentinel for high availability testing
7. **Redis Modules**: Support for Redis modules (RedisJSON, RedisSearch, etc.)

## Testing Plan

### Unit Tests

1. **Configuration Builder Tests**
   - [ ] Default values are correct
   - [ ] Each builder method works correctly
   - [ ] Builder methods are immutable (copy-on-write)
   - [ ] `Hashable` conformance works
   - [ ] `Sendable` conformance (compile-time check)

2. **Connection String Tests**
   - [ ] Basic format: `redis://host:port`
   - [ ] With password: `redis://:password@host:port`
   - [ ] With database: `redis://host:port/db`
   - [ ] With TLS: `rediss://host:port`
   - [ ] Combined: `rediss://:password@host:port/db`
   - [ ] Special characters in password (URL encoding if needed)

3. **ContainerRequest Conversion Tests**
   - [ ] Basic config produces correct ContainerRequest
   - [ ] Password appears in command args
   - [ ] Log level appears in command args
   - [ ] Snapshotting appears in command args
   - [ ] TLS port configuration is correct
   - [ ] Custom port is used
   - [ ] Wait strategy is preserved

### Integration Tests (Require Docker)

1. **Basic Functionality**
   - [ ] Default RedisContainer starts successfully
   - [ ] Connection string is correctly formatted
   - [ ] Container is accessible on reported port
   - [ ] Container logs contain "Ready to accept connections"

2. **Password Authentication**
   - [ ] Container starts with password configured
   - [ ] Connection string includes password
   - [ ] Command args include `--requirepass`

3. **Database Selection**
   - [ ] Connection string includes database number
   - [ ] Non-zero database is correctly formatted

4. **Custom Images**
   - [ ] redis:6-alpine works
   - [ ] redis:7 works
   - [ ] Custom port works

5. **Log Level Configuration**
   - [ ] Container starts with custom log level
   - [ ] Logs reflect configured verbosity

6. **Snapshotting Configuration**
   - [ ] Container starts with snapshotting enabled
   - [ ] Command args include save directive

7. **Wait Strategy**
   - [ ] Default log-based wait works reliably
   - [ ] Custom wait strategy can be applied
   - [ ] Timeout occurs if wait strategy is impossible

8. **Error Scenarios**
   - [ ] Invalid image name produces clear error
   - [ ] Timeout error is descriptive

### Manual Testing Checklist

- [ ] Test with RediStack (Swift Redis client) if available
- [ ] Test with redis-cli Docker container connection
- [ ] Verify performance (startup time < 5 seconds typical)
- [ ] Test on macOS
- [ ] Test on Linux (if CI available)
- [ ] Verify memory usage is reasonable
- [ ] Test concurrent Redis containers (no port conflicts)

## Acceptance Criteria

### Must Have

- [ ] `RedisContainer` struct implemented with all configuration properties
- [ ] Builder pattern methods: `withPassword`, `withDatabase`, `withTLS`, `withLogLevel`, `withSnapshotting`, `withConfigFile`, `withPort`, `withImage`
- [ ] `asContainerRequest()` conversion method
- [ ] `connectionString(host:port:)` helper method
- [ ] `Container.redisConnectionString(for:)` extension method
- [ ] `withRedisContainer(_:docker:operation:)` convenience function
- [ ] `RedisLogLevel` enum with all levels
- [ ] `RedisSnapshotting` struct
- [ ] Default image: `redis:7`
- [ ] Default port: `6379`
- [ ] Default wait strategy: `.logContains("Ready to accept connections")`
- [ ] Password authentication support
- [ ] Database selection support
- [ ] TLS support (basic, without cert generation)
- [ ] Unit tests with >80% coverage
- [ ] Integration tests for core scenarios
- [ ] Documentation in code (doc comments for all public APIs)
- [ ] README updated with examples
- [ ] FEATURES.md updated

### Should Have

- [ ] Log level configuration
- [ ] Snapshotting/persistence configuration
- [ ] Custom port support
- [ ] Custom image support
- [ ] Custom wait strategy override
- [ ] TLS with `allowInsecure` option
- [ ] Connection string with all combinations tested
- [ ] Error handling and validation
- [ ] Examples with different Redis versions

### Nice to Have

- [ ] Config file support (when copy feature available)
- [ ] TLS certificate generation (future enhancement)
- [ ] Integration example with Swift Redis client
- [ ] Performance benchmarks
- [ ] Redis PING health check (when exec available)
- [ ] Support for Redis modules
- [ ] Cluster mode support
- [ ] Sentinel support

### Definition of Done

- All "Must Have" criteria completed
- All "Should Have" criteria completed
- All unit tests passing
- All integration tests passing (with Docker)
- Code review completed
- Documentation reviewed and approved
- No regressions in existing tests
- Follows Swift API design guidelines
- Follows existing code patterns (builder pattern, actor usage, etc.)
- All public APIs have comprehensive doc comments
- README has clear, working examples
- Manually tested with at least one Redis client library
- Feature marked as implemented in FEATURES.md

## References

### Related Files

- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` - Generic container configuration
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift` - Container actor
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift` - Scoped lifecycle management
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift` - Wait strategy implementation
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md` - Feature roadmap

### External References

- [Testcontainers Go - Redis Module](https://golang.testcontainers.org/modules/redis/)
- [Testcontainers Redis Module (Java)](https://testcontainers.com/modules/redis/)
- [Redis Docker Official Image](https://hub.docker.com/_/redis)
- [Redis Configuration Documentation](https://redis.io/docs/management/config/)
- [Redis Connection URL Format](https://www.iana.org/assignments/uri-schemes/prov/redis)

### Similar Implementations in Other Languages

**Testcontainers Go**:
- Module: `github.com/testcontainers/testcontainers-go/modules/redis`
- Features: Snapshotting, log level, config file, TLS, connection string
- API: `redis.Run(ctx, image, opts...)`
- Connection: `container.ConnectionString(ctx)`

**Testcontainers Java**:
- Class: `RedisContainer`
- Features: Command execution, connection string, custom configuration
- API: `new RedisContainer(DockerImageName.parse("redis:7"))`

**Testcontainers Node**:
- Class: `RedisContainer`
- Features: Connection URL, wait strategies
- API: `new RedisContainer().start()`

### Design Decisions

1. **Why struct instead of class?**
   - Immutability by default (value semantics)
   - Thread-safe without locking
   - Follows existing `ContainerRequest` pattern
   - `Sendable` conformance is simpler

2. **Why not subclass Container?**
   - `Container` is an actor (not subclassable in current Swift)
   - Composition over inheritance
   - Module pattern allows conversion to generic container
   - Keeps module code separate from core

3. **Why conversion to ContainerRequest instead of direct Docker API?**
   - Reuses existing infrastructure
   - Single code path for container creation
   - Easy to test (unit test configuration, integration test with Docker)
   - Future-proof if Docker backend changes

4. **Why default to redis:7?**
   - Latest stable major version
   - Long-term support
   - Best feature set for testing
   - Users can easily override if needed

5. **Why log-based wait instead of TCP wait?**
   - More reliable (TCP port opens before Redis is ready)
   - Matches testcontainers-go approach
   - Can be overridden if needed
   - Better error messages on startup failure
