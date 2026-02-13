# Feature: Parallel Test Safety

## Summary

Implement comprehensive parallel test safety guidance and API improvements for swift-test-containers to ensure safe concurrent test execution. This feature addresses port collisions, container name conflicts, and test isolation challenges when running multiple test suites in parallel with `swift test --parallel` or with swift-testing's built-in parallelism.

**Key capabilities:**
- Automatic unique container naming with UUID/timestamp generation
- Guaranteed random port allocation to prevent port collisions
- Test isolation best practices and documentation
- Thread-safe container lifecycle management
- Guidance for parallel test execution patterns

## Current State

### Container Naming

**Location**: `/Sources/TestContainers/ContainerRequest.swift:28-50`

```swift
public struct ContainerRequest: Sendable, Hashable {
    public var image: String
    public var name: String?  // Optional, defaults to nil
    // ...

    public init(image: String) {
        self.image = image
        self.name = nil  // No automatic unique naming
        // ...
    }

    public func withName(_ name: String) -> Self {
        var copy = self
        copy.name = name
        return copy
    }
}
```

**Docker container creation** (`/Sources/TestContainers/DockerClient.swift:28-54`):
```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    if let name = request.name {
        args += ["--name", name]  // Name only used if explicitly set
    }
    // ...
}
```

**Issues:**
- No automatic unique naming - Docker generates random names like "flamboyant_galileo" if not specified
- If users explicitly set names without making them unique, parallel tests will fail with name conflicts
- No built-in mechanism to ensure uniqueness across parallel test runs

### Port Allocation

**Location**: `/Sources/TestContainers/ContainerRequest.swift:3-18`

```swift
public struct ContainerPort: Hashable, Sendable {
    public var containerPort: Int
    public var hostPort: Int?  // Optional host port

    public init(containerPort: Int, hostPort: Int? = nil) {
        self.containerPort = containerPort
        self.hostPort = hostPort
    }

    var dockerFlag: String {
        if let hostPort {
            return "\(hostPort):\(containerPort)"  // Fixed mapping if specified
        }
        return "\(containerPort)"  // Random port if nil (GOOD for parallel safety)
    }
}
```

**Port usage example** (`/Tests/TestContainersTests/DockerIntegrationTests.swift:9-11`):
```swift
let request = ContainerRequest(image: "redis:7")
    .withExposedPort(6379)  // No hostPort = random allocation (GOOD)
    .waitingFor(.tcpPort(6379, timeout: .seconds(30)))
```

**Good news:**
- Default behavior (`hostPort: nil`) already uses Docker's random port allocation via `-p <containerPort>`
- This prevents port collisions when running parallel tests
- `container.hostPort(_:)` correctly retrieves the dynamically assigned port

**Risk areas:**
- Users might explicitly set `hostPort` in tests, causing collisions
- No documentation warning against fixed port mappings
- Example tests don't demonstrate parallel-safe patterns

### Container Lifecycle

**Location**: `/Sources/TestContainers/WithContainer.swift:3-30`

```swift
public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    // ...
    let id = try await docker.runContainer(request)
    let container = Container(id: id, request: request, docker: docker)

    let cleanup: () -> Void = { _ = Task { try? await container.terminate() } }

    return try await withTaskCancellationHandler {
        do {
            try await container.waitUntilReady()
            let result = try await operation(container)
            try await container.terminate()  // Always cleaned up
            return result
        } catch {
            try? await container.terminate()
            throw error
        }
    } onCancel: {
        cleanup()  // Cleanup on cancellation
    }
}
```

**Good news:**
- `withContainer` ensures cleanup in all code paths (success, error, cancellation)
- `Container` is an actor, providing thread-safe access
- `DockerClient` is an actor, preventing race conditions in Docker CLI calls
- Lifecycle is properly scoped and doesn't leak containers

**Current isolation:**
- Each test gets its own container instance
- Docker containers are isolated at the OS level
- No shared state between containers

### Test Infrastructure

**Location**: `/Tests/TestContainersTests/DockerIntegrationTests.swift`

```swift
@Test func canStartContainer_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)  // Random port allocation
        .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)  // Get dynamic port
        #expect(port > 0)
        let endpoint = try await container.endpoint(for: 6379)
        #expect(endpoint.contains(":"))
    }
}
```

**Current test patterns:**
- Tests use default port allocation (good for parallelism)
- No tests currently verify parallel safety
- No tests intentionally create conflicts to verify isolation
- Swift testing with `@Test` macro is parallel-safe by default

### Labels for Container Tracking

**Location**: `/Sources/TestContainers/ContainerRequest.swift:41`

```swift
public init(image: String) {
    // ...
    self.labels = ["testcontainers.swift": "true"]  // Default label
    // ...
}
```

**Current labeling:**
- All containers get `testcontainers.swift=true` label
- No session ID or test-specific labels
- Could be enhanced for better cleanup/tracking

## Requirements

### Core Functionality

1. **Automatic Unique Container Naming**
   - Generate unique container names by default
   - Format: `tc-swift-<timestamp>-<uuid-short>` or similar
   - Allow users to override with custom names (with warning about parallel safety)
   - Ensure name generation is thread-safe

2. **Port Allocation Best Practices**
   - Document that `hostPort` should remain `nil` for parallel safety
   - Add warnings to `withExposedPort(_, hostPort:)` documentation
   - Create lint-friendly API that makes safe patterns obvious
   - Possibly add `withRandomPort(_:)` as explicit safe alternative

3. **Test Isolation Documentation**
   - Comprehensive guide for running tests in parallel
   - Common pitfalls and how to avoid them
   - Best practices for container naming
   - Port allocation strategies
   - Resource cleanup verification

4. **Session/Test Tracking Labels**
   - Add session ID label for identifying container groups
   - Add test name/ID label for debugging
   - Add timestamp label for cleanup tooling
   - Support custom labels for user tracking

5. **Parallel Safety Validation**
   - Test suite that runs multiple containers in parallel
   - Verify no port conflicts
   - Verify no name conflicts
   - Verify proper cleanup under load
   - Stress test with 10+ concurrent containers

### Non-Functional Requirements

1. **Performance**
   - Unique name generation should be fast (<1ms)
   - No performance degradation with parallel tests
   - Minimal overhead from additional labels

2. **Backward Compatibility**
   - Existing tests continue to work without changes
   - Optional opt-in for enhanced naming features
   - No breaking changes to public APIs

3. **Developer Experience**
   - Clear error messages when conflicts occur
   - Diagnostic information in test output
   - Easy-to-follow migration guide
   - Examples in README

## API Design

### Proposed Swift API Enhancements

#### 1. Automatic Unique Naming

```swift
// Add to ContainerRequest.swift
public struct ContainerRequest: Sendable, Hashable {
    public var image: String
    public var name: String?
    public var autoGenerateName: Bool  // NEW
    // ...

    public init(image: String) {
        self.image = image
        self.name = nil
        self.autoGenerateName = true  // NEW: Auto-generate by default
        // ...
    }

    public func withName(_ name: String, autoGenerate: Bool = false) -> Self {
        var copy = self
        copy.name = name
        copy.autoGenerateName = autoGenerate
        return copy
    }

    // NEW: Explicit control for parallel safety
    public func withAutoGeneratedName(_ prefix: String = "tc-swift") -> Self {
        var copy = self
        copy.autoGenerateName = true
        copy.name = prefix
        return copy
    }

    // NEW: Disable auto-generation (e.g., for debugging)
    public func withFixedName(_ name: String) -> Self {
        var copy = self
        copy.name = name
        copy.autoGenerateName = false
        return copy
    }

    // INTERNAL: Generate unique name when needed
    func resolvedName() -> String? {
        guard let baseName = name, autoGenerateName else {
            return name
        }
        return ContainerNameGenerator.generateUniqueName(prefix: baseName)
    }
}
```

#### 2. Container Name Generator

```swift
// NEW: Sources/TestContainers/ContainerNameGenerator.swift
import Foundation

enum ContainerNameGenerator {
    static func generateUniqueName(prefix: String = "tc-swift") -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let uuid = UUID().uuidString.prefix(8).lowercased()
        return "\(prefix)-\(timestamp)-\(uuid)"
    }

    static func generateSessionID() -> String {
        return UUID().uuidString
    }
}
```

#### 3. Enhanced Labels

```swift
// Add to ContainerRequest.swift
extension ContainerRequest {
    // NEW: Add test tracking labels
    public func withTestLabels(testName: String? = nil, sessionID: String? = nil) -> Self {
        var copy = self

        if let testName {
            copy.labels["testcontainers.swift.test"] = testName
        }

        if let sessionID {
            copy.labels["testcontainers.swift.session"] = sessionID
        }

        copy.labels["testcontainers.swift.timestamp"] = "\(Int(Date().timeIntervalSince1970))"

        return copy
    }
}
```

#### 4. Port Allocation Helpers

```swift
// Add to ContainerRequest.swift
extension ContainerRequest {
    /// Expose a container port with Docker's random port allocation (parallel-safe).
    /// This is the recommended approach for tests that may run in parallel.
    public func withExposedPort(_ containerPort: Int) -> Self {
        // Existing implementation (already safe)
    }

    /// Expose a container port with a fixed host port (NOT parallel-safe).
    ///
    /// ⚠️ Warning: Fixed port mappings can cause conflicts when running tests in parallel.
    /// Only use this when you have external requirements for specific ports.
    /// For parallel-safe tests, use `withExposedPort(_:)` without specifying a host port.
    public func withExposedPort(_ containerPort: Int, hostPort: Int) -> Self {
        // Existing implementation with enhanced documentation
    }

    /// NEW: Explicitly indicate random port allocation (self-documenting API)
    public func withRandomPort(_ containerPort: Int) -> Self {
        return withExposedPort(containerPort, hostPort: nil)
    }
}
```

#### 5. Parallel Safety Configuration

```swift
// NEW: Sources/TestContainers/ParallelSafetyConfig.swift
public struct ParallelSafetyConfig: Sendable {
    public var autoGenerateNames: Bool
    public var sessionID: String?
    public var validatePortAllocation: Bool

    public static let `default` = ParallelSafetyConfig(
        autoGenerateNames: true,
        sessionID: nil,
        validatePortAllocation: true
    )

    public static let strict = ParallelSafetyConfig(
        autoGenerateNames: true,
        sessionID: ContainerNameGenerator.generateSessionID(),
        validatePortAllocation: true
    )
}

// Add to ContainerRequest
extension ContainerRequest {
    public func withParallelSafety(_ config: ParallelSafetyConfig = .default) -> Self {
        var copy = self
        copy.autoGenerateName = config.autoGenerateNames

        if let sessionID = config.sessionID {
            copy.labels["testcontainers.swift.session"] = sessionID
        }

        // Validate no fixed ports if validation enabled
        if config.validatePortAllocation {
            for port in copy.ports where port.hostPort != nil {
                print("⚠️ Warning: Fixed host port \(port.hostPort!) may cause conflicts in parallel tests")
            }
        }

        return copy
    }
}
```

### Usage Examples

#### Example 1: Basic Parallel-Safe Test (Recommended)

```swift
import Testing
import TestContainers

@Test func parallelSafeRedisTest() async throws {
    // Default behavior is already parallel-safe:
    // - Random port allocation
    // - Auto-generated unique name (after this feature)
    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)  // Random port
        .waitingFor(.tcpPort(6379))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        // Connect using dynamic port
        let endpoint = try await container.endpoint(for: 6379)
        // Test logic...
    }
}
```

#### Example 2: Explicit Parallel Safety

```swift
@Test func explicitParallelSafety() async throws {
    let sessionID = ContainerNameGenerator.generateSessionID()

    let request = ContainerRequest(image: "postgres:15")
        .withExposedPort(5432)
        .withEnvironment(["POSTGRES_PASSWORD": "test"])
        .withParallelSafety(.strict)  // Explicit strict mode
        .withTestLabels(testName: "postgres-parallel-test", sessionID: sessionID)
        .waitingFor(.logContains("database system is ready to accept connections"))

    try await withContainer(request) { container in
        let port = try await container.hostPort(5432)
        // Test logic...
    }
}
```

#### Example 3: Multiple Containers in Parallel

```swift
@Test func multipleContainersInParallel() async throws {
    let sessionID = ContainerNameGenerator.generateSessionID()

    async let redis = withContainer(
        ContainerRequest(image: "redis:7")
            .withExposedPort(6379)
            .withTestLabels(sessionID: sessionID)
            .waitingFor(.tcpPort(6379))
    ) { container in
        try await container.endpoint(for: 6379)
    }

    async let postgres = withContainer(
        ContainerRequest(image: "postgres:15")
            .withExposedPort(5432)
            .withEnvironment(["POSTGRES_PASSWORD": "test"])
            .withTestLabels(sessionID: sessionID)
            .waitingFor(.logContains("ready to accept connections"))
    ) { container in
        try await container.endpoint(for: 5432)
    }

    let (redisEndpoint, postgresEndpoint) = try await (redis, postgres)
    // Both containers running in parallel safely
    // Test logic using both endpoints...
}
```

#### Example 4: Custom Prefix for Debugging

```swift
@Test func customNamedContainer() async throws {
    let request = ContainerRequest(image: "nginx:latest")
        .withAutoGeneratedName("my-test-nginx")  // Becomes: my-test-nginx-1702834567-a3b8c9d2
        .withExposedPort(80)
        .waitingFor(.tcpPort(80))

    try await withContainer(request) { container in
        // Container has identifiable name for debugging
        print("Container ID: \(container.id)")
    }
}
```

#### Example 5: Fixed Name for Special Cases (NOT RECOMMENDED for parallel tests)

```swift
@Test func fixedNameContainer() async throws {
    // Only use for single-threaded tests or when external integration requires it
    let request = ContainerRequest(image: "redis:7")
        .withFixedName("specific-redis-instance")  // Disables auto-generation
        .withExposedPort(6379, hostPort: 6380)     // Fixed port (also risky)
        .waitingFor(.tcpPort(6379))

    try await withContainer(request) { container in
        // Test logic requiring specific name/port...
    }
}
```

## Implementation Steps

### 1. Create ContainerNameGenerator Module

**File**: `/Sources/TestContainers/ContainerNameGenerator.swift`

```swift
import Foundation

/// Generates unique container names for parallel test safety.
enum ContainerNameGenerator {
    /// Generates a unique container name with timestamp and UUID.
    ///
    /// Format: `<prefix>-<timestamp>-<uuid8>`
    /// Example: `tc-swift-1702834567-a3b8c9d2`
    static func generateUniqueName(prefix: String = "tc-swift") -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let uuid = UUID().uuidString.prefix(8).lowercased()
        return "\(prefix)-\(timestamp)-\(uuid)"
    }

    /// Generates a unique session ID for grouping containers.
    static func generateSessionID() -> String {
        return UUID().uuidString
    }
}
```

**Testing**:
- Verify uniqueness across multiple rapid calls
- Verify format matches expected pattern
- Verify thread-safety with concurrent calls

### 2. Enhance ContainerRequest with Auto-Naming

**File**: `/Sources/TestContainers/ContainerRequest.swift`

Changes:
1. Add `autoGenerateName: Bool` property (default `true`)
2. Add `withAutoGeneratedName(_:)` method
3. Add `withFixedName(_:)` method
4. Update `withName(_:)` to support auto-generation flag
5. Add internal `resolvedName()` method

**Testing**:
- Test default behavior generates unique names
- Test custom prefix works
- Test fixed name disables generation
- Test multiple requests get different names

### 3. Update DockerClient to Use Resolved Names

**File**: `/Sources/TestContainers/DockerClient.swift`

Update `runContainer` method:
```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    // Use resolved name (auto-generated if enabled)
    if let name = request.resolvedName() {
        args += ["--name", name]
    }

    // ... rest of implementation
}
```

**Testing**:
- Verify containers get unique names
- Verify Docker accepts generated names
- Verify no name conflicts in parallel execution

### 4. Add Test Tracking Labels

**File**: `/Sources/TestContainers/ContainerRequest.swift`

Add extension:
```swift
extension ContainerRequest {
    public func withTestLabels(testName: String? = nil, sessionID: String? = nil) -> Self {
        var copy = self

        if let testName {
            copy.labels["testcontainers.swift.test"] = testName
        }

        if let sessionID {
            copy.labels["testcontainers.swift.session"] = sessionID
        }

        copy.labels["testcontainers.swift.timestamp"] = "\(Int(Date().timeIntervalSince1970))"

        return copy
    }
}
```

**Testing**:
- Verify labels appear on containers
- Verify label values are correct
- Verify labels are queryable via `docker ps --filter`

### 5. Enhance Port Allocation Documentation

**File**: `/Sources/TestContainers/ContainerRequest.swift`

Update documentation for `withExposedPort` methods:
- Add warning about fixed ports in parallel tests
- Clarify random allocation behavior
- Add examples for both patterns

Optional: Add `withRandomPort(_:)` convenience method for clarity.

**Testing**:
- Documentation builds without errors
- Examples compile successfully

### 6. Create Parallel Safety Configuration

**File**: `/Sources/TestContainers/ParallelSafetyConfig.swift`

Implement configuration struct and integration with `ContainerRequest`.

**Testing**:
- Test default config
- Test strict config
- Test custom configurations
- Test validation warnings

### 7. Add Parallel Safety Tests

**File**: `/Tests/TestContainersTests/ParallelSafetyTests.swift`

```swift
import Testing
import TestContainers

@Test func containerNamesAreUnique() async throws {
    var names: Set<String> = []

    for _ in 0..<10 {
        let name = ContainerNameGenerator.generateUniqueName()
        #expect(!names.contains(name))
        names.insert(name)
    }
}

@Test func multipleContainersInParallel_noPorts() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let sessionID = ContainerNameGenerator.generateSessionID()

    // Start 5 Redis containers in parallel
    let results = try await withThrowingTaskGroup(of: String.self) { group in
        for i in 0..<5 {
            group.addTask {
                let request = ContainerRequest(image: "redis:7")
                    .withExposedPort(6379)
                    .withTestLabels(testName: "parallel-test-\(i)", sessionID: sessionID)
                    .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

                return try await withContainer(request) { container in
                    let endpoint = try await container.endpoint(for: 6379)
                    return endpoint
                }
            }
        }

        var endpoints: [String] = []
        for try await endpoint in group {
            endpoints.append(endpoint)
        }
        return endpoints
    }

    // Verify all containers got unique endpoints
    #expect(results.count == 5)
    #expect(Set(results).count == 5)  // All unique
}

@Test func multipleContainersInParallel_noNameConflicts() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Start 3 PostgreSQL containers in parallel
    let results = try await withThrowingTaskGroup(of: String.self) { group in
        for i in 0..<3 {
            group.addTask {
                let request = ContainerRequest(image: "postgres:15-alpine")
                    .withExposedPort(5432)
                    .withEnvironment(["POSTGRES_PASSWORD": "test\(i)"])
                    .waitingFor(.logContains("ready to accept connections"))

                return try await withContainer(request) { container in
                    return container.id
                }
            }
        }

        var ids: [String] = []
        for try await id in group {
            ids.append(id)
        }
        return ids
    }

    // Verify all containers got unique IDs (implies unique names)
    #expect(results.count == 3)
    #expect(Set(results).count == 3)
}

@Test func fixedNameCausesConflictInParallel() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // This test demonstrates the problem with fixed names
    // We expect one to succeed and one to fail

    let fixedName = "fixed-name-test-\(UUID().uuidString.prefix(8))"

    await #expect(throws: TestContainersError.self) {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let request = ContainerRequest(image: "redis:7")
                    .withFixedName(fixedName)
                    .withExposedPort(6379)

                try await withContainer(request) { _ in
                    try await Task.sleep(for: .seconds(2))
                }
            }

            group.addTask {
                try await Task.sleep(for: .milliseconds(100))  // Let first one start

                let request = ContainerRequest(image: "redis:7")
                    .withFixedName(fixedName)  // Same name!
                    .withExposedPort(6379)

                try await withContainer(request) { _ in
                    // This should fail due to name conflict
                }
            }

            try await group.waitForAll()
        }
    }
}
```

**File**: `/Tests/TestContainersTests/ContainerNameGeneratorTests.swift`

```swift
import Testing
import TestContainers

@Test func generateUniqueName_hasCorrectFormat() {
    let name = ContainerNameGenerator.generateUniqueName()

    #expect(name.hasPrefix("tc-swift-"))
    let parts = name.split(separator: "-")
    #expect(parts.count == 4)  // tc, swift, timestamp, uuid

    // Verify timestamp is numeric
    if let timestamp = Int(parts[2]) {
        #expect(timestamp > 0)
    } else {
        Issue.record("Timestamp is not numeric")
    }

    // Verify UUID portion is 8 hex chars
    let uuidPart = String(parts[3])
    #expect(uuidPart.count == 8)
}

@Test func generateUniqueName_withCustomPrefix() {
    let name = ContainerNameGenerator.generateUniqueName(prefix: "my-custom")
    #expect(name.hasPrefix("my-custom-"))
}

@Test func generateUniqueName_isUnique() {
    let name1 = ContainerNameGenerator.generateUniqueName()
    let name2 = ContainerNameGenerator.generateUniqueName()

    #expect(name1 != name2)
}

@Test func generateSessionID_isUUID() {
    let sessionID = ContainerNameGenerator.generateSessionID()

    // Should be valid UUID format
    #expect(UUID(uuidString: sessionID) != nil)
}

@Test func concurrentNameGeneration_producesUniqueNames() async throws {
    let names = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<100 {
            group.addTask {
                ContainerNameGenerator.generateUniqueName()
            }
        }

        var results: [String] = []
        for try await name in group {
            results.append(name)
        }
        return results
    }

    // All names should be unique
    #expect(names.count == 100)
    #expect(Set(names).count == 100)
}
```

### 8. Update Documentation

**File**: `/README.md`

Add section on parallel test safety:
```markdown
## Parallel Test Safety

swift-test-containers is designed for safe parallel test execution out of the box.

### Automatic Safeguards

1. **Unique Container Names**: Containers automatically get unique names (e.g., `tc-swift-1702834567-a3b8c9d2`)
2. **Random Port Allocation**: By default, Docker assigns random available ports
3. **Scoped Lifecycle**: `withContainer` ensures proper cleanup even in parallel execution

### Best Practices

**✅ DO: Use random port allocation (default)**
```swift
let request = ContainerRequest(image: "redis:7")
    .withExposedPort(6379)  // No hostPort = random allocation
```

**❌ DON'T: Use fixed host ports in parallel tests**
```swift
let request = ContainerRequest(image: "redis:7")
    .withExposedPort(6379, hostPort: 6380)  // Will conflict in parallel!
```

**✅ DO: Retrieve dynamic ports at runtime**
```swift
try await withContainer(request) { container in
    let port = try await container.hostPort(6379)
    let endpoint = try await container.endpoint(for: 6379)
    // Use dynamic port...
}
```

### Running Tests in Parallel

```bash
# Swift Testing runs tests in parallel by default
swift test

# Specify parallelism level
swift test --parallel --num-workers 4
```

### Multiple Containers in One Test

```swift
@Test func multipleServices() async throws {
    async let redis = withContainer(
        ContainerRequest(image: "redis:7")
            .withExposedPort(6379)
            .waitingFor(.tcpPort(6379))
    ) { container in
        try await container.endpoint(for: 6379)
    }

    async let postgres = withContainer(
        ContainerRequest(image: "postgres:15")
            .withExposedPort(5432)
            .withEnvironment(["POSTGRES_PASSWORD": "test"])
            .waitingFor(.logContains("ready to accept connections"))
    ) { container in
        try await container.endpoint(for: 5432)
    }

    let (redisEndpoint, postgresEndpoint) = try await (redis, postgres)
    // Both running safely in parallel
}
```

### Debugging Parallel Tests

Add labels to track containers:
```swift
let sessionID = ContainerNameGenerator.generateSessionID()

let request = ContainerRequest(image: "redis:7")
    .withTestLabels(testName: "my-test", sessionID: sessionID)
    .withExposedPort(6379)
```

List containers by session:
```bash
docker ps --filter "label=testcontainers.swift.session=<session-id>"
```
```

**File**: `/FEATURES.md`

Update line 92:
```markdown
- [x] Parallel test safety guidance (port collisions, unique naming)
```

### 9. Add Troubleshooting Guide

**File**: Create new documentation file or add to README

```markdown
## Troubleshooting Parallel Tests

### Name Conflicts

**Error**: `docker: Error response from daemon: Conflict. The container name "/my-container" is already in use...`

**Solution**: Remove `.withFixedName()` or ensure unique names per test.

### Port Conflicts

**Error**: `Error starting container: Bind for 0.0.0.0:8080 failed: port is already allocated`

**Solution**: Remove explicit `hostPort` parameter:
```swift
// Before (bad for parallel):
.withExposedPort(8080, hostPort: 8080)

// After (parallel-safe):
.withExposedPort(8080)
```

### Leaked Containers

**Issue**: Containers not cleaned up after test failures

**Investigation**:
```bash
# List all test containers
docker ps -a --filter "label=testcontainers.swift=true"

# Clean up leaked containers
docker rm -f $(docker ps -aq --filter "label=testcontainers.swift=true")
```

**Solution**: The library handles cleanup automatically via `withContainer`. If you see leaks:
1. Check for force-killed test processes
2. Verify `withContainer` is used (not manual container management)
3. Check Docker daemon logs for errors
```

## Testing Plan

### Unit Tests

1. **ContainerNameGenerator Tests** (`ContainerNameGeneratorTests.swift`)
   - [x] Verify unique name generation
   - [x] Verify correct format (prefix-timestamp-uuid)
   - [x] Verify custom prefix support
   - [x] Verify session ID generation
   - [x] Verify thread-safety (concurrent generation)
   - [x] Verify uniqueness across 100+ rapid calls

2. **ContainerRequest Auto-Naming Tests** (`ContainerRequestTests.swift`)
   - [x] Verify default auto-generation enabled
   - [x] Verify `withAutoGeneratedName()` behavior
   - [x] Verify `withFixedName()` disables generation
   - [x] Verify `resolvedName()` returns unique names
   - [x] Verify custom prefixes work
   - [x] Verify multiple requests get different names

3. **Label Tests** (`ContainerRequestTests.swift`)
   - [x] Verify test labels are added
   - [x] Verify session ID labels
   - [x] Verify timestamp labels
   - [x] Verify labels merge with existing labels

### Integration Tests

1. **Parallel Container Startup** (`ParallelSafetyTests.swift`)
   - [x] Start 5+ containers in parallel (same image)
   - [x] Verify all start successfully
   - [x] Verify all get unique endpoints
   - [x] Verify all get unique names
   - [x] Verify proper cleanup

2. **Different Images in Parallel** (`ParallelSafetyTests.swift`)
   - [x] Start Redis, PostgreSQL, nginx simultaneously
   - [x] Verify no conflicts
   - [x] Verify all reachable
   - [x] Verify proper cleanup

3. **Name Conflict Detection** (`ParallelSafetyTests.swift`)
   - [x] Test with fixed names (expect failure)
   - [x] Verify error message is clear
   - [x] Verify one container succeeds, second fails

4. **Port Allocation Stress Test** (`ParallelSafetyTests.swift`)
   - [x] Start 10+ containers with same exposed port
   - [x] Verify Docker assigns unique host ports
   - [x] Verify all containers accessible
   - [x] Verify no port conflicts

5. **Session Tracking** (`ParallelSafetyTests.swift`)
   - [x] Start containers with session ID
   - [x] Verify labels appear correctly
   - [x] Verify can filter by session

### Manual Testing Checklist

- [ ] Run `swift test --parallel` with integration tests enabled
- [ ] Verify no failures or conflicts
- [ ] Check `docker ps` shows unique container names
- [ ] Run tests with 10+ workers: `swift test --parallel --num-workers 10`
- [ ] Monitor system resources during parallel execution
- [ ] Test on macOS and Linux (if available)
- [ ] Test with Docker Desktop and Docker Engine
- [ ] Verify cleanup is complete after test run
- [ ] Test graceful handling of test interruption (Ctrl+C)
- [ ] Verify error messages are helpful for common mistakes

### Performance Testing

- [ ] Measure overhead of unique name generation (<1ms)
- [ ] Verify no slowdown with 20+ parallel containers
- [ ] Check Docker daemon load during parallel tests
- [ ] Measure cleanup time with many containers

## Acceptance Criteria

### Must Have

- [x] `ContainerNameGenerator` module implemented
- [x] Automatic unique name generation enabled by default
- [x] `autoGenerateName` property in `ContainerRequest`
- [x] `withAutoGeneratedName(_:)` method
- [x] `withFixedName(_:)` method
- [x] `resolvedName()` internal method
- [x] `DockerClient.runContainer` uses resolved names
- [x] Test labels support (`withTestLabels`)
- [x] Session ID tracking
- [x] Timestamp labels
- [x] Enhanced documentation for port allocation
- [x] Warning documentation for fixed ports
- [x] Unit tests for name generation (>90% coverage)
- [x] Integration tests for parallel execution
- [x] Test demonstrating name conflict handling
- [x] Test demonstrating parallel safety (5+ containers)
- [x] README section on parallel test safety
- [x] Best practices documentation
- [x] Troubleshooting guide

### Should Have

- [x] `ParallelSafetyConfig` struct
- [x] `withParallelSafety(_:)` configuration method
- [x] Validation warnings for fixed ports
- [x] `withRandomPort(_:)` convenience method
- [x] Session-based container grouping examples
- [x] Stress test with 10+ containers
- [x] Cross-platform testing (macOS and Linux)
- [x] Performance benchmarks for name generation

### Nice to Have

- [ ] Global session ID for entire test run
- [ ] Automatic cleanup tool for leaked containers by session
- [ ] Performance metrics in test output
- [ ] Container count metrics per test
- [ ] Visual diagram of parallel execution patterns
- [ ] Integration with swift-testing's test metadata
- [ ] Custom name validation (character restrictions, length limits)
- [ ] Name collision detection before Docker call
- [ ] Automatic port range restriction for tests

### Definition of Done

- All "Must Have" and "Should Have" criteria completed
- All tests passing on macOS
- If Linux environment available, tests passing on Linux
- Code review completed
- Documentation reviewed and tested
- Manual testing completed (at least 5 parallel test runs)
- No regressions in existing tests
- README updated with clear examples and warnings
- Troubleshooting section comprehensive
- Performance validated (no significant overhead)
- Backward compatibility maintained (existing tests work unchanged)

## Implementation Timeline

### Phase 1: Core Name Generation (Week 1)
- Implement `ContainerNameGenerator`
- Update `ContainerRequest` with auto-naming
- Update `DockerClient` to use resolved names
- Unit tests for name generation

### Phase 2: Labels and Tracking (Week 1)
- Implement test labels
- Implement session ID tracking
- Unit tests for labels

### Phase 3: Testing and Validation (Week 2)
- Implement parallel safety integration tests
- Name conflict tests
- Port allocation stress tests
- Performance validation

### Phase 4: Documentation (Week 2)
- Update README with parallel safety section
- Add troubleshooting guide
- Update FEATURES.md
- Add inline documentation
- Review and polish all docs

### Phase 5: Polish and Review (Week 3)
- Code review feedback
- Performance optimization if needed
- Cross-platform testing
- Final manual testing
- Release notes preparation

## References

### Related Files

- `/Sources/TestContainers/ContainerRequest.swift` - Container configuration
- `/Sources/TestContainers/DockerClient.swift` - Docker CLI interaction
- `/Sources/TestContainers/Container.swift` - Container handle (actor)
- `/Sources/TestContainers/WithContainer.swift` - Scoped lifecycle management
- `/Tests/TestContainersTests/DockerIntegrationTests.swift` - Integration test patterns

### Similar Implementations

- **Testcontainers Java**:
  - Uses `DockerComposeContainer` for multi-container scenarios
  - Automatic network creation for isolation
  - Ryuk for cleanup

- **Testcontainers Go**:
  - `testcontainers.GenericContainer` with automatic cleanup
  - Random port allocation by default
  - Container name generation with prefix

- **Testcontainers Node**:
  - Automatic unique naming
  - Port mapping abstraction
  - Network isolation

### Swift Concurrency Considerations

- **Actors**: `Container` and `DockerClient` are actors (thread-safe by design)
- **Structured Concurrency**: `withThrowingTaskGroup` for parallel operations
- **Sendable**: All types conform to `Sendable` for data-race safety
- **Task Cancellation**: `withTaskCancellationHandler` ensures cleanup

### Docker CLI Reference

- `docker run --name <name>` - Naming containers
- `docker run -p <containerPort>` - Random port allocation
- `docker run -p <hostPort>:<containerPort>` - Fixed port mapping
- `docker port <container> <port>` - Port inspection
- `docker ps --filter "label=key=value"` - Label filtering
- `docker rm -f <container>` - Force remove

### Testing Frameworks

- **swift-testing**: Native parallelism, modern syntax
- **XCTest**: Traditional testing framework (serial by default, can enable parallel)

### Performance Considerations

- **UUID Generation**: ~1µs per call (negligible overhead)
- **Timestamp**: <1µs (very fast)
- **String Concatenation**: <1µs for short strings
- **Total Name Generation Overhead**: <5µs (acceptable)

### Security Considerations

- Container names are visible to other processes on the host
- Don't include sensitive information in container names or labels
- Session IDs don't need to be cryptographically secure (UUIDs are fine)
- Labels may be logged by Docker daemon

## Future Enhancements

### Post-MVP Ideas

1. **Container Reuse Pool**
   - Reuse containers across tests for faster execution
   - Requires safety guarantees (state reset, isolation)
   - Significant performance improvement for slow-starting containers

2. **Global Cleanup Daemon**
   - Background process to clean up leaked containers
   - Monitor containers by session/timestamp labels
   - Similar to Testcontainers' Ryuk

3. **Test Report Integration**
   - Container logs attached to failed tests
   - Performance metrics per container
   - Resource usage tracking

4. **Network Isolation**
   - Automatic network creation per test/session
   - Container-to-container communication helpers
   - Better isolation than host networking

5. **Smart Port Allocation**
   - Configurable port ranges for tests
   - Port pool management
   - Avoid ephemeral port conflicts

6. **Dependency Graph**
   - Define container dependencies
   - Ordered startup with wait conditions
   - Composable multi-container scenarios

## Questions and Risks

### Open Questions

1. **Backward Compatibility**: Should auto-naming be opt-in or opt-out?
   - **Decision**: Opt-out (auto-naming by default) for best parallel safety
   - Users can disable with `.withFixedName()` if needed

2. **Name Length Limits**: Docker has 63-character limit on container names
   - **Mitigation**: Keep prefix short, use 8-char UUID portion
   - Example: `tc-swift-1702834567-a3b8c9d2` = 32 chars (safe)

3. **Session ID Scope**: Per-test or per-test-run?
   - **Decision**: Flexible - user can choose
   - Provide both options in documentation

4. **Performance Impact**: Will name generation slow down tests?
   - **Analysis**: <5µs overhead per container (negligible)
   - Docker startup time (seconds) dominates

### Risks

1. **Breaking Changes**
   - **Risk**: Users relying on unnamed containers or specific naming patterns
   - **Mitigation**: Behavior change is additive (adds names where none existed)
   - **Impact**: Low - most users don't depend on container names

2. **Docker Name Collisions**
   - **Risk**: UUID collision (astronomically rare but possible)
   - **Mitigation**: Timestamp prefix makes collision nearly impossible
   - **Impact**: Very low probability

3. **Label Compatibility**
   - **Risk**: Old Docker versions might not support all label features
   - **Mitigation**: Labels are optional, failure to set labels shouldn't break tests
   - **Impact**: Low - modern Docker versions widely deployed

4. **Test Performance**
   - **Risk**: Parallel tests could overwhelm Docker daemon
   - **Mitigation**: Document recommended worker limits
   - **Impact**: Medium - needs performance testing

### Mitigation Strategies

1. **Extensive Testing**: Run parallel tests with 20+ workers to find limits
2. **Clear Documentation**: Warn about Docker daemon resource requirements
3. **Error Handling**: Graceful handling of Docker errors (name conflicts, etc.)
4. **Monitoring**: Add optional logging for debugging parallel execution
5. **Escape Hatch**: Provide `.withFixedName()` for users who need it

## Success Metrics

### Quantitative

- Zero parallel test failures due to name/port conflicts
- <1ms overhead for name generation
- 100% test cleanup rate in parallel execution
- Support for 20+ parallel containers on typical dev machine
- All unit and integration tests passing

### Qualitative

- Clear, helpful error messages for conflicts
- Intuitive API that guides users to safe patterns
- Comprehensive documentation with examples
- Positive feedback from early adopters
- Easy migration for existing users

## Appendix: Example Test Outputs

### Successful Parallel Execution

```
Test Suite 'All tests' started at 2024-12-15 10:30:00.000
Test Suite 'ParallelSafetyTests' started at 2024-12-15 10:30:00.100
Test Case 'multipleContainersInParallel_noPorts' started.
  [Container tc-swift-1702834567-a3b8c9d2] Starting redis:7
  [Container tc-swift-1702834568-b4c9d0e3] Starting redis:7
  [Container tc-swift-1702834568-c5d0e1f4] Starting redis:7
  [Container tc-swift-1702834568-d6e1f2g5] Starting redis:7
  [Container tc-swift-1702834569-e7f2g3h6] Starting redis:7
  All containers started successfully
  Endpoints: 127.0.0.1:55001, 127.0.0.1:55002, 127.0.0.1:55003, 127.0.0.1:55004, 127.0.0.1:55005
Test Case 'multipleContainersInParallel_noPorts' passed (3.456 seconds).
Test Suite 'ParallelSafetyTests' passed at 2024-12-15 10:30:03.556
```

### Name Conflict Detection

```
Test Case 'fixedNameCausesConflictInParallel' started.
  [Container fixed-name-test-a3b8c9d2] Starting redis:7
  [Container fixed-name-test-a3b8c9d2] ERROR: Name conflict
  Error: docker: Error response from daemon: Conflict. The container name "/fixed-name-test-a3b8c9d2" is already in use by container "abc123...". You have to remove (or rename) that container to be able to reuse that name.
Test Case 'fixedNameCausesConflictInParallel' passed (expected error).
```
