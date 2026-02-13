# Feature 027: Scoped Network Lifecycle - `withNetwork(_:_:)`

## Summary

Implement a scoped network lifecycle function `withNetwork(_:_:)` that creates a Docker network, executes a closure with the network handle, and ensures cleanup on success, error, or cancellation. This mirrors the existing `withContainer(_:_:)` pattern and provides automatic resource management for Docker networks used in integration tests.

Networks are essential for container-to-container communication. The scoped approach ensures networks are always cleaned up, preventing resource leaks during test execution.

## Current State

### How `withContainer(_:_:)` Works

The codebase has a proven scoped lifecycle pattern in `/Sources/TestContainers/WithContainer.swift`:

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

**Key patterns:**
1. **Pre-flight check**: Verify Docker is available before creating resources
2. **Resource creation**: Create the resource (container) and get its ID
3. **Cleanup handler**: Define cleanup logic upfront for cancellation scenarios
4. **Scoped execution**: Use `withTaskCancellationHandler` to ensure cleanup
5. **Success path**: Run operation, cleanup, return result
6. **Error path**: Cleanup on error, re-throw
7. **Cancellation path**: Fire-and-forget cleanup task

### Existing Network Support

Networks are mentioned in `/FEATURES.md` (lines 66-71) under Tier 2:

```
**Networking**
- [ ] Create/remove networks (`docker network create/rm`)
- [ ] Attach container to network(s) on start
- [ ] Network aliases (container-to-container by name)
- [ ] Container-to-container communication helpers
- [ ] `withNetwork(_:_:)` scoped lifecycle
```

Currently, there is **no** network management code in the codebase. This feature is the foundation for network support.

## Requirements

### Functional Requirements

1. **Network Creation**: Create a Docker network with configurable driver and options
2. **Scoped Lifecycle**: Ensure network cleanup on success, error, and cancellation
3. **Network Handle**: Provide a `Network` type that exposes network ID and metadata
4. **Docker Availability Check**: Verify Docker is running before creating networks
5. **Error Handling**: Clear error messages for network creation/deletion failures
6. **Sendable Closure**: Support concurrent execution with `@Sendable` operation closure
7. **Generic Return Type**: Allow operation to return any type `T`
8. **Automatic Cleanup**: Remove network even if operation throws or task is cancelled

### Non-Functional Requirements

1. **Consistency**: Mirror the `withContainer(_:_:)` API design and implementation patterns
2. **Testability**: Support both unit and integration testing
3. **Reliability**: Handle cleanup failures gracefully (best-effort, no throw on cleanup)
4. **Performance**: Minimal overhead from network creation/deletion

## API Design

### Network Request Configuration

Add a new file `/Sources/TestContainers/NetworkRequest.swift`:

```swift
import Foundation

public struct NetworkRequest: Sendable, Hashable {
    public var name: String?
    public var driver: String
    public var labels: [String: String]
    public var options: [String: String]
    public var internal: Bool

    public init(name: String? = nil, driver: String = "bridge") {
        self.name = name
        self.driver = driver
        self.labels = ["testcontainers.swift": "true"]
        self.options = [:]
        self.internal = false
    }

    public func withName(_ name: String) -> Self {
        var copy = self
        copy.name = name
        return copy
    }

    public func withDriver(_ driver: String) -> Self {
        var copy = self
        copy.driver = driver
        return copy
    }

    public func withLabel(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.labels[key] = value
        return copy
    }

    public func withOption(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.options[key] = value
        return copy
    }

    public func asInternal() -> Self {
        var copy = self
        copy.internal = true
        return copy
    }
}
```

### Network Handle

Add a new file `/Sources/TestContainers/Network.swift`:

```swift
import Foundation

public actor Network {
    public let id: String
    public let request: NetworkRequest

    private let docker: DockerClient

    init(id: String, request: NetworkRequest, docker: DockerClient) {
        self.id = id
        self.request = request
        self.docker = docker
    }

    public func name() -> String? {
        request.name
    }

    public func remove() async throws {
        try await docker.removeNetwork(id: id)
    }
}
```

### Scoped Network Lifecycle Function

Add a new file `/Sources/TestContainers/WithNetwork.swift`:

```swift
import Foundation

public func withNetwork<T>(
    _ request: NetworkRequest = NetworkRequest(),
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Network) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable("`docker` CLI not found or Docker engine not running.")
    }

    let id = try await docker.createNetwork(request)
    let network = Network(id: id, request: request, docker: docker)

    let cleanup: () -> Void = { _ = Task { try? await network.remove() } }

    return try await withTaskCancellationHandler {
        do {
            let result = try await operation(network)
            try await network.remove()
            return result
        } catch {
            try? await network.remove()
            throw error
        }
    } onCancel: {
        cleanup()
    }
}
```

### Docker Client Network Operations

Extend `/Sources/TestContainers/DockerClient.swift`:

```swift
func createNetwork(_ request: NetworkRequest) async throws -> String {
    var args: [String] = ["network", "create"]

    if let name = request.name {
        args += ["--driver", request.driver]
    } else {
        args += ["--driver", request.driver]
    }

    for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
        args += ["--label", "\(key)=\(value)"]
    }

    for (key, value) in request.options.sorted(by: { $0.key < $1.key }) {
        args += ["--opt", "\(key)=\(value)"]
    }

    if request.internal {
        args += ["--internal"]
    }

    if let name = request.name {
        args.append(name)
    } else {
        // Docker auto-generates name if not provided
        // We still pass no name to get a random one
    }

    let output = try await runDocker(args)
    let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { throw TestContainersError.unexpectedDockerOutput(output.stdout) }
    return id
}

func removeNetwork(id: String) async throws {
    _ = try await runDocker(["network", "rm", id])
}
```

### Usage Examples

```swift
// Basic usage - auto-generated network name
try await withNetwork { network in
    print("Created network: \(network.id)")
    // Use network in tests
}

// Named network with custom driver
let request = NetworkRequest()
    .withName("my-test-network")
    .withDriver("bridge")

try await withNetwork(request) { network in
    // Network is available for container connections
}

// Multiple containers on same network
try await withNetwork { network in
    let redisRequest = ContainerRequest(image: "redis:7")
        .withNetwork(network.id)  // Future feature: attach to network

    let appRequest = ContainerRequest(image: "myapp:latest")
        .withNetwork(network.id)

    try await withContainer(redisRequest) { redis in
        try await withContainer(appRequest) { app in
            // Both containers can communicate
        }
    }
}

// Internal network (no external access)
let internalNet = NetworkRequest()
    .withName("isolated-net")
    .asInternal()

try await withNetwork(internalNet) { network in
    // Network isolated from external traffic
}
```

## Implementation Steps

### Step 1: Add NetworkRequest Configuration

**File**: `/Sources/TestContainers/NetworkRequest.swift` (new file)

**Tasks**:
1. Create `NetworkRequest` struct with properties: name, driver, labels, options, internal
2. Implement `Sendable` and `Hashable` conformance
3. Add default initializer with sensible defaults (bridge driver, testcontainers label)
4. Implement builder methods: `withName`, `withDriver`, `withLabel`, `withOption`, `asInternal`
5. Follow the same pattern as `ContainerRequest` for consistency

**Acceptance**:
- Struct compiles without warnings
- Builder methods return modified copies (value semantics)
- Default label `testcontainers.swift: true` is included
- All methods are public

**Estimated Effort**: 45 minutes

### Step 2: Add Network Handle

**File**: `/Sources/TestContainers/Network.swift` (new file)

**Tasks**:
1. Create `Network` actor with properties: id, request, docker
2. Add `init(id:request:docker:)` with package visibility
3. Implement `name()` method returning `String?`
4. Implement `remove()` method delegating to `docker.removeNetwork(id:)`
5. Follow the same pattern as `Container` actor

**Acceptance**:
- Actor compiles without warnings
- Public API is clean and minimal
- Internal docker client is not exposed
- Follows `Container` patterns

**Estimated Effort**: 30 minutes

### Step 3: Extend DockerClient with Network Operations

**File**: `/Sources/TestContainers/DockerClient.swift`

**Tasks**:
1. Add `createNetwork(_ request: NetworkRequest) async throws -> String` method
2. Build Docker CLI arguments from request properties
3. Handle `--driver`, `--label`, `--opt`, `--internal` flags
4. Support both named and auto-generated network names
5. Parse network ID from stdout (first line, trimmed)
6. Add `removeNetwork(id: String) async throws` method
7. Use `docker network rm` for cleanup

**Acceptance**:
- Methods follow existing `runContainer` and `removeContainer` patterns
- Arguments are sorted for consistency (labels, options)
- Error handling matches existing Docker operations
- Returns network ID as trimmed string

**Estimated Effort**: 1 hour

### Step 4: Implement Scoped Lifecycle Function

**File**: `/Sources/TestContainers/WithNetwork.swift` (new file)

**Tasks**:
1. Create `withNetwork<T>(_:docker:operation:)` function
2. Add Docker availability check (mirror `withContainer`)
3. Create network using `docker.createNetwork(request)`
4. Create `Network` handle
5. Define cleanup handler for cancellation
6. Wrap operation in `withTaskCancellationHandler`
7. Implement success path: run operation, cleanup, return result
8. Implement error path: cleanup on error, re-throw
9. Implement cancellation path: fire-and-forget cleanup

**Acceptance**:
- Signature matches `withContainer` pattern exactly
- Default `NetworkRequest()` parameter for convenience
- Cleanup happens in all scenarios (success, error, cancellation)
- Error handling uses best-effort cleanup (`try?`)
- Generic return type `T` works correctly

**Estimated Effort**: 1 hour

### Step 5: Add Unit Tests

**File**: `/Tests/TestContainersTests/NetworkRequestTests.swift` (new file)

**Tests**:
```swift
@Test func defaultNetworkRequest() {
    let request = NetworkRequest()
    #expect(request.name == nil)
    #expect(request.driver == "bridge")
    #expect(request.labels["testcontainers.swift"] == "true")
    #expect(request.options.isEmpty)
    #expect(request.internal == false)
}

@Test func configuresNetworkName() {
    let request = NetworkRequest()
        .withName("my-network")
    #expect(request.name == "my-network")
}

@Test func configuresNetworkDriver() {
    let request = NetworkRequest()
        .withDriver("overlay")
    #expect(request.driver == "overlay")
}

@Test func configuresNetworkLabels() {
    let request = NetworkRequest()
        .withLabel("env", "test")
        .withLabel("team", "platform")
    #expect(request.labels["env"] == "test")
    #expect(request.labels["team"] == "platform")
    #expect(request.labels["testcontainers.swift"] == "true")
}

@Test func configuresNetworkOptions() {
    let request = NetworkRequest()
        .withOption("com.docker.network.bridge.name", "br0")
    #expect(request.options["com.docker.network.bridge.name"] == "br0")
}

@Test func configuresInternalNetwork() {
    let request = NetworkRequest()
        .asInternal()
    #expect(request.internal == true)
}

@Test func networkRequestIsHashable() {
    let req1 = NetworkRequest().withName("net1")
    let req2 = NetworkRequest().withName("net1")
    let req3 = NetworkRequest().withName("net2")

    #expect(req1 == req2)
    #expect(req1 != req3)
}
```

**Acceptance**:
- All configuration methods tested
- Default values verified
- Hashable conformance tested
- Tests pass without Docker running

**Estimated Effort**: 1 hour

### Step 6: Add Integration Tests

**File**: `/Tests/TestContainersTests/NetworkIntegrationTests.swift` (new file)

**Tests**:
```swift
@Test func canCreateAndRemoveNetwork_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = NetworkRequest()
        .withName("test-network-\(UUID().uuidString)")

    try await withNetwork(request) { network in
        #expect(!network.id.isEmpty)
        #expect(network.name() == request.name)
    }
}

@Test func automaticCleanupOnSuccess() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    var networkId: String = ""

    let request = NetworkRequest()
        .withName("cleanup-test-\(UUID().uuidString)")

    try await withNetwork(request) { network in
        networkId = network.id
        // Network should exist here
    }

    // Network should be removed after scope exits
    // Verify by trying to inspect it (should fail)
    let docker = DockerClient()
    await #expect(throws: TestContainersError.self) {
        try await docker.runDocker(["network", "inspect", networkId])
    }
}

@Test func automaticCleanupOnError() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    var networkId: String = ""

    let request = NetworkRequest()
        .withName("error-test-\(UUID().uuidString)")

    do {
        try await withNetwork(request) { network in
            networkId = network.id
            throw TestContainersError.timeout("Simulated error")
        }
    } catch {
        // Expected error
    }

    // Network should still be removed
    let docker = DockerClient()
    await #expect(throws: TestContainersError.self) {
        try await docker.runDocker(["network", "inspect", networkId])
    }
}

@Test func autoGeneratedNetworkName() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = NetworkRequest() // No name specified

    try await withNetwork(request) { network in
        #expect(!network.id.isEmpty)
        #expect(network.name() == nil)
    }
}

@Test func customDriverAndOptions() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = NetworkRequest()
        .withName("custom-bridge-\(UUID().uuidString)")
        .withDriver("bridge")
        .withOption("com.docker.network.driver.mtu", "1450")

    try await withNetwork(request) { network in
        #expect(!network.id.isEmpty)
    }
}

@Test func internalNetwork() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = NetworkRequest()
        .withName("internal-test-\(UUID().uuidString)")
        .asInternal()

    try await withNetwork(request) { network in
        #expect(!network.id.isEmpty)
    }
}
```

**Acceptance**:
- Network creation and removal verified
- Cleanup tested for success, error, and cancellation paths
- Auto-generated names work
- Custom driver and options work
- Internal networks can be created
- All tests pass when `TESTCONTAINERS_RUN_DOCKER_TESTS=1`

**Estimated Effort**: 2 hours

### Step 7: Update Package Exports

**File**: `/Sources/TestContainers/TestContainers.swift` (or similar)

**Tasks**:
1. Ensure `NetworkRequest`, `Network`, and `withNetwork` are publicly accessible
2. Verify module structure follows existing patterns

**Estimated Effort**: 15 minutes

### Step 8: Documentation

**Tasks**:
1. Add usage examples to README
2. Document network lifecycle pattern
3. Document integration with containers (future feature)
4. Add inline documentation to public APIs
5. Update `/FEATURES.md` to mark `withNetwork(_:_:)` as implemented

**Acceptance**:
- README has clear examples
- Public API has doc comments
- Examples include common use cases (named/unnamed, internal, multi-container)

**Estimated Effort**: 1 hour

## Dependencies

### Critical Dependency: Docker Network Commands

This feature depends on Docker network commands:

1. **`docker network create`**: Creates networks with drivers, options, labels
2. **`docker network rm`**: Removes networks by ID
3. **Network cleanup**: Networks can be removed while containers are running (will fail if containers are connected)

**Mitigation**: Docker network commands have been stable since Docker 1.9 (2015). The `DockerClient` infrastructure already handles command execution and error handling.

### Related Features

- **Existing**: `withContainer(_:_:)` scoped lifecycle (template for this feature)
- **Existing**: `DockerClient` for Docker CLI execution
- **Future**: Attach containers to networks (requires extending `ContainerRequest`)
- **Future**: Network aliases for container-to-container DNS
- **Future**: Container-to-container communication helpers

## Testing Plan

### Unit Tests

**Location**: `/Tests/TestContainersTests/NetworkRequestTests.swift`

**Coverage**:
1. Default values initialization
2. Each builder method (withName, withDriver, withLabel, withOption, asInternal)
3. Hashable and Equatable conformance
4. Sendable conformance (compile-time)
5. Value semantics (builder methods return new instances)

**Estimated Total**: 10 unit tests

### Integration Tests

**Location**: `/Tests/TestContainersTests/NetworkIntegrationTests.swift`

**Coverage**:
1. Basic network creation and removal
2. Named networks
3. Auto-generated network names
4. Custom drivers (bridge, overlay if supported)
5. Network options
6. Internal networks
7. Cleanup on success
8. Cleanup on error
9. Cleanup on cancellation
10. Network with labels
11. Multiple networks in parallel

**Estimated Total**: 11 integration tests

### Manual Testing

1. Test with various Docker versions (20.x, 24.x, 25.x)
2. Test on different platforms (macOS, Linux)
3. Test with Docker Desktop and Docker Engine
4. Verify cleanup with `docker network ls` after tests
5. Test error scenarios (invalid driver, Docker not running)
6. Test concurrent network creation
7. Performance testing with many networks

### Performance Testing

1. Measure network creation time (baseline: ~50-200ms)
2. Measure network removal time (baseline: ~50-100ms)
3. Test with 10, 50, 100 networks in parallel
4. Verify no resource leaks over many iterations

## Acceptance Criteria

### Functional

- [ ] `NetworkRequest` struct with name, driver, labels, options, internal properties
- [ ] `NetworkRequest` builder methods: withName, withDriver, withLabel, withOption, asInternal
- [ ] `Network` actor with id, request properties and name(), remove() methods
- [ ] `withNetwork<T>(_:docker:operation:)` function with scoped lifecycle
- [ ] `DockerClient.createNetwork(_:)` creates networks and returns ID
- [ ] `DockerClient.removeNetwork(id:)` removes networks by ID
- [ ] Network cleanup happens on success, error, and cancellation
- [ ] Default `NetworkRequest()` parameter creates unnamed bridge network
- [ ] Docker availability checked before network creation
- [ ] Networks labeled with `testcontainers.swift: true` by default

### Code Quality

- [ ] Follows existing patterns (mirrors `withContainer` implementation)
- [ ] Proper error handling with descriptive messages
- [ ] `Sendable` and `Hashable` conformance for `NetworkRequest`
- [ ] Actor isolation for `Network` handle
- [ ] No compiler warnings or errors
- [ ] Consistent naming conventions with existing code
- [ ] Value semantics for `NetworkRequest` builder methods

### Testing

- [ ] Unit tests verify `NetworkRequest` configuration
- [ ] Unit tests verify Hashable conformance
- [ ] Integration tests verify network creation and removal
- [ ] Integration tests verify cleanup on success, error, cancellation
- [ ] Integration tests verify named and unnamed networks
- [ ] Integration tests verify custom drivers and options
- [ ] Integration tests verify internal networks
- [ ] All tests pass with `TESTCONTAINERS_RUN_DOCKER_TESTS=1`
- [ ] Tests clean up resources even on failure

### Documentation

- [ ] Public API has doc comments
- [ ] README includes network usage examples
- [ ] Usage examples show named/unnamed networks
- [ ] Usage examples show internal networks
- [ ] Usage examples show multi-container scenarios (conceptual)
- [ ] `/FEATURES.md` updated to mark feature as implemented
- [ ] Notes on Docker version compatibility

## Open Questions

### 1. Network Naming Strategy

**Question**: Should we auto-generate unique names if none provided, or let Docker generate them?

**Options**:
- A. Let Docker auto-generate names (simple, less control)
- B. Generate UUID-based names in Swift (predictable, easier to debug)

**Recommendation**: Option A - Let Docker auto-generate. Simpler and follows Docker conventions. Users who care about names can specify them explicitly.

### 2. Network Inspection

**Question**: Should `Network` expose an `inspect()` method to get network details?

**Recommendation**: Not in initial implementation. Can be added later if needed. Keep scope minimal.

### 3. Network Reuse

**Question**: Should we support reusing existing networks instead of always creating new ones?

**Recommendation**: No for initial version. Create/remove pattern is simpler and avoids conflicts. Can add opt-in reuse later.

### 4. Multi-Network Support for Containers

**Question**: Should containers support multiple networks simultaneously?

**Recommendation**: Yes, but that's a separate feature (extending `ContainerRequest`). This ticket focuses only on network lifecycle.

### 5. Network Aliases

**Question**: Should we support network aliases for DNS resolution?

**Recommendation**: Not in this ticket. Network aliases are configured when attaching containers to networks, which is a future feature.

## Risks and Mitigations

### Risk: Network Cleanup Failure

**Impact**: Networks might leak if cleanup fails (e.g., containers still connected).

**Mitigation**:
- Use best-effort cleanup (`try?`) to avoid masking original errors
- Networks labeled with `testcontainers.swift: true` can be cleaned up manually
- Document that users should ensure containers are removed before networks
- Consider adding a cleanup utility in future (like Testcontainers Ryuk)

**Likelihood**: Medium
**Severity**: Low (networks are cheap, can be cleaned manually)

### Risk: Docker Version Compatibility

**Impact**: Older Docker versions might not support all network options.

**Mitigation**:
- Use stable Docker network API (available since Docker 1.9)
- Document minimum Docker version requirement
- Test with common Docker versions (20.x, 24.x, 25.x)

**Likelihood**: Low
**Severity**: Low

### Risk: Platform Differences

**Impact**: Network drivers might differ between Docker Desktop (macOS/Windows) and Docker Engine (Linux).

**Mitigation**:
- Default to `bridge` driver (universally supported)
- Document platform-specific limitations
- Test on multiple platforms

**Likelihood**: Medium
**Severity**: Low

### Risk: Concurrent Network Creation

**Impact**: Creating many networks in parallel might hit Docker API limits.

**Mitigation**:
- Docker network creation is generally fast and reliable
- No explicit rate limiting needed initially
- Monitor performance in tests

**Likelihood**: Low
**Severity**: Low

## Future Enhancements

### Phase 2: Container Network Attachment

Extend `ContainerRequest` to support networks:

```swift
public struct ContainerRequest {
    public var networks: [String]  // Network IDs or names
    public var networkAliases: [String: [String]]  // Network ID -> aliases

    public func withNetwork(_ networkId: String, aliases: [String] = []) -> Self
}
```

Extend `DockerClient.runContainer()` to add `--network` and `--network-alias` flags.

### Phase 3: Network Inspection

Add network inspection capabilities:

```swift
public actor Network {
    public func inspect() async throws -> NetworkInspection

    public struct NetworkInspection {
        public let id: String
        public let name: String
        public let driver: String
        public let scope: String
        public let internal: Bool
        public let containers: [String]  // Container IDs
    }
}
```

### Phase 4: Network Connect/Disconnect

Support runtime network attachment:

```swift
extension Container {
    public func connect(to networkId: String, aliases: [String] = []) async throws
    public func disconnect(from networkId: String) async throws
}
```

### Phase 5: Network Utilities

Helper functions for common patterns:

```swift
// Connect multiple containers to same network
public func withSharedNetwork<T>(
    containers: [ContainerRequest],
    operation: @Sendable ([Container]) async throws -> T
) async throws -> T

// Create network and attach containers in one call
public func withContainersOnNetwork<T>(
    _ requests: [ContainerRequest],
    networkRequest: NetworkRequest = NetworkRequest(),
    operation: @Sendable (Network, [Container]) async throws -> T
) async throws -> T
```

## References

### Existing Code

- **Scoped lifecycle pattern**: `/Sources/TestContainers/WithContainer.swift`
- **Container actor**: `/Sources/TestContainers/Container.swift`
- **Request configuration**: `/Sources/TestContainers/ContainerRequest.swift`
- **Docker client**: `/Sources/TestContainers/DockerClient.swift`
- **Error types**: `/Sources/TestContainers/TestContainersError.swift`
- **Integration tests**: `/Tests/TestContainersTests/DockerIntegrationTests.swift`

### Docker Documentation

- [Docker network create](https://docs.docker.com/engine/reference/commandline/network_create/)
- [Docker network rm](https://docs.docker.com/engine/reference/commandline/network_rm/)
- [Docker network drivers](https://docs.docker.com/network/drivers/)

### Similar Projects

- **Testcontainers Java**: `Network` class with `withNetwork()` helper
- **Testcontainers Go**: `network.New()` with defer cleanup pattern
- **Testcontainers Python**: `Network` context manager

### Related Feature Tickets

- **Feature 003**: Exec Wait Strategy (demonstrates feature ticket format)
- **Future Feature**: Container Network Attachment (depends on this ticket)
- **Future Feature**: Network Aliases (depends on this ticket)

## Estimated Total Effort

| Step | Effort |
|------|--------|
| 1. NetworkRequest struct | 45 min |
| 2. Network actor | 30 min |
| 3. DockerClient network ops | 1 hour |
| 4. withNetwork function | 1 hour |
| 5. Unit tests | 1 hour |
| 6. Integration tests | 2 hours |
| 7. Package exports | 15 min |
| 8. Documentation | 1 hour |
| **Total** | **7.5 hours** |

**Recommendation**: Allocate 8-10 hours to account for debugging and testing edge cases.
