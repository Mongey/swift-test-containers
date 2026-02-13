# Feature: NATSContainer Module

**Status**: Implemented

## Summary

Implement a pre-configured `NATSContainer` module for swift-test-containers that provides a typed Swift API for running NATS messaging servers in tests. This module will wrap the generic container API with NATS-specific configuration, including authentication, JetStream support, cluster configuration, and convenient connection string helpers.

NATS is a high-performance cloud-native messaging system that is widely used for microservices communication, event streaming, and distributed systems. This module will make it easy to test applications that depend on NATS without requiring manual configuration of container settings.

## Current State

### Generic Container API

Currently, users must manually configure NATS containers using the generic `ContainerRequest` API:

```swift
let request = ContainerRequest(image: "nats:2.12")
    .withExposedPort(4222)  // Client port
    .withExposedPort(8222)  // HTTP monitoring port
    .withExposedPort(6222)  // Routing port (for clusters)
    .withCommand(["-js"])   // Enable JetStream
    .waitingFor(.tcpPort(4222))

try await withContainer(request) { container in
    let port = try await container.hostPort(4222)
    let connectionString = "nats://\(container.host()):\(port)"
    // Use connection string...
}
```

This approach requires users to:
- Know the default NATS ports and their purposes
- Understand NATS command-line flags (e.g., `-js` for JetStream)
- Manually construct connection strings
- Configure authentication parameters correctly
- Handle cluster routing setup manually

### Module System Vision

According to `/FEATURES.md` (Tier 4), the project plans to implement service-specific modules with:
- Pre-configured containers with typed APIs
- Connection string helpers
- Sensible defaults
- Service-specific configuration methods

The `NATSContainer` will be one of the first modules in the "Message queues" category, alongside planned implementations for Kafka and RabbitMQ.

## Requirements

### Core Functionality

1. **Default Image**
   - Use `nats:2.12-alpine` as the default image (current stable version)
   - Support custom image override for testing specific versions
   - Use Alpine variant for smaller image size and faster pulls

2. **Port Management**
   - Client port: 4222 (primary NATS client connection port)
   - HTTP monitoring port: 8222 (for server metrics and health checks)
   - Routing port: 6222 (for cluster member communication)
   - All ports should be dynamically mapped to avoid conflicts
   - Provide typed accessors for each port

3. **Authentication Configuration**
   - Username/password authentication
   - Token-based authentication
   - No authentication (default for testing)
   - Support for credentials in connection string

4. **JetStream Support**
   - Enable/disable JetStream via configuration flag
   - Configure JetStream storage directory
   - Support JetStream-specific settings
   - Enable by default (as it's commonly needed for modern NATS applications)

5. **Cluster Configuration**
   - Support multi-node NATS clusters for testing
   - Configure cluster name and node name
   - Configure routes between cluster members
   - Support for network attachment (when network support is available)

6. **Connection String Helpers**
   - Generate standard NATS connection URL: `nats://host:port`
   - Include credentials in URL when configured: `nats://user:pass@host:port`
   - Support multiple server URLs for cluster configurations
   - Provide both throwing and non-throwing accessors

7. **Wait Strategy**
   - Default to TCP port wait on client port 4222
   - Consider HTTP monitoring endpoint wait when that feature is available
   - Configurable timeout (default: 60 seconds)

8. **Custom Configuration**
   - Support for custom NATS configuration file
   - Support for additional command-line arguments
   - Support for environment variables
   - Builder pattern for all configuration options

### Non-Functional Requirements

1. **Consistency**
   - Follow existing swift-test-containers patterns (builder pattern, actor-based Container)
   - Use same testing patterns as core library
   - Match naming conventions from testcontainers-go where applicable

2. **Documentation**
   - Comprehensive doc comments for all public APIs
   - README examples showing common use cases
   - Code examples for basic and advanced scenarios

3. **Testing**
   - Unit tests for configuration builder
   - Integration tests with real NATS containers
   - Test authentication scenarios
   - Test JetStream functionality
   - Test cluster setup (future, when network support available)

4. **Swift Compatibility**
   - Support Swift 5.9+ (matching Package.swift)
   - Full Swift Concurrency support (async/await)
   - Sendable conformance for thread safety
   - macOS 13+ platform requirement

## API Design

### Proposed Swift API

```swift
// New NATSContainer class - wraps Container with NATS-specific API
public final class NATSContainer: Sendable {
    public let container: Container
    private let config: NATSConfig

    // Factory method for creating NATS container
    public static func create(
        _ config: NATSConfig = NATSConfig(),
        docker: DockerClient = DockerClient()
    ) async throws -> NATSContainer

    // Connection string methods
    public func connectionString() async throws -> String
    public var mustConnectionString: String { get async }  // Panics on error

    // Port accessors
    public func clientPort() async throws -> Int
    public func monitoringPort() async throws -> Int
    public func routingPort() async throws -> Int

    // Convenience methods
    public func host() -> String
    public func endpoint() async throws -> String  // host:clientPort

    // Container lifecycle (delegates to wrapped container)
    public func logs() async throws -> String
    public func terminate() async throws
}

// Configuration object with builder pattern
public struct NATSConfig: Sendable, Hashable {
    public var image: String
    public var jetStreamEnabled: Bool
    public var jetStreamStorageDir: String?
    public var username: String?
    public var password: String?
    public var token: String?
    public var clusterName: String?
    public var nodeName: String?
    public var routes: [String]
    public var customArgs: [String]
    public var environment: [String: String]
    public var waitTimeout: Duration
    public var host: String

    // Default initializer with sensible defaults
    public init() {
        self.image = "nats:2.12-alpine"
        self.jetStreamEnabled = true
        self.jetStreamStorageDir = nil  // Uses container default /tmp
        self.username = nil
        self.password = nil
        self.token = nil
        self.clusterName = nil
        self.nodeName = nil
        self.routes = []
        self.customArgs = []
        self.environment = [:]
        self.waitTimeout = .seconds(60)
        self.host = "127.0.0.1"
    }

    // Builder methods
    public func withImage(_ image: String) -> Self
    public func withJetStream(_ enabled: Bool) -> Self
    public func withJetStreamStorageDir(_ dir: String) -> Self
    public func withUsername(_ username: String) -> Self
    public func withPassword(_ password: String) -> Self
    public func withCredentials(username: String, password: String) -> Self
    public func withToken(_ token: String) -> Self
    public func withCluster(name: String, nodeName: String? = nil) -> Self
    public func withRoute(_ route: String) -> Self
    public func withRoutes(_ routes: [String]) -> Self
    public func withArgument(_ arg: String) -> Self
    public func withArguments(_ args: [String]) -> Self
    public func withEnvironment(_ env: [String: String]) -> Self
    public func withWaitTimeout(_ timeout: Duration) -> Self
    public func withHost(_ host: String) -> Self
}

// Scoped lifecycle helper (similar to withContainer)
public func withNATSContainer<T>(
    _ config: NATSConfig = NATSConfig(),
    docker: DockerClient = DockerClient(),
    operation: @Sendable (NATSContainer) async throws -> T
) async throws -> T
```

### Usage Examples

#### Basic NATS Container

```swift
import Testing
import TestContainers

@Test func basicNATS() async throws {
    try await withNATSContainer { nats in
        let url = try await nats.connectionString()
        // url = "nats://127.0.0.1:52341"

        // Connect with your NATS client library
        let nc = try await NatsClient.connect(url)
        try await nc.publish("test.subject", data: "Hello NATS!")
        try nc.close()
    }
}
```

#### NATS with Authentication

```swift
@Test func natsWithAuth() async throws {
    let config = NATSConfig()
        .withCredentials(username: "testuser", password: "testpass")

    try await withNATSContainer(config) { nats in
        let url = try await nats.connectionString()
        // url = "nats://testuser:testpass@127.0.0.1:52341"

        let nc = try await NatsClient.connect(url)
        // Client automatically uses credentials from URL
    }
}
```

#### NATS with JetStream Disabled

```swift
@Test func natsWithoutJetStream() async throws {
    let config = NATSConfig()
        .withJetStream(false)

    try await withNATSContainer(config) { nats in
        let url = try await nats.connectionString()
        let nc = try await NatsClient.connect(url)

        // JetStream operations will fail
        // await #expect(throws: Error.self) {
        //     try await nc.jetStream().publish("stream.subject", data: "test")
        // }
    }
}
```

#### NATS with Custom Arguments

```swift
@Test func natsWithCustomConfig() async throws {
    let config = NATSConfig()
        .withArgument("-DV")  // Debug and verbose logging
        .withArgument("--max_payload")
        .withArgument("1048576")  // 1MB max payload

    try await withNATSContainer(config) { nats in
        let url = try await nats.connectionString()
        // Container started with custom arguments
    }
}
```

#### NATS Cluster (Future - when network support available)

```swift
@Test func natsCluster() async throws {
    let node1Config = NATSConfig()
        .withCluster(name: "test-cluster", nodeName: "node1")

    let node2Config = NATSConfig()
        .withCluster(name: "test-cluster", nodeName: "node2")
        .withRoute("nats://node1:6222")

    let node3Config = NATSConfig()
        .withCluster(name: "test-cluster", nodeName: "node3")
        .withRoute("nats://node1:6222")

    // Note: Requires network support to be implemented first
    try await withNetwork { network in
        try await withNATSContainer(node1Config) { nats1 in
            try await withNATSContainer(node2Config) { nats2 in
                try await withNATSContainer(node3Config) { nats3 in
                    // Three-node NATS cluster running
                    let url1 = try await nats1.connectionString()
                    let url2 = try await nats2.connectionString()
                    let url3 = try await nats3.connectionString()

                    let nc = try await NatsClient.connect([url1, url2, url3])
                    // Client connected to clustered NATS
                }
            }
        }
    }
}
```

#### Integration Test with Real Application

```swift
@Test func messagePublishAndSubscribe() async throws {
    let config = NATSConfig()
        .withJetStream(true)

    try await withNATSContainer(config) { nats in
        let url = try await nats.connectionString()

        // Create NATS connection
        let nc = try await NatsClient.connect(url)

        // Create JetStream context
        let js = nc.jetStream()

        // Create stream
        try await js.addStream(
            StreamConfig(name: "ORDERS", subjects: ["orders.>"])
        )

        // Publish messages
        try await js.publish("orders.new", data: "Order #1")
        try await js.publish("orders.new", data: "Order #2")

        // Subscribe and receive
        let sub = try await js.subscribe("orders.new")
        let msg1 = try await sub.nextMessage(timeout: .seconds(1))
        #expect(msg1.data == "Order #1")

        try nc.close()
    }
}
```

## Implementation Steps

### 1. Create Module Structure

**Directory**: `/Sources/TestContainers/Modules/NATS/`

Create a dedicated directory for the NATS module to keep it organized and separate from core functionality.

**Files to create**:
- `NATSContainer.swift` - Main container class
- `NATSConfig.swift` - Configuration object with builder pattern

**Alternative**: Since modules aren't implemented yet, could also create:
- `/Sources/TestContainers/NATSContainer.swift`
- `/Sources/TestContainers/NATSConfig.swift`

**Decision point**: Check project structure preferences. For first module, simpler flat structure may be preferred. Can refactor to module directory structure later when more modules are added.

### 2. Implement NATSConfig

**File**: `NATSConfig.swift`

```swift
import Foundation

public struct NATSConfig: Sendable, Hashable {
    // Properties as defined in API Design

    public init() {
        // Set defaults
    }

    // Implement all builder methods
    // Each method creates a copy and modifies the specified property
    public func withImage(_ image: String) -> Self {
        var copy = self
        copy.image = image
        return copy
    }

    // ... implement all other builder methods
}
```

**Key considerations**:
- All properties must be `Sendable` compatible
- Struct is immutable; builder methods return modified copies
- Hashable conformance for potential use in WaitStrategy or caching
- Comprehensive defaults for zero-configuration usage

### 3. Implement NATSContainer Class

**File**: `NATSContainer.swift`

```swift
import Foundation

public final class NATSContainer: Sendable {
    private let container: Container
    private let config: NATSConfig

    private init(container: Container, config: NATSConfig) {
        self.container = container
        self.config = config
    }

    public static func create(
        _ config: NATSConfig = NATSConfig(),
        docker: DockerClient = DockerClient()
    ) async throws -> NATSContainer {
        let request = Self.buildContainerRequest(config)

        if !(await docker.isAvailable()) {
            throw TestContainersError.dockerNotAvailable(
                "`docker` CLI not found or Docker engine not running."
            )
        }

        let id = try await docker.runContainer(request)
        let container = Container(id: id, request: request, docker: docker)
        try await container.waitUntilReady()

        return NATSContainer(container: container, config: config)
    }

    private static func buildContainerRequest(_ config: NATSConfig) -> ContainerRequest {
        var command = [String]()

        // Add JetStream flag if enabled
        if config.jetStreamEnabled {
            command.append("-js")
        }

        // Add storage directory if specified
        if let storageDir = config.jetStreamStorageDir {
            command.append("--store_dir")
            command.append(storageDir)
        }

        // Add authentication
        if let username = config.username {
            command.append("--user")
            command.append(username)
        }
        if let password = config.password {
            command.append("--pass")
            command.append(password)
        }
        if let token = config.token {
            command.append("--auth")
            command.append(token)
        }

        // Add cluster configuration
        if let clusterName = config.clusterName {
            command.append("--cluster_name")
            command.append(clusterName)
        }
        if let nodeName = config.nodeName {
            command.append("--name")
            command.append(nodeName)
        }
        for route in config.routes {
            command.append("--routes")
            command.append(route)
        }

        // Add custom arguments
        command.append(contentsOf: config.customArgs)

        var request = ContainerRequest(image: config.image)
            .withCommand(command)
            .withExposedPort(4222)  // Client port
            .withExposedPort(8222)  // HTTP monitoring port
            .withExposedPort(6222)  // Routing port
            .waitingFor(.tcpPort(4222, timeout: config.waitTimeout))
            .withHost(config.host)

        if !config.environment.isEmpty {
            request = request.withEnvironment(config.environment)
        }

        return request
    }

    public func connectionString() async throws -> String {
        let port = try await clientPort()
        let host = self.host()

        // Build connection string with credentials if configured
        if let username = config.username, let password = config.password {
            return "nats://\(username):\(password)@\(host):\(port)"
        } else if let token = config.token {
            return "nats://\(token)@\(host):\(port)"
        } else {
            return "nats://\(host):\(port)"
        }
    }

    public var mustConnectionString: String {
        get async {
            do {
                return try await connectionString()
            } catch {
                fatalError("Failed to get NATS connection string: \(error)")
            }
        }
    }

    public func clientPort() async throws -> Int {
        try await container.hostPort(4222)
    }

    public func monitoringPort() async throws -> Int {
        try await container.hostPort(8222)
    }

    public func routingPort() async throws -> Int {
        try await container.hostPort(6222)
    }

    public func host() -> String {
        container.host()
    }

    public func endpoint() async throws -> String {
        try await container.endpoint(for: 4222)
    }

    public func logs() async throws -> String {
        try await container.logs()
    }

    public func terminate() async throws {
        try await container.terminate()
    }
}
```

### 4. Implement Scoped Lifecycle Helper

**File**: `NATSContainer.swift` (continued)

```swift
public func withNATSContainer<T>(
    _ config: NATSConfig = NATSConfig(),
    docker: DockerClient = DockerClient(),
    operation: @Sendable (NATSContainer) async throws -> T
) async throws -> T {
    let nats = try await NATSContainer.create(config, docker: docker)

    let cleanup: () -> Void = {
        _ = Task { try? await nats.terminate() }
    }

    return try await withTaskCancellationHandler {
        do {
            let result = try await operation(nats)
            try await nats.terminate()
            return result
        } catch {
            try? await nats.terminate()
            throw error
        }
    } onCancel: {
        cleanup()
    }
}
```

**Key considerations**:
- Mirror the pattern from `withContainer()` in `/Sources/TestContainers/WithContainer.swift`
- Ensure cleanup on success, error, and cancellation
- Container is created and waited for readiness before operation starts
- Automatic cleanup prevents container leaks

### 5. Add Unit Tests

**File**: `/Tests/TestContainersTests/NATSConfigTests.swift`

```swift
import Testing
import TestContainers

@Test func natsConfig_defaultValues() {
    let config = NATSConfig()

    #expect(config.image == "nats:2.12-alpine")
    #expect(config.jetStreamEnabled == true)
    #expect(config.jetStreamStorageDir == nil)
    #expect(config.username == nil)
    #expect(config.password == nil)
    #expect(config.token == nil)
    #expect(config.clusterName == nil)
    #expect(config.nodeName == nil)
    #expect(config.routes.isEmpty)
    #expect(config.customArgs.isEmpty)
    #expect(config.environment.isEmpty)
    #expect(config.waitTimeout == .seconds(60))
    #expect(config.host == "127.0.0.1")
}

@Test func natsConfig_withImage() {
    let config = NATSConfig()
        .withImage("nats:2.10-alpine")

    #expect(config.image == "nats:2.10-alpine")
}

@Test func natsConfig_withJetStream() {
    let config = NATSConfig()
        .withJetStream(false)

    #expect(config.jetStreamEnabled == false)
}

@Test func natsConfig_withCredentials() {
    let config = NATSConfig()
        .withCredentials(username: "user", password: "pass")

    #expect(config.username == "user")
    #expect(config.password == "pass")
}

@Test func natsConfig_withToken() {
    let config = NATSConfig()
        .withToken("secret-token")

    #expect(config.token == "secret-token")
}

@Test func natsConfig_withCluster() {
    let config = NATSConfig()
        .withCluster(name: "my-cluster", nodeName: "node-1")

    #expect(config.clusterName == "my-cluster")
    #expect(config.nodeName == "node-1")
}

@Test func natsConfig_withRoutes() {
    let config = NATSConfig()
        .withRoute("nats://node1:6222")
        .withRoute("nats://node2:6222")

    #expect(config.routes.count == 2)
    #expect(config.routes.contains("nats://node1:6222"))
    #expect(config.routes.contains("nats://node2:6222"))
}

@Test func natsConfig_withArguments() {
    let config = NATSConfig()
        .withArgument("-DV")
        .withArguments(["--max_payload", "1048576"])

    #expect(config.customArgs.count == 3)
    #expect(config.customArgs[0] == "-DV")
    #expect(config.customArgs[1] == "--max_payload")
    #expect(config.customArgs[2] == "1048576")
}

@Test func natsConfig_builderChaining() {
    let config = NATSConfig()
        .withImage("nats:latest")
        .withJetStream(true)
        .withCredentials(username: "admin", password: "admin123")
        .withCluster(name: "test-cluster", nodeName: "node1")
        .withWaitTimeout(.seconds(30))

    #expect(config.image == "nats:latest")
    #expect(config.jetStreamEnabled == true)
    #expect(config.username == "admin")
    #expect(config.password == "admin123")
    #expect(config.clusterName == "test-cluster")
    #expect(config.nodeName == "node1")
    #expect(config.waitTimeout == .seconds(30))
}

@Test func natsConfig_hashable() {
    let config1 = NATSConfig()
        .withCredentials(username: "user", password: "pass")

    let config2 = NATSConfig()
        .withCredentials(username: "user", password: "pass")

    let config3 = NATSConfig()
        .withCredentials(username: "other", password: "pass")

    #expect(config1 == config2)
    #expect(config1 != config3)
}
```

### 6. Add Integration Tests

**File**: `/Tests/TestContainersTests/NATSContainerIntegrationTests.swift`

```swift
import Testing
import TestContainers

@Test func natsContainer_basic() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withNATSContainer { nats in
        let url = try await nats.connectionString()
        #expect(url.hasPrefix("nats://"))
        #expect(url.contains(":"))

        let port = try await nats.clientPort()
        #expect(port > 0)

        let endpoint = try await nats.endpoint()
        #expect(endpoint.contains(":"))
    }
}

@Test func natsContainer_withAuthentication() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = NATSConfig()
        .withCredentials(username: "testuser", password: "testpass")

    try await withNATSContainer(config) { nats in
        let url = try await nats.connectionString()
        #expect(url.contains("testuser:testpass@"))
    }
}

@Test func natsContainer_withoutJetStream() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = NATSConfig()
        .withJetStream(false)

    try await withNATSContainer(config) { nats in
        let port = try await nats.clientPort()
        #expect(port > 0)

        // Could verify JetStream is disabled by checking logs
        let logs = try await nats.logs()
        #expect(!logs.contains("JetStream"))
    }
}

@Test func natsContainer_withJetStreamEnabled() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = NATSConfig()
        .withJetStream(true)

    try await withNATSContainer(config) { nats in
        let logs = try await nats.logs()
        #expect(logs.contains("JetStream"))
    }
}

@Test func natsContainer_allPorts() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withNATSContainer { nats in
        let clientPort = try await nats.clientPort()
        let monitoringPort = try await nats.monitoringPort()
        let routingPort = try await nats.routingPort()

        #expect(clientPort > 0)
        #expect(monitoringPort > 0)
        #expect(routingPort > 0)

        // All ports should be different
        #expect(clientPort != monitoringPort)
        #expect(clientPort != routingPort)
        #expect(monitoringPort != routingPort)
    }
}

@Test func natsContainer_customImage() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = NATSConfig()
        .withImage("nats:2.10-alpine")

    try await withNATSContainer(config) { nats in
        let logs = try await nats.logs()
        // Verify container started
        #expect(!logs.isEmpty)
    }
}

@Test func natsContainer_withCustomArgs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = NATSConfig()
        .withArgument("-DV")  // Debug verbose

    try await withNATSContainer(config) { nats in
        let logs = try await nats.logs()
        // With debug enabled, logs should be more verbose
        #expect(!logs.isEmpty)
    }
}

@Test func natsContainer_mustConnectionString() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withNATSContainer { nats in
        let url = await nats.mustConnectionString
        #expect(url.hasPrefix("nats://"))
    }
}

@Test func natsContainer_lifecycle() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nats = try await NATSContainer.create()

    // Container should be running
    let port = try await nats.clientPort()
    #expect(port > 0)

    // Terminate should succeed
    try await nats.terminate()

    // After termination, port access should fail
    await #expect(throws: Error.self) {
        _ = try await nats.clientPort()
    }
}
```

### 7. Update Package.swift (if needed)

If using a separate module target, update `/Package.swift`:

```swift
products: [
    .library(
        name: "TestContainers",
        targets: ["TestContainers"]
    ),
    .library(
        name: "TestContainersNATS",
        targets: ["TestContainersNATS"]
    )
],
targets: [
    .target(
        name: "TestContainers"
    ),
    .target(
        name: "TestContainersNATS",
        dependencies: ["TestContainers"]
    ),
    .testTarget(
        name: "TestContainersTests",
        dependencies: ["TestContainers", "TestContainersNATS"]
    )
]
```

**Decision**: For first module, simpler to keep everything in `TestContainers` target. Can refactor to separate targets later if needed.

### 8. Documentation

**Update README.md** with NATS examples:

```markdown
## NATS Container

swift-test-containers provides a pre-configured NATS container module with JetStream support:

### Basic Usage

```swift
import Testing
import TestContainers

@Test func natsExample() async throws {
    try await withNATSContainer { nats in
        let url = try await nats.connectionString()
        // Connect your NATS client to url
    }
}
```

### With Authentication

```swift
@Test func natsWithAuth() async throws {
    let config = NATSConfig()
        .withCredentials(username: "user", password: "pass")

    try await withNATSContainer(config) { nats in
        let url = try await nats.connectionString()
        // url includes credentials: nats://user:pass@host:port
    }
}
```

### Configuration Options

- `withImage(_:)` - Use a different NATS image
- `withJetStream(_:)` - Enable/disable JetStream (enabled by default)
- `withCredentials(username:password:)` - Set authentication
- `withToken(_:)` - Use token authentication
- `withCluster(name:nodeName:)` - Configure cluster mode
- `withRoute(_:)` - Add cluster routes
- `withArgument(_:)` - Add custom NATS server arguments
```

**Add doc comments** to all public APIs in `NATSContainer.swift` and `NATSConfig.swift`.

## Testing Plan

### Unit Tests

1. **NATSConfig Tests** (7 test cases)
   - Default values validation
   - Image configuration
   - JetStream enable/disable
   - Credentials configuration
   - Token authentication
   - Cluster configuration
   - Custom arguments
   - Builder method chaining
   - Hashable conformance

2. **Container Request Building** (Internal logic)
   - Verify correct command-line arguments generated
   - Verify port mappings
   - Verify wait strategy configuration
   - Verify environment variable passing

### Integration Tests

1. **Basic Container Lifecycle**
   - Start default NATS container
   - Verify connection string format
   - Verify port accessibility
   - Verify container logs
   - Verify cleanup on success
   - Verify cleanup on error
   - Verify cleanup on cancellation

2. **Authentication Tests**
   - Username/password authentication
   - Token authentication
   - Verify credentials in connection string
   - No authentication (default)

3. **JetStream Tests**
   - JetStream enabled (default)
   - JetStream disabled
   - Verify via logs

4. **Port Tests**
   - Client port (4222) accessible
   - Monitoring port (8222) accessible
   - Routing port (6222) accessible
   - All ports are unique

5. **Custom Configuration Tests**
   - Custom image version
   - Custom arguments
   - Custom wait timeout

6. **Error Handling**
   - Docker not available
   - Invalid image
   - Container startup failure

### Manual Testing Checklist

- [ ] Test with official nats.swift client library (if available)
- [ ] Test with official nats.go client library via command-line tools
- [ ] Verify JetStream operations work (create stream, publish, subscribe)
- [ ] Test concurrent containers don't conflict on ports
- [ ] Test on macOS
- [ ] Test on Linux (if CI available)
- [ ] Performance test: container startup time
- [ ] Memory usage: verify container cleanup doesn't leak

### Real-World Integration Test

Create a comprehensive test that mimics actual usage:

```swift
@Test func natsRealWorldExample() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = NATSConfig()
        .withCredentials(username: "app", password: "secret")
        .withJetStream(true)

    try await withNATSContainer(config) { nats in
        let url = try await nats.connectionString()

        // This would use a real NATS client library
        // For now, verify the container is healthy via monitoring port
        let monitoringPort = try await nats.monitoringPort()
        let host = nats.host()

        // Could use URLSession to check monitoring endpoint
        // GET http://host:monitoringPort/healthz or /varz

        #expect(monitoringPort > 0)
        #expect(!host.isEmpty)
    }
}
```

## Acceptance Criteria

### Must Have

- [ ] `NATSConfig` struct with builder pattern implemented
- [ ] `NATSContainer` class with async/await API
- [ ] `withNATSContainer()` scoped lifecycle helper
- [ ] Default image: `nats:2.12-alpine`
- [ ] JetStream enabled by default
- [ ] Support for disabling JetStream
- [ ] Username/password authentication support
- [ ] Token authentication support
- [ ] Connection string generation (with and without credentials)
- [ ] Client port (4222) accessor
- [ ] Monitoring port (8222) accessor
- [ ] Routing port (6222) accessor
- [ ] TCP wait strategy on client port
- [ ] Custom image support
- [ ] Custom command-line arguments support
- [ ] `Sendable` conformance for thread safety
- [ ] Unit tests with >80% code coverage
- [ ] Integration tests with real NATS containers
- [ ] Doc comments on all public APIs
- [ ] README examples

### Should Have

- [ ] `mustConnectionString` property (panics on error, convenience for tests)
- [ ] Cluster configuration support (name, node name)
- [ ] Cluster routes support (for future multi-container testing)
- [ ] JetStream storage directory configuration
- [ ] Environment variable support
- [ ] Custom wait timeout configuration
- [ ] Host configuration (for non-localhost scenarios)
- [ ] Logs accessor
- [ ] Terminate method
- [ ] Error handling with clear messages
- [ ] Integration test with NATS monitoring endpoint

### Nice to Have

- [ ] Example integration with real NATS Swift client (if exists)
- [ ] HTTP wait strategy using monitoring port (when HTTP wait is implemented)
- [ ] Configuration file support (via `io.Reader` equivalent in Swift)
- [ ] TLS/SSL configuration
- [ ] NATS server metrics scraping from monitoring port
- [ ] Cluster setup example (when network support is available)
- [ ] Performance benchmarks
- [ ] Debug logging for troubleshooting

### Definition of Done

- All "Must Have" criteria completed
- All "Should Have" criteria completed
- All tests passing locally
- Integration tests pass with `TESTCONTAINERS_RUN_DOCKER_TESTS=1`
- Code follows existing swift-test-containers patterns
- No regressions in existing tests
- All public APIs have comprehensive doc comments
- README includes NATS examples in Quick Start or dedicated section
- Feature added to FEATURES.md (Tier 4 - Module System)
- Manual testing completed with at least 2 scenarios
- Code is ready for review

## References

### Related Files

**Core library**:
- `/Sources/TestContainers/ContainerRequest.swift` - Request builder pattern
- `/Sources/TestContainers/Container.swift` - Container actor
- `/Sources/TestContainers/WithContainer.swift` - Scoped lifecycle pattern
- `/Sources/TestContainers/DockerClient.swift` - Docker CLI integration
- `/Sources/TestContainers/Waiter.swift` - Wait strategy implementation
- `/Sources/TestContainers/TestContainersError.swift` - Error types

**Tests**:
- `/Tests/TestContainersTests/DockerIntegrationTests.swift` - Integration test pattern
- `/Tests/TestContainersTests/ContainerRequestTests.swift` - Unit test pattern

**Documentation**:
- `/README.md` - User-facing documentation
- `/FEATURES.md` - Feature tracking

### External References

**Testcontainers implementations**:
- [Testcontainers Go - NATS Module](https://golang.testcontainers.org/modules/nats/) - Primary reference
- [Testcontainers Go - NATS Source](https://github.com/testcontainers/testcontainers-go/blob/main/modules/nats/nats.go) - Implementation details
- [Testcontainers - NATS Module](https://testcontainers.com/modules/nats/) - General documentation

**NATS documentation**:
- [NATS Docker Hub](https://hub.docker.com/_/nats) - Official image documentation
- [NATS JetStream Docker](https://docs.nats.io/running-a-nats-service/nats_docker/jetstream_docker) - JetStream configuration
- [NATS Server Configuration](https://docs.nats.io/running-a-nats-service/configuration) - Configuration options

**Swift resources**:
- Swift Package Manager
- Swift Concurrency (async/await, actors, Sendable)
- Swift Testing framework

## Implementation Notes

### Module Architecture Decision

Two options for organizing the code:

**Option 1: Flat structure** (Recommended for first module)
- Add `NATSContainer.swift` and `NATSConfig.swift` to `/Sources/TestContainers/`
- Keep everything in the main `TestContainers` target
- Simpler for users (single import)
- Can refactor later when more modules exist

**Option 2: Dedicated module**
- Create `/Sources/TestContainersNATS/` directory
- Separate library target in Package.swift
- Users import both `TestContainers` and `TestContainersNATS`
- Better separation, but more complex for first module

**Recommendation**: Start with Option 1, refactor to Option 2 when implementing second module (e.g., PostgresContainer).

### NATS Server Flags

Key NATS command-line flags to support:

- `-js` - Enable JetStream
- `--store_dir <dir>` - JetStream storage directory
- `--user <username>` - Username for authentication
- `--pass <password>` - Password for authentication
- `--auth <token>` - Token for authentication
- `--cluster_name <name>` - Cluster name
- `--name <node>` - Node name
- `--routes <urls>` - Cluster routes (comma-separated or repeated flag)
- `-DV` - Debug and verbose logging
- `--max_payload <bytes>` - Maximum payload size

### Connection String Format

NATS connection URL formats:
- No auth: `nats://host:port`
- Username/password: `nats://user:pass@host:port`
- Token: `nats://token@host:port`
- Multiple servers: `nats://host1:port1,host2:port2,host3:port3`

### Cluster Configuration

For cluster testing (future feature when networks are supported):
- Requires custom network to allow container-to-container communication
- Each node needs unique name
- Each node needs cluster name
- Nodes 2-N need routes to node 1 (or all nodes route to each other)
- Route format: `nats://nodename:6222`

Example cluster setup:
```bash
# Node 1
docker run -d --name nats1 --network nats-cluster \
  nats:2.12-alpine \
  --cluster_name mycluster --name node1 \
  --cluster nats://0.0.0.0:6222

# Node 2
docker run -d --name nats2 --network nats-cluster \
  nats:2.12-alpine \
  --cluster_name mycluster --name node2 \
  --cluster nats://0.0.0.0:6222 \
  --routes nats://nats1:6222
```

### Dependencies on Other Features

**Current blockers**: None - can implement immediately

**Future enhancements** (depend on other features):
- Cluster testing requires **Network support** (Tier 2, planned)
- Health check wait could use **HTTP wait strategy** (Tier 1, in progress)
- Configuration file support needs **Copy files to container** (Tier 1, planned)
- Advanced monitoring requires **Exec in container** (Tier 1, planned)

### Testing Without NATS Client Library

Since we may not have a Swift NATS client library readily available:

1. **Use HTTP monitoring endpoint**:
   ```swift
   let monitoringPort = try await nats.monitoringPort()
   let url = URL(string: "http://\(nats.host()):\(monitoringPort)/varz")!
   let (data, _) = try await URLSession.shared.data(from: url)
   // Parse JSON response
   ```

2. **Use Docker exec** (when available):
   ```swift
   let result = try await nats.exec(["nats", "server", "info"])
   #expect(result.exitCode == 0)
   ```

3. **Parse container logs**:
   ```swift
   let logs = try await nats.logs()
   #expect(logs.contains("Server is ready"))
   ```

### Performance Considerations

- NATS Alpine image is ~15MB (much smaller than other message queues)
- Typical startup time: 1-3 seconds
- JetStream adds minimal overhead
- Port probing every 200ms is sufficient (may not need custom wait strategy)

### Security Considerations

- Default configuration has no authentication (OK for tests)
- When authentication is enabled, credentials appear in connection string
- Credentials also appear in container command (visible in `docker ps`)
- For production-like testing, consider token auth instead of user/pass
- TLS support is a nice-to-have, not required for first version
