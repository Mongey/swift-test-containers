# Feature 026: Container-to-Container Communication Helpers

## Summary

Implement helpers to enable container-to-container communication in swift-test-containers. This feature provides API methods to discover internal container endpoints (IP addresses, hostnames, internal ports) that other containers can use to connect within Docker networks. This is essential for multi-container test scenarios where one container needs to communicate with another (e.g., an application container connecting to a database container).

## Current State

The codebase currently supports host-to-container communication via port mapping in `/Sources/TestContainers/Container.swift`:

```swift
public func hostPort(_ containerPort: Int) async throws -> Int {
    try await docker.port(id: id, containerPort: containerPort)
}

public func host() -> String {
    request.host  // Returns "127.0.0.1" by default
}

public func endpoint(for containerPort: Int) async throws -> String {
    let port = try await hostPort(containerPort)
    return "\(request.host):\(port)"
}
```

**Key Characteristics**:
- `hostPort()` returns the **host-mapped port** (e.g., 32768) via `docker port`
- `host()` returns the **host IP** (default: 127.0.0.1)
- `endpoint()` combines them for host-to-container connections (e.g., "127.0.0.1:32768")

**What's Missing**:
- No way to get the container's **internal IP address** within Docker networks
- No way to get the container's **hostname** or **container ID** for DNS-based communication
- No way to construct **internal endpoints** using container ports (not host-mapped ports)
- No support for discovering network-specific IP addresses when a container is on multiple networks

**Current Limitations**:
1. Tests requiring container-to-container communication must manually run `docker inspect`
2. No typed API for internal networking information
3. Network-aware containers can't easily discover each other

From `/Sources/TestContainers/DockerClient.swift`, the infrastructure uses `docker` CLI commands:
- Container operations: `docker run`, `docker rm -f`, `docker logs`, `docker port`
- **Missing**: `docker inspect` for retrieving container metadata (including network information)

From `/Sources/TestContainers/ContainerRequest.swift`, containers can be configured with:
- Port mappings (host ↔ container)
- Environment variables
- Labels
- **Missing**: Network attachment (planned per FEATURES.md line 68)

## Requirements

### Functional Requirements

1. **Get Container Internal IP**: Retrieve the container's IP address within its Docker network(s)
   - Primary network IP (the first network the container is attached to)
   - Support for multiple networks (if container is on multiple networks)

2. **Get Container Hostname**: Retrieve the container's hostname/ID for DNS-based communication
   - Container ID (always available, usable as hostname)
   - Container name (if set via `.withName()`)

3. **Get Internal Port**: Access the container's internal port (not the host-mapped port)
   - Direct access to the port exposed within the container
   - No need to query `docker port` since internal ports are known from the request

4. **Build Internal Endpoints**: Construct connection strings for container-to-container communication
   - Format: `<internal-ip>:<container-port>`
   - Format: `<hostname>:<container-port>`

5. **Network-Aware Discovery**: Support containers on custom Docker networks
   - Get IP address for a specific network
   - Handle default bridge network vs. custom networks

### Non-Functional Requirements

1. **Consistency**: Follow existing API patterns (async actor methods, error handling)
2. **Performance**: Minimize `docker inspect` calls (cache results when possible)
3. **Clarity**: Clear distinction between host endpoints (external) and internal endpoints
4. **Testability**: Support both unit and integration testing
5. **Forward Compatibility**: Design API to support future network features

## API Design

### Proposed Container API Extensions

Add new methods to `/Sources/TestContainers/Container.swift`:

```swift
public actor Container {
    // ... existing properties and methods ...

    // MARK: - Container-to-Container Communication

    /// Returns the container's internal IP address within its primary Docker network.
    /// This IP is used for container-to-container communication, not host-to-container.
    ///
    /// - Returns: The container's internal IP address (e.g., "172.17.0.2")
    /// - Throws: `TestContainersError` if unable to inspect the container
    ///
    /// Example:
    /// ```swift
    /// let dbIP = try await dbContainer.internalIP()
    /// let appRequest = ContainerRequest(image: "myapp:latest")
    ///     .withEnvironment(["DB_HOST": dbIP])
    /// ```
    public func internalIP() async throws -> String {
        let networks = try await docker.inspectNetworks(id: id)
        guard let firstNetwork = networks.first else {
            throw TestContainersError.unexpectedDockerOutput("No networks found for container")
        }
        return firstNetwork.ipAddress
    }

    /// Returns the container's internal IP address for a specific Docker network.
    ///
    /// - Parameter networkName: The name of the Docker network
    /// - Returns: The container's IP address within the specified network
    /// - Throws: `TestContainersError` if the network is not found or has no IP
    ///
    /// Example:
    /// ```swift
    /// let ip = try await container.internalIP(forNetwork: "my-test-network")
    /// ```
    public func internalIP(forNetwork networkName: String) async throws -> String {
        let networks = try await docker.inspectNetworks(id: id)
        guard let network = networks.first(where: { $0.name == networkName }) else {
            throw TestContainersError.networkNotFound(networkName, id: id)
        }
        return network.ipAddress
    }

    /// Returns the container's hostname, which can be used for DNS-based communication
    /// within Docker networks that support DNS resolution.
    ///
    /// - Returns: The container's name (if set) or container ID (short form)
    ///
    /// Note: Container ID is always usable as a hostname within Docker networks.
    /// If a name was set via `.withName()`, that name is returned instead.
    ///
    /// Example:
    /// ```swift
    /// let dbHostname = try await dbContainer.internalHostname()
    /// // Returns "my-db" if started with .withName("my-db")
    /// // Returns "a1b2c3d4e5f6" if no name was set (short container ID)
    /// ```
    public func internalHostname() async throws -> String {
        if let name = request.name {
            return name
        }
        // Return short container ID (first 12 chars)
        return String(id.prefix(12))
    }

    /// Returns an internal endpoint (IP:port) for container-to-container communication.
    /// This uses the container's internal IP and internal port, not host-mapped values.
    ///
    /// - Parameter containerPort: The port exposed within the container
    /// - Returns: An endpoint string in the format "ip:port" (e.g., "172.17.0.2:5432")
    /// - Throws: `TestContainersError` if unable to get the container's internal IP
    ///
    /// Example:
    /// ```swift
    /// let dbEndpoint = try await dbContainer.internalEndpoint(for: 5432)
    /// // Returns "172.17.0.2:5432" (not "127.0.0.1:32768")
    /// ```
    public func internalEndpoint(for containerPort: Int) async throws -> String {
        let ip = try await internalIP()
        return "\(ip):\(containerPort)"
    }

    /// Returns an internal endpoint using the container's hostname instead of IP.
    /// Useful when DNS resolution is available (custom networks, not default bridge).
    ///
    /// - Parameter containerPort: The port exposed within the container
    /// - Returns: An endpoint string in the format "hostname:port"
    /// - Throws: `TestContainersError` if unable to get the container's hostname
    ///
    /// Example:
    /// ```swift
    /// let dbEndpoint = try await dbContainer.internalHostnameEndpoint(for: 5432)
    /// // Returns "my-db:5432" or "a1b2c3d4e5f6:5432"
    /// ```
    public func internalHostnameEndpoint(for containerPort: Int) async throws -> String {
        let hostname = try await internalHostname()
        return "\(hostname):\(containerPort)"
    }
}
```

### Proposed DockerClient Extensions

Add network inspection support to `/Sources/TestContainers/DockerClient.swift`:

```swift
public struct ContainerNetwork: Sendable, Hashable {
    public let name: String
    public let ipAddress: String
    public let gateway: String?
    public let networkID: String
}

extension DockerClient {
    /// Inspects a container's network configuration.
    ///
    /// - Parameter id: The container ID
    /// - Returns: Array of networks the container is attached to
    /// - Throws: `TestContainersError.commandFailed` if inspection fails
    func inspectNetworks(id: String) async throws -> [ContainerNetwork] {
        // Use docker inspect with Go template to extract network info
        let format = """
        {{range $net, $conf := .NetworkSettings.Networks}}\
        {{$net}},{{$conf.IPAddress}},{{$conf.Gateway}},{{$conf.NetworkID}}
        {{end}}
        """

        let output = try await runDocker([
            "inspect",
            "--format", format,
            id
        ])

        return try parseNetworkInspection(output.stdout)
    }

    private func parseNetworkInspection(_ output: String) throws -> [ContainerNetwork] {
        var networks: [ContainerNetwork] = []

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ",").map(String.init)
            guard parts.count == 4 else { continue }

            let name = parts[0]
            let ip = parts[1]
            let gateway = parts[2].isEmpty ? nil : parts[2]
            let networkID = parts[3]

            guard !ip.isEmpty else { continue }

            networks.append(ContainerNetwork(
                name: name,
                ipAddress: ip,
                gateway: gateway,
                networkID: networkID
            ))
        }

        guard !networks.isEmpty else {
            throw TestContainersError.unexpectedDockerOutput(
                "No network information found in docker inspect output"
            )
        }

        return networks
    }
}
```

### Proposed Error Extensions

Add to `/Sources/TestContainers/TestContainersError.swift`:

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    // ... existing cases ...
    case networkNotFound(String, id: String)

    public var description: String {
        switch self {
        // ... existing cases ...
        case let .networkNotFound(network, id):
            return "Network '\(network)' not found for container \(id)"
        }
    }
}
```

### Usage Examples

#### Example 1: Database + Application (IP-based communication)

```swift
import Testing
import TestContainers

@Test func appConnectsToDatabase() async throws {
    // Start PostgreSQL container
    let dbRequest = ContainerRequest(image: "postgres:16")
        .withName("test-db")
        .withEnvironment(["POSTGRES_PASSWORD": "secret"])
        .withExposedPort(5432)
        .waitingFor(.tcpPort(5432))

    try await withContainer(dbRequest) { db in
        // Get internal endpoint for container-to-container communication
        let dbInternalHost = try await db.internalIP()
        let dbInternalPort = 5432  // Container's internal port, not host-mapped

        // Start application container with database connection
        let appRequest = ContainerRequest(image: "myapp:latest")
            .withEnvironment([
                "DB_HOST": dbInternalHost,
                "DB_PORT": "\(dbInternalPort)",
                "DB_PASSWORD": "secret"
            ])
            .withExposedPort(8080)
            .waitingFor(.tcpPort(8080))

        try await withContainer(appRequest) { app in
            // Access app from host using host endpoint
            let appHostPort = try await app.hostPort(8080)
            let appURL = "http://127.0.0.1:\(appHostPort)"

            // Test that app can reach database...
        }
    }
}
```

#### Example 2: Using hostname-based communication

```swift
@Test func microservicesWithDNS() async throws {
    // Start service A
    let serviceARequest = ContainerRequest(image: "service-a:latest")
        .withName("service-a")
        .withExposedPort(8080)
        .waitingFor(.tcpPort(8080))

    try await withContainer(serviceARequest) { serviceA in
        // Get hostname for DNS-based communication
        let serviceAHostname = try await serviceA.internalHostname()
        // Returns "service-a"

        // Start service B that needs to call service A
        let serviceBRequest = ContainerRequest(image: "service-b:latest")
            .withEnvironment([
                "SERVICE_A_URL": "http://\(serviceAHostname):8080"
            ])
            .withExposedPort(9090)

        try await withContainer(serviceBRequest) { serviceB in
            // Test cross-service communication...
        }
    }
}
```

#### Example 3: Multiple networks

```swift
@Test func multipleNetworks() async throws {
    // When custom network support is added, this will work:
    let dbRequest = ContainerRequest(image: "postgres:16")
        .withName("db")
        .withExposedPort(5432)
        // .withNetwork("backend-network")  // Future feature

    try await withContainer(dbRequest) { db in
        // Get IP for specific network
        let backendIP = try await db.internalIP(forNetwork: "backend-network")

        // Or use primary network IP
        let primaryIP = try await db.internalIP()
    }
}
```

## Implementation Steps

### Step 1: Add ContainerNetwork struct and error case

**File**: `/Sources/TestContainers/DockerClient.swift`

1. Add the `ContainerNetwork` struct before the `DockerClient` class definition
2. Add the struct with all required properties (name, ipAddress, gateway, networkID)

**File**: `/Sources/TestContainers/TestContainersError.swift`

1. Add `case networkNotFound(String, id: String)` to the enum
2. Add corresponding description in the switch statement

**Estimated Effort**: 15 minutes

### Step 2: Implement Docker inspect for networks

**File**: `/Sources/TestContainers/DockerClient.swift`

1. Add `inspectNetworks(id:)` method to DockerClient
2. Implement using `docker inspect --format` with Go template
3. Add `parseNetworkInspection(_:)` helper method
4. Handle parsing errors gracefully

**Technical Details**:
- Use Go template format string to extract network data as CSV
- Format: `{{range}}` over `.NetworkSettings.Networks`
- Extract: network name, IP address, gateway, network ID
- Parse line-by-line, split by comma

**Estimated Effort**: 1 hour

### Step 3: Add internal IP methods to Container

**File**: `/Sources/TestContainers/Container.swift`

1. Add `internalIP()` method (returns primary network IP)
2. Add `internalIP(forNetwork:)` method (returns network-specific IP)
3. Both methods call `docker.inspectNetworks(id:)`
4. Add proper error handling for missing networks

**Estimated Effort**: 30 minutes

### Step 4: Add internal hostname method to Container

**File**: `/Sources/TestContainers/Container.swift`

1. Add `internalHostname()` method
2. Return `request.name` if available
3. Otherwise return short container ID (first 12 characters)
4. No network calls needed (data already available)

**Estimated Effort**: 15 minutes

### Step 5: Add internal endpoint methods to Container

**File**: `/Sources/TestContainers/Container.swift`

1. Add `internalEndpoint(for:)` method
2. Add `internalHostnameEndpoint(for:)` method
3. Both methods combine IP/hostname with port
4. No additional Docker calls (reuse existing methods)

**Estimated Effort**: 15 minutes

### Step 6: Add Unit Tests

**File**: `/Tests/TestContainersTests/ContainerRequestTests.swift` or new test file

Add tests for:
1. ContainerNetwork struct equality and hashing
2. Error case for network not found
3. Network inspection output parsing (mock Docker output)
4. Edge cases: empty networks, malformed output, missing IPs

```swift
@Test func parsesNetworkInspectionOutput() throws {
    let mockOutput = """
    bridge,172.17.0.2,172.17.0.1,abc123
    custom-net,172.20.0.5,172.20.0.1,def456

    """

    let networks = try DockerClient.parseNetworkInspection(mockOutput)

    #expect(networks.count == 2)
    #expect(networks[0].name == "bridge")
    #expect(networks[0].ipAddress == "172.17.0.2")
}
```

**Estimated Effort**: 1 hour

### Step 7: Add Integration Tests

**File**: `/Tests/TestContainersTests/DockerIntegrationTests.swift` or new file

Add integration tests with real containers:

```swift
@Test func getsContainerInternalIP() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let ip = try await container.internalIP()

        // Verify it's a valid IP address format
        #expect(ip.contains("."))
        #expect(!ip.isEmpty)

        // IP should be in private range (172.17.x.x for default bridge)
        #expect(ip.hasPrefix("172.") || ip.hasPrefix("192.168."))
    }
}

@Test func getsContainerHostname_withName() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withName("test-hostname-\(UUID().uuidString)")
        .withCommand(["sleep", "10"])

    try await withContainer(request) { container in
        let hostname = try await container.internalHostname()
        #expect(hostname.hasPrefix("test-hostname-"))
    }
}

@Test func getsContainerHostname_withoutName() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "10"])

    try await withContainer(request) { container in
        let hostname = try await container.internalHostname()

        // Should return short container ID (12 chars)
        #expect(hostname.count == 12)
        #expect(hostname == String(container.id.prefix(12)))
    }
}

@Test func buildsInternalEndpoint() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379))

    try await withContainer(request) { container in
        let endpoint = try await container.internalEndpoint(for: 6379)

        // Should be in format "ip:port"
        #expect(endpoint.contains(":6379"))
        let parts = endpoint.split(separator: ":")
        #expect(parts.count == 2)
        #expect(parts[1] == "6379")
    }
}

@Test func containerToContainerCommunication() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Start Redis container
    let redisRequest = ContainerRequest(image: "redis:7")
        .withName("test-redis")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379))

    try await withContainer(redisRequest) { redis in
        let redisIP = try await redis.internalIP()
        let redisHostname = try await redis.internalHostname()

        #expect(redisHostname == "test-redis")
        #expect(!redisIP.isEmpty)

        // Start Alpine container that can reach Redis
        let clientRequest = ContainerRequest(image: "alpine:3")
            .withCommand([
                "sh", "-c",
                "apk add --no-cache redis && sleep 30"
            ])

        try await withContainer(clientRequest) { client in
            // Verify we can get its IP too
            let clientIP = try await client.internalIP()
            #expect(clientIP != redisIP)  // Different IPs
        }
    }
}
```

**Estimated Effort**: 2 hours

### Step 8: Documentation

Add to README.md or create separate doc:

1. Explain the difference between host endpoints and internal endpoints
2. Provide usage examples for common scenarios:
   - Database + application communication
   - Multi-service architectures
   - DNS vs IP-based communication
3. Document limitations (default bridge network vs custom networks)
4. Add troubleshooting section

**Estimated Effort**: 1 hour

## Dependencies

### Required Infrastructure

1. **Docker CLI**: Must support `docker inspect` command (all modern versions do)
2. **Container Runtime**: Container must be running to inspect networks
3. **Network Information**: Container must be attached to at least one network

### Related Features

- **Network creation/attachment** (FEATURES.md line 67-69): This feature provides the *discovery* API; network management is separate
- **Container inspection** (FEATURES.md line 46): This feature implements a subset of inspection (networks only)
- **Module system** (FEATURES.md line 110-124): Service-specific modules will use these helpers for connection strings

### Future Dependencies

This feature will be enhanced by:
- Custom network support (containers on same network can use DNS)
- Network aliases (multiple names for same container)
- Multi-container orchestration (automatic endpoint discovery)

## Testing Plan

### Unit Tests

**Location**: `/Tests/TestContainersTests/ContainerNetworkTests.swift` (new file)

1. **Struct tests**:
   - ContainerNetwork equality
   - ContainerNetwork hashing
   - Sendable conformance (compile-time)

2. **Parsing tests**:
   - Valid network inspection output
   - Multiple networks
   - Single network
   - Empty gateway
   - Malformed output (missing fields)
   - Empty output
   - Output with no IPs

3. **Error handling tests**:
   - Network not found error message
   - Unexpected docker output error

### Integration Tests

**Location**: `/Tests/TestContainersTests/DockerIntegrationTests.swift`

1. **Single container tests**:
   - Get internal IP from container
   - Get hostname (with name set)
   - Get hostname (without name - uses container ID)
   - Build internal endpoint
   - Build hostname endpoint

2. **Multi-container tests**:
   - Two containers have different IPs
   - Container A can discover Container B's endpoint
   - IP addresses are in valid private ranges

3. **Real-world scenario tests**:
   - Redis container internal endpoint
   - PostgreSQL container internal endpoint
   - Alpine container with minimal setup

4. **Error scenario tests**:
   - Query non-existent network name
   - Handle container with no networks (should not happen in practice)

### Manual Testing

1. Test with various container images (Alpine, Redis, PostgreSQL, MySQL, Nginx)
2. Test with named vs unnamed containers
3. Verify IP addresses are reachable from other containers (requires custom network setup)
4. Test performance of repeated inspect calls
5. Verify behavior on different Docker setups (Docker Desktop, Docker Engine, Colima)

## Acceptance Criteria

### Functional

- [ ] `Container.internalIP()` returns the container's primary network IP address
- [ ] `Container.internalIP(forNetwork:)` returns IP for a specific network
- [ ] `Container.internalHostname()` returns container name or short ID
- [ ] `Container.internalEndpoint(for:)` returns IP:port format
- [ ] `Container.internalHostnameEndpoint(for:)` returns hostname:port format
- [ ] `DockerClient.inspectNetworks(id:)` parses network information correctly
- [ ] Error thrown when network not found
- [ ] Error thrown when container has no networks

### API Quality

- [ ] Methods follow async/await actor patterns
- [ ] Proper error handling with descriptive messages
- [ ] Method names clearly distinguish internal (container-to-container) from host endpoints
- [ ] Sendable conformance maintained throughout
- [ ] Public API well-documented with doc comments

### Code Quality

- [ ] No new compiler warnings
- [ ] Follows existing code style and patterns
- [ ] Proper separation of concerns (parsing in DockerClient, API in Container)
- [ ] Efficient: Docker inspect called only when needed
- [ ] Defensive: Handle malformed or unexpected Docker output

### Testing

- [ ] Unit tests verify parsing logic with mock data
- [ ] Integration tests verify real container network discovery
- [ ] Multi-container test verifies different IPs are assigned
- [ ] Error cases tested (network not found, no networks)
- [ ] All tests pass in CI/CD pipeline
- [ ] Tests gated by `TESTCONTAINERS_RUN_DOCKER_TESTS=1`

### Documentation

- [ ] API documentation (doc comments) for all public methods
- [ ] Usage examples in README or separate guide
- [ ] Clear explanation of host vs internal endpoints
- [ ] Troubleshooting guide for common issues
- [ ] Examples show both IP-based and hostname-based communication

## Open Questions

### 1. Caching Strategy

**Question**: Should we cache the results of `docker inspect` to avoid repeated calls?

**Options**:
- A) No caching: Call `docker inspect` every time (simple but potentially slow)
- B) Cache for container lifetime: Store results in Container actor (efficient but may miss dynamic changes)
- C) Time-based cache: Cache for N seconds (complex, may add stale data issues)

**Recommendation**: Start with **no caching (A)** for simplicity. Network information rarely changes during a container's lifetime in test scenarios. If performance becomes an issue, add caching in a future enhancement.

### 2. Network Selection Strategy

**Question**: When a container is on multiple networks, which one should `internalIP()` return?

**Options**:
- A) First network in the list (current approach)
- B) Default bridge network if present, otherwise first
- C) Network with the most containers
- D) Make it configurable

**Recommendation**: **A (first network)** for simplicity. Docker inspect returns networks in a consistent order. Most test containers only have one network (default bridge). For multi-network scenarios, users should use `internalIP(forNetwork:)` explicitly.

### 3. Network Aliases Support

**Question**: Should we support network aliases (alternate DNS names)?

**Context**: Docker networks can have aliases (e.g., container reachable as "db", "postgres", "primary-db")

**Recommendation**: **Defer to future enhancement**. Current API returns the container name or ID. Network aliases require additional inspection fields and API design. This feature is needed after custom network support is implemented.

### 4. Gateway and NetworkID Exposure

**Question**: Should we expose gateway and networkID in the public API?

**Recommendation**: **No, keep them in ContainerNetwork struct but don't add dedicated methods**. They're available if we need them later, but most use cases only need IP and hostname. This keeps the API surface small.

### 5. IPv6 Support

**Question**: How should we handle IPv6 addresses?

**Recommendation**: **Support automatically if present**. The parsing logic should handle both IPv4 and IPv6 addresses. `docker inspect` returns the format Docker assigns. No special handling needed initially. Can add specific IPv6 methods if needed later.

### 6. Port Validation

**Question**: Should `internalEndpoint(for:)` validate that the port was actually exposed?

**Recommendation**: **No validation**. The method is informational - it tells you *how* to reach the port if it exists. It doesn't verify the port is open. This is consistent with the existing `endpoint(for:)` method which also doesn't validate. Users are responsible for configuring ports correctly.

## Risks and Mitigations

### Risk: Docker Inspect Output Changes

**Impact**: If Docker changes the output format of `docker inspect`, parsing could break.

**Likelihood**: Low (Docker maintains backward compatibility)

**Mitigation**:
- Use Go template format (more stable than raw JSON)
- Add comprehensive parsing tests
- Fail gracefully with clear error messages
- Easy to update parsing logic in one place (DockerClient)

### Risk: No Networks Available

**Impact**: Container might have no networks in unusual configurations.

**Likelihood**: Very low (Docker always attaches at least the default bridge)

**Mitigation**:
- Throw clear error if no networks found
- Document that containers must have at least one network
- Integration tests verify this scenario

### Risk: Network Information Stale

**Impact**: If a container's networks change dynamically, cached info could be stale.

**Likelihood**: Very low (test containers rarely have network changes)

**Mitigation**:
- No caching initially (always fresh data)
- If caching added later, document the behavior
- Provide way to refresh if needed

### Risk: Performance Overhead

**Impact**: Calling `docker inspect` on every request could be slow.

**Likelihood**: Low (inspect is fast, ~10-50ms)

**Mitigation**:
- Only call inspect when network methods are used (lazy)
- Most tests only need IP once or twice
- Can add caching in future if needed
- Integration tests will measure performance impact

### Risk: DNS Not Available

**Impact**: Hostname-based communication might not work on default bridge network.

**Likelihood**: Medium (default bridge has limited DNS support)

**Mitigation**:
- Document that DNS works best with custom networks
- Provide both IP-based and hostname-based methods
- Recommend IP-based communication for default bridge
- Custom network support (future feature) will enable full DNS

### Risk: Confusion with Existing Endpoint Methods

**Impact**: Users might confuse `endpoint()` vs `internalEndpoint()`.

**Likelihood**: Medium (similar names)

**Mitigation**:
- Clear documentation with examples
- Descriptive method names ("internal" prefix)
- Doc comments explain the difference
- Examples show both use cases side-by-side

## Future Enhancements

### 1. Network Inspection Caching

Cache `docker inspect` results to improve performance for repeated calls:

```swift
private actor NetworkCache {
    private var cache: [String: [ContainerNetwork]] = [:]

    func get(for id: String) -> [ContainerNetwork]? {
        cache[id]
    }

    func set(for id: String, networks: [ContainerNetwork]) {
        cache[id] = networks
    }
}
```

### 2. Network Alias Support

Retrieve all DNS aliases for a container:

```swift
public func internalAliases(forNetwork networkName: String) async throws -> [String] {
    let aliases = try await docker.inspectNetworkAliases(id: id, network: networkName)
    return aliases
}
```

### 3. Connection Testing

Verify that an internal endpoint is actually reachable:

```swift
public func canReach(_ otherContainer: Container, port: Int) async throws -> Bool {
    // Exec into this container and try to connect to other container
    let endpoint = try await otherContainer.internalEndpoint(for: port)
    // Use netcat or curl to test connectivity
}
```

### 4. Typed Connection Strings

Provide service-specific connection string builders:

```swift
// In future PostgresContainer module:
public func connectionString() async throws -> String {
    let ip = try await internalIP()
    let port = 5432
    let password = request.environment["POSTGRES_PASSWORD"] ?? ""
    return "postgresql://postgres:\(password)@\(ip):\(port)/postgres"
}
```

### 5. Multi-Network Endpoints

Get endpoints for all networks simultaneously:

```swift
public func allInternalEndpoints(for containerPort: Int) async throws -> [String: String] {
    let networks = try await docker.inspectNetworks(id: id)
    var endpoints: [String: String] = [:]
    for network in networks {
        endpoints[network.name] = "\(network.ipAddress):\(containerPort)"
    }
    return endpoints
}
```

### 6. IPv6 Specific Methods

Dedicated IPv6 support when needed:

```swift
public func internalIPv6() async throws -> String {
    let networks = try await docker.inspectNetworks(id: id)
    // Look for IPv6 address in network settings
}
```

## References

### Existing Code

- **Container API**: `/Sources/TestContainers/Container.swift` (lines 15-26)
  - Shows existing `hostPort()`, `host()`, `endpoint()` methods
  - Pattern to follow for internal endpoint methods

- **Docker Client**: `/Sources/TestContainers/DockerClient.swift`
  - Infrastructure for running docker commands
  - Pattern for adding new docker operations

- **Error Handling**: `/Sources/TestContainers/TestContainersError.swift`
  - Pattern for adding new error cases

- **Process Execution**: `/Sources/TestContainers/ProcessRunner.swift`
  - Low-level command execution (no changes needed)

### Similar Projects

- **Testcontainers Java**:
  - `GenericContainer.getContainerIpAddress()` - returns internal IP
  - `GenericContainer.getHost()` - returns host IP (external)
  - Network support via `.withNetwork()` and `.withNetworkAliases()`

- **Testcontainers Go**:
  - `Container.Host(ctx)` - returns Docker host
  - `Container.ContainerIP(ctx)` - returns internal IP
  - `Container.NetworkAliases(ctx)` - returns DNS aliases

- **Testcontainers Python**:
  - `DockerContainer.get_container_host_ip()` - internal IP
  - Network support via `.with_network()` and `.with_network_aliases()`

### Docker Documentation

- `docker inspect` command: [docs.docker.com/engine/reference/commandline/inspect/](https://docs.docker.com/engine/reference/commandline/inspect/)
- Go template format: [docs.docker.com/config/formatting/](https://docs.docker.com/config/formatting/)
- Container networking: [docs.docker.com/network/](https://docs.docker.com/network/)
- Network drivers: [docs.docker.com/network/drivers/](https://docs.docker.com/network/drivers/)

### Related Feature Tickets

- **Network creation** (FEATURES.md line 67): `docker network create/rm`
- **Network attachment** (FEATURES.md line 68): Attach container to custom networks
- **Network aliases** (FEATURES.md line 69): DNS names for containers
- **Container inspection** (FEATURES.md line 46): Full container metadata inspection

---

## Appendix: Docker Inspect Output Format

For reference, here's what `docker inspect --format` returns for network information:

### Command

```bash
docker inspect --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}},{{$conf.IPAddress}},{{$conf.Gateway}},{{$conf.NetworkID}}
{{end}}' <container-id>
```

### Sample Output

```
bridge,172.17.0.2,172.17.0.1,abc123def456789
```

For a container on multiple networks:

```
bridge,172.17.0.2,172.17.0.1,abc123def456789
my-network,172.20.0.5,172.20.0.1,def456abc123456
```

### Field Descriptions

- **Network name**: Name of the Docker network (e.g., "bridge", "my-network")
- **IP Address**: Container's IP within this network (e.g., "172.17.0.2")
- **Gateway**: Network gateway IP (e.g., "172.17.0.1", may be empty)
- **Network ID**: Docker's internal network identifier (long hash)

### Alternative JSON Approach

Could also parse JSON for more robustness:

```bash
docker inspect --format '{{json .NetworkSettings.Networks}}' <container-id>
```

Returns:
```json
{
  "bridge": {
    "IPAddress": "172.17.0.2",
    "Gateway": "172.17.0.1",
    "NetworkID": "abc123def456789",
    ...
  }
}
```

However, CSV approach is simpler and sufficient for our needs.
