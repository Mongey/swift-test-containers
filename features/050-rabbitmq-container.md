# Feature: RabbitMQContainer Module

## Summary

Implement a pre-configured `RabbitMQContainer` module for swift-test-containers that provides a typed, Swift-idiomatic API for running RabbitMQ containers in tests. This module will encapsulate RabbitMQ-specific configuration (credentials, virtual hosts, management plugin, connection strings) and provide convenient helper methods for obtaining AMQP connection URLs, eliminating the need for manual port mapping and URL construction.

## Current State

### Generic Container API

Today, users must manually configure RabbitMQ containers using the generic `ContainerRequest` API:

```swift
let request = ContainerRequest(image: "rabbitmq:3.12-management-alpine")
    .withExposedPort(5672)  // AMQP port
    .withExposedPort(15672) // Management UI port
    .withEnvironment([
        "RABBITMQ_DEFAULT_USER": "admin",
        "RABBITMQ_DEFAULT_PASS": "password"
    ])
    .waitingFor(.tcpPort(5672))

try await withContainer(request) { container in
    let amqpPort = try await container.hostPort(5672)
    let managementPort = try await container.hostPort(15672)

    // Manual URL construction
    let amqpURL = "amqp://admin:password@\(container.host()):\(amqpPort)/"

    // Use amqpURL for testing...
}
```

**Pain points**:
- Manual environment variable configuration
- Manual port exposure and mapping
- Manual AMQP URL construction with credentials
- No type safety for RabbitMQ-specific configuration
- Easy to forget management plugin image variant
- No helpers for virtual hosts, SSL, or advanced configuration

## Requirements

### Core Functionality

1. **Default Image**
   - Default to `rabbitmq:3.13-management-alpine` (latest stable with management plugin)
   - Allow image override for testing specific versions
   - Prefer `-management` variants for better debugging experience

2. **Credentials Configuration**
   - Default username: `guest`
   - Default password: `guest`
   - Builder methods to customize credentials: `withAdminUsername()`, `withAdminPassword()`
   - Credentials automatically passed to container via environment variables

3. **Virtual Host Support**
   - Default virtual host: `/` (RabbitMQ default)
   - Builder method to specify custom virtual host: `withVirtualHost()`
   - Virtual host included in connection URL

4. **Management Plugin**
   - Management UI enabled by default (via `-management` image)
   - Expose management port (15672)
   - Provide helper for management UI URL: `managementURL()`

5. **Connection String Helpers**
   - `amqpURL()` - returns AMQP connection string (e.g., `amqp://guest:guest@localhost:5672/`)
   - `amqpURL(virtualHost:)` - returns AMQP URL for specific virtual host
   - `managementURL()` - returns HTTP management UI URL (e.g., `http://localhost:15672`)
   - All URLs auto-resolve host and port mappings

6. **Port Configuration**
   - AMQP port: 5672 (always exposed)
   - Management port: 15672 (exposed when using -management image)
   - Optional: AMQPS port 5671 (exposed when SSL enabled)
   - Optional: HTTPS management port 15671 (exposed when SSL enabled)

7. **Wait Strategy**
   - Default: TCP wait on AMQP port 5672
   - Consider: HTTP wait on management API `/api/health/checks/alarms` (requires HTTP wait strategy implementation)
   - Timeout: 60 seconds (reasonable for RabbitMQ startup)

8. **SSL/TLS Support** (Nice to have)
   - `withSSL()` builder method
   - Automatic AMQPS port exposure (5671)
   - `amqpsURL()` helper method
   - SSL certificate configuration via bind mounts

9. **Advanced Configuration** (Future enhancement)
   - Plugin enablement (shovel, federation, etc.)
   - Custom configuration file mounting
   - Memory/resource limits
   - Clustering support (multi-node)

### Non-Functional Requirements

1. **Consistency with Existing Patterns**
   - Follow `ContainerRequest` builder pattern
   - Use `withContainer()` lifecycle management
   - Return `Container` actor for consistency
   - Use `async throws` error handling

2. **Reference Implementation Parity**
   - Match testcontainers-go RabbitMQ module capabilities
   - Adapt Go patterns to idiomatic Swift
   - Maintain similar method naming conventions

3. **Developer Experience**
   - Type-safe configuration
   - Sensible defaults (zero-config for basic usage)
   - Clear error messages
   - Comprehensive documentation with examples

## API Design

### Proposed Swift API

```swift
// Module structure: Sources/TestContainers/Modules/RabbitMQContainer.swift

/// Pre-configured RabbitMQ container with typed API and connection helpers
public struct RabbitMQContainer: Sendable, Hashable {
    // Configuration
    public var image: String
    public var adminUsername: String
    public var adminPassword: String
    public var virtualHost: String
    public var enableSSL: Bool

    // Inherit base container configuration
    private var baseRequest: ContainerRequest

    /// Initialize with default configuration
    public init(image: String = "rabbitmq:3.13-management-alpine") {
        self.image = image
        self.adminUsername = "guest"
        self.adminPassword = "guest"
        self.virtualHost = "/"
        self.enableSSL = false

        // Build base request with RabbitMQ defaults
        self.baseRequest = ContainerRequest(image: image)
            .withExposedPort(5672)  // AMQP
            .withExposedPort(15672) // Management UI
            .withEnvironment([
                "RABBITMQ_DEFAULT_USER": "guest",
                "RABBITMQ_DEFAULT_PASS": "guest"
            ])
            .waitingFor(.tcpPort(5672, timeout: .seconds(60)))
    }

    // MARK: - Builder Methods

    /// Set admin username
    public func withAdminUsername(_ username: String) -> Self {
        var copy = self
        copy.adminUsername = username
        copy.baseRequest = copy.baseRequest.withEnvironment([
            "RABBITMQ_DEFAULT_USER": username
        ])
        return copy
    }

    /// Set admin password
    public func withAdminPassword(_ password: String) -> Self {
        var copy = self
        copy.adminPassword = password
        copy.baseRequest = copy.baseRequest.withEnvironment([
            "RABBITMQ_DEFAULT_PASS": password
        ])
        return copy
    }

    /// Set virtual host
    public func withVirtualHost(_ vhost: String) -> Self {
        var copy = self
        copy.virtualHost = vhost
        return copy
    }

    /// Enable SSL/TLS (exposes AMQPS port 5671)
    public func withSSL() -> Self {
        var copy = self
        copy.enableSSL = true
        copy.baseRequest = copy.baseRequest.withExposedPort(5671)
        return copy
    }

    /// Customize wait strategy
    public func waitingFor(_ strategy: WaitStrategy) -> Self {
        var copy = self
        copy.baseRequest = copy.baseRequest.waitingFor(strategy)
        return copy
    }

    /// Add environment variable
    public func withEnvironment(_ env: [String: String]) -> Self {
        var copy = self
        copy.baseRequest = copy.baseRequest.withEnvironment(env)
        return copy
    }

    /// Add label
    public func withLabel(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.baseRequest = copy.baseRequest.withLabel(key, value)
        return copy
    }

    // MARK: - Container Request

    /// Get the underlying ContainerRequest for starting the container
    public func asContainerRequest() -> ContainerRequest {
        baseRequest
    }
}

// MARK: - Connection Helpers

extension Container {
    /// Get AMQP connection URL for RabbitMQ
    /// - Parameter config: RabbitMQContainer configuration
    /// - Returns: AMQP URL string (e.g., "amqp://guest:guest@localhost:5672/")
    public func amqpURL(config: RabbitMQContainer) async throws -> String {
        let port = try await hostPort(5672)
        let vhost = config.virtualHost == "/" ? "" : config.virtualHost
        return "amqp://\(config.adminUsername):\(config.adminPassword)@\(host()):\(port)/\(vhost)"
    }

    /// Get AMQP connection URL with custom virtual host
    /// - Parameters:
    ///   - config: RabbitMQContainer configuration
    ///   - virtualHost: Virtual host path
    /// - Returns: AMQP URL string
    public func amqpURL(config: RabbitMQContainer, virtualHost: String) async throws -> String {
        let port = try await hostPort(5672)
        let vhost = virtualHost == "/" ? "" : virtualHost
        return "amqp://\(config.adminUsername):\(config.adminPassword)@\(host()):\(port)/\(vhost)"
    }

    /// Get AMQPS (secure) connection URL for RabbitMQ
    /// - Parameter config: RabbitMQContainer configuration
    /// - Returns: AMQPS URL string
    public func amqpsURL(config: RabbitMQContainer) async throws -> String {
        guard config.enableSSL else {
            throw TestContainersError.configurationError("SSL not enabled. Use .withSSL() on RabbitMQContainer")
        }
        let port = try await hostPort(5671)
        let vhost = config.virtualHost == "/" ? "" : config.virtualHost
        return "amqps://\(config.adminUsername):\(config.adminPassword)@\(host()):\(port)/\(vhost)"
    }

    /// Get management UI HTTP URL
    /// - Returns: Management URL string (e.g., "http://localhost:15672")
    public func managementURL() async throws -> String {
        let port = try await hostPort(15672)
        return "http://\(host()):\(port)"
    }
}

// MARK: - Convenience Lifecycle Method

/// Run RabbitMQ container with scoped lifecycle
/// - Parameters:
///   - config: RabbitMQ configuration
///   - docker: Docker client (default: shared client)
///   - operation: Closure to execute with the running container
/// - Returns: Result from operation closure
public func withRabbitMQContainer<T>(
    _ config: RabbitMQContainer = RabbitMQContainer(),
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    try await withContainer(config.asContainerRequest(), docker: docker, operation: operation)
}
```

### Usage Examples

#### Basic Usage (Default Configuration)

```swift
import Testing
import TestContainers

@Test func rabbitmqBasicExample() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Use defaults: guest/guest, port 5672, management on 15672
    try await withRabbitMQContainer() { container in
        let config = RabbitMQContainer()
        let amqpURL = try await container.amqpURL(config: config)

        // amqpURL = "amqp://guest:guest@localhost:xxxxx/"
        #expect(amqpURL.hasPrefix("amqp://guest:guest@"))

        let mgmtURL = try await container.managementURL()
        #expect(mgmtURL.hasPrefix("http://localhost:"))
    }
}
```

#### Custom Credentials

```swift
@Test func rabbitmqCustomCredentials() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = RabbitMQContainer()
        .withAdminUsername("admin")
        .withAdminPassword("secret123")

    try await withRabbitMQContainer(config) { container in
        let amqpURL = try await container.amqpURL(config: config)

        #expect(amqpURL.contains("admin:secret123"))

        // Connect and test...
    }
}
```

#### Virtual Host Configuration

```swift
@Test func rabbitmqVirtualHost() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = RabbitMQContainer()
        .withVirtualHost("/test-vhost")

    try await withRabbitMQContainer(config) { container in
        let amqpURL = try await container.amqpURL(config: config)

        #expect(amqpURL.hasSuffix("/test-vhost"))
    }
}
```

#### Different RabbitMQ Version

```swift
@Test func rabbitmqSpecificVersion() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = RabbitMQContainer(image: "rabbitmq:3.11-management")
        .withAdminUsername("admin")
        .withAdminPassword("password")

    try await withRabbitMQContainer(config) { container in
        let amqpURL = try await container.amqpURL(config: config)
        // Test with RabbitMQ 3.11...
    }
}
```

#### Custom Wait Strategy

```swift
@Test func rabbitmqCustomWait() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = RabbitMQContainer()
        .waitingFor(.logContains("Server startup complete", timeout: .seconds(90)))

    try await withRabbitMQContainer(config) { container in
        let amqpURL = try await container.amqpURL(config: config)
        // Container waited for log message before proceeding
    }
}
```

#### Using Generic withContainer API

```swift
@Test func rabbitmqGenericAPI() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = RabbitMQContainer()
        .withAdminUsername("user")
        .withAdminPassword("pass")

    // Convert to ContainerRequest for generic API
    let request = config.asContainerRequest()

    try await withContainer(request) { container in
        let amqpURL = try await container.amqpURL(config: config)
        // Use amqpURL...
    }
}
```

## Implementation Steps

### 1. Create Module Structure

**File**: `/Sources/TestContainers/Modules/RabbitMQContainer.swift`

- Define `RabbitMQContainer` struct with `Sendable` and `Hashable` conformance
- Implement initializer with sensible defaults
- Add internal `baseRequest` property to wrap `ContainerRequest`
- Ensure struct is immutable (copy-on-write builder pattern)

**Key considerations**:
- Follow existing code style from `ContainerRequest.swift`
- Use value semantics (struct, not class)
- Document all public APIs with doc comments
- Set default image to latest stable RabbitMQ with management plugin

### 2. Implement Builder Methods

**File**: `/Sources/TestContainers/Modules/RabbitMQContainer.swift`

- `withAdminUsername(_:)` - updates username and environment
- `withAdminPassword(_:)` - updates password and environment
- `withVirtualHost(_:)` - stores virtual host for URL construction
- `withSSL()` - enables SSL and exposes port 5671
- `waitingFor(_:)` - delegates to underlying `ContainerRequest`
- `withEnvironment(_:)` - pass-through to base request
- `withLabel(_:_:)` - pass-through to base request
- `asContainerRequest()` - returns configured `ContainerRequest`

**Implementation pattern**:
```swift
public func withAdminUsername(_ username: String) -> Self {
    var copy = self
    copy.adminUsername = username
    copy.baseRequest = copy.baseRequest.withEnvironment([
        "RABBITMQ_DEFAULT_USER": username
    ])
    return copy
}
```

**Key considerations**:
- Each builder method returns `Self` for chaining
- Use copy-on-write semantics (mutate copy, return it)
- Update both RabbitMQContainer state and underlying ContainerRequest
- Preserve existing environment variables when adding new ones

### 3. Implement Connection Helper Extensions

**File**: `/Sources/TestContainers/Modules/RabbitMQContainer.swift` (or separate extension file)

- Add `Container` extension with connection helpers
- Implement `amqpURL(config:)` method
- Implement `amqpURL(config:virtualHost:)` method
- Implement `amqpsURL(config:)` method
- Implement `managementURL()` method

**URL Construction Logic**:
```swift
public func amqpURL(config: RabbitMQContainer) async throws -> String {
    let port = try await hostPort(5672)
    let vhost = config.virtualHost == "/" ? "" : config.virtualHost
    return "amqp://\(config.adminUsername):\(config.adminPassword)@\(host()):\(port)/\(vhost)"
}
```

**Key considerations**:
- Use existing `hostPort(_:)` and `host()` methods from `Container`
- Handle virtual host encoding (root "/" becomes empty string)
- URL-encode credentials if they contain special characters
- Throw descriptive errors for SSL methods when SSL not enabled

### 4. Implement Convenience Lifecycle Function

**File**: `/Sources/TestContainers/Modules/RabbitMQContainer.swift`

- Create `withRabbitMQContainer(_:docker:operation:)` function
- Delegate to existing `withContainer(_:docker:operation:)` function
- Convert `RabbitMQContainer` to `ContainerRequest` via `asContainerRequest()`

**Implementation**:
```swift
public func withRabbitMQContainer<T>(
    _ config: RabbitMQContainer = RabbitMQContainer(),
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    try await withContainer(config.asContainerRequest(), docker: docker, operation: operation)
}
```

**Key considerations**:
- Provide default `RabbitMQContainer()` for zero-config usage
- Maintain consistency with existing `withContainer()` API
- Use `@Sendable` for Swift Concurrency safety

### 5. Add Unit Tests

**File**: `/Tests/TestContainersTests/RabbitMQContainerTests.swift`

Test coverage:

- **Configuration Tests**
  - Default values (guest/guest, image, ports, virtual host)
  - Builder pattern (chaining methods)
  - Immutability (builder returns new instance)
  - `Hashable` conformance
  - `asContainerRequest()` conversion

- **Builder Method Tests**
  - `withAdminUsername()` updates username and environment
  - `withAdminPassword()` updates password and environment
  - `withVirtualHost()` stores virtual host
  - `withSSL()` enables SSL and exposes port 5671
  - Method chaining produces correct cumulative configuration

- **Connection String Tests** (mock or unit)
  - AMQP URL format with default virtual host
  - AMQP URL format with custom virtual host
  - Credentials in URL
  - Management URL format
  - AMQPS URL throws when SSL not enabled

Example test:
```swift
@Test func rabbitmqContainer_defaultConfiguration() {
    let config = RabbitMQContainer()

    #expect(config.image == "rabbitmq:3.13-management-alpine")
    #expect(config.adminUsername == "guest")
    #expect(config.adminPassword == "guest")
    #expect(config.virtualHost == "/")
    #expect(config.enableSSL == false)
}

@Test func rabbitmqContainer_builderPattern() {
    let config = RabbitMQContainer()
        .withAdminUsername("admin")
        .withAdminPassword("secret")
        .withVirtualHost("/prod")

    #expect(config.adminUsername == "admin")
    #expect(config.adminPassword == "secret")
    #expect(config.virtualHost == "/prod")
}

@Test func rabbitmqContainer_asContainerRequest() {
    let config = RabbitMQContainer()
        .withAdminUsername("admin")

    let request = config.asContainerRequest()

    #expect(request.image == "rabbitmq:3.13-management-alpine")
    #expect(request.environment["RABBITMQ_DEFAULT_USER"] == "admin")
    #expect(request.ports.contains { $0.containerPort == 5672 })
    #expect(request.ports.contains { $0.containerPort == 15672 })
}
```

### 6. Add Integration Tests

**File**: `/Tests/TestContainersTests/RabbitMQContainerIntegrationTests.swift`

Integration test scenarios:

- **Basic Startup**
  - Default configuration starts successfully
  - Container responds on AMQP port
  - Management UI is accessible

- **Credentials**
  - Custom credentials work
  - AMQP URL contains correct credentials
  - Can authenticate with provided credentials (if AMQP client available)

- **Virtual Hosts**
  - Default virtual host works
  - Custom virtual host in URL
  - Connection to custom virtual host (requires vhost creation or AMQP client)

- **Management API**
  - Management URL is accessible
  - Management API responds (e.g., GET /api/overview)

- **Different Versions**
  - RabbitMQ 3.11 works
  - RabbitMQ 3.12 works
  - RabbitMQ 3.13 works

- **Wait Strategies**
  - TCP wait strategy succeeds
  - Log wait strategy works (e.g., "Server startup complete")
  - Custom timeout respected

Example integration tests:
```swift
@Test func rabbitmqContainer_basicStartup() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withRabbitMQContainer() { container in
        let config = RabbitMQContainer()
        let amqpURL = try await container.amqpURL(config: config)

        #expect(amqpURL.hasPrefix("amqp://guest:guest@"))
        #expect(amqpURL.hasSuffix("/"))

        // Verify AMQP port is accessible
        let amqpPort = try await container.hostPort(5672)
        #expect(amqpPort > 0)

        // Verify management port is accessible
        let mgmtPort = try await container.hostPort(15672)
        #expect(mgmtPort > 0)
    }
}

@Test func rabbitmqContainer_customCredentials() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = RabbitMQContainer()
        .withAdminUsername("admin")
        .withAdminPassword("password123")

    try await withRabbitMQContainer(config) { container in
        let amqpURL = try await container.amqpURL(config: config)

        #expect(amqpURL.contains("admin:password123"))
    }
}

@Test func rabbitmqContainer_managementUI() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withRabbitMQContainer() { container in
        let mgmtURL = try await container.managementURL()

        #expect(mgmtURL.hasPrefix("http://"))
        #expect(mgmtURL.contains(":"))

        // Optional: Make HTTP request to verify management UI responds
        // let url = URL(string: mgmtURL)!
        // let (_, response) = try await URLSession.shared.data(from: url)
        // #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}

@Test func rabbitmqContainer_virtualHost() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = RabbitMQContainer()
        .withVirtualHost("/test")

    try await withRabbitMQContainer(config) { container in
        let amqpURL = try await container.amqpURL(config: config)

        #expect(amqpURL.hasSuffix("/test"))
    }
}

@Test func rabbitmqContainer_differentVersion() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = RabbitMQContainer(image: "rabbitmq:3.11-management")

    try await withRabbitMQContainer(config) { container in
        let amqpURL = try await container.amqpURL(config: config)
        #expect(!amqpURL.isEmpty)
    }
}
```

### 7. Update Package Structure

**File**: `/Sources/TestContainers/TestContainers.swift` (if exists, or update exports)

- Export `RabbitMQContainer` publicly
- Export `withRabbitMQContainer` function

If no central export file exists, ensure `RabbitMQContainer.swift` is in the target.

### 8. Documentation

- **README.md**: Add RabbitMQ module example in main README
  ```swift
  // RabbitMQ Container
  try await withRabbitMQContainer() { container in
      let config = RabbitMQContainer()
      let amqpURL = try await container.amqpURL(config: config)
      // Use RabbitMQ connection...
  }
  ```

- **FEATURES.md**: Update to mark RabbitMQContainer as implemented in Tier 4

- **Inline Documentation**: Add comprehensive doc comments to all public APIs
  - Struct-level documentation explaining purpose
  - Method-level documentation for all builders
  - Parameter and return value documentation
  - Usage examples in doc comments

- **Module README** (optional): Create `/Sources/TestContainers/Modules/README.md` explaining the modules system

## Testing Plan

### Unit Tests

1. **RabbitMQContainer Configuration**
   - Default values are correct
   - Builder pattern works (method chaining)
   - Immutability (each builder returns new instance)
   - `Hashable` conformance (can be used in sets/dictionaries)
   - `Sendable` conformance (thread-safe)

2. **Builder Methods**
   - `withAdminUsername()` updates username and environment
   - `withAdminPassword()` updates password and environment
   - `withVirtualHost()` updates virtual host
   - `withSSL()` enables SSL and exposes port 5671
   - `withEnvironment()` merges with existing environment
   - `waitingFor()` updates wait strategy
   - Method chaining produces cumulative configuration

3. **ContainerRequest Conversion**
   - `asContainerRequest()` returns valid request
   - Environment variables correctly set
   - Ports correctly exposed
   - Wait strategy correctly configured
   - Image correctly set

4. **Connection String Generation**
   - AMQP URL format is correct (requires mock Container or helper function)
   - Virtual host encoding (/ becomes empty, others preserved)
   - Credentials included in URL
   - Management URL format
   - AMQPS URL only works when SSL enabled

### Integration Tests

1. **Basic Container Lifecycle**
   - Default configuration starts RabbitMQ successfully
   - Container is accessible on AMQP port
   - Management UI is accessible
   - Container stops cleanly

2. **Credentials**
   - Custom username/password work
   - AMQP URL contains custom credentials
   - Can connect with custom credentials (requires AMQP client)

3. **Virtual Hosts**
   - Default virtual host (/) works
   - Custom virtual host in connection URL
   - Multiple virtual hosts can be configured

4. **Management API**
   - Management UI URL is correct
   - Management API is accessible (HTTP GET request)
   - Can authenticate with management API

5. **Wait Strategies**
   - TCP wait on port 5672 succeeds
   - Log wait for startup message works
   - Custom timeout is respected
   - Failed wait throws timeout error

6. **Version Compatibility**
   - RabbitMQ 3.11 works
   - RabbitMQ 3.12 works
   - RabbitMQ 3.13 works
   - Non-management images work (without management UI)

7. **Error Handling**
   - SSL methods throw when SSL not enabled
   - Invalid configuration produces clear errors
   - Network failures handled gracefully

### Manual Testing Checklist

- [ ] Test with real Swift AMQP client library (e.g., swift-nio-amqp if available)
- [ ] Test management UI in browser
- [ ] Test with different RabbitMQ versions (3.11, 3.12, 3.13)
- [ ] Test on macOS
- [ ] Test on Linux (if CI available)
- [ ] Verify connection strings work with real clients
- [ ] Test concurrent container creation
- [ ] Verify cleanup on error/cancellation
- [ ] Check memory usage and resource cleanup

## Acceptance Criteria

### Must Have

- [x] `RabbitMQContainer` struct defined with `Sendable` and `Hashable` conformance
- [x] Default configuration (guest/guest, rabbitmq:3.13-management-alpine)
- [x] Builder methods: `withAdminUsername()`, `withAdminPassword()`, `withVirtualHost()`
- [x] Builder methods: `waitingFor()`
- [x] `toContainerRequest()` conversion method
- [x] `RunningRabbitMQContainer` with `amqpURL()` helper
- [x] `RunningRabbitMQContainer` with `managementURL()` helper
- [x] `withRabbitMQContainer()` convenience function
- [x] AMQP port 5672 exposed
- [x] Management port 15672 exposed
- [x] Default wait strategy (TCP on port 5672)
- [x] Unit tests with >80% coverage
- [x] Integration tests covering basic scenarios
- [x] Documentation in code (doc comments)
- [ ] README updated with RabbitMQ example
- [x] FEATURES.md updated

### Should Have

- [x] `amqpURL(virtualHost:)` for custom virtual host override
- [x] Virtual host correctly encoded in connection URLs
- [x] SSL support via `withSSL()` method
- [x] `amqpsURL()` helper when SSL enabled
- [x] AMQPS port 5671 exposed when SSL enabled
- [x] Clear error when SSL methods called without SSL enabled
- [ ] Integration tests with multiple RabbitMQ versions
- [ ] Integration tests for management API access
- [x] Helpful error messages

### Nice to Have

- [ ] HTTPS management URL support (port 15671 with SSL)
- [ ] Plugin configuration support
- [ ] Custom configuration file mounting
- [ ] Multiple virtual host creation helpers
- [ ] User/permission management helpers
- [ ] Clustering support (multi-node)
- [ ] TLS certificate configuration
- [ ] Example integration with Swift AMQP client library
- [ ] Performance benchmarks

### Definition of Done

- All "Must Have" and "Should Have" criteria completed
- All tests passing (unit and integration)
- Code review completed
- Documentation reviewed and accurate
- No regressions in existing functionality
- Follows project code style and patterns
- All public APIs have comprehensive doc comments
- README includes clear RabbitMQ examples
- Manually tested with at least 2 different RabbitMQ versions
- Integration tests pass consistently (not flaky)

## References

### Related Files

- `/Sources/TestContainers/ContainerRequest.swift` - Builder pattern reference
- `/Sources/TestContainers/Container.swift` - Container actor for extensions
- `/Sources/TestContainers/WithContainer.swift` - Lifecycle management pattern
- `/Sources/TestContainers/TestContainersError.swift` - Error types
- `/Tests/TestContainersTests/ContainerRequestTests.swift` - Unit test patterns
- `/Tests/TestContainersTests/DockerIntegrationTests.swift` - Integration test patterns

### Similar Implementations (Reference for Feature Parity)

- **Testcontainers Go**: [RabbitMQ Module](https://golang.testcontainers.org/modules/rabbitmq/)
  - `Run(ctx, img, opts...)` function
  - `WithAdminUsername()`, `WithAdminPassword()` options
  - `AmqpURL()`, `AmqpsURL()` connection methods
  - `HttpURL()`, `HttpsURL()` management methods
  - SSL configuration support
  - Virtual host configuration

- **Testcontainers Java**: RabbitMQ Module
  - Constructor with image parameter
  - `withVHost()` method
  - `getAmqpUrl()`, `getAmqpsUrl()` methods
  - `getHttpUrl()`, `getHttpsUrl()` methods

- **Testcontainers .NET**: RabbitMQ Module
  - Builder pattern with fluent API
  - Username/password configuration
  - Connection string helpers

### RabbitMQ Documentation

- [RabbitMQ Docker Hub](https://hub.docker.com/_/rabbitmq)
- [RabbitMQ Management Plugin](https://www.rabbitmq.com/docs/management)
- [RabbitMQ Configuration](https://www.rabbitmq.com/docs/configure)
- [RabbitMQ Virtual Hosts](https://www.rabbitmq.com/docs/vhosts)

### Swift AMQP Libraries (for integration testing)

- swift-nio-amqp (if available)
- AMQPSwift
- RabbitMQNIO

## Future Enhancements

### Advanced Configuration

1. **Plugin Management**
   ```swift
   .withPlugins(["rabbitmq_shovel", "rabbitmq_federation"])
   ```

2. **Custom Configuration File**
   ```swift
   .withConfigFile("/path/to/rabbitmq.conf")
   ```

3. **Memory Limits**
   ```swift
   .withMemoryLimit("512m")
   .withMemoryHighWatermark(0.4)
   ```

4. **Clustering**
   ```swift
   .withClusterNodes(["rabbit@node1", "rabbit@node2"])
   ```

5. **Queue/Exchange Pre-configuration**
   ```swift
   .withQueue("my-queue", durable: true)
   .withExchange("my-exchange", type: "topic")
   .withBinding(queue: "my-queue", exchange: "my-exchange", routingKey: "*.important")
   ```

6. **User Management**
   ```swift
   .withUser("app-user", password: "secret", tags: ["administrator"])
   .withPermissions(user: "app-user", vhost: "/", configure: ".*", write: ".*", read: ".*")
   ```

### Integration with Other Modules

When multi-container networking is implemented:

```swift
// RabbitMQ + Application container
let network = await Network.create()

let rabbitmq = RabbitMQContainer()
    .withNetwork(network)
    .withNetworkAlias("rabbitmq")

let app = ContainerRequest(image: "myapp:latest")
    .withNetwork(network)
    .withEnvironment([
        "RABBITMQ_URL": "amqp://guest:guest@rabbitmq:5672/"
    ])

try await withContainers([rabbitmq.asContainerRequest(), app]) { containers in
    // Test application with RabbitMQ
}
```

## Implementation Phases

### Phase 1: Core Module (MVP)
- Basic `RabbitMQContainer` struct
- Default configuration
- Basic builder methods (username, password, virtual host)
- Connection helpers (AMQP URL, management URL)
- Unit tests and basic integration tests

### Phase 2: Advanced Features
- SSL/TLS support
- Custom wait strategies
- Multiple version testing
- Enhanced error handling

### Phase 3: Extended Configuration
- Plugin support
- Custom configuration files
- Advanced integration tests
- Performance optimization

### Phase 4: Ecosystem Integration
- Documentation and examples
- Integration with Swift AMQP clients
- Clustering support (if networking implemented)
- User and permission management
