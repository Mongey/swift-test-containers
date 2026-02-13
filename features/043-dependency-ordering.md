# Feature 043: Dependency Ordering and Health/Wait Graph

**Status**: Proposed
**Priority**: Tier 3 (Advanced Features)
**Tracking**: FEATURES.md line 101 - "Dependency ordering + health/wait graph"

---

## Summary

Implement container dependency ordering with health/wait graph support for multi-container test scenarios. This feature enables declaring container dependencies, automatically starting containers in topological order, and waiting for each container's dependencies to be ready before starting dependent containers. This is essential for complex integration tests involving multiple interdependent services (e.g., application + database + message queue).

**Use cases:**
- Start database before application container
- Wait for message queue to be healthy before starting consumers
- Orchestrate complex multi-service test environments
- Ensure correct initialization order for interconnected services
- Prevent race conditions in multi-container test setups

---

## Current State

### Container Lifecycle Today

The library currently manages containers independently through the `withContainer()` scoped lifecycle function at `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`:

```swift
public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable(...)
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

### Current Limitations

1. **No Dependency Declaration**: Containers cannot declare dependencies on other containers
2. **Independent Startup**: All containers start independently without coordination
3. **Manual Orchestration**: Users must manually manage startup order with nested `withContainer` calls
4. **No Shared Lifecycle**: No way to manage multiple containers as a cohesive unit
5. **Race Conditions**: No guarantee that dependencies are ready before dependent containers start
6. **No Topology Validation**: No circular dependency detection or validation

### Current Workarounds

Users currently must manually orchestrate multi-container setups:

```swift
@Test func manualOrchestration() async throws {
    // Start database first
    try await withContainer(dbRequest) { db in
        // Then start application, manually passing DB connection info
        let appRequest = ContainerRequest(image: "myapp:latest")
            .withEnvironment([
                "DB_HOST": try await db.host(),
                "DB_PORT": String(try await db.hostPort(5432))
            ])

        try await withContainer(appRequest) { app in
            // Run tests
        }
    }
}
```

**Problems with manual orchestration:**
- Verbose and error-prone
- Doesn't scale to 3+ containers
- No automatic network setup between containers
- Hard to reuse configurations
- Manual environment variable passing

---

## Requirements

### Functional Requirements

1. **Dependency Declaration**
   - Declare container dependencies via builder method on `ContainerRequest`
   - Support multiple dependencies per container
   - Dependencies reference containers by identifier/name
   - Clear API for specifying what to wait for (started, healthy, ready)

2. **Topological Sort**
   - Automatically determine startup order from dependency graph
   - Start independent containers in parallel
   - Start dependent containers only after their dependencies are ready
   - Respect dependency chains (A → B → C starts in order A, B, C)

3. **Circular Dependency Detection**
   - Detect circular dependencies before starting any containers
   - Throw descriptive error indicating the cycle
   - Include all containers involved in the cycle in error message

4. **Health/Wait Graph**
   - Wait for each dependency's wait strategy to complete before starting dependent
   - Support different wait conditions per dependency
   - Inherit wait strategies from container definitions
   - Allow overriding wait behavior at dependency declaration

5. **Multi-Container Lifecycle**
   - New `withContainerGroup()` function for managing multiple containers
   - Automatic cleanup of all containers in dependency order (reverse topological)
   - Proper cleanup on error (stop started containers in reverse order)
   - Cancellation support (cleanup all containers on task cancellation)

6. **Container Communication**
   - Containers in a group should be able to reference each other
   - Access to container endpoints/ports from dependent containers
   - Automatic network setup for container-to-container communication
   - Environment variable injection for dependency connection info

### Non-Functional Requirements

1. **Performance**: Parallel startup where dependencies allow
2. **Type Safety**: Compile-time safety for container references where possible
3. **Error Handling**: Clear error messages for dependency failures
4. **Sendability**: All types remain `Sendable` for Swift concurrency
5. **Testability**: Design to allow both unit and integration testing
6. **Consistency**: Follow existing API patterns and conventions

---

## API Design

### Proposed API

#### 1. Dependency Declaration on ContainerRequest

```swift
// Extension to ContainerRequest
extension ContainerRequest {
    /// Declare that this container depends on another container
    public func dependsOn(_ containerName: String, waitFor: DependencyWaitStrategy = .ready) -> Self {
        var copy = self
        copy.dependencies.append(ContainerDependency(
            name: containerName,
            waitStrategy: waitFor
        ))
        return copy
    }

    /// Declare multiple dependencies at once
    public func dependsOn(_ containerNames: [String], waitFor: DependencyWaitStrategy = .ready) -> Self {
        var copy = self
        for name in containerNames {
            copy.dependencies.append(ContainerDependency(
                name: name,
                waitStrategy: waitFor
            ))
        }
        return copy
    }
}

// Add to ContainerRequest struct
public struct ContainerRequest: Sendable, Hashable {
    // ... existing fields ...
    public var dependencies: [ContainerDependency]

    // Updated initializer
    public init(image: String) {
        // ... existing initialization ...
        self.dependencies = []
    }
}
```

#### 2. Dependency Wait Strategy

```swift
/// Defines what readiness condition to wait for on a dependency
public enum DependencyWaitStrategy: Sendable, Hashable {
    /// Wait for container to be started (docker run completes)
    case started

    /// Wait for container's configured wait strategy to succeed
    case ready

    /// Wait for container's health check to report healthy
    case healthy

    /// Custom wait strategy for this dependency (overrides container's default)
    case custom(WaitStrategy)
}

public struct ContainerDependency: Sendable, Hashable {
    public let name: String
    public let waitStrategy: DependencyWaitStrategy
}
```

#### 3. Container Group Management

```swift
/// Represents a group of containers with dependencies
public struct ContainerGroup: Sendable {
    public let containers: [String: ContainerRequest]

    public init(_ containers: [String: ContainerRequest]) {
        self.containers = containers
    }

    /// Validates the dependency graph (no cycles, all deps exist)
    public func validate() throws {
        try DependencyGraph.validate(containers)
    }

    /// Returns containers in topological order
    public func startOrder() throws -> [String] {
        try DependencyGraph.topologicalSort(containers)
    }
}

/// Scoped lifecycle for container groups
public func withContainerGroup<T>(
    _ group: ContainerGroup,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (ContainerGroupHandle) async throws -> T
) async throws -> T
```

#### 4. Container Group Handle

```swift
/// Handle for interacting with a running container group
public actor ContainerGroupHandle {
    private let containers: [String: Container]
    private let docker: DockerClient

    /// Get a specific container by name
    public func container(_ name: String) async throws -> Container {
        guard let container = containers[name] else {
            throw TestContainersError.containerNotFound(name)
        }
        return container
    }

    /// Get all container names
    public func containerNames() -> [String] {
        Array(containers.keys)
    }

    /// Terminate all containers in reverse dependency order
    public func terminateAll() async throws {
        // Implementation starts containers in reverse topological order
    }
}
```

#### 5. Dependency Graph Utilities

```swift
/// Internal utilities for dependency graph analysis
enum DependencyGraph {
    /// Validate graph has no cycles and all dependencies exist
    static func validate(_ containers: [String: ContainerRequest]) throws

    /// Returns containers in topological sort order
    static func topologicalSort(_ containers: [String: ContainerRequest]) throws -> [String]

    /// Detect cycles in dependency graph
    static func detectCycle(_ containers: [String: ContainerRequest]) throws
}
```

### Usage Examples

#### Example 1: Simple Database + Application

```swift
@Test func applicationWithDatabase() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let db = ContainerRequest(image: "postgres:16")
        .withName("postgres")
        .withEnvironment(["POSTGRES_PASSWORD": "test"])
        .withExposedPort(5432)
        .waitingFor(.healthCheck(timeout: .seconds(30)))

    let app = ContainerRequest(image: "myapp:latest")
        .withName("app")
        .withExposedPort(8080)
        .dependsOn("postgres", waitFor: .healthy)
        .waitingFor(.httpCheck(port: 8080, path: "/health"))

    let group = ContainerGroup([
        "postgres": db,
        "app": app
    ])

    try await withContainerGroup(group) { containers in
        let appContainer = try await containers.container("app")
        let endpoint = try await appContainer.endpoint(for: 8080)

        // Run tests against application
        #expect(!endpoint.isEmpty)
    }
}
```

#### Example 2: Complex Multi-Service Setup

```swift
@Test func microservicesSetup() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Database (no dependencies)
    let db = ContainerRequest(image: "postgres:16")
        .withName("database")
        .withEnvironment(["POSTGRES_PASSWORD": "test"])
        .withExposedPort(5432)
        .waitingFor(.healthCheck())

    // Message queue (no dependencies)
    let mq = ContainerRequest(image: "rabbitmq:3-management")
        .withName("rabbitmq")
        .withExposedPort(5672)
        .withExposedPort(15672)
        .waitingFor(.tcpPort(5672))

    // API service (depends on DB and MQ)
    let api = ContainerRequest(image: "api-service:latest")
        .withName("api")
        .withExposedPort(8080)
        .dependsOn(["database", "rabbitmq"], waitFor: .ready)
        .waitingFor(.http(HTTPWaitConfig(port: 8080).withPath("/ready")))

    // Worker service (depends on DB and MQ)
    let worker = ContainerRequest(image: "worker-service:latest")
        .withName("worker")
        .dependsOn(["database", "rabbitmq"], waitFor: .ready)
        .waitingFor(.logContains("Worker started"))

    // Frontend (depends on API)
    let frontend = ContainerRequest(image: "frontend:latest")
        .withName("frontend")
        .withExposedPort(3000)
        .dependsOn("api", waitFor: .ready)
        .waitingFor(.http(HTTPWaitConfig(port: 3000)))

    let group = ContainerGroup([
        "database": db,
        "rabbitmq": mq,
        "api": api,
        "worker": worker,
        "frontend": frontend
    ])

    // Validate before starting
    try group.validate()

    // Verify startup order
    let order = try group.startOrder()
    // Should start: [database, rabbitmq] → [api, worker] → [frontend]

    try await withContainerGroup(group) { containers in
        // All containers ready in dependency order
        let frontendContainer = try await containers.container("frontend")
        let frontendPort = try await frontendContainer.hostPort(3000)

        // Run integration tests
        #expect(frontendPort > 0)
    }
}
```

#### Example 3: Custom Wait Strategy on Dependency

```swift
@Test func customDependencyWait() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let db = ContainerRequest(image: "postgres:16")
        .withName("db")
        .withEnvironment(["POSTGRES_PASSWORD": "test"])
        .withExposedPort(5432)
        .waitingFor(.tcpPort(5432))  // Default wait: TCP only

    let app = ContainerRequest(image: "myapp:latest")
        .withName("app")
        .dependsOn("db", waitFor: .custom(.all([
            .tcpPort(5432),
            .logContains("database system is ready to accept connections")
        ])))  // Custom: wait for both TCP and log
        .waitingFor(.tcpPort(8080))

    let group = ContainerGroup(["db": db, "app": app])

    try await withContainerGroup(group) { containers in
        // App only started after DB is fully ready
        let app = try await containers.container("app")
        #expect(try await app.hostPort(8080) > 0)
    }
}
```

#### Example 4: Parallel Independent Containers

```swift
@Test func parallelStartup() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Three independent containers (no dependencies)
    let redis = ContainerRequest(image: "redis:7")
        .withName("redis")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379))

    let postgres = ContainerRequest(image: "postgres:16")
        .withName("postgres")
        .withEnvironment(["POSTGRES_PASSWORD": "test"])
        .withExposedPort(5432)
        .waitingFor(.tcpPort(5432))

    let mongo = ContainerRequest(image: "mongo:7")
        .withName("mongo")
        .withExposedPort(27017)
        .waitingFor(.tcpPort(27017))

    let group = ContainerGroup([
        "redis": redis,
        "postgres": postgres,
        "mongo": mongo
    ])

    let start = ContinuousClock.now

    try await withContainerGroup(group) { containers in
        // All three should start in parallel
        #expect(containers.containerNames().count == 3)
    }

    let elapsed = start.duration(to: ContinuousClock.now)

    // Should complete in ~max(individual times), not sum
    // Typically < 10 seconds for parallel vs ~15-20 for serial
    #expect(elapsed < .seconds(15))
}
```

---

## Implementation Steps

### Step 1: Add Dependencies to ContainerRequest

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

1. Add `ContainerDependency` struct
2. Add `DependencyWaitStrategy` enum
3. Add `dependencies` property to `ContainerRequest`
4. Add `dependsOn()` builder methods
5. Update `Hashable` conformance to include dependencies

**Estimated effort**: 2 hours

### Step 2: Implement Dependency Graph Utilities

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DependencyGraph.swift` (new)

1. Implement `validate()` function:
   - Check all dependency names reference existing containers
   - Detect circular dependencies using DFS
   - Throw descriptive errors with cycle path

2. Implement `topologicalSort()` function:
   - Kahn's algorithm or DFS-based approach
   - Return containers in startup order
   - Handle multiple valid orderings (deterministic tie-breaking)

3. Implement `detectCycle()` helper:
   - DFS with visited/visiting/visited states
   - Build cycle path for error messages
   - Return detailed cycle information

**Algorithm reference (Topological Sort using DFS)**:
```swift
enum DependencyGraph {
    static func topologicalSort(_ containers: [String: ContainerRequest]) throws -> [String] {
        var visited = Set<String>()
        var visiting = Set<String>()
        var result: [String] = []

        func visit(_ name: String) throws {
            if visited.contains(name) { return }

            if visiting.contains(name) {
                throw TestContainersError.circularDependency(buildCyclePath(from: name))
            }

            visiting.insert(name)

            let container = containers[name]!
            for dep in container.dependencies {
                guard containers[dep.name] != nil else {
                    throw TestContainersError.dependencyNotFound(dep.name, referencedBy: name)
                }
                try visit(dep.name)
            }

            visiting.remove(name)
            visited.insert(name)
            result.append(name)
        }

        for name in containers.keys.sorted() {  // Sorted for deterministic order
            try visit(name)
        }

        return result
    }
}
```

**Estimated effort**: 4 hours

### Step 3: Create ContainerGroup Type

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerGroup.swift` (new)

1. Define `ContainerGroup` struct
2. Implement `validate()` method (delegates to DependencyGraph)
3. Implement `startOrder()` method (delegates to DependencyGraph)
4. Add convenience initializers (dictionary, varargs)
5. Add `Sendable` conformance

**Estimated effort**: 2 hours

### Step 4: Create ContainerGroupHandle Actor

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerGroupHandle.swift` (new)

1. Define `ContainerGroupHandle` actor
2. Implement container storage and lookup
3. Implement `container(_:)` method
4. Implement `containerNames()` method
5. Implement `terminateAll()` method (reverse topological order)
6. Add internal initializer

**Estimated effort**: 2 hours

### Step 5: Implement withContainerGroup Lifecycle Function

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainerGroup.swift` (new)

1. Validate container group
2. Get topological order
3. Start containers in order:
   - Use `withThrowingTaskGroup` for parallel independent containers
   - For each container, wait for dependencies first
   - Start container using existing DockerClient
   - Wait for container's readiness
4. Create `ContainerGroupHandle`
5. Execute user operation
6. Cleanup all containers in reverse order
7. Handle errors and cancellation

**Pseudo-code structure**:
```swift
public func withContainerGroup<T>(
    _ group: ContainerGroup,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (ContainerGroupHandle) async throws -> T
) async throws -> T {
    // Validate
    try group.validate()
    let startOrder = try group.startOrder()

    // Build dependency readiness tracking
    var readyContainers: [String: Container] = [:]
    var readinessConditions: [String: CheckedContinuation<Void, Error>] = [:]

    return try await withTaskCancellationHandler {
        do {
            // Start containers in topological order
            for name in startOrder {
                let request = group.containers[name]!

                // Wait for dependencies to be ready
                for dep in request.dependencies {
                    try await waitForDependency(dep, in: readyContainers)
                }

                // Start this container
                let id = try await docker.runContainer(request)
                let container = Container(id: id, request: request, docker: docker)
                try await container.waitUntilReady()

                readyContainers[name] = container
            }

            // All containers started, run user operation
            let handle = ContainerGroupHandle(containers: readyContainers, docker: docker)
            let result = try await operation(handle)

            // Cleanup in reverse order
            try await cleanupContainers(readyContainers, order: startOrder.reversed())

            return result
        } catch {
            // Cleanup started containers on error
            try? await cleanupContainers(readyContainers, order: startOrder.reversed())
            throw error
        }
    } onCancel: {
        Task {
            try? await cleanupContainers(readyContainers, order: startOrder.reversed())
        }
    }
}
```

**Key challenges**:
- Parallel startup of independent containers while respecting dependencies
- Proper error handling and partial cleanup
- Waiting for dependency-specific wait strategies

**Estimated effort**: 8 hours

### Step 6: Implement Dependency Wait Logic

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift` (extend)

Add method to wait for a dependency based on `DependencyWaitStrategy`:

```swift
extension Container {
    func waitForDependencyStrategy(_ strategy: DependencyWaitStrategy) async throws {
        switch strategy {
        case .started:
            // Container is already started, no additional wait
            return

        case .ready:
            // Use container's configured wait strategy
            try await waitUntilReady()

        case .healthy:
            // Wait for health check (requires Feature 004)
            try await waitForHealth()

        case .custom(let waitStrategy):
            // Use custom wait strategy
            let originalStrategy = request.waitStrategy
            var modifiedRequest = request
            modifiedRequest.waitStrategy = waitStrategy

            let tempContainer = Container(id: id, request: modifiedRequest, docker: docker)
            try await tempContainer.waitUntilReady()
        }
    }
}
```

**Estimated effort**: 3 hours

### Step 7: Add Error Cases

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

Add new error cases:

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    // ... existing cases ...

    case circularDependency([String])  // Cycle path
    case dependencyNotFound(String, referencedBy: String)
    case containerNotFound(String)
    case emptyContainerGroup

    public var description: String {
        switch self {
        // ... existing cases ...

        case let .circularDependency(cycle):
            let path = cycle.joined(separator: " → ")
            return "Circular dependency detected: \(path) → \(cycle.first!)"

        case let .dependencyNotFound(dependency, container):
            return "Container '\(container)' depends on '\(dependency)', but '\(dependency)' is not in the group"

        case let .containerNotFound(name):
            return "Container '\(name)' not found in group"

        case .emptyContainerGroup:
            return "Container group is empty"
        }
    }
}
```

**Estimated effort**: 1 hour

### Step 8: Optimize Parallel Startup

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainerGroup.swift`

Enhance `withContainerGroup` to start independent containers in parallel:

1. Group containers by "level" (distance from leaf nodes)
2. Start all containers at the same level in parallel
3. Wait for entire level to complete before starting next level

**Algorithm**:
```swift
// Build levels (0 = no deps, 1 = depends on level 0, etc.)
func buildLevels(_ containers: [String: ContainerRequest]) -> [[String]] {
    var levels: [[String]] = []
    var assigned = Set<String>()

    while assigned.count < containers.count {
        var currentLevel: [String] = []

        for (name, request) in containers {
            if assigned.contains(name) { continue }

            // Check if all dependencies are assigned to previous levels
            let allDepsAssigned = request.dependencies.allSatisfy { assigned.contains($0.name) }

            if allDepsAssigned {
                currentLevel.append(name)
            }
        }

        if currentLevel.isEmpty {
            // This shouldn't happen if validation passed
            fatalError("Unable to determine startup levels")
        }

        levels.append(currentLevel)
        assigned.formUnion(currentLevel)
    }

    return levels
}

// Start containers level by level
for level in levels {
    try await withThrowingTaskGroup(of: (String, Container).self) { group in
        for name in level {
            group.addTask {
                let request = group.containers[name]!
                let id = try await docker.runContainer(request)
                let container = Container(id: id, request: request, docker: docker)
                try await container.waitUntilReady()
                return (name, container)
            }
        }

        for try await (name, container) in group {
            readyContainers[name] = container
        }
    }
}
```

**Estimated effort**: 4 hours

### Step 9: Add Network Setup (Optional Enhancement)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerGroup.swift`

Optionally create a shared Docker network for container group:

1. Add network name to `ContainerGroup`
2. Create network before starting containers
3. Attach all containers to network
4. Remove network after cleanup
5. Enable container-to-container communication via container names

**Note**: This step depends on network creation features (Tier 2 in FEATURES.md). Can be deferred to Phase 2.

**Estimated effort**: 6 hours (if implementing network support)

---

## Testing Plan

### Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DependencyGraphTests.swift` (new)

1. **Topological Sort Tests**
   ```swift
   @Test func topologicalSort_simpleChain() throws {
       let containers = [
           "a": ContainerRequest(image: "alpine").withName("a"),
           "b": ContainerRequest(image: "alpine").withName("b").dependsOn("a"),
           "c": ContainerRequest(image: "alpine").withName("c").dependsOn("b")
       ]

       let order = try DependencyGraph.topologicalSort(containers)

       #expect(order.firstIndex(of: "a")! < order.firstIndex(of: "b")!)
       #expect(order.firstIndex(of: "b")! < order.firstIndex(of: "c")!)
   }

   @Test func topologicalSort_diamond() throws {
       //     a
       //    / \
       //   b   c
       //    \ /
       //     d
       let containers = [
           "a": ContainerRequest(image: "alpine").withName("a"),
           "b": ContainerRequest(image: "alpine").withName("b").dependsOn("a"),
           "c": ContainerRequest(image: "alpine").withName("c").dependsOn("a"),
           "d": ContainerRequest(image: "alpine").withName("d").dependsOn(["b", "c"])
       ]

       let order = try DependencyGraph.topologicalSort(containers)

       #expect(order.firstIndex(of: "a")! < order.firstIndex(of: "b")!)
       #expect(order.firstIndex(of: "a")! < order.firstIndex(of: "c")!)
       #expect(order.firstIndex(of: "b")! < order.firstIndex(of: "d")!)
       #expect(order.firstIndex(of: "c")! < order.firstIndex(of: "d")!)
   }

   @Test func topologicalSort_independent() throws {
       let containers = [
           "a": ContainerRequest(image: "alpine").withName("a"),
           "b": ContainerRequest(image: "alpine").withName("b"),
           "c": ContainerRequest(image: "alpine").withName("c")
       ]

       let order = try DependencyGraph.topologicalSort(containers)

       #expect(order.count == 3)
       #expect(Set(order) == Set(["a", "b", "c"]))
   }
   ```

2. **Circular Dependency Detection**
   ```swift
   @Test func detectCycle_simple() throws {
       //  a → b → a
       let containers = [
           "a": ContainerRequest(image: "alpine").withName("a").dependsOn("b"),
           "b": ContainerRequest(image: "alpine").withName("b").dependsOn("a")
       ]

       #expect(throws: TestContainersError.circularDependency) {
           try DependencyGraph.topologicalSort(containers)
       }
   }

   @Test func detectCycle_complex() throws {
       //  a → b → c → d → b
       let containers = [
           "a": ContainerRequest(image: "alpine").withName("a").dependsOn("b"),
           "b": ContainerRequest(image: "alpine").withName("b").dependsOn("c"),
           "c": ContainerRequest(image: "alpine").withName("c").dependsOn("d"),
           "d": ContainerRequest(image: "alpine").withName("d").dependsOn("b")
       ]

       #expect(throws: TestContainersError.circularDependency) {
           try DependencyGraph.topologicalSort(containers)
       }
   }

   @Test func detectCycle_selfReference() throws {
       let containers = [
           "a": ContainerRequest(image: "alpine").withName("a").dependsOn("a")
       ]

       #expect(throws: TestContainersError.circularDependency) {
           try DependencyGraph.topologicalSort(containers)
       }
   }
   ```

3. **Validation Tests**
   ```swift
   @Test func validate_missingDependency() throws {
       let containers = [
           "a": ContainerRequest(image: "alpine").withName("a").dependsOn("b")
           // "b" doesn't exist
       ]

       #expect(throws: TestContainersError.dependencyNotFound) {
           try DependencyGraph.validate(containers)
       }
   }

   @Test func validate_emptyGroup() throws {
       let group = ContainerGroup([:])

       // Empty group is valid (though useless)
       try group.validate()
   }
   ```

4. **ContainerRequest Builder Tests**
   ```swift
   @Test func dependsOn_single() {
       let request = ContainerRequest(image: "alpine")
           .withName("app")
           .dependsOn("db")

       #expect(request.dependencies.count == 1)
       #expect(request.dependencies[0].name == "db")
       #expect(request.dependencies[0].waitStrategy == .ready)
   }

   @Test func dependsOn_multiple() {
       let request = ContainerRequest(image: "alpine")
           .withName("app")
           .dependsOn(["db", "cache"])

       #expect(request.dependencies.count == 2)
       #expect(request.dependencies.map(\.name).contains("db"))
       #expect(request.dependencies.map(\.name).contains("cache"))
   }

   @Test func dependsOn_customWait() {
       let request = ContainerRequest(image: "alpine")
           .withName("app")
           .dependsOn("db", waitFor: .healthy)

       #expect(request.dependencies[0].waitStrategy == .healthy)
   }
   ```

### Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerGroupIntegrationTests.swift` (new)

**Prerequisites**: All tests opt-in via `TESTCONTAINERS_RUN_DOCKER_TESTS=1`

1. **Simple Dependency Chain**
   ```swift
   @Test func containerGroup_simpleChain() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let db = ContainerRequest(image: "postgres:16")
           .withName("db")
           .withEnvironment(["POSTGRES_PASSWORD": "test"])
           .withExposedPort(5432)
           .waitingFor(.tcpPort(5432, timeout: .seconds(30)))

       let app = ContainerRequest(image: "alpine:3")
           .withName("app")
           .withCommand(["sleep", "10"])
           .dependsOn("db", waitFor: .ready)

       let group = ContainerGroup(["db": db, "app": app])

       try await withContainerGroup(group) { containers in
           let dbContainer = try await containers.container("db")
           let appContainer = try await containers.container("app")

           #expect(try await dbContainer.hostPort(5432) > 0)
           #expect(appContainer.id.count > 0)
       }
   }
   ```

2. **Parallel Independent Containers**
   ```swift
   @Test func containerGroup_parallelStartup() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let redis = ContainerRequest(image: "redis:7")
           .withName("redis")
           .withExposedPort(6379)
           .waitingFor(.tcpPort(6379))

       let postgres = ContainerRequest(image: "postgres:16")
           .withName("postgres")
           .withEnvironment(["POSTGRES_PASSWORD": "test"])
           .withExposedPort(5432)
           .waitingFor(.tcpPort(5432))

       let group = ContainerGroup(["redis": redis, "postgres": postgres])

       let start = ContinuousClock.now

       try await withContainerGroup(group) { containers in
           #expect(containers.containerNames().count == 2)
       }

       let elapsed = start.duration(to: ContinuousClock.now)

       // Should complete faster than serial startup
       // (exact timing depends on machine, but parallel should be noticeably faster)
       #expect(elapsed < .seconds(20))
   }
   ```

3. **Diamond Dependency**
   ```swift
   @Test func containerGroup_diamond() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       //       redis
       //      /     \
       //  alpine1  alpine2
       //      \     /
       //      alpine3

       let redis = ContainerRequest(image: "redis:7")
           .withName("redis")
           .withExposedPort(6379)
           .waitingFor(.tcpPort(6379))

       let alpine1 = ContainerRequest(image: "alpine:3")
           .withName("alpine1")
           .withCommand(["sleep", "10"])
           .dependsOn("redis")

       let alpine2 = ContainerRequest(image: "alpine:3")
           .withName("alpine2")
           .withCommand(["sleep", "10"])
           .dependsOn("redis")

       let alpine3 = ContainerRequest(image: "alpine:3")
           .withName("alpine3")
           .withCommand(["sleep", "10"])
           .dependsOn(["alpine1", "alpine2"])

       let group = ContainerGroup([
           "redis": redis,
           "alpine1": alpine1,
           "alpine2": alpine2,
           "alpine3": alpine3
       ])

       try await withContainerGroup(group) { containers in
           #expect(containers.containerNames().count == 4)
       }
   }
   ```

4. **Circular Dependency Failure**
   ```swift
   @Test func containerGroup_circularDependencyFails() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let a = ContainerRequest(image: "alpine:3")
           .withName("a")
           .withCommand(["sleep", "10"])
           .dependsOn("b")

       let b = ContainerRequest(image: "alpine:3")
           .withName("b")
           .withCommand(["sleep", "10"])
           .dependsOn("a")

       let group = ContainerGroup(["a": a, "b": b])

       await #expect(throws: TestContainersError.circularDependency) {
           try await withContainerGroup(group) { _ in }
       }
   }
   ```

5. **Error Cleanup Test**
   ```swift
   @Test func containerGroup_cleansUpOnError() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let db = ContainerRequest(image: "postgres:16")
           .withName("db")
           .withEnvironment(["POSTGRES_PASSWORD": "test"])
           .withExposedPort(5432)
           .waitingFor(.tcpPort(5432))

       let app = ContainerRequest(image: "alpine:3")
           .withName("app")
           .withCommand(["sleep", "10"])
           .dependsOn("db")

       let group = ContainerGroup(["db": db, "app": app])

       do {
           try await withContainerGroup(group) { containers in
               // Throw error during operation
               throw TestContainersError.timeout("simulated error")
           }
           #expect(Bool(false), "Should have thrown")
       } catch {
           // Expected error
       }

       // Verify containers were cleaned up
       // (Would need docker ps to verify, or check via DockerClient)
   }
   ```

6. **Custom Dependency Wait Strategy**
   ```swift
   @Test func containerGroup_customWaitStrategy() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let db = ContainerRequest(image: "postgres:16")
           .withName("db")
           .withEnvironment(["POSTGRES_PASSWORD": "test"])
           .withExposedPort(5432)
           .waitingFor(.tcpPort(5432))  // Default: just TCP

       let app = ContainerRequest(image: "alpine:3")
           .withName("app")
           .withCommand(["sleep", "5"])
           .dependsOn("db", waitFor: .custom(.logContains("database system is ready")))

       let group = ContainerGroup(["db": db, "app": app])

       try await withContainerGroup(group) { containers in
           let db = try await containers.container("db")
           let logs = try await db.logs()

           // App only started after log appeared
           #expect(logs.contains("database system is ready"))
       }
   }
   ```

### Manual Testing Checklist

- [ ] Test with 2-container setup (DB + app)
- [ ] Test with 5+ container setup (microservices)
- [ ] Test circular dependency error message clarity
- [ ] Test missing dependency error message clarity
- [ ] Test cleanup on cancellation (Ctrl+C during test)
- [ ] Test cleanup on error (exception during operation)
- [ ] Verify containers start in correct order (check docker ps timestamps)
- [ ] Verify parallel startup performance improvement
- [ ] Test on macOS and Linux
- [ ] Test with slow-starting containers (long wait strategies)

---

## Acceptance Criteria

### Definition of Done

- [ ] `ContainerRequest` has `dependencies` property and `dependsOn()` builder methods
- [ ] `ContainerDependency` and `DependencyWaitStrategy` types defined
- [ ] `DependencyGraph` utility with `topologicalSort()` and `validate()` implemented
- [ ] Circular dependency detection throws clear error with cycle path
- [ ] Missing dependency validation throws clear error
- [ ] `ContainerGroup` struct with validation and startup order
- [ ] `ContainerGroupHandle` actor for accessing running containers
- [ ] `withContainerGroup()` scoped lifecycle function
- [ ] Containers start in topological order
- [ ] Independent containers start in parallel
- [ ] Dependent containers wait for dependencies to be ready
- [ ] Dependency wait strategies honored (started, ready, healthy, custom)
- [ ] Cleanup happens in reverse topological order
- [ ] Error handling cleans up partially-started containers
- [ ] Cancellation support with proper cleanup
- [ ] All unit tests pass (topological sort, cycle detection, validation)
- [ ] All integration tests pass with real containers
- [ ] Error messages are clear and actionable
- [ ] Documentation updated (inline comments and examples)
- [ ] FEATURES.md updated to mark "Dependency ordering + health/wait graph" as implemented

### Success Metrics

1. **Correctness**: All integration tests pass with complex dependency graphs
2. **Performance**: Independent containers start in parallel (not serialized)
3. **Usability**: Users can define multi-container setups in <10 lines of fluent API
4. **Reliability**: Cleanup always happens even on error/cancellation
5. **Error Clarity**: Circular dependency errors include full cycle path

---

## Implementation Risks & Mitigations

### Risk 1: Parallel Execution Complexity

**Problem**: Managing parallel container startup with dependencies is complex with Swift structured concurrency.

**Mitigation**:
- Start with simple serial execution (topological order)
- Add parallel optimization in Phase 2
- Use `withThrowingTaskGroup` for structured concurrency
- Extensive integration testing

### Risk 2: Partial Cleanup on Error

**Problem**: If container N fails to start, containers 1..N-1 must be cleaned up properly.

**Mitigation**:
- Track all started containers in order
- Use `defer` or explicit cleanup blocks
- Clean up in reverse order
- Test error scenarios explicitly

### Risk 3: Dependency Wait Strategy Complexity

**Problem**: Different wait strategies per dependency adds complexity.

**Mitigation**:
- Start with simple `.ready` (use container's default wait strategy)
- Add `.started`, `.healthy`, `.custom` in subsequent phases
- Reuse existing `Container.waitUntilReady()` logic

### Risk 4: Network Setup (Future)

**Problem**: Container-to-container communication requires network setup.

**Mitigation**:
- Phase 1: Focus on dependency ordering only
- Phase 2: Add automatic network creation (depends on Tier 2 network features)
- Document current limitations clearly

### Risk 5: Performance with Large Graphs

**Problem**: 20+ container graphs might have performance issues.

**Mitigation**:
- Optimize topological sort (O(V+E) is acceptable)
- Parallel startup by "levels"
- Benchmark with 10, 20, 50 container graphs
- Document recommended limits

---

## Future Enhancements

### Phase 2: Advanced Features

1. **Automatic Network Creation**
   - Create shared Docker network for container group
   - Enable container-to-container communication via names
   - Auto-inject network connection info

2. **Environment Variable Injection**
   - Automatically inject dependency endpoints as env vars
   - Example: `DB_HOST=postgres`, `DB_PORT=5432`
   - Configurable template for env var names

3. **Health Monitoring**
   - Continuous health monitoring during test execution
   - Restart unhealthy containers
   - Alert on container failures

4. **Startup Profiling**
   - Track time to start each container
   - Identify slow-starting containers
   - Suggest optimizations

5. **Container Reuse**
   - Reuse container group across multiple tests
   - Faster test execution
   - Requires state reset between tests

6. **Declarative Configuration**
   - Load container group from YAML/JSON
   - Similar to docker-compose.yml
   - Easier configuration management

7. **Conditional Dependencies**
   - Start container only if condition met
   - Example: Start worker only if queue has messages
   - Dynamic dependency resolution

8. **Dependency Constraints**
   - Version constraints on dependencies
   - Compatibility checking
   - Warning on mismatched versions

---

## Related Work

### References

- **testcontainers-java**: Compose module with dependency support
- **testcontainers-go**: `docker.GenericNetwork` and manual orchestration
- **docker-compose**: Inspiration for `depends_on` and `healthcheck` integration
- **Kubernetes**: Pod initialization containers (init containers concept)

### Existing Files

- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` - Container configuration
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift` - Container runtime
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift` - Single container lifecycle
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift` - Docker CLI interface
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift` - Wait/poll logic

### Dependencies

- **Requires**: None (can be implemented standalone)
- **Enhances**: Feature 004 (Health Check Wait) for `.healthy` dependency wait strategy
- **Enhanced by**: Tier 2 Networking features for automatic network setup

---

## Priority & Effort Estimate

**Priority**: Tier 3 (Advanced Features)
**Complexity**: High

**Effort Breakdown**:
- Step 1 (Dependencies on ContainerRequest): 2 hours
- Step 2 (Dependency Graph): 4 hours
- Step 3 (ContainerGroup): 2 hours
- Step 4 (ContainerGroupHandle): 2 hours
- Step 5 (withContainerGroup): 8 hours
- Step 6 (Dependency Wait Logic): 3 hours
- Step 7 (Error Cases): 1 hour
- Step 8 (Parallel Optimization): 4 hours
- Testing (Unit + Integration): 8 hours
- Documentation: 2 hours

**Total Estimated Effort**: 36 hours (~5 days)

**Recommended Approach**:
1. **Phase 1** (MVP): Steps 1-7 (serial startup only) - 22 hours (~3 days)
2. **Phase 2** (Optimization): Step 8 (parallel startup) - 4 hours
3. **Phase 3** (Future): Network integration - 10+ hours (separate feature)

---

## Questions & Decisions

### Open Questions

1. Should empty container group be allowed?
   - **Decision**: Yes, for testing purposes (though not useful in practice)

2. Should we support "optional" dependencies (best-effort)?
   - **Decision**: Deferred to Phase 2. Start with hard dependencies only.

3. How to handle container restart during test execution?
   - **Decision**: Out of scope for Phase 1. Container failure = test failure.

4. Should we support weighted startup priority?
   - **Decision**: No. Topological order is sufficient.

5. Maximum container group size?
   - **Decision**: No hard limit. Document performance characteristics.

### Decided

- Use DFS-based topological sort (simpler than Kahn's algorithm)
- Serial startup in Phase 1, parallel in Phase 2
- Reverse topological order for cleanup
- Reuse existing `Container.waitUntilReady()` for dependency waits
- Explicit validation step before starting containers

---

**Last updated**: 2025-12-15
