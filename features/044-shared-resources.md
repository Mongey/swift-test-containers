# Feature 044: Shared Networks and Volumes Across Container Stacks

**Status**: IMPLEMENTED
**Priority**: Tier 3 (Advanced Features)
**Complexity**: High
**Implementation Date**: 2026-02-13

---

## Summary

Implement support for shared networks and volumes that can be used across multiple containers in a stack. This feature enables:

- **Shared Networks**: Create Docker networks that multiple containers can join, enabling container-to-container communication
- **Shared Volumes**: Create Docker volumes that can be mounted by multiple containers for data sharing
- **Stack Management**: Group related containers with shared resources and manage their lifecycle together
- **Automatic Cleanup**: Ensure networks and volumes are properly removed when stacks are terminated

This feature is essential for testing distributed systems, microservices architectures, and applications requiring inter-container communication or shared storage.

---

## Current State

### Container Lifecycle

The project currently supports individual container management with scoped lifecycle:

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`

```swift
public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    // Starts a single container
    // Ensures cleanup via withTaskCancellationHandler
    // Calls container.terminate() on success/error/cancellation
}
```

### Container Configuration

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

Current `ContainerRequest` supports:
- Image, name, command
- Environment variables
- Labels
- Port mappings
- Wait strategies
- Host configuration

**Not yet supported**:
- Network attachment
- Volume mounts
- Named volumes
- Network aliases

### Docker Client

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Current `DockerClient` operations:
- `runContainer(_:)` - Start containers with `-d`
- `removeContainer(id:)` - Remove with `docker rm -f`
- `logs(id:)` - Fetch container logs
- `port(id:containerPort:)` - Get port mappings

**Not yet supported**:
- Network operations (`docker network create/rm/connect/disconnect`)
- Volume operations (`docker volume create/rm/inspect`)

### ProcessRunner Infrastructure

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ProcessRunner.swift`

The existing `ProcessRunner` can execute any Docker CLI command, providing a foundation for network and volume operations.

---

## Requirements

### Functional Requirements

#### Networks

1. **Network Creation**
   - Create Docker networks with configurable drivers (bridge, host, overlay)
   - Support network-specific options (subnet, gateway, IP range)
   - Assign custom names and labels
   - Return network handle for reference

2. **Network Attachment**
   - Attach containers to networks at creation time
   - Support multiple networks per container
   - Configure network aliases for DNS resolution
   - Support IPv4/IPv6 configuration

3. **Network Discovery**
   - List networks created by the library
   - Query network details (containers, configuration)
   - Check if network exists

4. **Network Cleanup**
   - Automatic removal when stack terminates
   - Disconnect containers before network removal
   - Handle cleanup on error and cancellation

#### Volumes

1. **Volume Creation**
   - Create named Docker volumes
   - Support volume drivers (local, nfs, etc.)
   - Configure volume options and labels
   - Return volume handle for reference

2. **Volume Mounting**
   - Mount named volumes to containers
   - Support read-only and read-write modes
   - Specify mount points (paths)
   - Support multiple volume mounts per container

3. **Volume Discovery**
   - List volumes created by the library
   - Query volume details (mount points, driver)
   - Check if volume exists

4. **Volume Cleanup**
   - Automatic removal when stack terminates
   - Force removal even if in use
   - Handle cleanup on error and cancellation

#### Container Stacks

1. **Stack Definition**
   - Group multiple containers with shared resources
   - Define dependencies between containers
   - Configure shared networks and volumes
   - Support wait strategies per container

2. **Stack Lifecycle**
   - Start all containers in dependency order
   - Wait for all containers to be ready
   - Provide access to all running containers
   - Terminate entire stack (containers, networks, volumes)

3. **Resource Management**
   - Track all resources (containers, networks, volumes)
   - Ensure proper cleanup order (containers → networks → volumes)
   - Handle partial failures during startup
   - Support cancellation at any point

### Non-Functional Requirements

1. **Consistency**: Follow existing patterns (actors, async/throws, builders)
2. **Sendable**: All types must be `Sendable` for Swift concurrency
3. **Safety**: Automatic cleanup on success, error, and cancellation
4. **Testability**: Unit and integration tests required
5. **Documentation**: Public API must be documented
6. **Performance**: Minimize Docker CLI calls where possible
7. **Isolation**: Use labels to avoid conflicts with user's Docker environment

---

## API Design

### Network Types

```swift
/// Configuration for creating a Docker network.
public struct NetworkRequest: Sendable, Hashable {
    public var name: String?
    public var driver: NetworkDriver
    public var labels: [String: String]
    public var options: [String: String]
    public var subnet: String?
    public var gateway: String?
    public var ipRange: String?

    public init(
        name: String? = nil,
        driver: NetworkDriver = .bridge
    ) {
        self.name = name
        self.driver = driver
        self.labels = ["testcontainers.swift": "true"]
        self.options = [:]
        self.subnet = nil
        self.gateway = nil
        self.ipRange = nil
    }

    // Builder methods
    public func withName(_ name: String) -> Self
    public func withDriver(_ driver: NetworkDriver) -> Self
    public func withLabel(_ key: String, _ value: String) -> Self
    public func withOption(_ key: String, _ value: String) -> Self
    public func withSubnet(_ subnet: String) -> Self
    public func withGateway(_ gateway: String) -> Self
    public func withIPRange(_ ipRange: String) -> Self
}

/// Docker network drivers.
public enum NetworkDriver: String, Sendable, Hashable {
    case bridge
    case host
    case overlay
    case macvlan
    case none
}

/// A Docker network handle.
public actor Network {
    public let id: String
    public let name: String
    public let request: NetworkRequest

    /// Get network details (driver, subnet, containers).
    public func inspect() async throws -> NetworkInfo

    /// Remove the network.
    public func remove() async throws
}

/// Network inspection information.
public struct NetworkInfo: Sendable {
    public let id: String
    public let name: String
    public let driver: String
    public let subnet: String?
    public let gateway: String?
    public let containers: [String: ContainerNetworkInfo]
}

public struct ContainerNetworkInfo: Sendable {
    public let containerID: String
    public let ipv4Address: String?
    public let ipv6Address: String?
}

/// Network attachment for containers.
public struct NetworkAttachment: Sendable, Hashable {
    public var network: String // network ID or name
    public var aliases: [String]
    public var ipv4Address: String?
    public var ipv6Address: String?

    public init(
        network: String,
        aliases: [String] = []
    ) {
        self.network = network
        self.aliases = aliases
        self.ipv4Address = nil
        self.ipv6Address = nil
    }

    public func withAliases(_ aliases: [String]) -> Self
    public func withIPv4Address(_ address: String) -> Self
    public func withIPv6Address(_ address: String) -> Self
}
```

### Volume Types

```swift
/// Configuration for creating a Docker volume.
public struct VolumeRequest: Sendable, Hashable {
    public var name: String?
    public var driver: String
    public var labels: [String: String]
    public var driverOpts: [String: String]

    public init(
        name: String? = nil,
        driver: String = "local"
    ) {
        self.name = name
        self.driver = driver
        self.labels = ["testcontainers.swift": "true"]
        self.driverOpts = [:]
    }

    // Builder methods
    public func withName(_ name: String) -> Self
    public func withDriver(_ driver: String) -> Self
    public func withLabel(_ key: String, _ value: String) -> Self
    public func withDriverOption(_ key: String, _ value: String) -> Self
}

/// A Docker volume handle.
public actor Volume {
    public let name: String
    public let request: VolumeRequest

    /// Get volume details (driver, mount point, options).
    public func inspect() async throws -> VolumeInfo

    /// Remove the volume.
    public func remove(force: Bool = false) async throws
}

/// Volume inspection information.
public struct VolumeInfo: Sendable {
    public let name: String
    public let driver: String
    public let mountpoint: String
    public let labels: [String: String]
    public let options: [String: String]
}

/// Volume mount for containers.
public struct VolumeMount: Sendable, Hashable {
    public var volume: String // volume name
    public var containerPath: String
    public var readOnly: Bool

    public init(
        volume: String,
        containerPath: String,
        readOnly: Bool = false
    ) {
        self.volume = volume
        self.containerPath = containerPath
        self.readOnly = readOnly
    }

    public func withReadOnly(_ readOnly: Bool = true) -> Self
}

/// Bind mount for containers (host path to container path).
public struct BindMount: Sendable, Hashable {
    public var hostPath: String
    public var containerPath: String
    public var readOnly: Bool

    public init(
        hostPath: String,
        containerPath: String,
        readOnly: Bool = false
    ) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.readOnly = readOnly
    }

    public func withReadOnly(_ readOnly: Bool = true) -> Self
}
```

### Enhanced ContainerRequest

```swift
// Extend existing ContainerRequest
extension ContainerRequest {
    public var networks: [NetworkAttachment]
    public var volumeMounts: [VolumeMount]
    public var bindMounts: [BindMount]

    // New builder methods
    public func withNetwork(_ network: String, aliases: [String] = []) -> Self
    public func withNetworkAttachment(_ attachment: NetworkAttachment) -> Self
    public func withVolumeMount(_ mount: VolumeMount) -> Self
    public func withVolume(_ volumeName: String, containerPath: String, readOnly: Bool = false) -> Self
    public func withBindMount(_ mount: BindMount) -> Self
    public func withBind(_ hostPath: String, containerPath: String, readOnly: Bool = false) -> Self
}
```

### Container Stack API

```swift
/// A container in a stack definition.
public struct StackContainer: Sendable {
    public var name: String
    public var request: ContainerRequest
    public var dependsOn: [String]

    public init(
        name: String,
        request: ContainerRequest,
        dependsOn: [String] = []
    ) {
        self.name = name
        self.request = request
        self.dependsOn = dependsOn
    }
}

/// Configuration for a multi-container stack.
public struct StackRequest: Sendable {
    public var containers: [StackContainer]
    public var networks: [NetworkRequest]
    public var volumes: [VolumeRequest]

    public init(
        containers: [StackContainer] = [],
        networks: [NetworkRequest] = [],
        volumes: [VolumeRequest] = []
    ) {
        self.containers = containers
        self.networks = networks
        self.volumes = volumes
    }

    // Builder methods
    public func withContainer(_ container: StackContainer) -> Self
    public func withContainer(
        name: String,
        request: ContainerRequest,
        dependsOn: [String] = []
    ) -> Self
    public func withNetwork(_ network: NetworkRequest) -> Self
    public func withVolume(_ volume: VolumeRequest) -> Self
}

/// A running container stack with all resources.
public actor ContainerStack {
    public let containers: [String: Container]
    public let networks: [String: Network]
    public let volumes: [String: Volume]

    /// Get a container by name.
    public func container(_ name: String) -> Container?

    /// Get a network by name.
    public func network(_ name: String) -> Network?

    /// Get a volume by name.
    public func volume(_ name: String) -> Volume?

    /// Terminate the entire stack (containers, networks, volumes).
    public func terminate() async throws
}

/// Scoped lifecycle for container stacks.
public func withStack<T>(
    _ request: StackRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (ContainerStack) async throws -> T
) async throws -> T
```

### Usage Examples

#### Example 1: Web App with Database

```swift
@Test func webAppWithDatabase() async throws {
    // Create a shared network
    let network = NetworkRequest(name: "app-network")

    // Create a shared volume for database data
    let dbVolume = VolumeRequest(name: "postgres-data")

    // Define PostgreSQL container
    let postgres = StackContainer(
        name: "postgres",
        request: ContainerRequest(image: "postgres:16")
            .withEnvironment(["POSTGRES_PASSWORD": "secret"])
            .withNetwork("app-network", aliases: ["db"])
            .withVolume("postgres-data", containerPath: "/var/lib/postgresql/data")
            .withExposedPort(5432)
            .waitingFor(.logContains("database system is ready to accept connections"))
    )

    // Define web app container
    let webapp = StackContainer(
        name: "webapp",
        request: ContainerRequest(image: "myapp:latest")
            .withEnvironment(["DB_HOST": "db", "DB_PASSWORD": "secret"])
            .withNetwork("app-network")
            .withExposedPort(8080)
            .waitingFor(.http(HTTPWaitConfig(port: 8080).withPath("/health"))),
        dependsOn: ["postgres"]
    )

    // Create and run the stack
    let stack = StackRequest()
        .withNetwork(network)
        .withVolume(dbVolume)
        .withContainer(postgres)
        .withContainer(webapp)

    try await withStack(stack) { stack in
        // Both containers are running and connected
        guard let app = await stack.container("webapp") else {
            throw TestContainersError.unexpectedDockerOutput("webapp not found")
        }

        let endpoint = try await app.endpoint(for: 8080)
        // Test the application...
    }
    // Stack automatically cleaned up (containers, network, volume)
}
```

#### Example 2: Microservices with Shared Network

```swift
@Test func microservicesArchitecture() async throws {
    let network = NetworkRequest(name: "services-net")

    let stack = StackRequest()
        .withNetwork(network)
        .withContainer(
            name: "api",
            request: ContainerRequest(image: "api:latest")
                .withNetwork("services-net", aliases: ["api"])
                .withExposedPort(8080)
                .waitingFor(.tcpPort(8080))
        )
        .withContainer(
            name: "worker",
            request: ContainerRequest(image: "worker:latest")
                .withNetwork("services-net")
                .withEnvironment(["API_URL": "http://api:8080"])
                .waitingFor(.logContains("Worker started"))
        )
        .withContainer(
            name: "redis",
            request: ContainerRequest(image: "redis:7")
                .withNetwork("services-net", aliases: ["cache"])
                .withExposedPort(6379)
                .waitingFor(.tcpPort(6379))
        )

    try await withStack(stack) { stack in
        // All services can communicate via network aliases
        guard let api = await stack.container("api"),
              let worker = await stack.container("worker"),
              let redis = await stack.container("redis") else {
            throw TestContainersError.unexpectedDockerOutput("Container not found")
        }

        // Run integration tests...
    }
}
```

#### Example 3: Shared Volume Between Containers

```swift
@Test func sharedDataVolume() async throws {
    let volume = VolumeRequest(name: "shared-data")

    let stack = StackRequest()
        .withVolume(volume)
        .withContainer(
            name: "producer",
            request: ContainerRequest(image: "alpine:3.19")
                .withVolume("shared-data", containerPath: "/data")
                .withCommand(["sh", "-c", "echo 'test' > /data/file.txt && sleep 30"])
        )
        .withContainer(
            name: "consumer",
            request: ContainerRequest(image: "alpine:3.19")
                .withVolume("shared-data", containerPath: "/data", readOnly: true)
                .withCommand(["sleep", "30"])
        )

    try await withStack(stack) { stack in
        guard let consumer = await stack.container("consumer") else {
            throw TestContainersError.unexpectedDockerOutput("consumer not found")
        }

        // Wait a moment for producer to write
        try await Task.sleep(for: .seconds(2))

        // Read from shared volume via consumer
        let result = try await consumer.exec(["cat", "/data/file.txt"])
        #expect(result.stdout.contains("test"))
    }
}
```

#### Example 4: Individual Network/Volume Management

```swift
@Test func manualResourceManagement() async throws {
    // Create network manually
    try await withNetwork(NetworkRequest(name: "test-net")) { network in
        // Create volume manually
        try await withVolume(VolumeRequest(name: "test-vol")) { volume in
            // Use resources in container
            let request = ContainerRequest(image: "alpine:3.19")
                .withNetwork(await network.name)
                .withVolume(await volume.name, containerPath: "/data")
                .withCommand(["sleep", "30"])

            try await withContainer(request) { container in
                // Container is connected to network and has volume mounted
                let result = try await container.exec(["ls", "/data"])
                #expect(result.exitCode == 0)
            }
        }
        // Volume removed here
    }
    // Network removed here
}

// Scoped lifecycle helpers
public func withNetwork<T>(
    _ request: NetworkRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Network) async throws -> T
) async throws -> T

public func withVolume<T>(
    _ request: VolumeRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Volume) async throws -> T
) async throws -> T
```

---

## Implementation Steps

### Step 1: Extend DockerClient with Network Operations (2 hours)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Add methods:
```swift
func createNetwork(_ request: NetworkRequest) async throws -> String // returns network ID
func removeNetwork(id: String) async throws
func inspectNetwork(id: String) async throws -> NetworkInfo
func listNetworks(filters: [String: String]) async throws -> [NetworkInfo]
```

Implementation details:
- Use `docker network create` with flags: `--driver`, `--subnet`, `--gateway`, `--label`
- Use `docker network rm` for cleanup
- Use `docker network inspect` for details
- Parse JSON output from inspect command

### Step 2: Extend DockerClient with Volume Operations (2 hours)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Add methods:
```swift
func createVolume(_ request: VolumeRequest) async throws -> String // returns volume name
func removeVolume(name: String, force: Bool) async throws
func inspectVolume(name: String) async throws -> VolumeInfo
func listVolumes(filters: [String: String]) async throws -> [VolumeInfo]
```

Implementation details:
- Use `docker volume create` with flags: `--driver`, `--label`, `--opt`
- Use `docker volume rm` (with optional `-f`) for cleanup
- Use `docker volume inspect` for details
- Parse JSON output from inspect command

### Step 3: Create Network and Volume Types (2 hours)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Network.swift` (new)

Implement:
- `NetworkRequest` struct with builder pattern
- `NetworkDriver` enum
- `NetworkAttachment` struct
- `Network` actor with `inspect()` and `remove()` methods
- `NetworkInfo` and `ContainerNetworkInfo` structs

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Volume.swift` (new)

Implement:
- `VolumeRequest` struct with builder pattern
- `VolumeMount` and `BindMount` structs
- `Volume` actor with `inspect()` and `remove()` methods
- `VolumeInfo` struct

### Step 4: Extend ContainerRequest for Networks and Volumes (1 hour)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

Add properties:
```swift
public var networks: [NetworkAttachment]
public var volumeMounts: [VolumeMount]
public var bindMounts: [BindMount]
```

Add builder methods:
```swift
public func withNetwork(_ network: String, aliases: [String] = []) -> Self
public func withNetworkAttachment(_ attachment: NetworkAttachment) -> Self
public func withVolumeMount(_ mount: VolumeMount) -> Self
public func withVolume(_ volumeName: String, containerPath: String, readOnly: Bool = false) -> Self
public func withBindMount(_ mount: BindMount) -> Self
public func withBind(_ hostPath: String, containerPath: String, readOnly: Bool = false) -> Self
```

### Step 5: Update DockerClient.runContainer to Support Networks and Volumes (1 hour)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Update `runContainer(_:)` to include:
- `--network` flag(s) for network attachments
- `--network-alias` for network aliases
- `--volume` or `-v` for volume mounts
- `--mount` for bind mounts

Example:
```bash
docker run -d \
  --network my-network --network-alias api \
  --volume my-vol:/data \
  --mount type=bind,source=/host/path,target=/container/path \
  my-image
```

### Step 6: Implement Scoped Network and Volume Helpers (1 hour)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithNetwork.swift` (new)

Implement:
```swift
public func withNetwork<T>(
    _ request: NetworkRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Network) async throws -> T
) async throws -> T
```

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithVolume.swift` (new)

Implement:
```swift
public func withVolume<T>(
    _ request: VolumeRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Volume) async throws -> T
) async throws -> T
```

### Step 7: Create Container Stack Types (2 hours)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerStack.swift` (new)

Implement:
- `StackContainer` struct
- `StackRequest` struct with builder pattern
- `ContainerStack` actor with resource tracking
- Dependency resolution logic (topological sort)
- Cleanup order logic (reverse of startup)

### Step 8: Implement withStack() Function (2-3 hours)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithStack.swift` (new)

Implement:
```swift
public func withStack<T>(
    _ request: StackRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (ContainerStack) async throws -> T
) async throws -> T
```

Logic:
1. Check Docker availability
2. Create all networks (collect IDs/names)
3. Create all volumes (collect names)
4. Resolve container dependencies (topological sort)
5. Start containers in dependency order
6. Wait for each container to be ready
7. Create `ContainerStack` with all resources
8. Execute user operation
9. Clean up in reverse order:
   - Terminate all containers
   - Remove all networks
   - Remove all volumes
10. Handle cancellation and errors at each step

### Step 9: Unit Tests (2 hours)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/NetworkRequestTests.swift` (new)

Test:
- `NetworkRequest` builder pattern
- `NetworkAttachment` construction
- Default values and Hashable conformance

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/VolumeRequestTests.swift` (new)

Test:
- `VolumeRequest` builder pattern
- `VolumeMount` and `BindMount` construction
- Default values and Hashable conformance

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/StackRequestTests.swift` (new)

Test:
- `StackRequest` builder pattern
- `StackContainer` construction
- Dependency resolution logic

### Step 10: Integration Tests (3-4 hours)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/NetworkIntegrationTests.swift` (new)

Test:
- Create and remove networks
- Attach containers to networks
- Container-to-container communication via aliases
- Network isolation

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/VolumeIntegrationTests.swift` (new)

Test:
- Create and remove volumes
- Mount volumes in containers
- Read/write data to volumes
- Shared volumes between containers

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/StackIntegrationTests.swift` (new)

Test:
- Multi-container stacks
- Dependency ordering
- Shared networks and volumes
- Cleanup on success, error, and cancellation

---

## Testing Plan

### Unit Tests

1. **NetworkRequest Builder**
   - Test all builder methods
   - Verify defaults (driver=bridge, labels)
   - Test Hashable conformance

2. **VolumeRequest Builder**
   - Test all builder methods
   - Verify defaults (driver=local, labels)
   - Test Hashable conformance

3. **StackRequest Builder**
   - Test container addition
   - Test network/volume addition
   - Verify immutability

4. **Dependency Resolution**
   - Test topological sort with simple dependencies
   - Test circular dependency detection
   - Test independent containers (parallel start)

### Integration Tests (Docker Required)

1. **Network Tests**
   - Create network → verify exists → remove → verify gone
   - Attach two containers to network → ping by alias
   - Network isolation (containers in different networks can't communicate)

2. **Volume Tests**
   - Create volume → mount in container → write data → verify persisted
   - Share volume between two containers → write from one, read from other
   - Read-only mounts → verify write fails

3. **Container with Networks and Volumes**
   - Single container with network and volume
   - Verify container has correct IP in network
   - Verify volume mount is accessible

4. **Stack Tests**
   - Two containers with shared network
   - Three containers with dependencies (A → B → C)
   - Database + app stack with volume for DB data
   - Verify cleanup on success
   - Verify cleanup on error during startup
   - Verify cleanup on cancellation

5. **Error Scenarios**
   - Invalid network configuration
   - Volume mount to non-existent path
   - Circular dependencies
   - Container start failure in stack

### Manual Testing Checklist

- [ ] Run PostgreSQL + web app stack
- [ ] Run Kafka + Zookeeper stack (complex dependencies)
- [ ] Run multiple stacks in parallel (no conflicts)
- [ ] Verify cleanup with `docker network ls` and `docker volume ls`
- [ ] Test on macOS and Linux
- [ ] Performance test (stack with 10+ containers)

---

## Acceptance Criteria

### Must Have

- [ ] `NetworkRequest` with builder pattern and Docker network creation
- [ ] `VolumeRequest` with builder pattern and Docker volume creation
- [ ] `Network` actor with inspect and remove methods
- [ ] `Volume` actor with inspect and remove methods
- [ ] `ContainerRequest` extended with network and volume support
- [ ] `DockerClient` supports network operations (create, remove, inspect)
- [ ] `DockerClient` supports volume operations (create, remove, inspect)
- [ ] `DockerClient.runContainer()` applies networks and volumes
- [ ] `withNetwork()` scoped lifecycle helper
- [ ] `withVolume()` scoped lifecycle helper
- [ ] `StackRequest` with containers, networks, and volumes
- [ ] `ContainerStack` actor with resource tracking
- [ ] `withStack()` scoped lifecycle helper with proper cleanup
- [ ] Dependency resolution for container startup order
- [ ] Network aliases for DNS-based discovery
- [ ] Shared volumes between containers
- [ ] Automatic cleanup on success, error, and cancellation
- [ ] Unit tests for all types and builders
- [ ] Integration tests for networks, volumes, and stacks
- [ ] Documentation comments on all public APIs
- [ ] Updated `FEATURES.md`

### Should Have

- [ ] Bind mounts (host path → container path)
- [ ] Read-only volume mounts
- [ ] Network subnet and gateway configuration
- [ ] Volume driver options
- [ ] Parallel container startup (for independent containers)
- [ ] Stack inspection (list all resources)
- [ ] Error messages include resource details

### Nice to Have

- [ ] Network connect/disconnect after container creation
- [ ] Volume copy/backup utilities
- [ ] Stack template system (reusable configurations)
- [ ] Health checks at stack level
- [ ] Stack logs aggregation
- [ ] Network traffic analysis helpers

### Out of Scope (Future)

- Docker Compose file parsing
- Swarm mode / overlay networks
- Multi-host networking
- Advanced volume drivers (NFS, cloud storage)
- Network plugins and custom drivers

---

## Docker CLI Reference

### Network Commands

```bash
# Create network
docker network create \
  --driver bridge \
  --subnet 172.20.0.0/16 \
  --gateway 172.20.0.1 \
  --label testcontainers.swift=true \
  my-network

# List networks
docker network ls --filter label=testcontainers.swift=true

# Inspect network
docker network inspect my-network

# Remove network
docker network rm my-network

# Connect container to network
docker network connect --alias myalias my-network container-id

# Disconnect container from network
docker network disconnect my-network container-id
```

### Volume Commands

```bash
# Create volume
docker volume create \
  --driver local \
  --label testcontainers.swift=true \
  --opt type=tmpfs \
  my-volume

# List volumes
docker volume ls --filter label=testcontainers.swift=true

# Inspect volume
docker volume inspect my-volume

# Remove volume
docker volume rm my-volume
docker volume rm -f my-volume  # force

# Use volume in container
docker run -d --volume my-volume:/data my-image
docker run -d --mount type=volume,source=my-volume,target=/data my-image
```

### Container with Networks and Volumes

```bash
# Run container with network and volume
docker run -d \
  --network my-network \
  --network-alias api \
  --volume my-volume:/data \
  --mount type=bind,source=/host/path,target=/container/path,readonly \
  my-image
```

---

## Related Features

### Prerequisites

- [x] Container lifecycle (`withContainer`)
- [x] Wait strategies (TCP, log)
- [ ] Container exec (Feature 007) - useful for testing connectivity

### Enables Future Features

- [ ] Docker Compose support (parse docker-compose.yml)
- [ ] Service discovery helpers
- [ ] Module system (pre-configured stacks)
- [ ] Lifecycle hooks at stack level
- [ ] Stack monitoring and health checks

---

## References

### Testcontainers Go Implementation

- Networks: https://github.com/testcontainers/testcontainers-go/blob/main/network.go
- Docker Compose: https://github.com/testcontainers/testcontainers-go/tree/main/modules/compose

### Docker Documentation

- Networks: https://docs.docker.com/engine/reference/commandline/network/
- Volumes: https://docs.docker.com/engine/reference/commandline/volume/
- Docker Compose: https://docs.docker.com/compose/compose-file/

### Existing Patterns

- **Scoped lifecycle**: `withContainer(_:_:)` pattern
- **Builder pattern**: `ContainerRequest` with `.withX()` methods
- **Actor isolation**: `DockerClient`, `Container` are actors
- **Sendable types**: All public types conform to `Sendable`
- **Automatic cleanup**: `withTaskCancellationHandler` for cancellation
- **Labels**: `testcontainers.swift=true` for resource tracking

---

## Implementation Checklist

- [ ] Extend `DockerClient` with network operations
- [ ] Extend `DockerClient` with volume operations
- [ ] Create `NetworkRequest` with builder pattern
- [ ] Create `VolumeRequest` with builder pattern
- [ ] Create `Network` actor
- [ ] Create `Volume` actor
- [ ] Create `NetworkAttachment`, `VolumeMount`, `BindMount` types
- [ ] Extend `ContainerRequest` with network/volume properties
- [ ] Update `DockerClient.runContainer()` to apply networks/volumes
- [ ] Implement `withNetwork()` helper
- [ ] Implement `withVolume()` helper
- [ ] Create `StackContainer` and `StackRequest` types
- [ ] Implement dependency resolution logic
- [ ] Create `ContainerStack` actor
- [ ] Implement `withStack()` helper
- [ ] Write unit tests for all types
- [ ] Write integration tests for networks
- [ ] Write integration tests for volumes
- [ ] Write integration tests for stacks
- [ ] Add documentation comments
- [ ] Update `FEATURES.md`
- [ ] Add examples to `README.md`
- [ ] Manual testing with real-world stacks
- [ ] Code review and refinement

---

## Estimated Timeline

| Phase | Time | Description |
|-------|------|-------------|
| Network support in DockerClient | 2 hours | Create, remove, inspect networks |
| Volume support in DockerClient | 2 hours | Create, remove, inspect volumes |
| Network and Volume types | 2 hours | Requests, actors, info structs |
| ContainerRequest extensions | 1 hour | Add network/volume support |
| Scoped helpers (withNetwork/withVolume) | 1 hour | Individual resource lifecycle |
| Stack types and dependency resolution | 2 hours | StackRequest, StackContainer, sorting |
| withStack() implementation | 2-3 hours | Full stack lifecycle with cleanup |
| Unit tests | 2 hours | Test types, builders, dependencies |
| Integration tests | 3-4 hours | Networks, volumes, stacks in Docker |
| Documentation | 1 hour | Comments, README, FEATURES.md |
| **Total** | **18-20 hours** | Full feature implementation |

Adjusted estimate considering complexity: **12-16 hours** for MVP (without all nice-to-haves)

---

## Notes

### Implementation Complexity

- **Dependency Resolution**: Topological sort required to determine container startup order
- **Cleanup Order**: Must terminate containers before removing networks/volumes
- **Error Handling**: Partial failures during stack startup require careful cleanup
- **Concurrency**: Independent containers can start in parallel for performance
- **Resource Naming**: Auto-generate names for unnamed resources to avoid conflicts

### Docker CLI Limitations

- Network connect must happen at `docker run` time or via separate `docker network connect`
- Volume mount must happen at `docker run` time (can't add later)
- Circular dependency detection must be done in Swift (Docker doesn't prevent it)

### Alternative Approaches

1. **Sequential vs Parallel Startup**: Start all independent containers in parallel for speed
2. **Eager vs Lazy Cleanup**: Clean up immediately on error vs defer all cleanup to end
3. **Named vs Anonymous Resources**: Allow unnamed networks/volumes with auto-generated names

### Future Enhancements

- **Stack Templates**: Save common stack configurations for reuse
- **Hot Reload**: Replace containers in running stack without full restart
- **Stack Export**: Generate docker-compose.yml from StackRequest
- **Resource Pooling**: Reuse networks/volumes across test runs for speed
