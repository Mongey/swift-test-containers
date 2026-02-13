# Feature 024: Attach Container to Network(s) on Start

## Summary

Implement the ability to attach containers to one or more Docker networks at startup, with support for network aliases and IP address assignment. This enables container-to-container communication, service discovery via DNS, and isolated network topologies for integration testing scenarios.

## Current State

The codebase currently supports basic container configuration through `ContainerRequest` in `/Sources/TestContainers/ContainerRequest.swift`:

```swift
public struct ContainerRequest: Sendable, Hashable {
    public var image: String
    public var name: String?
    public var command: [String]
    public var environment: [String: String]
    public var labels: [String: String]
    public var ports: [ContainerPort]
    public var waitStrategy: WaitStrategy
    public var host: String

    // Builder methods: withName, withCommand, withEnvironment,
    // withLabel, withExposedPort, waitingFor, withHost
}
```

**Container Lifecycle** (`/Sources/TestContainers/DockerClient.swift`, lines 28-54):
- Uses `docker run -d` to start containers
- Supports name, environment, ports, labels, image, and command
- No network configuration options currently available

**Current Network Behavior**:
- Containers start on Docker's default bridge network
- No explicit network attachment configuration
- No support for network aliases or custom IP assignment
- No support for multiple network attachments

## Requirements

### Functional Requirements

1. **Single Network Attachment**: Attach container to a single named network at startup using `docker run --network`
2. **Multiple Network Attachments**: Attach container to multiple networks (one at start, others via `docker network connect`)
3. **Network Aliases**: Specify DNS aliases for service discovery within the network
4. **Custom IP Assignment**: Optionally specify IPv4/IPv6 addresses (where network supports it)
5. **Network Mode Support**: Support special network modes (`bridge`, `host`, `none`, `container:<name|id>`)
6. **Builder Pattern**: Fluent API consistent with existing `ContainerRequest` methods
7. **Sendable & Hashable**: Must conform to `Sendable` and `Hashable` like other request properties

### Non-Functional Requirements

1. **Consistency**: Follow existing builder pattern conventions
2. **Testability**: Support both unit and integration testing
3. **Docker CLI**: Implement using Docker CLI commands (no SDK dependency)
4. **Error Handling**: Clear error messages for network configuration failures

## API Design

### Proposed Network Configuration Types

Add new types to `/Sources/TestContainers/ContainerRequest.swift`:

```swift
/// Represents a network attachment with optional configuration
public struct NetworkAttachment: Sendable, Hashable {
    public var networkName: String
    public var aliases: [String]
    public var ipv4Address: String?
    public var ipv6Address: String?

    public init(
        networkName: String,
        aliases: [String] = [],
        ipv4Address: String? = nil,
        ipv6Address: String? = nil
    ) {
        self.networkName = networkName
        self.aliases = aliases
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
    }
}

/// Network mode for container networking
public enum NetworkMode: Sendable, Hashable {
    case bridge
    case host
    case none
    case container(String) // container:<name|id>
    case custom(String)    // user-defined network name

    var dockerFlag: String {
        switch self {
        case .bridge: return "bridge"
        case .host: return "host"
        case .none: return "none"
        case .container(let nameOrId): return "container:\(nameOrId)"
        case .custom(let name): return name
        }
    }
}
```

### ContainerRequest Extensions

Add network properties and builder methods:

```swift
public struct ContainerRequest: Sendable, Hashable {
    // ... existing properties ...
    public var networks: [NetworkAttachment]
    public var networkMode: NetworkMode?

    public init(image: String) {
        // ... existing initialization ...
        self.networks = []
        self.networkMode = nil
    }

    // Attach to a single network (simple case)
    public func withNetwork(_ networkName: String) -> Self {
        var copy = self
        copy.networks.append(NetworkAttachment(networkName: networkName))
        return copy
    }

    // Attach with network configuration
    public func withNetwork(_ attachment: NetworkAttachment) -> Self {
        var copy = self
        copy.networks.append(attachment)
        return copy
    }

    // Attach with aliases for service discovery
    public func withNetwork(_ networkName: String, aliases: [String]) -> Self {
        var copy = self
        copy.networks.append(NetworkAttachment(
            networkName: networkName,
            aliases: aliases
        ))
        return copy
    }

    // Set network mode (bridge, host, none, container)
    public func withNetworkMode(_ mode: NetworkMode) -> Self {
        var copy = self
        copy.networkMode = mode
        return copy
    }
}
```

### DockerClient Extensions

Add network connection methods to `/Sources/TestContainers/DockerClient.swift`:

```swift
// Connect container to a network after it's started
func connectToNetwork(
    containerId: String,
    networkName: String,
    aliases: [String] = [],
    ipv4Address: String? = nil,
    ipv6Address: String? = nil
) async throws {
    var args = ["network", "connect"]

    for alias in aliases {
        args += ["--alias", alias]
    }

    if let ipv4 = ipv4Address {
        args += ["--ip", ipv4]
    }

    if let ipv6 = ipv6Address {
        args += ["--ip6", ipv6]
    }

    args += [networkName, containerId]
    _ = try await runDocker(args)
}
```

### Usage Examples

```swift
// Example 1: Single network attachment
let request = ContainerRequest(image: "redis:7")
    .withNetwork("my-test-network")
    .withExposedPort(6379)

// Example 2: Network with aliases for service discovery
let dbRequest = ContainerRequest(image: "postgres:16")
    .withNetwork("app-network", aliases: ["postgres", "db"])
    .withEnvironment(["POSTGRES_PASSWORD": "test"])
    .withExposedPort(5432)

// Example 3: Multiple networks
let appRequest = ContainerRequest(image: "myapp:latest")
    .withNetwork(NetworkAttachment(
        networkName: "frontend-network",
        aliases: ["api"]
    ))
    .withNetwork(NetworkAttachment(
        networkName: "backend-network",
        aliases: ["app", "service"]
    ))

// Example 4: Custom IP address assignment
let staticIPRequest = ContainerRequest(image: "nginx:alpine")
    .withNetwork(NetworkAttachment(
        networkName: "web-network",
        aliases: ["webserver"],
        ipv4Address: "172.20.0.10"
    ))

// Example 5: Special network modes
let hostModeRequest = ContainerRequest(image: "monitoring:latest")
    .withNetworkMode(.host)

let sidecarRequest = ContainerRequest(image: "sidecar:latest")
    .withNetworkMode(.container("main-app-container"))

// Example 6: Multi-container test scenario
try await withContainer(dbRequest) { db in
    let appRequest = ContainerRequest(image: "myapp:latest")
        .withNetwork("app-network")
        .withEnvironment([
            "DATABASE_HOST": "postgres",  // Use alias from dbRequest
            "DATABASE_PORT": "5432"
        ])

    try await withContainer(appRequest) { app in
        // App can connect to DB via "postgres" hostname
        let endpoint = try await app.endpoint(for: 8080)
        // ... test app ...
    }
}
```

## Implementation Steps

### Step 1: Add Network Types

**File**: `/Sources/TestContainers/ContainerRequest.swift`

1. Add `NetworkAttachment` struct with properties for network name, aliases, and IP addresses
2. Add `NetworkMode` enum with cases for standard modes and custom networks
3. Add computed property `dockerFlag` to `NetworkMode` for CLI flag generation

**Estimated Effort**: 30 minutes

### Step 2: Extend ContainerRequest

**File**: `/Sources/TestContainers/ContainerRequest.swift`

1. Add `networks: [NetworkAttachment]` property
2. Add `networkMode: NetworkMode?` property
3. Initialize these properties in `init(image:)`
4. Add builder methods: `withNetwork(_:)`, `withNetwork(_:aliases:)`, `withNetworkMode(_:)`
5. Ensure `Hashable` and `Sendable` conformance is maintained

**Notes**:
- `networks` is an array to support multiple attachments
- `networkMode` is optional (nil = use Docker default)
- When both `networkMode` and `networks` are specified, `networkMode` takes precedence for primary network

**Estimated Effort**: 45 minutes

### Step 3: Update DockerClient.runContainer

**File**: `/Sources/TestContainers/DockerClient.swift`

Modify the `runContainer` method (currently lines 28-54) to handle network configuration:

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    if let name = request.name {
        args += ["--name", name]
    }

    // Handle network mode or first network attachment
    if let mode = request.networkMode {
        args += ["--network", mode.dockerFlag]
    } else if let firstNetwork = request.networks.first {
        args += ["--network", firstNetwork.networkName]

        // Add aliases for first network (only at start)
        for alias in firstNetwork.aliases {
            args += ["--network-alias", alias]
        }

        // Add IP addresses for first network
        if let ipv4 = firstNetwork.ipv4Address {
            args += ["--ip", ipv4]
        }
        if let ipv6 = firstNetwork.ipv6Address {
            args += ["--ip6", ipv6]
        }
    }

    // ... existing environment, ports, labels configuration ...

    args.append(request.image)
    args += request.command

    let output = try await runDocker(args)
    let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { throw TestContainersError.unexpectedDockerOutput(output.stdout) }

    // Connect to additional networks (if any)
    for network in request.networks.dropFirst() {
        try await connectToNetwork(
            containerId: id,
            networkName: network.networkName,
            aliases: network.aliases,
            ipv4Address: network.ipv4Address,
            ipv6Address: network.ipv6Address
        )
    }

    return id
}
```

**Notes**:
- First network attached via `docker run --network`
- Additional networks attached via `docker network connect`
- Network aliases added via `--network-alias` flag (at start) or `--alias` (when connecting)
- IP addresses specified via `--ip` and `--ip6` flags

**Estimated Effort**: 1 hour

### Step 4: Add Network Connection Method

**File**: `/Sources/TestContainers/DockerClient.swift`

Add the `connectToNetwork` method as shown in the API Design section above.

**Estimated Effort**: 30 minutes

### Step 5: Add Unit Tests

**File**: `/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests for network configuration:

```swift
@Test func withSingleNetwork() {
    let request = ContainerRequest(image: "alpine:3")
        .withNetwork("test-network")

    #expect(request.networks.count == 1)
    #expect(request.networks[0].networkName == "test-network")
    #expect(request.networks[0].aliases.isEmpty)
}

@Test func withNetworkAndAliases() {
    let request = ContainerRequest(image: "alpine:3")
        .withNetwork("test-network", aliases: ["service1", "app"])

    #expect(request.networks.count == 1)
    #expect(request.networks[0].aliases == ["service1", "app"])
}

@Test func withMultipleNetworks() {
    let request = ContainerRequest(image: "alpine:3")
        .withNetwork("network1")
        .withNetwork("network2", aliases: ["alias1"])

    #expect(request.networks.count == 2)
    #expect(request.networks[0].networkName == "network1")
    #expect(request.networks[1].networkName == "network2")
}

@Test func withNetworkAttachment() {
    let attachment = NetworkAttachment(
        networkName: "custom-network",
        aliases: ["service"],
        ipv4Address: "172.20.0.5"
    )
    let request = ContainerRequest(image: "alpine:3")
        .withNetwork(attachment)

    #expect(request.networks[0].ipv4Address == "172.20.0.5")
}

@Test func withNetworkMode() {
    let hostRequest = ContainerRequest(image: "alpine:3")
        .withNetworkMode(.host)
    #expect(hostRequest.networkMode == .host)

    let containerRequest = ContainerRequest(image: "alpine:3")
        .withNetworkMode(.container("other-container"))
    #expect(containerRequest.networkMode == .container("other-container"))
}

@Test func networkModeDockerFlags() {
    #expect(NetworkMode.bridge.dockerFlag == "bridge")
    #expect(NetworkMode.host.dockerFlag == "host")
    #expect(NetworkMode.none.dockerFlag == "none")
    #expect(NetworkMode.container("app").dockerFlag == "container:app")
    #expect(NetworkMode.custom("my-net").dockerFlag == "my-net")
}
```

**Estimated Effort**: 45 minutes

### Step 6: Add Integration Tests

**File**: `/Tests/TestContainersTests/DockerIntegrationTests.swift` or new file

Add integration tests with real Docker networks:

```swift
@Test func containerAttachesToSingleNetwork() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create test network
    let docker = DockerClient()
    let networkName = "test-network-\(UUID().uuidString)"
    _ = try await docker.runDocker(["network", "create", networkName])
    defer { _ = try? await docker.runDocker(["network", "rm", networkName]) }

    let request = ContainerRequest(image: "alpine:3")
        .withNetwork(networkName)
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        // Verify container is on the network
        let output = try await docker.runDocker([
            "inspect", container.id,
            "--format", "{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}"
        ])
        #expect(!output.stdout.isEmpty)
    }
}

@Test func containerAttachesToMultipleNetworks() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()
    let network1 = "test-net1-\(UUID().uuidString)"
    let network2 = "test-net2-\(UUID().uuidString)"

    _ = try await docker.runDocker(["network", "create", network1])
    _ = try await docker.runDocker(["network", "create", network2])
    defer {
        _ = try? await docker.runDocker(["network", "rm", network1])
        _ = try? await docker.runDocker(["network", "rm", network2])
    }

    let request = ContainerRequest(image: "alpine:3")
        .withNetwork(network1)
        .withNetwork(network2)
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        // Verify container is on both networks
        let output = try await docker.runDocker([
            "inspect", container.id,
            "--format", "{{json .NetworkSettings.Networks}}"
        ])
        #expect(output.stdout.contains(network1))
        #expect(output.stdout.contains(network2))
    }
}

@Test func containerToContainerCommunication() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()
    let networkName = "test-comm-network-\(UUID().uuidString)"
    _ = try await docker.runDocker(["network", "create", networkName])
    defer { _ = try? await docker.runDocker(["network", "rm", networkName]) }

    // Start Redis on custom network with alias
    let redisRequest = ContainerRequest(image: "redis:7-alpine")
        .withNetwork(networkName, aliases: ["redis", "cache"])
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

    try await withContainer(redisRequest) { redis in
        // Start Alpine container on same network to test DNS resolution
        let testRequest = ContainerRequest(image: "alpine:3")
            .withNetwork(networkName)
            .withCommand(["sleep", "30"])

        try await withContainer(testRequest) { alpine in
            // Test DNS resolution of alias
            let output = try await docker.runDocker([
                "exec", alpine.id,
                "nslookup", "redis"
            ])
            #expect(output.stdout.contains("redis"))

            // Test connectivity (Redis is running)
            let pingOutput = try await docker.runDocker([
                "exec", alpine.id,
                "nc", "-zv", "redis", "6379"
            ])
            #expect(pingOutput.exitCode == 0)
        }
    }
}

@Test func containerWithHostNetworkMode() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withNetworkMode(.host)
        .withCommand(["sleep", "5"])

    try await withContainer(request) { container in
        let docker = DockerClient()
        let output = try await docker.runDocker([
            "inspect", container.id,
            "--format", "{{.HostConfig.NetworkMode}}"
        ])
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "host")
    }
}

@Test func containerWithCustomIPAddress() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()
    let networkName = "test-ip-network-\(UUID().uuidString)"

    // Create network with custom subnet
    _ = try await docker.runDocker([
        "network", "create",
        "--subnet", "172.20.0.0/16",
        networkName
    ])
    defer { _ = try? await docker.runDocker(["network", "rm", networkName]) }

    let request = ContainerRequest(image: "alpine:3")
        .withNetwork(NetworkAttachment(
            networkName: networkName,
            ipv4Address: "172.20.0.10"
        ))
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let output = try await docker.runDocker([
            "inspect", container.id,
            "--format", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}"
        ])
        #expect(output.stdout.contains("172.20.0.10"))
    }
}
```

**Estimated Effort**: 2 hours

### Step 7: Documentation

Update README or add usage guide:

1. Basic network attachment examples
2. Multi-container communication patterns
3. Network alias usage for service discovery
4. Network mode options (host, bridge, none, container)
5. Custom IP assignment
6. Best practices for test isolation
7. Notes about network lifecycle management

**Estimated Effort**: 1 hour

## Dependencies

### Docker Network Commands

This feature depends on Docker CLI network commands:

1. **`docker run --network`**: Attach container to network at start
2. **`docker run --network-alias`**: Set DNS aliases at start
3. **`docker run --ip`**: Set IPv4 address at start
4. **`docker run --ip6`**: Set IPv6 address at start
5. **`docker network connect`**: Attach running container to additional networks
6. **`docker network connect --alias`**: Set DNS aliases when connecting
7. **`docker inspect`**: Verify network configuration (testing only)

**Mitigation**: All required Docker commands are standard and available in Docker Engine 1.9+. The existing `DockerClient` infrastructure handles command execution reliably.

### Network Creation

**Note**: This feature assumes networks already exist. Network creation and management should be handled separately (see Tier 2 features in FEATURES.md). Users are responsible for:
- Creating networks before starting containers
- Cleaning up networks after tests
- Managing network lifecycle

**Future Work**: Consider adding `withNetwork(_:_:)` scoped lifecycle helper (similar to `withContainer`) or network creation methods to `DockerClient`.

### Related Features

- **Container Lifecycle**: Basic container start/stop (implemented)
- **Port Mapping**: Port exposure and mapping (implemented)
- **Network Creation**: Creating/removing Docker networks (not implemented - separate feature)
- **Multi-Container Orchestration**: Managing related containers (future feature)

## Testing Plan

### Unit Tests

Location: `/Tests/TestContainersTests/ContainerRequestTests.swift`

1. Test single network attachment configuration
2. Test multiple network attachments
3. Test network with aliases
4. Test network with custom IP addresses
5. Test network mode enum cases
6. Test builder method chaining
7. Test `Hashable` and `Equatable` conformance
8. Test `Sendable` conformance (compile-time check)
9. Test `NetworkMode.dockerFlag` property

### Integration Tests

Location: `/Tests/TestContainersTests/DockerIntegrationTests.swift`

1. **Single network**: Container attaches to one custom network
2. **Multiple networks**: Container attaches to multiple networks
3. **Network aliases**: DNS resolution works via aliases
4. **Container communication**: Two containers communicate via custom network
5. **Host mode**: Container uses host networking
6. **None mode**: Container has no networking
7. **Container mode**: Container shares network with another container
8. **Custom IP**: Container receives assigned IP address
9. **Mixed configuration**: Network + ports + environment all work together

### Manual Testing

1. Test with various network drivers (bridge, overlay, macvlan)
2. Test network isolation (containers on different networks can't communicate)
3. Test with Docker Compose networks
4. Test network cleanup on container termination
5. Verify no network resource leaks
6. Test concurrent containers on same network
7. Test with IPv6 networks

### Performance Testing

1. Measure overhead of multiple network attachments
2. Verify `docker network connect` completes quickly
3. Test with many networks (10+) per container

## Acceptance Criteria

### Functional

- [ ] `NetworkAttachment` struct added with network name, aliases, and IP addresses
- [ ] `NetworkMode` enum added with standard modes and custom networks
- [ ] `ContainerRequest.networks` property added for multiple attachments
- [ ] `ContainerRequest.networkMode` property added for special modes
- [ ] `withNetwork(_:)` builder method attaches to single network
- [ ] `withNetwork(_:aliases:)` builder method attaches with aliases
- [ ] `withNetwork(_:)` (NetworkAttachment) builder method supports full configuration
- [ ] `withNetworkMode(_:)` builder method sets network mode
- [ ] First network attached via `docker run --network`
- [ ] Additional networks attached via `docker network connect`
- [ ] Network aliases work for DNS resolution
- [ ] Custom IP addresses assigned correctly
- [ ] Network mode (host, none, container) works correctly

### Code Quality

- [ ] Follows existing builder pattern conventions
- [ ] Proper error handling with descriptive messages
- [ ] `Sendable` and `Hashable` conformance maintained
- [ ] No new compiler warnings
- [ ] Code is well-documented with inline comments
- [ ] Public APIs have DocC documentation comments

### Testing

- [ ] Unit tests verify configuration and builder methods
- [ ] Integration tests verify network attachment
- [ ] Integration tests verify multi-container communication
- [ ] Integration tests verify network modes
- [ ] Integration tests verify custom IP assignment
- [ ] All tests pass in CI/CD pipeline
- [ ] Tests use opt-in Docker execution pattern

### Documentation

- [ ] API documentation added for new types and methods
- [ ] Usage examples provided for common scenarios
- [ ] README updated with network feature examples
- [ ] Multi-container communication patterns documented
- [ ] Notes about network lifecycle management
- [ ] Best practices for test isolation documented

## Open Questions

1. **Network creation**: Should we provide network creation helpers?
   - **Recommendation**: No, keep it separate. Users can create networks manually or we can add a separate feature for network lifecycle management.

2. **Network mode vs networks**: What if both are specified?
   - **Recommendation**: `networkMode` takes precedence for the primary network. Additional networks in `networks` array are still attached via `docker network connect`.

3. **IP address conflicts**: How to handle IP address already in use?
   - **Recommendation**: Let Docker handle it and propagate error. Document that IP addresses must be available.

4. **Default network**: Should containers still go on default bridge if no network specified?
   - **Recommendation**: Yes, maintain Docker's default behavior. Only override when explicitly configured.

5. **Network disconnection**: Should we support disconnecting from networks?
   - **Recommendation**: No, not in this feature. Containers are ephemeral in test scenarios. Add to `Container` API later if needed.

6. **Scoped network lifecycle**: Should we add `withNetwork(_:_:)` helper?
   - **Recommendation**: Defer to separate feature. This feature focuses on attaching to existing networks.

7. **Link aliases vs network aliases**: Should we support legacy `--link` flag?
   - **Recommendation**: No, Docker deprecated `--link` in favor of user-defined networks. Use network aliases only.

## Risks and Mitigations

### Risk: Network Not Found

**Impact**: Container start fails if specified network doesn't exist.

**Mitigation**:
- Document that networks must be created before use
- Provide clear error messages from Docker
- Show examples of network creation in documentation
- Consider adding network existence check before container start (optional enhancement)

### Risk: IP Address Conflicts

**Impact**: Container start fails if IP address is already in use.

**Mitigation**:
- Document IP address management best practices
- Recommend dynamic IP assignment for most use cases
- Propagate Docker error messages clearly
- Suggest using static IPs only when necessary

### Risk: Multiple Network Attachment Failures

**Impact**: Container starts on first network but fails to attach to additional networks.

**Mitigation**:
- Implement atomic network attachment (all or nothing)
- If any `docker network connect` fails, remove the container
- Log which network attachment failed
- Return clear error with network name that failed

### Risk: DNS Resolution Delays

**Impact**: Container-to-container communication might fail immediately after start.

**Mitigation**:
- Document that DNS propagation may take brief moment
- Recommend using wait strategies for network-dependent services
- Suggest retry logic in application code
- Consider adding network wait strategy (future enhancement)

### Risk: Network Resource Leaks

**Impact**: Networks might not be cleaned up after tests.

**Mitigation**:
- Document network cleanup responsibility
- Show examples of network cleanup in defer blocks
- Consider adding cleanup helper functions
- Use unique network names (UUID) in tests to avoid conflicts

## Future Enhancements

1. **Network Creation API**: Add methods to create/remove networks (`DockerClient.createNetwork`, `withNetwork(_:_:)` scoped helper)
2. **Network Inspection**: Query network details, connected containers, subnet info
3. **Network Wait Strategy**: Wait for network-dependent services to be reachable
4. **Link Endpoints**: Discover endpoints of other containers on same network
5. **Network Drivers**: Support custom network driver options (MTU, gateways, etc.)
6. **IPv6 First-Class Support**: Better IPv6 configuration and testing
7. **Network Aliases from Container**: Add aliases without knowing network in advance
8. **Overlay Networks**: Support for Swarm mode and overlay networking
9. **Network Policies**: Apply network policies for security testing
10. **Network Statistics**: Query network usage and performance metrics

## References

- **Existing code**: `/Sources/TestContainers/ContainerRequest.swift`
- **Docker client**: `/Sources/TestContainers/DockerClient.swift` (lines 28-54)
- **Container lifecycle**: `/Sources/TestContainers/WithContainer.swift`
- **Test patterns**: `/Tests/TestContainersTests/DockerIntegrationTests.swift`
- **Docker CLI reference**:
  - `docker run --network`: https://docs.docker.com/engine/reference/commandline/run/#network
  - `docker network connect`: https://docs.docker.com/engine/reference/commandline/network_connect/
  - User-defined networks: https://docs.docker.com/network/bridge/
- **Similar projects**:
  - Testcontainers Java: `Network` and `GenericContainer.withNetwork()`
  - Testcontainers Go: `NetworkRequest` and `ContainerRequest.Networks`
  - Testcontainers Python: `Network` and `DockerContainer.with_network()`

## Estimated Total Effort

- Implementation: 4.5 hours
- Testing: 3 hours
- Documentation: 1 hour
- Code review and refinement: 1 hour
- **Total**: ~9.5 hours
