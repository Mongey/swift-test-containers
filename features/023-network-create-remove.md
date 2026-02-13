# Feature 023: Network Create and Remove

## Summary

Implement Docker network creation and removal (`docker network create` and `docker network rm`) to enable custom network management in swift-test-containers. This feature allows users to create isolated networks for container communication, define network drivers (bridge, host, overlay, etc.), configure subnets and gateways, and cleanly remove networks after use.

Networks are essential for multi-container testing scenarios where containers need to communicate with each other, and for isolating test environments from default Docker networks.

## Current State

The codebase currently has **no network support**. Analysis of `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/` shows:

- **DockerClient.swift**: Manages container lifecycle (`run`, `rm`, `logs`, `port`) but has no network operations
- **ContainerRequest.swift**: Supports image, name, command, environment, labels, and ports, but no network attachment options
- **Container.swift**: Provides container handles for port mapping and logs, but no network information
- **WithContainer.swift**: Scoped lifecycle management for containers only

Containers currently run on Docker's default bridge network with no ability to:
- Create custom networks with specific configurations
- Attach containers to user-defined networks
- Configure network aliases for container-to-container communication
- Clean up networks after tests

From `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md` (lines 66-71):
```
**Networking**
- [ ] Create/remove networks (`docker network create/rm`)
- [ ] Attach container to network(s) on start
- [ ] Network aliases (container-to-container by name)
- [ ] Container-to-container communication helpers
- [ ] `withNetwork(_:_:)` scoped lifecycle
```

## Requirements

### Functional Requirements

1. **Network Creation**
   - Create Docker networks with user-defined names
   - Support network drivers: `bridge` (default), `host`, `overlay`, `macvlan`, `none`
   - Configure network options (e.g., `com.docker.network.bridge.name`, `com.docker.network.driver.mtu`)
   - Set network labels for metadata and cleanup tracking
   - Configure subnet CIDR (e.g., "172.20.0.0/16")
   - Configure gateway IP (e.g., "172.20.0.1")
   - Configure IP range for container allocation
   - Enable/disable IPv6
   - Set internal network flag (no external connectivity)
   - Configure attachable flag (for swarm mode)

2. **Network Removal**
   - Remove networks by name or ID
   - Handle cleanup gracefully even if network doesn't exist
   - Provide clear error messages if network is still in use by containers

3. **Network Handle**
   - Return network ID and name after creation
   - Provide network metadata (driver, subnet, gateway)
   - Support querying network existence

4. **Scoped Lifecycle** (Future)
   - `withNetwork(_:_:)` function similar to `withContainer(_:_:)`
   - Automatic cleanup on success, error, and cancellation
   - Support for multi-container scenarios within single network

### Non-Functional Requirements

1. **Consistency**: Follow existing patterns from container management
2. **Idiomatic Swift**: Use `actor`, `async/await`, `Sendable`, builder pattern
3. **Testability**: Support unit and integration testing
4. **Error Handling**: Clear, actionable error messages
5. **Concurrency Safety**: Thread-safe network operations via actor model

## API Design

### NetworkRequest Builder

Following the pattern established in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`, create a fluent builder for network configuration:

```swift
// File: /Sources/TestContainers/NetworkRequest.swift
import Foundation

public struct NetworkRequest: Sendable, Hashable {
    public var name: String?
    public var driver: NetworkDriver
    public var options: [String: String]
    public var labels: [String: String]
    public var ipamConfig: IPAMConfig?
    public var enableIPv6: Bool
    public var `internal`: Bool
    public var attachable: Bool

    public init() {
        self.name = nil
        self.driver = .bridge
        self.options = [:]
        self.labels = ["testcontainers.swift": "true"]
        self.ipamConfig = nil
        self.enableIPv6 = false
        self.internal = false
        self.attachable = false
    }

    public func withName(_ name: String) -> Self {
        var copy = self
        copy.name = name
        return copy
    }

    public func withDriver(_ driver: NetworkDriver) -> Self {
        var copy = self
        copy.driver = driver
        return copy
    }

    public func withOption(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.options[key] = value
        return copy
    }

    public func withLabel(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.labels[key] = value
        return copy
    }

    public func withIPAM(_ config: IPAMConfig) -> Self {
        var copy = self
        copy.ipamConfig = config
        return copy
    }

    public func withIPv6(_ enabled: Bool) -> Self {
        var copy = self
        copy.enableIPv6 = enabled
        return copy
    }

    public func asInternal(_ internal: Bool) -> Self {
        var copy = self
        copy.internal = `internal`
        return copy
    }

    public func asAttachable(_ attachable: Bool) -> Self {
        var copy = self
        copy.attachable = attachable
        return copy
    }
}

public enum NetworkDriver: String, Sendable, Hashable {
    case bridge
    case host
    case overlay
    case macvlan
    case none
}

public struct IPAMConfig: Sendable, Hashable {
    public var subnet: String?
    public var gateway: String?
    public var ipRange: String?

    public init(subnet: String? = nil, gateway: String? = nil, ipRange: String? = nil) {
        self.subnet = subnet
        self.gateway = gateway
        self.ipRange = ipRange
    }
}
```

### Network Handle

Following the pattern from `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`:

```swift
// File: /Sources/TestContainers/Network.swift
import Foundation

public actor Network {
    public let id: String
    public let name: String
    public let request: NetworkRequest

    private let docker: DockerClient

    init(id: String, name: String, request: NetworkRequest, docker: DockerClient) {
        self.id = id
        self.name = name
        self.request = request
        self.docker = docker
    }

    public func remove() async throws {
        try await docker.removeNetwork(id: id)
    }
}
```

### DockerClient Extensions

Add network operations to `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`:

```swift
// Add to DockerClient actor
func createNetwork(_ request: NetworkRequest) async throws -> (id: String, name: String) {
    var args: [String] = ["network", "create"]

    args += ["--driver", request.driver.rawValue]

    for (key, value) in request.options.sorted(by: { $0.key < $1.key }) {
        args += ["--opt", "\(key)=\(value)"]
    }

    for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
        args += ["--label", "\(key)=\(value)"]
    }

    if let ipam = request.ipamConfig {
        if let subnet = ipam.subnet {
            args += ["--subnet", subnet]
        }
        if let gateway = ipam.gateway {
            args += ["--gateway", gateway]
        }
        if let ipRange = ipam.ipRange {
            args += ["--ip-range", ipRange]
        }
    }

    if request.enableIPv6 {
        args += ["--ipv6"]
    }

    if request.internal {
        args += ["--internal"]
    }

    if request.attachable {
        args += ["--attachable"]
    }

    // Generate name if not provided
    let networkName = request.name ?? "tc-network-\(UUID().uuidString.prefix(8))"
    args.append(networkName)

    let output = try await runDocker(args)
    let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else {
        throw TestContainersError.unexpectedDockerOutput(output.stdout)
    }

    return (id: id, name: networkName)
}

func removeNetwork(id: String) async throws {
    _ = try await runDocker(["network", "rm", id])
}

func networkExists(_ nameOrID: String) async throws -> Bool {
    // Use docker network inspect, return false if exit code != 0
    do {
        _ = try await runDocker(["network", "inspect", nameOrID])
        return true
    } catch {
        return false
    }
}
```

### Scoped Lifecycle Function (Future Enhancement)

Following the pattern from `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`:

```swift
// File: /Sources/TestContainers/WithNetwork.swift
import Foundation

public func withNetwork<T>(
    _ request: NetworkRequest = NetworkRequest(),
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Network) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable(
            "`docker` CLI not found or Docker engine not running."
        )
    }

    let (id, name) = try await docker.createNetwork(request)
    let network = Network(id: id, name: name, request: request, docker: docker)

    let cleanup: () -> Void = {
        _ = Task { try? await network.remove() }
    }

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

```swift
// Example 1: Basic network creation and removal
let docker = DockerClient()
let request = NetworkRequest()
    .withName("my-test-network")

let (id, name) = try await docker.createNetwork(request)
print("Created network: \(name) (\(id))")
try await docker.removeNetwork(id: id)

// Example 2: Custom subnet configuration
let request = NetworkRequest()
    .withName("isolated-network")
    .withIPAM(IPAMConfig(
        subnet: "172.20.0.0/16",
        gateway: "172.20.0.1"
    ))
    .asInternal(true)

let network = Network(/* ... */)
defer { try? await network.remove() }

// Example 3: Scoped lifecycle (Future)
try await withNetwork(
    NetworkRequest()
        .withName("test-network")
        .withDriver(.bridge)
) { network in
    // Network automatically cleaned up after block
    print("Network ID: \(network.id)")
}

// Example 4: Multi-container with shared network (Future)
try await withNetwork(
    NetworkRequest().withName("app-network")
) { network in
    let dbRequest = ContainerRequest(image: "postgres:16")
        .withNetwork(network.name)
        .withNetworkAlias("database")

    let appRequest = ContainerRequest(image: "myapp:latest")
        .withNetwork(network.name)
        .withEnvironment(["DB_HOST": "database"])

    try await withContainer(dbRequest) { db in
        try await withContainer(appRequest) { app in
            // Both containers on same network, app can reach db at "database:5432"
        }
    }
}
```

## Implementation Steps

### Step 1: Create NetworkRequest Builder

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/NetworkRequest.swift`

**Tasks**:
1. Create `NetworkRequest` struct with builder pattern (following `ContainerRequest`)
2. Create `NetworkDriver` enum with common drivers
3. Create `IPAMConfig` struct for subnet/gateway configuration
4. Implement all builder methods (`withName`, `withDriver`, etc.)
5. Ensure `Sendable` and `Hashable` conformance

**Pattern Reference**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` (lines 26-89)

**Estimated Effort**: 1.5 hours

### Step 2: Add Network Operations to DockerClient

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

**Tasks**:
1. Implement `createNetwork(_:)` method
   - Build `docker network create` command with all flags
   - Handle name generation if not provided
   - Return network ID and name tuple
   - Parse Docker output correctly
2. Implement `removeNetwork(id:)` method
   - Simple `docker network rm` wrapper
   - Consistent with `removeContainer(id:)` pattern (line 56-58)
3. Implement `networkExists(_:)` helper (optional, for testing)

**Pattern Reference**:
- `runContainer(_:)` method (lines 28-54)
- `removeContainer(id:)` method (lines 56-58)
- Argument building pattern with sorted dictionaries (lines 35-45)

**Estimated Effort**: 2 hours

### Step 3: Create Network Handle

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Network.swift`

**Tasks**:
1. Create `Network` actor with id, name, request, and docker client
2. Implement `remove()` method
3. Follow the same pattern as `Container` actor

**Pattern Reference**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift` (lines 3-13, 32-34)

**Estimated Effort**: 30 minutes

### Step 4: Add Network Errors to TestContainersError

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

**Tasks**:
1. Add network-specific error cases if needed (e.g., `.networkInUse`)
2. Update error descriptions

**Pattern Reference**: Lines 3-21 for existing error cases

**Estimated Effort**: 20 minutes

### Step 5: Add Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/NetworkRequestTests.swift` (new file)

**Tasks**:
1. Test `NetworkRequest` builder methods
2. Test default values
3. Test `Hashable` and `Equatable` conformance
4. Test IPAM configuration

```swift
import Testing
import TestContainers

@Test func defaultNetworkRequest() {
    let request = NetworkRequest()
    #expect(request.driver == .bridge)
    #expect(request.labels["testcontainers.swift"] == "true")
    #expect(request.enableIPv6 == false)
}

@Test func configuresNetworkName() {
    let request = NetworkRequest()
        .withName("test-network")

    #expect(request.name == "test-network")
}

@Test func configuresNetworkDriver() {
    let request = NetworkRequest()
        .withDriver(.overlay)

    #expect(request.driver == .overlay)
}

@Test func configuresIPAM() {
    let request = NetworkRequest()
        .withIPAM(IPAMConfig(
            subnet: "172.20.0.0/16",
            gateway: "172.20.0.1"
        ))

    #expect(request.ipamConfig?.subnet == "172.20.0.0/16")
    #expect(request.ipamConfig?.gateway == "172.20.0.1")
}

@Test func configuresLabels() {
    let request = NetworkRequest()
        .withLabel("env", "test")
        .withLabel("team", "backend")

    #expect(request.labels["env"] == "test")
    #expect(request.labels["team"] == "backend")
    #expect(request.labels["testcontainers.swift"] == "true")
}

@Test func configuresNetworkOptions() {
    let request = NetworkRequest()
        .withOption("com.docker.network.driver.mtu", "1500")

    #expect(request.options["com.docker.network.driver.mtu"] == "1500")
}

@Test func networkRequestIsHashable() {
    let req1 = NetworkRequest().withName("net1")
    let req2 = NetworkRequest().withName("net1")
    let req3 = NetworkRequest().withName("net2")

    #expect(req1 == req2)
    #expect(req1 != req3)
}
```

**Pattern Reference**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

**Estimated Effort**: 1 hour

### Step 6: Add Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/NetworkIntegrationTests.swift` (new file)

**Tasks**:
1. Test basic network creation and removal
2. Test network with custom subnet
3. Test network with labels and options
4. Test error handling (network in use, duplicate name)
5. Test cleanup of networks

```swift
import Testing
import TestContainers

@Test func canCreateAndRemoveNetwork() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()
    let request = NetworkRequest()
        .withName("test-network-\(UUID().uuidString)")

    let (id, name) = try await docker.createNetwork(request)
    #expect(!id.isEmpty)
    #expect(!name.isEmpty)

    // Verify network exists
    let exists = try await docker.networkExists(id)
    #expect(exists)

    // Clean up
    try await docker.removeNetwork(id: id)
}

@Test func canCreateNetworkWithCustomSubnet() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()
    let request = NetworkRequest()
        .withName("subnet-test-\(UUID().uuidString)")
        .withIPAM(IPAMConfig(
            subnet: "172.28.0.0/16",
            gateway: "172.28.0.1"
        ))

    let (id, _) = try await docker.createNetwork(request)
    defer { _ = try? await docker.removeNetwork(id: id) }

    #expect(!id.isEmpty)
}

@Test func canCreateInternalNetwork() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()
    let request = NetworkRequest()
        .withName("internal-test-\(UUID().uuidString)")
        .asInternal(true)

    let (id, _) = try await docker.createNetwork(request)
    defer { _ = try? await docker.removeNetwork(id: id) }

    #expect(!id.isEmpty)
}

@Test func networkActorCanRemoveNetwork() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()
    let request = NetworkRequest()
        .withName("actor-test-\(UUID().uuidString)")

    let (id, name) = try await docker.createNetwork(request)
    let network = Network(id: id, name: name, request: request, docker: docker)

    // Network should exist
    let exists = try await docker.networkExists(id)
    #expect(exists)

    // Remove via actor
    try await network.remove()

    // Network should not exist
    let existsAfter = try await docker.networkExists(id)
    #expect(!existsAfter)
}

@Test func generatesNameIfNotProvided() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()
    let request = NetworkRequest()

    let (id, name) = try await docker.createNetwork(request)
    defer { _ = try? await docker.removeNetwork(id: id) }

    #expect(!id.isEmpty)
    #expect(name.hasPrefix("tc-network-"))
}
```

**Pattern Reference**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

**Estimated Effort**: 2 hours

### Step 7: Implement Scoped Lifecycle (Optional, Future Enhancement)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithNetwork.swift`

**Tasks**:
1. Create `withNetwork(_:docker:operation:)` function
2. Follow exact pattern from `withContainer`
3. Ensure cleanup on success, error, and cancellation

**Pattern Reference**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift` (lines 3-30)

**Estimated Effort**: 1 hour

### Step 8: Documentation

**Tasks**:
1. Add API documentation comments to all public types and methods
2. Add usage examples to feature ticket or README
3. Document network driver options and limitations
4. Note about network cleanup and best practices

**Estimated Effort**: 1 hour

### Total Estimated Effort: 9-11 hours

## Dependencies

### Docker CLI

This feature depends on the `docker network` command set:
- `docker network create [OPTIONS] NETWORK`
- `docker network rm NETWORK [NETWORK...]`
- `docker network inspect NETWORK`

These commands are available in all modern Docker versions (17.06+).

### Existing Infrastructure

Leverages existing infrastructure:
- `ProcessRunner` actor for command execution
- `DockerClient.runDocker(_:)` for Docker CLI invocation
- `TestContainersError` for error handling
- Builder pattern established by `ContainerRequest`

### Future Dependencies

Container network attachment (planned separately) will depend on this feature:
- `ContainerRequest.withNetwork(_:)` will reference network names
- `ContainerRequest.withNetworkAlias(_:)` will set container aliases on networks

## Testing Plan

### Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/NetworkRequestTests.swift`

1. Test all builder methods return correct values
2. Test default values are applied correctly
3. Test `Hashable` conformance works correctly
4. Test `Sendable` conformance (compile-time check)
5. Test IPAM configuration builder
6. Test network driver enum cases

### Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/NetworkIntegrationTests.swift`

1. **Basic Creation**: Create and remove a simple bridge network
2. **Custom Subnet**: Create network with custom CIDR and gateway
3. **Internal Network**: Create internal network (no external connectivity)
4. **Labels**: Create network with custom labels, verify they're set
5. **Options**: Create network with driver options (MTU, etc.)
6. **Name Generation**: Verify auto-generated names when not provided
7. **Network Actor**: Test `Network.remove()` method
8. **Error Cases**: Test removal of non-existent network
9. **Concurrent Creation**: Create multiple networks in parallel
10. **Cleanup**: Verify network doesn't exist after removal

### Manual Testing Checklist

1. Create network and inspect with `docker network inspect`
2. Verify subnet configuration is correct
3. Verify labels are applied correctly
4. Test with different drivers (bridge, overlay)
5. Test network removal with containers still attached (should fail gracefully)
6. Test parallel network creation and removal
7. Verify memory leaks don't occur with repeated create/remove cycles

### Performance Testing

1. Measure time to create/remove networks (should be < 500ms each)
2. Test rapid creation/removal cycles (10+ iterations)
3. Monitor for resource leaks with 100+ network lifecycle operations

## Acceptance Criteria

### Functional

- [x] `NetworkRequest` struct created with builder pattern
- [x] Support for network drivers: bridge, host, overlay, macvlan, none
- [x] Support for IPAM configuration (subnet, gateway, IP range)
- [x] Support for network options, labels, flags (internal, attachable, IPv6)
- [x] `DockerClient.createNetwork(_:)` executes `docker network create` correctly
- [x] `DockerClient.removeNetwork(id:)` executes `docker network rm` correctly
- [x] `Network` actor provides handle with id, name, and remove method
- [x] Network names auto-generated with `tc-network-` prefix if not provided
- [x] Networks have `testcontainers.swift: "true"` label by default

### Code Quality

- [x] Follows existing patterns from `ContainerRequest` and `Container`
- [x] All public APIs have documentation comments
- [x] `Sendable` and `Hashable` conformance maintained
- [x] Proper error handling with descriptive messages
- [x] No compiler warnings
- [x] Code formatted consistently with existing codebase

### Testing

- [x] Unit tests verify all builder methods and defaults
- [x] Integration tests cover creation, configuration, and removal (via mock docker script)
- [x] Error cases tested (non-existent network, etc.)
- [x] Tests follow opt-in pattern with `TESTCONTAINERS_RUN_DOCKER_TESTS=1`
- [x] All tests pass locally and in CI

### Documentation

- [ ] API documentation for `NetworkRequest`, `Network`, and DockerClient methods
- [ ] Usage examples for common scenarios
- [ ] Notes about Docker version requirements
- [ ] Guidance on network cleanup and best practices

## Open Questions

1. **Network Inspection**: Should we add `DockerClient.inspectNetwork()` to query network details?
   - **Recommendation**: Defer to future enhancement. Basic create/remove is sufficient for MVP.

2. **Network Driver Validation**: Should we validate driver names before sending to Docker?
   - **Recommendation**: No, let Docker handle validation. Return errors from Docker CLI.

3. **Duplicate Network Names**: How should we handle attempts to create networks with duplicate names?
   - **Recommendation**: Let Docker CLI fail with appropriate error. Don't add special handling.

4. **Container Attachment**: Should network creation automatically attach containers?
   - **Recommendation**: No, that's a separate feature. Networks and container attachment are orthogonal.

5. **Network Prune**: Should we add a cleanup method to remove all testcontainers networks?
   - **Recommendation**: Yes, add to future enhancements. Use label-based filtering: `docker network prune --filter label=testcontainers.swift=true`

6. **IPv6 Configuration**: Do we need detailed IPv6 subnet configuration?
   - **Recommendation**: Start simple with just `--ipv6` flag. Add detailed IPv6 IPAM in future if needed.

## Risks and Mitigations

### Risk: Network Name Conflicts

**Impact**: Multiple tests creating networks with the same name could collide.

**Mitigation**:
- Generate unique names by default using `tc-network-{uuid}`
- Document that users should use unique names in tests
- Consider adding test isolation guidance

### Risk: Network Cleanup Failures

**Impact**: Networks might not be removed if containers are still attached.

**Mitigation**:
- Document that containers must be removed before networks
- Add clear error messages when network removal fails
- Consider adding force-remove option in future (requires removing attached containers first)

### Risk: Driver Availability

**Impact**: Not all drivers are available in all Docker environments (e.g., overlay requires swarm mode).

**Mitigation**:
- Document driver requirements
- Let Docker CLI provide error messages
- Consider adding driver availability checks in future

### Risk: Subnet Conflicts

**Impact**: User-defined subnets might conflict with existing Docker networks or host routes.

**Mitigation**:
- Document subnet planning best practices
- Recommend using private IP ranges (172.x, 10.x, 192.168.x)
- Let Docker handle validation and conflicts

## Future Enhancements

### Tier 1: Container Network Attachment
- Add `ContainerRequest.withNetwork(_:)` to attach containers to networks
- Add `ContainerRequest.withNetworkAlias(_:)` for DNS aliases
- Support attaching to multiple networks

### Tier 2: Network Inspection and Querying
- `Network.inspect()` to get full network details
- `Network.connectedContainers()` to list attached containers
- `DockerClient.listNetworks()` to query all networks

### Tier 3: Advanced Network Configuration
- Support for custom IPAM drivers
- IPv6 configuration with custom subnets
- Network-level bandwidth limits
- Encrypted overlay networks

### Tier 4: Scoped Lifecycle
- `withNetwork(_:_:)` for automatic cleanup
- Support for multi-container scenarios within single network
- Nested network scopes

### Tier 5: Network Utilities
- Label-based network cleanup (sweep all testcontainers networks)
- Network prune with filters
- Wait strategies for network readiness (if needed)

## References

### Internal Codebase
- **Container patterns**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`
- **Request builder**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`
- **Docker client**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`
- **Scoped lifecycle**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`
- **Error handling**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`
- **Feature list**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md`

### Docker Documentation
- [Docker network create reference](https://docs.docker.com/engine/reference/commandline/network_create/)
- [Docker network rm reference](https://docs.docker.com/engine/reference/commandline/network_rm/)
- [Docker networking overview](https://docs.docker.com/network/)

### Similar Projects
- **Testcontainers Go**: `docker.CreateNetwork()`, `NetworkRequest` struct
- **Testcontainers Java**: `Network` class, `NetworkImpl` implementation
- **Testcontainers Node**: `DockerClient.createNetwork()` method

## Implementation Notes

### Command Structure

**Network Create**:
```bash
docker network create \
  --driver bridge \
  --subnet 172.20.0.0/16 \
  --gateway 172.20.0.1 \
  --ip-range 172.20.10.0/24 \
  --label testcontainers.swift=true \
  --label env=test \
  --opt com.docker.network.driver.mtu=1500 \
  --internal \
  --attachable \
  --ipv6 \
  my-network-name
```

**Network Remove**:
```bash
docker network rm my-network-name
# or by ID
docker network rm 9f3a8d2b1c4e
```

**Network Inspect** (for testing):
```bash
docker network inspect my-network-name
```

### Output Parsing

`docker network create` returns the network ID on stdout:
```
9f3a8d2b1c4e7f6a8b3d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b
```

### Error Handling

Common Docker network errors:
- Network already exists: `Error response from daemon: network with name my-network already exists`
- Network in use: `Error response from daemon: network my-network has active endpoints`
- Invalid subnet: `Error response from daemon: invalid subnet specified`
- Driver not available: `Error response from daemon: driver "overlay" not supported`

All errors are captured via `TestContainersError.commandFailed` from the existing error handling in `DockerClient.runDocker()`.
