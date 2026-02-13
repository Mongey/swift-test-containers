# Feature 042: Multi-Container Stacks

**Status**: Implemented
**Priority**: Tier 3 (Advanced Features)
**Tracking**: FEATURES.md line 100
**Category**: Infrastructure

---

## Summary

Implement a multi-container stack abstraction that allows defining and running multiple related containers together as a coordinated unit. This enables testing scenarios that require multiple services (e.g., application + database + cache), with support for dependency ordering, shared networking, container references, and scoped lifecycle management.

**Key capabilities:**
- Define multiple containers as a cohesive stack
- Reference containers within the stack by name/identifier
- Share configuration across containers (networks, volumes, environment)
- Coordinate startup order with dependency-aware wait strategies
- Manage lifecycle of all containers together with automatic cleanup
- Enable container-to-container communication via shared networks

---

## Current State

### Single-Container API

The current API in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift` supports only single containers:

```swift
public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable("`docker` CLI not found or Docker engine not running.")
    }

    let id = try await docker.runContainer(request)
    let container = Container(id: id, request: request, docker: docker)

    let cleanup: () -> Void = { _ = Task { try? await container.terminate() } }

    return try await withTaskCancellationHandler {
        do {
            try await container.waitUntilReady()
            let result = try await operation(container)
            try await container.terminate()
            return result
        } catch {
            try? await container.terminate()
            throw error
        }
    } onCancel: {
        cleanup()
    }
}
```

**Current limitations:**
- No built-in support for running multiple related containers
- No shared networking between containers (each container isolated)
- No dependency coordination (if app depends on DB, must manually order)
- No way to reference one container from another's configuration
- Each container requires separate `withContainer` call (cumbersome for complex setups)
- No shared resource management (networks, volumes) across containers

**Workarounds users currently employ:**
```swift
// Nested withContainer calls - verbose and hard to manage
try await withContainer(dbRequest) { db in
    let dbHost = try await db.endpoint(for: 5432)

    let appRequest = ContainerRequest(image: "myapp:latest")
        .withEnvironment(["DB_URL": "postgres://\(dbHost)/test"])

    try await withContainer(appRequest) { app in
        // Test with both containers
    }
    // app terminates before db cleanup
}
```

**Problems with current approach:**
1. Nested scopes become deeply indented with multiple containers
2. Inner containers can't easily reference outer container endpoints
3. No automatic network creation for container-to-container communication
4. Manual dependency coordination required
5. Error handling becomes complex across multiple scopes
6. No atomic cleanup if one container fails to start

---

## Requirements

### Core Functionality

1. **Stack Definition**
   - Define multiple containers as a single logical unit
   - Fluent builder API consistent with `ContainerRequest` pattern
   - Support for named container references within the stack
   - Immutable stack configuration (modifications return new instance)

2. **Container References**
   - Reference containers by name/identifier within the stack
   - Access container endpoints from other containers' configuration
   - Support for template variables (e.g., `{{db.host}}:{{db.port}}`)
   - Type-safe container lookups during execution

3. **Shared Configuration**
   - Shared networks automatically created and attached
   - Shared volumes (named volumes) across containers
   - Shared environment variables with stack-level defaults
   - Shared labels (e.g., stack identifier, cleanup metadata)

4. **Dependency Ordering**
   - Explicit dependency declarations (container A depends on B)
   - Automatic topological sort for startup order
   - Parallel startup where dependencies allow
   - Dependency-aware wait strategies (wait for dependency readiness)

5. **Scoped Lifecycle**
   - `withStack(_:_:)` helper similar to `withContainer`
   - Start all containers in dependency order
   - Wait for all containers to be ready (respecting dependencies)
   - Automatic cleanup on success, error, and cancellation
   - Cleanup in reverse dependency order (dependents stop before dependencies)

6. **Container-to-Container Communication**
   - Containers can communicate via shared network
   - Network aliases for DNS-based discovery (e.g., `db` resolves to database container)
   - Support for host-based communication (via `host.docker.internal` or mapped ports)

### Non-Functional Requirements

1. **Performance**
   - Parallel container startup where dependencies allow
   - Efficient network creation (single network per stack by default)
   - Minimal overhead compared to manual multi-container setup

2. **Reliability**
   - Atomic startup: if any container fails, clean up all started containers
   - Graceful shutdown in dependency order
   - Proper error propagation with context (which container failed)
   - Task cancellation support with full cleanup

3. **Usability**
   - API feels natural to Swift developers
   - Clear error messages (which container, why, what stage)
   - Minimal boilerplate compared to nested `withContainer` calls
   - Works with existing `ContainerRequest` configurations

4. **Compatibility**
   - Works with all existing wait strategies
   - Compatible with existing Docker backend (CLI-based)
   - Supports all existing container configuration options
   - Can mix stack and non-stack containers in same test

---

## API Design

### Proposed Swift API

#### ContainerStack

```swift
/// A multi-container stack for coordinated lifecycle management
public struct ContainerStack: Sendable, Hashable {
    public var containers: [String: ContainerRequest]
    public var dependencies: [String: Set<String>]
    public var network: NetworkConfig?
    public var volumes: [String: VolumeConfig]
    public var environment: [String: String]
    public var labels: [String: String]

    public init() {
        self.containers = [:]
        self.dependencies = [:]
        self.network = NetworkConfig(name: nil, createIfMissing: true)
        self.volumes = [:]
        self.environment = [:]
        self.labels = ["testcontainers.swift.stack": "true"]
    }

    // Builder methods
    public func withContainer(_ name: String, _ request: ContainerRequest) -> Self
    public func withDependency(_ dependent: String, dependsOn: String) -> Self
    public func withDependencies(_ dependent: String, dependsOn: [String]) -> Self
    public func withNetwork(_ config: NetworkConfig) -> Self
    public func withVolume(_ name: String, _ config: VolumeConfig) -> Self
    public func withEnvironment(_ environment: [String: String]) -> Self
    public func withLabel(_ key: String, _ value: String) -> Self
}

/// Network configuration for container stacks
public struct NetworkConfig: Sendable, Hashable {
    public var name: String?
    public var driver: String
    public var createIfMissing: Bool
    public var internal: Bool

    public init(name: String? = nil, createIfMissing: Bool = true) {
        self.name = name
        self.driver = "bridge"
        self.createIfMissing = createIfMissing
        self.internal = false
    }

    public func withName(_ name: String) -> Self
    public func withDriver(_ driver: String) -> Self
    public func withInternal(_ internal: Bool) -> Self
}

/// Volume configuration for shared storage
public struct VolumeConfig: Sendable, Hashable {
    public var driver: String
    public var options: [String: String]

    public init(driver: String = "local") {
        self.driver = driver
        self.options = [:]
    }

    public func withDriver(_ driver: String) -> Self
    public func withOption(_ key: String, _ value: String) -> Self
}
```

#### RunningStack

```swift
/// A running container stack with access to individual containers
public actor RunningStack {
    public let stackId: String
    private let containers: [String: Container]
    private let network: NetworkInfo?
    private let docker: DockerClient

    init(stackId: String, containers: [String: Container], network: NetworkInfo?, docker: DockerClient) {
        self.stackId = stackId
        self.containers = containers
        self.network = network
        self.docker = docker
    }

    /// Get a container by name
    public func container(_ name: String) throws -> Container {
        guard let container = containers[name] else {
            throw TestContainersError.containerNotFound(name, availableContainers: Array(containers.keys))
        }
        return container
    }

    /// Get all containers in the stack
    public func allContainers() -> [String: Container] {
        containers
    }

    /// Get the network name for container-to-container communication
    public func networkName() -> String? {
        network?.name
    }

    /// Terminate all containers in the stack (reverse dependency order)
    public func terminate() async throws {
        // Implementation handles cleanup
    }
}

struct NetworkInfo {
    let name: String
    let id: String
}
```

#### withStack Helper

```swift
/// Run a multi-container stack with scoped lifecycle management
public func withStack<T>(
    _ stack: ContainerStack,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (RunningStack) async throws -> T
) async throws -> T {
    // Similar pattern to withContainer but manages multiple containers
}
```

### Usage Examples

#### Example 1: Application + Database Stack

```swift
@Test func testWithDatabaseStack() async throws {
    let stack = ContainerStack()
        .withContainer("postgres",
            ContainerRequest(image: "postgres:15")
                .withExposedPort(5432)
                .withEnvironment(["POSTGRES_PASSWORD": "test", "POSTGRES_DB": "testdb"])
                .waitingFor(.tcpPort(5432))
        )
        .withContainer("app",
            ContainerRequest(image: "myapp:latest")
                .withExposedPort(8080)
                .withEnvironment([
                    "DATABASE_HOST": "postgres",  // Container name as hostname
                    "DATABASE_PORT": "5432",
                    "DATABASE_NAME": "testdb"
                ])
                .waitingFor(.http(HTTPWaitConfig(port: 8080).withPath("/health")))
        )
        .withDependency("app", dependsOn: "postgres")

    try await withStack(stack) { running in
        let app = try await running.container("app")
        let endpoint = try await app.endpoint(for: 8080)

        // Make HTTP request to app, which connects to postgres via container network
        // ...
    }
}
```

#### Example 2: Microservices Stack

```swift
@Test func testMicroservicesStack() async throws {
    let stack = ContainerStack()
        .withContainer("redis",
            ContainerRequest(image: "redis:7")
                .withExposedPort(6379)
                .waitingFor(.tcpPort(6379))
        )
        .withContainer("postgres",
            ContainerRequest(image: "postgres:15")
                .withExposedPort(5432)
                .withEnvironment(["POSTGRES_PASSWORD": "test"])
                .waitingFor(.logContains("database system is ready"))
        )
        .withContainer("api",
            ContainerRequest(image: "api-service:latest")
                .withExposedPort(8080)
                .withEnvironment([
                    "REDIS_URL": "redis://redis:6379",
                    "DATABASE_URL": "postgresql://postgres:test@postgres:5432/test"
                ])
                .waitingFor(.http(HTTPWaitConfig(port: 8080).withPath("/ready")))
        )
        .withContainer("worker",
            ContainerRequest(image: "worker-service:latest")
                .withEnvironment([
                    "REDIS_URL": "redis://redis:6379",
                    "DATABASE_URL": "postgresql://postgres:test@postgres:5432/test"
                ])
                .waitingFor(.logContains("Worker started"))
        )
        .withDependencies("api", dependsOn: ["redis", "postgres"])
        .withDependencies("worker", dependsOn: ["redis", "postgres"])

    try await withStack(stack) { running in
        let api = try await running.container("api")
        let apiEndpoint = try await api.endpoint(for: 8080)

        // Test API that uses Redis cache and Postgres database
        // Worker processes jobs from Redis in background
    }
}
```

#### Example 3: Custom Network and Shared Volume

```swift
@Test func testWithSharedResources() async throws {
    let stack = ContainerStack()
        .withNetwork(NetworkConfig(name: "test-network"))
        .withVolume("shared-data", VolumeConfig())
        .withContainer("producer",
            ContainerRequest(image: "producer:latest")
                .withCommand(["produce", "/data/output.txt"])
                // Volume mount would be added via withVolume method on ContainerRequest
                .waitingFor(.logContains("Production complete"))
        )
        .withContainer("consumer",
            ContainerRequest(image: "consumer:latest")
                .withCommand(["consume", "/data/output.txt"])
                .waitingFor(.logContains("Consumption complete"))
        )
        .withDependency("consumer", dependsOn: "producer")

    try await withStack(stack) { running in
        let consumer = try await running.container("consumer")
        let logs = try await consumer.logs()
        #expect(logs.contains("Consumption complete"))
    }
}
```

#### Example 4: Dynamic Configuration with Host Ports

```swift
@Test func testStackWithHostAccess() async throws {
    let stack = ContainerStack()
        .withContainer("database",
            ContainerRequest(image: "postgres:15")
                .withExposedPort(5432)
                .withEnvironment(["POSTGRES_PASSWORD": "test"])
                .waitingFor(.tcpPort(5432))
        )

    try await withStack(stack) { running in
        let db = try await running.container("database")
        let hostPort = try await db.hostPort(5432)

        // Connect to database from test host using mapped port
        let connectionString = "postgresql://localhost:\(hostPort)/test"
        // Test with connection string...
    }
}
```

---

## Implementation Steps

### Step 1: Define Core Stack Types

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerStack.swift` (new)

- Define `ContainerStack` struct with builder pattern
- Implement `withContainer`, `withDependency`, `withDependencies` methods
- Implement `withNetwork`, `withVolume`, `withEnvironment`, `withLabel` methods
- Ensure `Sendable` and `Hashable` conformance
- Add validation for circular dependencies
- Add validation for container name uniqueness
- Add validation for dependency references (all dependencies must exist)

**Key implementation details:**
```swift
public struct ContainerStack: Sendable, Hashable {
    // ... fields ...

    public func withContainer(_ name: String, _ request: ContainerRequest) -> Self {
        var copy = self
        copy.containers[name] = request
        return copy
    }

    public func withDependency(_ dependent: String, dependsOn: String) -> Self {
        var copy = self
        copy.dependencies[dependent, default: []].insert(dependsOn)
        return copy
    }

    /// Validates the stack configuration (called before execution)
    func validate() throws {
        // Check all containers referenced in dependencies exist
        // Check for circular dependencies using topological sort
        // Throw descriptive errors
    }

    /// Returns containers in dependency order (topological sort)
    func startupOrder() throws -> [String] {
        // Kahn's algorithm or DFS-based topological sort
    }
}
```

### Step 2: Implement Network Configuration Types

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/NetworkConfig.swift` (new)

- Define `NetworkConfig` struct with builder pattern
- Define `VolumeConfig` struct with builder pattern
- Implement `Hashable` and `Sendable` conformance
- Add documentation for network drivers and options

### Step 3: Extend DockerClient for Network Operations

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Add methods for network management:

```swift
extension DockerClient {
    /// Create a Docker network
    func createNetwork(name: String, driver: String = "bridge", internal: Bool = false) async throws -> String {
        var args = ["network", "create", "--driver", driver]
        if internal {
            args.append("--internal")
        }
        args.append(name)

        let output = try await runDocker(args)
        let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw TestContainersError.unexpectedDockerOutput(output.stdout)
        }
        return id
    }

    /// Remove a Docker network
    func removeNetwork(id: String) async throws {
        _ = try await runDocker(["network", "rm", id])
    }

    /// Check if a network exists
    func networkExists(name: String) async throws -> Bool {
        do {
            let output = try await runDocker(["network", "inspect", name])
            return !output.stdout.isEmpty
        } catch {
            return false
        }
    }
}
```

### Step 4: Extend ContainerRequest for Network Attachment

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

Add network and alias support:

```swift
public struct ContainerRequest: Sendable, Hashable {
    // ... existing fields ...
    public var networks: [String]
    public var networkAliases: [String: [String]] // network name -> aliases

    public func withNetwork(_ network: String, aliases: [String] = []) -> Self {
        var copy = self
        copy.networks.append(network)
        if !aliases.isEmpty {
            copy.networkAliases[network] = aliases
        }
        return copy
    }
}
```

Update `DockerClient.runContainer()` to handle network flags:

```swift
// In runContainer method, add:
for network in request.networks {
    args += ["--network", network]
    if let aliases = request.networkAliases[network], !aliases.isEmpty {
        for alias in aliases {
            args += ["--network-alias", alias]
        }
    }
}
```

### Step 5: Implement RunningStack Actor

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/RunningStack.swift` (new)

```swift
public actor RunningStack {
    public let stackId: String
    private let containers: [String: Container]
    private let network: NetworkInfo?
    private let shutdownOrder: [String] // Reverse of startup order
    private let docker: DockerClient

    init(stackId: String, containers: [String: Container], network: NetworkInfo?, shutdownOrder: [String], docker: DockerClient) {
        self.stackId = stackId
        self.containers = containers
        self.network = network
        self.shutdownOrder = shutdownOrder
        self.docker = docker
    }

    public func container(_ name: String) throws -> Container {
        guard let container = containers[name] else {
            throw TestContainersError.containerNotFound(name, availableContainers: Array(containers.keys))
        }
        return container
    }

    public func allContainers() -> [String: Container] {
        containers
    }

    public func networkName() -> String? {
        network?.name
    }

    public func terminate() async throws {
        // Terminate containers in reverse dependency order
        for name in shutdownOrder {
            if let container = containers[name] {
                try? await container.terminate()
            }
        }

        // Remove network if created
        if let network = network {
            try? await docker.removeNetwork(id: network.id)
        }
    }
}

struct NetworkInfo {
    let name: String
    let id: String
}
```

### Step 6: Implement withStack Helper

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithStack.swift` (new)

```swift
public func withStack<T>(
    _ stack: ContainerStack,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (RunningStack) async throws -> T
) async throws -> T {
    // 1. Validate configuration
    try stack.validate()

    // 2. Check Docker availability
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable("`docker` CLI not found or Docker engine not running.")
    }

    // 3. Create network if needed
    let networkInfo: NetworkInfo?
    if let networkConfig = stack.network, networkConfig.createIfMissing {
        let networkName = networkConfig.name ?? "testcontainers-\(UUID().uuidString.prefix(8))"
        let networkId = try await docker.createNetwork(
            name: networkName,
            driver: networkConfig.driver,
            internal: networkConfig.internal
        )
        networkInfo = NetworkInfo(name: networkName, id: networkId)
    } else {
        networkInfo = nil
    }

    // 4. Determine startup order
    let startupOrder = try stack.startupOrder()
    let shutdownOrder = startupOrder.reversed()

    // 5. Start containers in dependency order
    var runningContainers: [String: Container] = [:]

    let cleanup: () -> Void = {
        Task {
            for name in shutdownOrder {
                if let container = runningContainers[name] {
                    try? await container.terminate()
                }
            }
            if let network = networkInfo {
                try? await docker.removeNetwork(id: network.id)
            }
        }
    }

    return try await withTaskCancellationHandler {
        do {
            // Start containers
            for name in startupOrder {
                guard let request = stack.containers[name] else { continue }

                // Attach to network if created
                var modifiedRequest = request
                if let network = networkInfo {
                    modifiedRequest = modifiedRequest.withNetwork(network.name, aliases: [name])
                }

                // Merge stack-level environment and labels
                modifiedRequest = modifiedRequest
                    .withEnvironment(stack.environment)
                modifiedRequest.labels.merge(stack.labels) { _, new in new }

                // Start container
                let id = try await docker.runContainer(modifiedRequest)
                let container = Container(id: id, request: modifiedRequest, docker: docker)
                runningContainers[name] = container

                // Wait for container to be ready
                try await container.waitUntilReady()
            }

            // Create RunningStack
            let running = RunningStack(
                stackId: networkInfo?.name ?? "stack-\(UUID().uuidString.prefix(8))",
                containers: runningContainers,
                network: networkInfo,
                shutdownOrder: shutdownOrder,
                docker: docker
            )

            // Execute user operation
            let result = try await operation(running)

            // Cleanup
            try await running.terminate()

            return result
        } catch {
            cleanup()
            throw error
        }
    } onCancel: {
        cleanup()
    }
}
```

### Step 7: Add Dependency Graph Validation

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DependencyGraph.swift` (new)

Implement topological sort and cycle detection:

```swift
enum DependencyGraph {
    /// Performs topological sort on container dependencies
    /// Throws if circular dependency detected
    static func topologicalSort(
        containers: Set<String>,
        dependencies: [String: Set<String>]
    ) throws -> [String] {
        var inDegree: [String: Int] = [:]
        var adjList: [String: Set<String>] = [:]

        // Initialize
        for container in containers {
            inDegree[container] = 0
            adjList[container] = []
        }

        // Build graph
        for (dependent, deps) in dependencies {
            for dep in deps {
                guard containers.contains(dep) else {
                    throw TestContainersError.invalidDependency(
                        dependent: dependent,
                        dependency: dep,
                        reason: "Dependency '\(dep)' not found in stack"
                    )
                }
                adjList[dep, default: []].insert(dependent)
                inDegree[dependent, default: 0] += 1
            }
        }

        // Kahn's algorithm
        var queue: [String] = inDegree.filter { $0.value == 0 }.map { $0.key }
        var result: [String] = []

        while !queue.isEmpty {
            let node = queue.removeFirst()
            result.append(node)

            for neighbor in adjList[node, default: []] {
                inDegree[neighbor, default: 0] -= 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                }
            }
        }

        // Check for cycles
        if result.count != containers.count {
            let unvisited = containers.subtracting(result)
            throw TestContainersError.circularDependency(containers: Array(unvisited))
        }

        return result
    }
}
```

### Step 8: Update Error Types

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

Add new error cases:

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    // ... existing cases ...
    case containerNotFound(String, availableContainers: [String])
    case invalidDependency(dependent: String, dependency: String, reason: String)
    case circularDependency(containers: [String])
    case networkCreationFailed(String)

    public var description: String {
        switch self {
        // ... existing cases ...
        case let .containerNotFound(name, available):
            return "Container '\(name)' not found in stack. Available: \(available.joined(separator: ", "))"
        case let .invalidDependency(dependent, dependency, reason):
            return "Invalid dependency: '\(dependent)' depends on '\(dependency)' - \(reason)"
        case let .circularDependency(containers):
            return "Circular dependency detected among containers: \(containers.joined(separator: ", "))"
        case let .networkCreationFailed(message):
            return "Failed to create Docker network: \(message)"
        }
    }
}
```

### Step 9: Add Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerStackTests.swift` (new)

```swift
import Testing
import TestContainers

@Test func stackBuilderPattern() {
    let stack = ContainerStack()
        .withContainer("db", ContainerRequest(image: "postgres:15"))
        .withContainer("app", ContainerRequest(image: "app:latest"))
        .withDependency("app", dependsOn: "db")

    #expect(stack.containers.count == 2)
    #expect(stack.dependencies["app"] == ["db"])
}

@Test func stackValidation_missingDependency() throws {
    let stack = ContainerStack()
        .withContainer("app", ContainerRequest(image: "app:latest"))
        .withDependency("app", dependsOn: "db") // db doesn't exist

    #expect(throws: TestContainersError.self) {
        try stack.validate()
    }
}

@Test func stackValidation_circularDependency() throws {
    let stack = ContainerStack()
        .withContainer("a", ContainerRequest(image: "test:latest"))
        .withContainer("b", ContainerRequest(image: "test:latest"))
        .withDependency("a", dependsOn: "b")
        .withDependency("b", dependsOn: "a")

    #expect(throws: TestContainersError.self) {
        try stack.validate()
    }
}

@Test func topologicalSort_simpleChain() throws {
    let order = try DependencyGraph.topologicalSort(
        containers: ["a", "b", "c"],
        dependencies: ["b": ["a"], "c": ["b"]]
    )

    #expect(order.firstIndex(of: "a")! < order.firstIndex(of: "b")!)
    #expect(order.firstIndex(of: "b")! < order.firstIndex(of: "c")!)
}

@Test func topologicalSort_diamond() throws {
    let order = try DependencyGraph.topologicalSort(
        containers: ["a", "b", "c", "d"],
        dependencies: ["b": ["a"], "c": ["a"], "d": ["b", "c"]]
    )

    #expect(order.firstIndex(of: "a")! < order.firstIndex(of: "d")!)
    #expect(order.firstIndex(of: "b")! < order.firstIndex(of: "d")!)
    #expect(order.firstIndex(of: "c")! < order.firstIndex(of: "d")!)
}

@Test func networkConfig_builder() {
    let config = NetworkConfig(name: "test-net")
        .withDriver("bridge")
        .withInternal(true)

    #expect(config.name == "test-net")
    #expect(config.driver == "bridge")
    #expect(config.internal == true)
}
```

### Step 10: Add Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerStackIntegrationTests.swift` (new)

```swift
import Testing
import TestContainers

@Test func stackWithTwoContainers() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let stack = ContainerStack()
        .withContainer("redis",
            ContainerRequest(image: "redis:7")
                .withExposedPort(6379)
                .waitingFor(.tcpPort(6379))
        )
        .withContainer("nginx",
            ContainerRequest(image: "nginx:alpine")
                .withExposedPort(80)
                .waitingFor(.tcpPort(80))
        )

    try await withStack(stack) { running in
        let redis = try await running.container("redis")
        let nginx = try await running.container("nginx")

        #expect(try await redis.hostPort(6379) > 0)
        #expect(try await nginx.hostPort(80) > 0)
    }
}

@Test func stackWithDependencies() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let stack = ContainerStack()
        .withContainer("postgres",
            ContainerRequest(image: "postgres:15")
                .withExposedPort(5432)
                .withEnvironment(["POSTGRES_PASSWORD": "test"])
                .waitingFor(.logContains("database system is ready"))
        )
        .withContainer("app",
            ContainerRequest(image: "nginx:alpine")
                .withExposedPort(80)
                .waitingFor(.tcpPort(80))
        )
        .withDependency("app", dependsOn: "postgres")

    try await withStack(stack) { running in
        // Verify both containers are running
        let app = try await running.container("app")
        let db = try await running.container("postgres")

        #expect(try await app.hostPort(80) > 0)
        #expect(try await db.hostPort(5432) > 0)

        // Verify network exists
        #expect(running.networkName() != nil)
    }
}

@Test func stackNetworkCommunication() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let stack = ContainerStack()
        .withContainer("redis",
            ContainerRequest(image: "redis:7")
                .withExposedPort(6379)
                .waitingFor(.tcpPort(6379))
        )
        .withContainer("redis-cli",
            ContainerRequest(image: "redis:7")
                .withCommand(["sh", "-c", "sleep 5 && redis-cli -h redis ping"])
                .waitingFor(.logContains("PONG", timeout: .seconds(10)))
        )
        .withDependency("redis-cli", dependsOn: "redis")

    try await withStack(stack) { running in
        let client = try await running.container("redis-cli")
        let logs = try await client.logs()
        #expect(logs.contains("PONG"))
    }
}

@Test func stackCleanupOnError() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let stack = ContainerStack()
        .withContainer("failing",
            ContainerRequest(image: "nginx:alpine")
                .withExposedPort(9999)  // Won't open
                .waitingFor(.tcpPort(9999, timeout: .seconds(3)))
        )

    await #expect(throws: TestContainersError.self) {
        try await withStack(stack) { _ in }
    }

    // Verify containers are cleaned up (would need Docker client to verify)
}
```

### Step 11: Documentation

- Add comprehensive doc comments to all public APIs
- Create examples directory with common stack patterns
- Update README.md with stack usage examples
- Document network communication patterns
- Add troubleshooting guide for multi-container scenarios

---

## Testing Plan

### Unit Tests

1. **ContainerStack Builder Tests**
   - Test all builder methods return new instances (immutability)
   - Test container addition and retrieval
   - Test dependency declaration
   - Test network and volume configuration
   - Test Hashable conformance

2. **Validation Tests**
   - Missing dependency reference detection
   - Circular dependency detection
   - Container name uniqueness
   - Empty stack handling

3. **Dependency Graph Tests**
   - Topological sort correctness
   - Simple chain (A → B → C)
   - Diamond dependency (B,C → A; D → B,C)
   - Multiple independent chains
   - Cycle detection

4. **Network Configuration Tests**
   - NetworkConfig builder pattern
   - VolumeConfig builder pattern
   - Default values

### Integration Tests

1. **Basic Multi-Container Stack**
   - Start 2-3 independent containers
   - Verify all containers running
   - Verify proper cleanup

2. **Dependency Ordering**
   - Stack with A → B → C dependencies
   - Verify startup order (logs/timestamps)
   - Verify shutdown order (reverse)

3. **Network Communication**
   - Two containers on shared network
   - Container A can reach Container B by name
   - Verify DNS resolution works

4. **Error Handling**
   - Container fails to start: verify cleanup of already-started containers
   - Wait strategy timeout: verify cleanup
   - Task cancellation: verify cleanup

5. **Complex Stack**
   - 5+ containers with multiple dependency levels
   - Parallel startup where possible
   - Verify performance (not serial startup)

6. **Host Port Access**
   - Access container via mapped host port
   - Verify endpoint returns valid host:port

### Manual Testing Checklist

- [ ] Test with realistic application stack (app + db + cache)
- [ ] Verify logs from multiple containers are distinguishable
- [ ] Test error messages are clear when container fails
- [ ] Test cleanup happens on Ctrl+C / test interruption
- [ ] Verify network isolation between different test stacks
- [ ] Performance test: 10 containers startup time
- [ ] Memory leak test: 100 stack start/stop cycles

---

## Acceptance Criteria

### Must Have

- [ ] `ContainerStack` struct with fluent builder API
- [ ] `withStack(_:_:)` helper function with scoped lifecycle
- [ ] `RunningStack` actor for accessing running containers
- [ ] Dependency declaration via `withDependency`
- [ ] Dependency validation (missing references, circular deps)
- [ ] Topological sort for startup ordering
- [ ] Automatic network creation and attachment
- [ ] Container references by name within stack
- [ ] Shared environment variables at stack level
- [ ] Proper cleanup on success, error, and cancellation
- [ ] Cleanup in reverse dependency order
- [ ] Docker network operations in DockerClient
- [ ] New error types for stack-specific failures
- [ ] Unit tests for dependency graph and validation
- [ ] Integration tests with real Docker containers
- [ ] Documentation for all public APIs

### Should Have

- [ ] Parallel container startup where dependencies allow
- [ ] Network aliases for DNS-based discovery
- [ ] Shared volume support
- [ ] Stack-level labels
- [ ] Clear error messages indicating which container failed
- [ ] Support for mixing custom networks and default bridge
- [ ] Performance test showing parallel startup

### Nice to Have

- [ ] Template variable substitution (e.g., `{{db.host}}`)
- [ ] Volume mount support in ContainerRequest
- [ ] Network driver customization
- [ ] Stack snapshots / state inspection
- [ ] Metrics (time to ready per container, total startup time)
- [ ] Retry logic for transient network failures
- [ ] Health checks for inter-container dependencies
- [ ] Support for external networks (don't create, just attach)

### Definition of Done

- All "Must Have" criteria completed
- All "Should Have" criteria completed
- All unit tests passing
- All integration tests passing
- Code review completed
- Documentation complete with examples
- No regressions in single-container API
- README includes multi-container examples
- FEATURES.md updated to mark as implemented
- Manually tested with realistic multi-service stack
- Performance validated (parallel startup works)

---

## Implementation Risks & Mitigations

### Risk 1: Docker Network Cleanup Failures

**Problem**: If tests fail or are interrupted, Docker networks may leak.

**Mitigation**:
- Use stack-level labels for cleanup tracking
- Implement cleanup on process exit (defer/signal handling)
- Add utility function to clean up orphaned test networks
- Use unique network names with timestamp/UUID
- Document manual cleanup: `docker network prune`

### Risk 2: Dependency Ordering Bugs

**Problem**: Complex dependency graphs might start containers in wrong order.

**Mitigation**:
- Thorough unit tests for topological sort
- Integration tests with known dependency patterns
- Add logging/instrumentation to track startup order
- Validate graph before starting any containers

### Risk 3: Container-to-Container Communication Failures

**Problem**: Containers can't reach each other despite shared network.

**Mitigation**:
- Document network alias requirements
- Provide clear examples of proper hostname usage
- Add integration test that verifies DNS resolution
- Document common pitfalls (using 127.0.0.1 instead of container name)

### Risk 4: Performance Degradation with Large Stacks

**Problem**: Many containers might start slowly even with parallel execution.

**Mitigation**:
- Implement parallel startup for independent containers
- Add timeout configuration at stack level
- Benchmark and optimize critical path
- Document best practices for large stacks

### Risk 5: Complex Error Messages

**Problem**: Nested errors from multiple containers could be confusing.

**Mitigation**:
- Include container name in all error messages
- Show startup stage (creating, starting, waiting)
- Collect errors from all containers before failing
- Provide summary of which containers succeeded vs. failed

---

## Future Enhancements

### Beyond Initial Implementation

1. **Docker Compose File Import**
   - Parse `docker-compose.yml` files
   - Convert to `ContainerStack` configuration
   - Support subset of Compose features

2. **Template Variable Substitution**
   - Reference other containers' endpoints: `{{db.endpoint}}`
   - Runtime variable expansion
   - Type-safe variable references

3. **Stack Presets / Modules**
   - Pre-configured stacks (LAMP, MEAN, etc.)
   - `PostgresStack()`, `KafkaStack()` helpers
   - Composable stack fragments

4. **Advanced Wait Strategies**
   - Wait for container A to reach state before starting B
   - Health check dependencies
   - Custom readiness predicates across containers

5. **Resource Sharing**
   - Shared tmpfs mounts
   - Volume population from one container to another
   - Named volume lifecycle tied to stack

6. **Observability**
   - Stack-level logging aggregation
   - Startup timeline visualization
   - Resource usage metrics (CPU, memory per container)

7. **Stack Reuse**
   - Keep stack running across multiple tests
   - Reset state between tests (database cleanup, cache flush)
   - Significant speedup for integration test suites

8. **External Service Integration**
   - Reference external services (existing Docker containers)
   - Mix TestContainers with manually managed infrastructure
   - Support for Docker Compose services

---

## Related Work

### References

- **testcontainers-java**: `DockerComposeContainer`, `Network` class
- **testcontainers-go**: `docker.Network`, `NetworkRequest`, container dependencies
- **testcontainers-node**: `docker-compose` module
- **Docker Compose**: Reference for multi-container orchestration patterns
- **Swift Structured Concurrency**: `withThrowingTaskGroup` for parallel execution

### Dependencies

- Existing `DockerClient` for Docker CLI operations
- Existing `Container` actor for individual container management
- Existing `withContainer` pattern for scoped lifecycle
- Existing wait strategies for container readiness

### Similar Implementations

- **testcontainers-go**:
  ```go
  network, _ := network.New(ctx)
  postgres, _ := postgres.RunContainer(ctx, network)
  app, _ := app.RunContainer(ctx, network, postgres)
  ```

- **testcontainers-java**:
  ```java
  Network network = Network.newNetwork();
  GenericContainer postgres = new GenericContainer("postgres")
      .withNetwork(network)
      .withNetworkAliases("postgres");
  GenericContainer app = new GenericContainer("app")
      .withNetwork(network);
  ```

---

## Questions & Decisions

### Open Questions

1. Should we support volume mounts in initial implementation or defer?
   - **Decision**: Defer to follow-up feature (012-volume-mounts integration)

2. Should network be created automatically or require explicit configuration?
   - **Decision**: Automatic by default, with opt-out via `NetworkConfig`

3. How to handle port conflicts between stacks in parallel tests?
   - **Decision**: Use random host port mapping (existing behavior), document best practices

4. Should we validate container images exist before starting?
   - **Decision**: Defer to image pull policy feature, rely on Docker's behavior initially

5. Maximum stack size (number of containers)?
   - **Decision**: No artificial limit, trust Docker's limits

### Decided

- Use actor pattern for `RunningStack` (consistent with `Container`)
- Automatic network creation by default
- Reverse dependency order for cleanup
- Fail fast on first container startup failure
- No support for `docker-compose.yml` in v1 (future enhancement)
- Parallel startup for containers without dependencies
- Stack-level labels for identification and cleanup

---

## Sign-off

**Proposed by**: Feature request (FEATURES.md Tier 3)
**Reviewed by**: TBD
**Approved by**: TBD
**Target milestone**: Post-MVP

---

**Last updated**: 2025-12-15
