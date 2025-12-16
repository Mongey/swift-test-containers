# Feature: Container Inspection

## Summary

Add container inspection capability to retrieve detailed runtime information about running containers. This feature exposes container state, health status, network configuration, environment variables, port mappings, labels, and timestamps through a structured Swift API backed by `docker inspect`.

**Related:** Listed in FEATURES.md under Tier 1 "Runtime operations" - "Inspect container (state, health, IPs, env, ports, labels)"

## Current State

The library currently provides limited container information:

**Available Information:**
- Container ID: `container.id` (String)
- Host port mapping: `container.hostPort(_:)` via `docker port` command
  - Implementation: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift:65-72`
  - Parses output from `docker port <id> <containerPort>` to extract the mapped host port
- Endpoint construction: `container.endpoint(for:)` combining host and port
- Original request: `container.request` (ContainerRequest)

**Limitations:**
- No access to container state (running, paused, exited, etc.)
- No health check status visibility
- Cannot retrieve container IP addresses
- No way to read environment variables from running container
- Cannot access all port mappings at once (must query individually)
- Labels not accessible after container creation
- No timestamp information (created, started, finished)

## Requirements

### Core Inspection Data

The inspect feature must provide:

1. **Container State**
   - Status: running, created, restarting, removing, paused, exited, dead
   - Running: boolean flag
   - Paused: boolean flag
   - Exit code (for stopped containers)
   - Error message (if any)
   - Process ID (PID)
   - Started timestamp
   - Finished timestamp (for stopped containers)

2. **Health Status** (if container has HEALTHCHECK)
   - Health status: starting, healthy, unhealthy
   - Failing streak count
   - Last health check log

3. **Network Information**
   - Primary IP address (bridge network)
   - All network attachments with their IPs
   - Gateway addresses
   - MAC addresses
   - Network names and IDs

4. **Port Mappings**
   - All exposed ports with their host bindings
   - Protocol (tcp/udp)
   - Container port → Host IP + Host port mapping

5. **Configuration**
   - Environment variables (merged from image + runtime)
   - Labels (merged from image + runtime)
   - Image ID and name
   - Working directory
   - Entrypoint and command

6. **Timestamps**
   - Created timestamp (ISO8601)
   - Started timestamp (ISO8601)
   - Finished timestamp (ISO8601, if stopped)

### API Design

#### Inspection Result Types

```swift
/// Comprehensive container inspection information
public struct ContainerInspection: Sendable {
    public let id: String
    public let created: Date
    public let name: String
    public let state: ContainerState
    public let config: ContainerConfig
    public let networkSettings: NetworkSettings
}

/// Container runtime state
public struct ContainerState: Sendable {
    public let status: Status
    public let running: Bool
    public let paused: Bool
    public let restarting: Bool
    public let oomKilled: Bool
    public let dead: Bool
    public let pid: Int
    public let exitCode: Int
    public let error: String
    public let startedAt: Date?
    public let finishedAt: Date?
    public let health: HealthStatus?

    public enum Status: String, Sendable {
        case created
        case running
        case paused
        case restarting
        case removing
        case exited
        case dead
    }
}

/// Container health check status
public struct HealthStatus: Sendable {
    public let status: Status
    public let failingStreak: Int
    public let log: [HealthLog]

    public enum Status: String, Sendable {
        case none
        case starting
        case healthy
        case unhealthy
    }
}

public struct HealthLog: Sendable {
    public let start: Date
    public let end: Date
    public let exitCode: Int
    public let output: String
}

/// Container configuration details
public struct ContainerConfig: Sendable {
    public let hostname: String
    public let user: String
    public let env: [String]  // Format: "KEY=VALUE"
    public let cmd: [String]
    public let image: String
    public let workingDir: String
    public let entrypoint: [String]
    public let labels: [String: String]
}

/// Network configuration and IP addresses
public struct NetworkSettings: Sendable {
    public let bridge: String
    public let sandboxID: String
    public let ports: [PortBinding]
    public let ipAddress: String  // Primary IP
    public let gateway: String
    public let macAddress: String
    public let networks: [String: NetworkAttachment]
}

public struct PortBinding: Sendable, Hashable {
    public let containerPort: Int
    public let protocol: String  // "tcp" or "udp"
    public let hostIP: String?
    public let hostPort: Int?
}

public struct NetworkAttachment: Sendable {
    public let networkID: String
    public let endpointID: String
    public let gateway: String
    public let ipAddress: String
    public let ipPrefixLen: Int
    public let macAddress: String
    public let aliases: [String]
}
```

#### Container API Extension

```swift
extension Container {
    /// Inspect the container to retrieve detailed runtime information
    ///
    /// - Returns: Comprehensive inspection data including state, config, and networking
    /// - Throws: TestContainersError if Docker command fails or output is invalid
    public func inspect() async throws -> ContainerInspection
}
```

#### DockerClient Internal API

```swift
extension DockerClient {
    /// Execute docker inspect and return parsed JSON
    func inspect(id: String) async throws -> ContainerInspection
}
```

## Implementation Steps

### 1. Add Inspection Data Types

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerInspection.swift` (new)

- Define all inspection result types shown in API Design
- All types must be `Sendable` (library uses actors and async/await)
- Implement `Codable` conformance for JSON deserialization
- Map Docker's JSON structure to Swift types
- Handle optional fields gracefully (health may be nil, timestamps may be zero dates)

**Key Considerations:**
- Docker returns timestamps in RFC3339 format: use `ISO8601DateFormatter`
- Docker uses zero dates `"0001-01-01T00:00:00Z"` for unset timestamps: treat as nil
- Port mappings in Docker JSON use format `"6379/tcp": [{"HostIp": "0.0.0.0", "HostPort": "32768"}]`
- Environment uses array of `"KEY=VALUE"` strings: consider parsing to `[String: String]` or keeping raw
- Health field may be completely absent if container has no HEALTHCHECK

### 2. Implement Docker Inspect Command

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Add new method following existing patterns:

```swift
func inspect(id: String) async throws -> ContainerInspection {
    let output = try await runDocker(["inspect", id, "--format", "json"])
    let jsonData = output.stdout.data(using: .utf8) ?? Data()

    // Docker inspect returns array of objects, we need first element
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let dateString = try container.decode(String.self)

        // Handle Docker's zero date
        if dateString.hasPrefix("0001-01-01") {
            return Date(timeIntervalSince1970: 0)
        }

        guard let date = ISO8601DateFormatter().date(from: dateString) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid date format: \(dateString)"
            )
        }
        return date
    }

    let inspections = try decoder.decode([ContainerInspection].self, from: jsonData)
    guard let inspection = inspections.first else {
        throw TestContainersError.unexpectedDockerOutput("docker inspect returned empty array")
    }

    return inspection
}
```

**Pattern Reference:**
- Follow existing error handling from `port()` and `logs()` methods
- Use `runDocker()` helper which checks exit codes and throws `TestContainersError.commandFailed`
- Parse JSON output similar to how `parseDockerPort()` parses text output
- Throw `TestContainersError.unexpectedDockerOutput` for malformed responses

### 3. Add Public API to Container

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

Add method following existing patterns:

```swift
public func inspect() async throws -> ContainerInspection {
    try await docker.inspect(id: id)
}
```

**Pattern Reference:**
- Container is an `actor`, methods are implicitly async
- Delegate to `docker` client instance
- Pass through `id` (container ID string)
- Mirror pattern from `hostPort()`, `logs()`, `terminate()` methods

### 4. Add CodingKeys and JSON Mapping

Docker's JSON field names use PascalCase and nested structures. Add explicit CodingKeys:

```swift
extension ContainerInspection {
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case created = "Created"
        case name = "Name"
        case state = "State"
        case config = "Config"
        case networkSettings = "NetworkSettings"
    }
}

extension ContainerState {
    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case running = "Running"
        case paused = "Paused"
        case restarting = "Restarting"
        case oomKilled = "OOMKilled"
        case dead = "Dead"
        case pid = "Pid"
        case exitCode = "ExitCode"
        case error = "Error"
        case startedAt = "StartedAt"
        case finishedAt = "FinishedAt"
        case health = "Health"
    }
}

// Similar for other types...
```

### 5. Handle Port Mapping Deserialization

Docker's port format is complex:

```json
"Ports": {
  "6379/tcp": [
    {"HostIp": "0.0.0.0", "HostPort": "32768"},
    {"HostIp": "::", "HostPort": "32768"}
  ],
  "8080/tcp": null
}
```

Implement custom decoding:

```swift
extension NetworkSettings {
    enum CodingKeys: String, CodingKey {
        case bridge = "Bridge"
        case sandboxID = "SandboxID"
        case ports = "Ports"
        case ipAddress = "IPAddress"
        case gateway = "Gateway"
        case macAddress = "MacAddress"
        case networks = "Networks"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bridge = try container.decode(String.self, forKey: .bridge)
        sandboxID = try container.decode(String.self, forKey: .sandboxID)
        ipAddress = try container.decode(String.self, forKey: .ipAddress)
        gateway = try container.decode(String.self, forKey: .gateway)
        macAddress = try container.decode(String.self, forKey: .macAddress)
        networks = try container.decode([String: NetworkAttachment].self, forKey: .networks)

        // Custom port parsing
        let portsDict = try container.decode([String: [DockerPortBinding]?].self, forKey: .ports)
        var portBindings: [PortBinding] = []

        for (portProto, bindings) in portsDict {
            let parts = portProto.split(separator: "/")
            guard parts.count == 2,
                  let port = Int(parts[0]) else { continue }
            let proto = String(parts[1])

            if let bindings = bindings {
                for binding in bindings {
                    portBindings.append(PortBinding(
                        containerPort: port,
                        protocol: proto,
                        hostIP: binding.hostIP.isEmpty ? nil : binding.hostIP,
                        hostPort: Int(binding.hostPort)
                    ))
                }
            } else {
                // Exposed but not bound
                portBindings.append(PortBinding(
                    containerPort: port,
                    protocol: proto,
                    hostIP: nil,
                    hostPort: nil
                ))
            }
        }

        ports = portBindings
    }
}

private struct DockerPortBinding: Decodable {
    let hostIP: String
    let hostPort: String

    enum CodingKeys: String, CodingKey {
        case hostIP = "HostIp"
        case hostPort = "HostPort"
    }
}
```

### 6. Update Error Handling

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

Consider adding specific error case if JSON parsing needs better diagnostics:

```swift
case jsonDecodingFailed(String, underlyingError: Error)
```

However, existing `unexpectedDockerOutput` may be sufficient - evaluate during implementation.

## Testing Plan

### Unit Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerInspectionTests.swift` (new)

Test JSON parsing without Docker:

```swift
import Testing
import TestContainers

@Test func parsesRunningContainerInspection() throws {
    let json = """
    [{
        "Id": "abc123",
        "Created": "2025-12-15T10:56:24.952960502Z",
        "Name": "/test-container",
        "State": {
            "Status": "running",
            "Running": true,
            "Paused": false,
            "Restarting": false,
            "OOMKilled": false,
            "Dead": false,
            "Pid": 12345,
            "ExitCode": 0,
            "Error": "",
            "StartedAt": "2025-12-15T10:56:25.049568794Z",
            "FinishedAt": "0001-01-01T00:00:00Z"
        },
        "Config": {
            "Hostname": "abc123",
            "User": "",
            "Env": ["PATH=/usr/bin", "REDIS_VERSION=7.0"],
            "Cmd": ["redis-server"],
            "Image": "redis:7",
            "WorkingDir": "/data",
            "Entrypoint": ["docker-entrypoint.sh"],
            "Labels": {"app": "test"}
        },
        "NetworkSettings": {
            "Bridge": "",
            "SandboxID": "sandbox123",
            "Ports": {
                "6379/tcp": [
                    {"HostIp": "0.0.0.0", "HostPort": "32768"}
                ]
            },
            "IPAddress": "172.17.0.2",
            "Gateway": "172.17.0.1",
            "MacAddress": "02:42:ac:11:00:02",
            "Networks": {
                "bridge": {
                    "NetworkID": "net123",
                    "EndpointID": "ep123",
                    "Gateway": "172.17.0.1",
                    "IPAddress": "172.17.0.2",
                    "IPPrefixLen": 16,
                    "MacAddress": "02:42:ac:11:00:02",
                    "Aliases": []
                }
            }
        }
    }]
    """

    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    // Configure decoder with date strategy

    let inspections = try decoder.decode([ContainerInspection].self, from: data)
    let inspection = try #require(inspections.first)

    #expect(inspection.id == "abc123")
    #expect(inspection.name == "/test-container")
    #expect(inspection.state.status == .running)
    #expect(inspection.state.running == true)
    #expect(inspection.state.pid == 12345)
    #expect(inspection.config.env.contains("PATH=/usr/bin"))
    #expect(inspection.networkSettings.ipAddress == "172.17.0.2")
    #expect(inspection.networkSettings.ports.count == 1)
    #expect(inspection.networkSettings.ports[0].containerPort == 6379)
    #expect(inspection.networkSettings.ports[0].hostPort == 32768)
}

@Test func parsesContainerWithHealth() throws {
    // Test JSON with Health field populated
}

@Test func parsesStoppedContainer() throws {
    // Test with Status: "exited", Running: false, non-zero exit code
}

@Test func parsesContainerWithMultiplePorts() throws {
    // Test with multiple port bindings
}

@Test func parsesContainerWithoutPortBindings() throws {
    // Test with exposed ports but no host bindings (null values)
}
```

### Integration Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

Add test alongside existing `canStartContainer_whenOptedIn`:

```swift
@Test func canInspectRunningContainer_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7-alpine")
        .withExposedPort(6379)
        .withEnvironment(["CUSTOM_VAR": "test-value"])
        .withLabel("test-label", "label-value")
        .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

    try await withContainer(request) { container in
        let inspection = try await container.inspect()

        // Verify state
        #expect(inspection.state.status == .running)
        #expect(inspection.state.running == true)
        #expect(inspection.state.pid > 0)
        #expect(inspection.state.exitCode == 0)

        // Verify config
        #expect(inspection.config.image == "redis:7-alpine")
        #expect(inspection.config.env.contains("CUSTOM_VAR=test-value"))
        #expect(inspection.config.labels["test-label"] == "label-value")

        // Verify network
        #expect(!inspection.networkSettings.ipAddress.isEmpty)
        #expect(inspection.networkSettings.ipAddress.starts(with: "172."))

        // Verify ports
        let redisPort = inspection.networkSettings.ports.first { $0.containerPort == 6379 }
        #expect(redisPort != nil)
        #expect(redisPort?.protocol == "tcp")
        #expect(redisPort?.hostPort != nil)

        // Cross-check with existing API
        let hostPort = try await container.hostPort(6379)
        #expect(redisPort?.hostPort == hostPort)
    }
}

@Test func canInspectContainerWithoutHealthCheck_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "sleep 10"])

    try await withContainer(request) { container in
        let inspection = try await container.inspect()
        #expect(inspection.state.health == nil)
    }
}
```

### Manual Testing

```bash
# Enable Docker integration tests
export TESTCONTAINERS_RUN_DOCKER_TESTS=1

# Run all tests
swift test

# Run specific test
swift test --filter canInspectRunningContainer
```

## Acceptance Criteria

### Required

- [x] `Container.inspect()` method returns `ContainerInspection` struct
- [x] Inspection includes container state (status, running, pid, exit code)
- [x] Inspection includes all environment variables from container
- [x] Inspection includes all labels from container
- [x] Inspection includes all port mappings with protocol, container port, host IP, and host port
- [x] Inspection includes primary IP address and network attachments
- [x] Inspection includes timestamps (created, started, finished)
- [x] Health status included if container has HEALTHCHECK, nil otherwise
- [x] All types are `Sendable` and thread-safe
- [x] Integration test validates inspect against real Redis container
- [x] Unit tests cover JSON parsing edge cases (stopped containers, multiple ports, missing health)
- [x] Error handling follows existing patterns (`TestContainersError.unexpectedDockerOutput`)
- [x] Docker's zero dates (`0001-01-01T00:00:00Z`) handled gracefully
- [x] Exposed but unbound ports handled correctly (null host port)

### Nice to Have

- [ ] Convenience methods like `inspection.primaryIP()`, `inspection.isHealthy()`
- [ ] Helper to convert environment array to dictionary: `inspection.config.environmentDict()`
- [ ] Performance test: inspect is fast (< 100ms typical)
- [x] Documentation examples in inline comments
- [x] Update FEATURES.md to mark "Inspect container" as implemented

### Out of Scope

- Streaming/watching container state changes (requires Docker SDK or polling)
- Inspect images (separate from container inspection)
- Inspect networks or volumes
- Diff/changes to container filesystem (docker diff)
- Container stats (CPU, memory usage - runtime metrics)

## References

### Docker CLI Documentation
- `docker inspect` reference: https://docs.docker.com/reference/cli/docker/inspect/
- JSON output format: https://docs.docker.com/reference/api/engine/version/v1.47/#tag/Container/operation/ContainerInspect

### Existing Code Patterns
- Container actor: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`
- DockerClient pattern: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`
- Error handling: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`
- Integration tests: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

### Related Features
- Port mapping (`docker port`): `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift:65-94`
- Logs retrieval: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift:60-63`
- Container lifecycle: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`

### Similar Libraries
- testcontainers-go inspect: https://github.com/testcontainers/testcontainers-go/blob/main/docker.go
- Testcontainers Java inspect: https://github.com/testcontainers/testcontainers-java/blob/main/core/src/main/java/org/testcontainers/containers/GenericContainer.java
