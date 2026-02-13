# Feature 025: Network Aliases (Container-to-Container Communication by Name)

## Summary

Implement network aliases to enable container-to-container communication using hostnames/aliases instead of IP addresses. This feature allows containers to discover and communicate with each other using DNS names on custom Docker networks, which is essential for testing distributed systems, microservices, and multi-container applications.

## Current State

The codebase currently has **no networking support** beyond the default Docker bridge network:

**Container Configuration** (`/Sources/TestContainers/ContainerRequest.swift`):
- Supports `image`, `name`, `command`, `environment`, `labels`, `ports`, and `waitStrategy`
- No network-related properties (networks, aliases, links)
- Only supports port mapping to host (`-p` flag)

**Docker Client** (`/Sources/TestContainers/DockerClient.swift`, lines 28-54):
- `runContainer()` builds `docker run` arguments
- No support for `--network` or `--network-alias` flags
- Containers run on default bridge network

**Current Limitations**:
1. Containers cannot communicate with each other by name
2. No custom network creation or management
3. No DNS resolution between containers
4. Tests requiring multi-container setups must use host networking or IP addresses

According to `/FEATURES.md` (lines 66-71), networking support is planned for Tier 2 (Medium Priority):
- Create/remove networks (`docker network create/rm`)
- Attach container to network(s) on start
- **Network aliases (container-to-container by name)** ← This feature
- Container-to-container communication helpers
- `withNetwork(_:_:)` scoped lifecycle

## Requirements

### Functional Requirements

1. **Network Alias Configuration**: Allow specifying one or more network aliases when creating a container
2. **DNS Resolution**: Containers on the same network can resolve each other by alias
3. **Multiple Aliases**: Support multiple aliases per container (Docker allows this)
4. **Network Attachment**: Automatically attach container to a specified network
5. **Default Network Support**: Support both custom networks and default bridge network
6. **Network Lifecycle**: Create networks before containers, clean up after tests
7. **Scoped Network Management**: `withNetwork(_:_:)` helper for automatic cleanup

### Non-Functional Requirements

1. **Consistency**: Follow existing builder pattern and API design
2. **Safety**: Ensure networks are cleaned up on test completion, error, or cancellation
3. **Testability**: Support both unit and integration testing
4. **Performance**: Minimal overhead from network operations
5. **Swift Concurrency**: Compatible with actors and structured concurrency

## API Design

### Network Model

Add a new `Network` actor to represent a Docker network (similar to `Container`):

```swift
// File: /Sources/TestContainers/Network.swift
public actor Network {
    public let id: String
    public let name: String

    private let docker: DockerClient

    init(id: String, name: String, docker: DockerClient) {
        self.id = id
        self.name = name
        self.docker = docker
    }

    public func remove() async throws {
        try await docker.removeNetwork(id: id)
    }
}
```

### NetworkRequest Builder

Add a `NetworkRequest` struct following the existing `ContainerRequest` pattern:

```swift
// File: /Sources/TestContainers/NetworkRequest.swift
public struct NetworkRequest: Sendable, Hashable {
    public var name: String?
    public var driver: String
    public var labels: [String: String]

    public init() {
        self.name = nil
        self.driver = "bridge"
        self.labels = ["testcontainers.swift": "true"]
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
}
```

### ContainerRequest Extensions

Add network and alias properties to `ContainerRequest`:

```swift
// File: /Sources/TestContainers/ContainerRequest.swift (additions)
public struct ContainerRequest: Sendable, Hashable {
    // ... existing properties ...
    public var networks: [String]  // Network names or IDs
    public var networkAliases: [String]  // DNS aliases on the network

    public init(image: String) {
        // ... existing initialization ...
        self.networks = []
        self.networkAliases = []
    }

    public func withNetwork(_ network: String) -> Self {
        var copy = self
        copy.networks.append(network)
        return copy
    }

    public func withNetworkAlias(_ alias: String) -> Self {
        var copy = self
        copy.networkAliases.append(alias)
        return copy
    }

    public func withNetworkAliases(_ aliases: [String]) -> Self {
        var copy = self
        copy.networkAliases.append(contentsOf: aliases)
        return copy
    }
}
```

### Scoped Network Lifecycle

Add a `withNetwork` helper (similar to `withContainer`):

```swift
// File: /Sources/TestContainers/WithNetwork.swift
public func withNetwork<T>(
    _ request: NetworkRequest = NetworkRequest(),
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Network) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable("`docker` CLI not found or Docker engine not running.")
    }

    let id = try await docker.createNetwork(request)
    let network = Network(id: id, name: request.name ?? id, docker: docker)

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

### Usage Examples

#### Example 1: Two Containers with Network Aliases

```swift
import Testing
import TestContainers

@Test func microservicesCanCommunicate() async throws {
    try await withNetwork(NetworkRequest().withName("app-network")) { network in
        // Start Redis with alias "cache"
        let redisRequest = ContainerRequest(image: "redis:7")
            .withNetwork(network.name)
            .withNetworkAlias("cache")
            .withExposedPort(6379)
            .waitingFor(.tcpPort(6379))

        // Start app that connects to Redis via "cache" hostname
        let appRequest = ContainerRequest(image: "myapp:latest")
            .withNetwork(network.name)
            .withNetworkAlias("app")
            .withEnvironment(["REDIS_URL": "redis://cache:6379"])
            .withExposedPort(8080)
            .waitingFor(.tcpPort(8080))

        try await withContainer(redisRequest) { redis in
            try await withContainer(appRequest) { app in
                // App can reach Redis via "cache" hostname
                let port = try await app.hostPort(8080)
                #expect(port > 0)
            }
        }
    }
}
```

#### Example 2: Multiple Aliases for One Container

```swift
@Test func containerWithMultipleAliases() async throws {
    try await withNetwork() { network in
        let request = ContainerRequest(image: "nginx:alpine")
            .withNetwork(network.name)
            .withNetworkAliases(["web", "www", "nginx"])
            .withExposedPort(80)
            .waitingFor(.tcpPort(80))

        try await withContainer(request) { container in
            // Container is reachable via all three aliases:
            // - web:80
            // - www:80
            // - nginx:80
            #expect(container.id.isEmpty == false)
        }
    }
}
```

#### Example 3: Testing DNS Resolution

```swift
@Test func containerCanResolveOtherByAlias() async throws {
    try await withNetwork() { network in
        let server = ContainerRequest(image: "nginx:alpine")
            .withNetwork(network.name)
            .withNetworkAlias("server")
            .withExposedPort(80)
            .waitingFor(.tcpPort(80))

        let client = ContainerRequest(image: "alpine:3")
            .withNetwork(network.name)
            .withCommand(["sleep", "30"])

        try await withContainer(server) { _ in
            try await withContainer(client) { client in
                // Client can resolve "server" via DNS
                let output = try await client.exec(["ping", "-c", "1", "server"])
                #expect(output.exitCode == 0)
            }
        }
    }
}
```

#### Example 4: Legacy Network Name String

```swift
@Test func usingNetworkNameDirectly() async throws {
    // Create network manually
    let docker = DockerClient()
    let networkId = try await docker.createNetwork(
        NetworkRequest().withName("my-test-network")
    )

    defer {
        Task { try? await docker.removeNetwork(id: networkId) }
    }

    let request = ContainerRequest(image: "redis:7")
        .withNetwork("my-test-network")
        .withNetworkAlias("redis")

    try await withContainer(request) { container in
        #expect(container.id.isEmpty == false)
    }
}
```

## Implementation Steps

### Step 1: Add Network Model and NetworkRequest

**File**: `/Sources/TestContainers/Network.swift` (new file)

Create the `Network` actor as shown in API Design.

**File**: `/Sources/TestContainers/NetworkRequest.swift` (new file)

Create the `NetworkRequest` struct as shown in API Design.

**Estimated Effort**: 1 hour

### Step 2: Add Network Support to DockerClient

**File**: `/Sources/TestContainers/DockerClient.swift`

Add three new methods:

```swift
func createNetwork(_ request: NetworkRequest) async throws -> String {
    var args: [String] = ["network", "create"]

    if let name = request.name {
        args.append(name)
    }

    args += ["--driver", request.driver]

    for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
        args += ["--label", "\(key)=\(value)"]
    }

    // If no name specified, generate one
    if request.name == nil {
        args.append("testcontainers-\(UUID().uuidString)")
    }

    let output = try await runDocker(args)
    let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else {
        throw TestContainersError.unexpectedDockerOutput(output.stdout)
    }
    return id
}

func removeNetwork(id: String) async throws {
    _ = try await runDocker(["network", "rm", id])
}

func inspectNetwork(id: String) async throws -> String {
    let output = try await runDocker(["network", "inspect", id])
    return output.stdout
}
```

**Estimated Effort**: 1 hour

### Step 3: Add Network and Alias Properties to ContainerRequest

**File**: `/Sources/TestContainers/ContainerRequest.swift`

Add properties and builder methods as shown in API Design.

**Estimated Effort**: 30 minutes

### Step 4: Update DockerClient.runContainer() to Support Networks and Aliases

**File**: `/Sources/TestContainers/DockerClient.swift` (modify `runContainer` method, lines 28-54)

Add network and alias handling after port mapping (around line 42):

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    if let name = request.name {
        args += ["--name", name]
    }

    for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
        args += ["-e", "\(key)=\(value)"]
    }

    for mapping in request.ports {
        args += ["-p", mapping.dockerFlag]
    }

    // NEW: Add network support
    for network in request.networks {
        args += ["--network", network]
    }

    // NEW: Add network aliases (requires at least one network)
    for alias in request.networkAliases {
        args += ["--network-alias", alias]
    }

    for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
        args += ["--label", "\(key)=\(value)"]
    }

    args.append(request.image)
    args += request.command

    let output = try await runDocker(args)
    let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { throw TestContainersError.unexpectedDockerOutput(output.stdout) }
    return id
}
```

**Important Note**: The `--network-alias` flag only works when a container is attached to a custom network (not the default bridge). We should document this limitation.

**Estimated Effort**: 30 minutes

### Step 5: Add withNetwork Helper

**File**: `/Sources/TestContainers/WithNetwork.swift` (new file)

Create the scoped lifecycle helper as shown in API Design.

**Estimated Effort**: 30 minutes

### Step 6: Add Exec Support (Dependency for Testing)

**File**: `/Sources/TestContainers/DockerClient.swift`

Add exec method for integration tests (needed to test DNS resolution):

```swift
func exec(id: String, command: [String]) async throws -> CommandOutput {
    var args = ["exec", id]
    args += command

    // Note: Don't use runDocker() because we want to allow non-zero exit codes
    let output = try await runner.run(executable: dockerPath, arguments: args)
    return output
}
```

**File**: `/Sources/TestContainers/Container.swift`

Add public exec method:

```swift
public func exec(_ command: [String]) async throws -> CommandOutput {
    try await docker.exec(id: id, command: command)
}
```

**Estimated Effort**: 30 minutes

### Step 7: Add Unit Tests

**File**: `/Tests/TestContainersTests/ContainerRequestTests.swift`

```swift
@Test func configuresNetwork() {
    let request = ContainerRequest(image: "nginx:alpine")
        .withNetwork("my-network")

    #expect(request.networks == ["my-network"])
}

@Test func configuresMultipleNetworks() {
    let request = ContainerRequest(image: "nginx:alpine")
        .withNetwork("network1")
        .withNetwork("network2")

    #expect(request.networks == ["network1", "network2"])
}

@Test func configuresNetworkAlias() {
    let request = ContainerRequest(image: "nginx:alpine")
        .withNetworkAlias("web")

    #expect(request.networkAliases == ["web"])
}

@Test func configuresMultipleNetworkAliases() {
    let request = ContainerRequest(image: "nginx:alpine")
        .withNetworkAliases(["web", "www", "nginx"])

    #expect(request.networkAliases == ["web", "www", "nginx"])
}

@Test func networkRequestDefaults() {
    let request = NetworkRequest()

    #expect(request.name == nil)
    #expect(request.driver == "bridge")
    #expect(request.labels["testcontainers.swift"] == "true")
}

@Test func configuresNetworkName() {
    let request = NetworkRequest()
        .withName("app-network")

    #expect(request.name == "app-network")
}
```

**Estimated Effort**: 1 hour

### Step 8: Add Integration Tests

**File**: `/Tests/TestContainersTests/NetworkIntegrationTests.swift` (new file)

```swift
import Foundation
import Testing
import TestContainers

@Test func networkCreationAndRemoval() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()
    let request = NetworkRequest().withName("test-network-\(UUID().uuidString)")

    let networkId = try await docker.createNetwork(request)
    #expect(!networkId.isEmpty)

    // Cleanup
    try await docker.removeNetwork(id: networkId)
}

@Test func withNetworkHelper() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    var capturedNetworkId: String?

    try await withNetwork(NetworkRequest().withName("scoped-network")) { network in
        capturedNetworkId = network.id
        #expect(!network.id.isEmpty)
        #expect(network.name == "scoped-network")
    }

    // Verify network was cleaned up
    let docker = DockerClient()
    await #expect(throws: TestContainersError.self) {
        _ = try await docker.inspectNetwork(id: capturedNetworkId!)
    }
}

@Test func containerWithNetworkAlias() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withNetwork() { network in
        let request = ContainerRequest(image: "nginx:alpine")
            .withNetwork(network.name)
            .withNetworkAlias("webserver")
            .withExposedPort(80)
            .waitingFor(.tcpPort(80))

        try await withContainer(request) { container in
            #expect(container.id.isEmpty == false)
        }
    }
}

@Test func twoContainersCommunicateByAlias() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withNetwork() { network in
        // Server container
        let server = ContainerRequest(image: "nginx:alpine")
            .withNetwork(network.name)
            .withNetworkAlias("server")
            .withExposedPort(80)
            .waitingFor(.tcpPort(80))

        // Client container
        let client = ContainerRequest(image: "alpine:3")
            .withNetwork(network.name)
            .withCommand(["sleep", "300"])

        try await withContainer(server) { _ in
            try await withContainer(client) { clientContainer in
                // Test DNS resolution: client pings server by alias
                let result = try await clientContainer.exec(["ping", "-c", "1", "server"])
                #expect(result.exitCode == 0)
            }
        }
    }
}

@Test func containerWithMultipleAliases() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withNetwork() { network in
        let server = ContainerRequest(image: "nginx:alpine")
            .withNetwork(network.name)
            .withNetworkAliases(["web", "www", "nginx"])
            .withExposedPort(80)
            .waitingFor(.tcpPort(80))

        let client = ContainerRequest(image: "alpine:3")
            .withNetwork(network.name)
            .withCommand(["sleep", "300"])

        try await withContainer(server) { _ in
            try await withContainer(client) { clientContainer in
                // Test all three aliases
                for alias in ["web", "www", "nginx"] {
                    let result = try await clientContainer.exec(["ping", "-c", "1", alias])
                    #expect(result.exitCode == 0, "Failed to resolve alias: \(alias)")
                }
            }
        }
    }
}

@Test func redisAndAppCommunication() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withNetwork() { network in
        let redis = ContainerRequest(image: "redis:7-alpine")
            .withNetwork(network.name)
            .withNetworkAlias("cache")
            .withExposedPort(6379)
            .waitingFor(.tcpPort(6379))

        let alpine = ContainerRequest(image: "alpine:3")
            .withNetwork(network.name)
            .withCommand(["sleep", "300"])

        try await withContainer(redis) { _ in
            try await withContainer(alpine) { client in
                // Install redis-cli and test connection
                let install = try await client.exec([
                    "sh", "-c", "apk add --no-cache redis > /dev/null 2>&1"
                ])
                #expect(install.exitCode == 0)

                // Test Redis connection via alias "cache"
                let ping = try await client.exec([
                    "redis-cli", "-h", "cache", "PING"
                ])
                #expect(ping.exitCode == 0)
                #expect(ping.stdout.contains("PONG"))
            }
        }
    }
}
```

**Estimated Effort**: 2 hours

### Step 9: Documentation

**File**: `/README.md`

Add section on network aliases after the Quick Start section:

```markdown
## Container-to-Container Communication

Use network aliases to enable containers to communicate using DNS names:

\`\`\`swift
import Testing
import TestContainers

@Test func microservicesCommunicate() async throws {
    try await withNetwork() { network in
        let redis = ContainerRequest(image: "redis:7")
            .withNetwork(network.name)
            .withNetworkAlias("cache")
            .withExposedPort(6379)
            .waitingFor(.tcpPort(6379))

        let app = ContainerRequest(image: "myapp:latest")
            .withNetwork(network.name)
            .withEnvironment(["REDIS_URL": "redis://cache:6379"])
            .withExposedPort(8080)

        try await withContainer(redis) { _ in
            try await withContainer(app) { container in
                // App connects to Redis via "cache" hostname
                let port = try await container.hostPort(8080)
            }
        }
    }
}
\`\`\`
```

**File**: `/FEATURES.md`

Update networking section (lines 66-71) to mark this as implemented:

```markdown
**Networking**
- [ ] Create/remove networks (`docker network create/rm`)
- [ ] Attach container to network(s) on start
- [x] Network aliases (container-to-container by name)
- [ ] Container-to-container communication helpers
- [ ] `withNetwork(_:_:)` scoped lifecycle
```

**Estimated Effort**: 1 hour

### Step 10: Update Package.swift (if needed)

Ensure new source files are included in the target. SwiftPM should auto-discover them, but verify compilation.

**Estimated Effort**: 15 minutes

## Dependencies

### Critical Dependencies

1. **Docker Network Commands**:
   - `docker network create [options] [name]`
   - `docker network rm <id>`
   - `docker network inspect <id>`
   - `docker run --network <name> --network-alias <alias>`

2. **Network Alias Limitations**:
   - `--network-alias` only works with custom networks (not default bridge)
   - Requires `--network` flag to be specified
   - DNS resolution only works between containers on same network

3. **Exec Support** (for testing):
   - `docker exec <container> <command>`
   - Needed to test DNS resolution from inside containers

### Feature Dependencies

This feature builds on:
- **Existing**: `ContainerRequest` builder pattern
- **Existing**: `withContainer` scoped lifecycle
- **Existing**: `DockerClient` command execution
- **New**: Container exec support (Step 6)

This feature enables:
- Multi-container integration tests
- Microservices communication testing
- Database client/server scenarios
- Service discovery patterns

## Testing Plan

### Unit Tests

**Location**: `/Tests/TestContainersTests/ContainerRequestTests.swift`

1. `ContainerRequest` network configuration
2. `ContainerRequest` network alias configuration
3. `NetworkRequest` builder methods
4. Property defaults and chaining
5. `Hashable` and `Sendable` conformance

### Integration Tests

**Location**: `/Tests/TestContainersTests/NetworkIntegrationTests.swift`

1. **Network Lifecycle**: Create and remove networks
2. **Scoped Helper**: `withNetwork` cleanup on success, error, cancellation
3. **Single Container**: Container with network alias
4. **Two Containers**: DNS resolution between containers
5. **Multiple Aliases**: Container reachable via multiple names
6. **Real-World Scenario**: Redis + client communication
7. **Error Handling**: Invalid network names, missing network, alias without network

### Manual Testing

1. Test with various container images (Nginx, Redis, PostgreSQL, Alpine)
2. Test with multiple containers (3+) on same network
3. Test network cleanup after test failures
4. Test network isolation (containers on different networks cannot communicate)
5. Verify DNS resolution timing (immediate vs. eventual)

## Acceptance Criteria

### Functional

- [ ] `Network` actor created with `id`, `name`, and `remove()` method
- [ ] `NetworkRequest` struct with builder methods for name, driver, labels
- [ ] `DockerClient.createNetwork()` creates Docker networks
- [ ] `DockerClient.removeNetwork()` removes Docker networks
- [ ] `DockerClient.inspectNetwork()` inspects network details
- [ ] `ContainerRequest.networks` property stores network names/IDs
- [ ] `ContainerRequest.networkAliases` property stores DNS aliases
- [ ] `ContainerRequest.withNetwork()` builder method
- [ ] `ContainerRequest.withNetworkAlias()` builder method
- [ ] `ContainerRequest.withNetworkAliases()` builder method
- [ ] `DockerClient.runContainer()` passes `--network` flags
- [ ] `DockerClient.runContainer()` passes `--network-alias` flags
- [ ] `withNetwork()` helper creates network, runs operation, cleans up
- [ ] Containers on same network can resolve each other by alias
- [ ] Multiple aliases per container work correctly
- [ ] Networks are cleaned up on success, error, and cancellation

### Code Quality

- [ ] Follows existing code patterns (builder, scoped lifecycle, actor)
- [ ] Proper error handling with descriptive messages
- [ ] `Sendable` and `Hashable` conformance maintained
- [ ] No new compiler warnings or errors
- [ ] Code follows Swift API design guidelines

### Testing

- [ ] Unit tests verify configuration builders
- [ ] Integration tests verify network creation/removal
- [ ] Integration tests verify DNS resolution between containers
- [ ] Integration tests verify multiple aliases
- [ ] Integration tests verify real-world scenarios (Redis, Nginx)
- [ ] All tests pass in CI/CD pipeline
- [ ] Tests are opt-in via `TESTCONTAINERS_RUN_DOCKER_TESTS=1`

### Documentation

- [ ] API documentation for `Network` actor
- [ ] API documentation for `NetworkRequest`
- [ ] API documentation for new `ContainerRequest` methods
- [ ] Usage examples in README
- [ ] FEATURES.md updated to mark network aliases as implemented
- [ ] Notes about network alias limitations (custom networks only)

## Open Questions

### 1. Should we support connecting to multiple networks simultaneously?

Docker allows `--network` to be specified multiple times. Should we support this?

**Recommendation**: Yes, support multiple networks via `networks: [String]` array. This enables:
- Containers that bridge multiple network segments
- Complex topologies for testing
- Service mesh patterns

**Implementation**: Already designed this way in API Design.

### 2. Should we auto-create networks if they don't exist?

**Recommendation**: No, require explicit network creation. This prevents:
- Implicit behavior that's hard to debug
- Network name collisions
- Unclear ownership and lifecycle

Users should use `withNetwork()` or manually create networks.

### 3. Should we support network drivers other than "bridge"?

Docker supports: bridge, host, overlay, macvlan, none.

**Recommendation**: Support via `NetworkRequest.withDriver()`, but default to "bridge". Document that:
- "bridge" works for most test scenarios
- "host" bypasses network isolation
- "overlay" requires Docker Swarm
- Other drivers are advanced use cases

**Implementation**: Already designed this way in API Design.

### 4. Should we validate that aliases are only used with custom networks?

Docker will fail if `--network-alias` is used without `--network` or with the default bridge.

**Recommendation**: Document the limitation, but don't validate in code. Let Docker return the error. This keeps the library simple and avoids duplicating Docker's validation logic.

### 5. Should we support network-scoped environment variables?

Docker allows env vars when creating networks. Do we need this?

**Recommendation**: Not for MVP. Can add later if needed via `NetworkRequest.withOptions()` or similar.

### 6. Should we support attaching existing containers to networks?

Docker supports `docker network connect` to attach running containers to networks.

**Recommendation**: Not for MVP. Focus on attaching during container creation. Can add `container.attachToNetwork()` later if needed.

### 7. How do we handle network name conflicts?

If two tests try to create networks with the same name simultaneously?

**Recommendation**:
- Don't enforce uniqueness in code
- Recommend users either:
  - Use `withNetwork()` with auto-generated names
  - Use unique names (e.g., include test name or UUID)
- Document parallel test safety in future enhancement

## Risks and Mitigations

### Risk: Network Leaks

**Impact**: Networks not cleaned up after test failures could accumulate over time.

**Mitigation**:
- Use `withTaskCancellationHandler` for cleanup on cancellation
- Add cleanup in error paths
- Add labels to networks (`testcontainers.swift: true`) for future sweeper
- Document manual cleanup: `docker network prune --filter label=testcontainers.swift=true`

### Risk: DNS Resolution Timing

**Impact**: DNS may not be immediately available when container starts.

**Mitigation**:
- Document that wait strategies should account for DNS propagation
- Recommend using `.tcpPort()` or `.exec()` wait strategies that poll
- DNS is typically instant in Docker, but document the possibility

### Risk: Network Driver Compatibility

**Impact**: Non-bridge drivers may not work on all platforms (e.g., overlay requires Swarm).

**Mitigation**:
- Default to "bridge" driver
- Document driver compatibility requirements
- Let Docker return errors for unsupported configurations

### Risk: Port Conflicts on Custom Networks

**Impact**: Containers on custom networks don't need port mapping for inter-container communication, which might confuse users.

**Mitigation**:
- Document that:
  - Port mapping (`-p`) is for host access
  - Network aliases are for container-to-container access
  - Both can be used together
- Provide clear examples of each pattern

### Risk: Container Startup Order

**Impact**: If container A depends on container B's DNS name, A might fail if started first.

**Mitigation**:
- Document that wait strategies should be used
- Show examples of correct startup order
- Consider future enhancement: dependency graphs (FEATURES.md already mentions this)

## Future Enhancements

### Phase 2: Enhanced Network Features

1. **Network Inspection**: Expose network details (containers, driver, options)
2. **Attach/Detach**: Attach running containers to networks dynamically
3. **Network Aliases per Network**: Support different aliases on different networks
4. **IPv6 Support**: Enable IPv6 on networks
5. **Internal Networks**: Create isolated networks with no external access
6. **Custom Network Options**: DNS, MTU, subnet configuration

### Phase 3: Multi-Container Orchestration

1. **Dependency Graphs**: Define container startup order based on dependencies
2. **Health-aware Startup**: Wait for dependencies to be healthy before starting dependents
3. **Shared Network Lifecycle**: Multiple containers share network lifecycle
4. **Network Templates**: Pre-configured networks for common scenarios

### Phase 4: Service-Specific Helpers

1. **PostgresContainer**: Auto-configure network alias and connection string
2. **RedisContainer**: Auto-configure network alias and connection string
3. **KafkaContainer**: Multi-broker setup with network aliases
4. **Multi-container Modules**: Pre-configured stacks (e.g., app + database + cache)

## References

### Existing Code

- **Container Request Pattern**: `/Sources/TestContainers/ContainerRequest.swift`
- **Scoped Lifecycle Pattern**: `/Sources/TestContainers/WithContainer.swift`
- **Docker Client**: `/Sources/TestContainers/DockerClient.swift`
- **Container Actor**: `/Sources/TestContainers/Container.swift`
- **Error Handling**: `/Sources/TestContainers/TestContainersError.swift`

### Docker Documentation

- [Docker Network Overview](https://docs.docker.com/network/)
- [Docker Network Commands](https://docs.docker.com/engine/reference/commandline/network/)
- [Container Networking](https://docs.docker.com/config/containers/container-networking/)
- [Network Alias Flag](https://docs.docker.com/engine/reference/commandline/run/#network-alias)

### Similar Projects

- **Testcontainers Java**: [Network Support](https://java.testcontainers.org/features/networking/)
- **Testcontainers Go**: [Network](https://golang.testcontainers.org/features/networking/)
- **Testcontainers .NET**: [Networks](https://dotnet.testcontainers.org/api/create_docker_network/)

### Feature Planning

- **Roadmap**: `/FEATURES.md` (lines 66-71, 169)
- **Similar Feature Example**: `/features/003-exec-wait-strategy.md`

## Estimated Total Effort

| Step | Component | Hours |
|------|-----------|-------|
| 1 | Network model + NetworkRequest | 1.0 |
| 2 | DockerClient network methods | 1.0 |
| 3 | ContainerRequest network properties | 0.5 |
| 4 | Update runContainer() | 0.5 |
| 5 | withNetwork helper | 0.5 |
| 6 | Exec support (dependency) | 0.5 |
| 7 | Unit tests | 1.0 |
| 8 | Integration tests | 2.0 |
| 9 | Documentation | 1.0 |
| 10 | Package updates | 0.25 |
| **Total** | | **8.25 hours** |

**Note**: This estimate assumes familiarity with the codebase and includes time for testing and documentation. Actual time may vary based on edge cases discovered during implementation.
