# Feature 012: Volume Mounts (Named Volumes)

**Status**: Implemented
**Priority**: Tier 2 (Medium Priority)
**Estimated Complexity**: Medium
**Dependencies**: None

---

## Summary

Enable mounting named Docker volumes into containers to provide persistent storage that survives container restarts and can be shared between containers. This feature allows tests to:

- Store and retrieve data that persists across container lifecycles
- Pre-populate volumes with test data
- Share data between multiple containers
- Test applications that require persistent storage (databases, file uploads, etc.)

Named volumes are managed by Docker and offer better portability than bind mounts, making them ideal for test scenarios.

---

## Current State

### ContainerRequest Capabilities

The `ContainerRequest` struct (located at `/Sources/TestContainers/ContainerRequest.swift`) currently supports:

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
}
```

**Builder methods available**:
- `.withName(_:)` - Set container name
- `.withCommand(_:)` - Set container command
- `.withEnvironment(_:)` - Add environment variables
- `.withLabel(_:_:)` - Add labels
- `.withExposedPort(_:hostPort:)` - Expose and map ports
- `.waitingFor(_:)` - Set wait strategy
- `.withHost(_:)` - Set host address

### DockerClient Implementation

The `DockerClient.runContainer(_:)` method (at `/Sources/TestContainers/DockerClient.swift:28-54`) builds Docker CLI arguments:

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

    for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
        args += ["--label", "\(key)=\(value)"]
    }

    args.append(request.image)
    args += request.command

    let output = try await runDocker(args)
    // ...
}
```

**Pattern observations**:
1. Arguments are built incrementally into `args` array
2. Collections are sorted for deterministic ordering (important for Hashable)
3. Each configuration type (env, ports, labels) has dedicated loop
4. Image is appended before command arguments

**Missing**: Volume mount argument construction (no `-v` or `--mount` flags)

---

## Requirements

### Functional Requirements

1. **Named Volume Specification**
   - Support Docker-managed named volumes
   - Volume name must be valid Docker volume identifier
   - Multiple volumes per container

2. **Mount Path Configuration**
   - Specify container-side mount path (absolute path)
   - Mount path must be valid Unix path

3. **Read-Only Option**
   - Support read-only mounts via `:ro` suffix
   - Default to read-write mounts

4. **Volume Driver Options** (Future Enhancement)
   - Initial implementation: default driver only
   - Future: support custom drivers and driver options

### Non-Functional Requirements

1. **Type Safety**
   - Leverage Swift's type system to prevent invalid configurations
   - Value type semantics (struct, Sendable, Hashable)

2. **Consistency**
   - Follow existing builder pattern in `ContainerRequest`
   - Match code style and patterns (sorted keys, etc.)

3. **Testability**
   - Unit testable without Docker
   - Integration testable with Docker

---

## API Design

### Proposed Types

```swift
/// Represents a volume mount configuration
public struct VolumeMount: Hashable, Sendable {
    public var volumeName: String
    public var containerPath: String
    public var readOnly: Bool

    public init(volumeName: String, containerPath: String, readOnly: Bool = false) {
        self.volumeName = volumeName
        self.containerPath = containerPath
        self.readOnly = readOnly
    }

    /// Converts to Docker CLI flag format: "volumeName:containerPath" or "volumeName:containerPath:ro"
    var dockerFlag: String {
        if readOnly {
            return "\(volumeName):\(containerPath):ro"
        }
        return "\(volumeName):\(containerPath)"
    }
}
```

### ContainerRequest Extension

```swift
public struct ContainerRequest: Sendable, Hashable {
    // ... existing properties ...
    public var volumes: [VolumeMount]

    public init(image: String) {
        // ... existing initialization ...
        self.volumes = []
    }

    /// Mounts a named volume into the container
    /// - Parameters:
    ///   - volumeName: Docker volume name (must already exist or will be created)
    ///   - containerPath: Absolute path inside container
    ///   - readOnly: Whether to mount as read-only (default: false)
    /// - Returns: Updated ContainerRequest
    public func withVolume(_ volumeName: String, mountedAt containerPath: String, readOnly: Bool = false) -> Self {
        var copy = self
        copy.volumes.append(VolumeMount(volumeName: volumeName, containerPath: containerPath, readOnly: readOnly))
        return copy
    }

    /// Alternative: accepts VolumeMount directly for advanced use cases
    public func withVolumeMount(_ mount: VolumeMount) -> Self {
        var copy = self
        copy.volumes.append(mount)
        return copy
    }
}
```

### DockerClient Integration

```swift
// In DockerClient.runContainer(_:)
// Add after labels loop, before image:

for mount in request.volumes {
    args += ["-v", mount.dockerFlag]
}
```

### Usage Examples

```swift
// Example 1: Simple named volume mount
let request = ContainerRequest(image: "postgres:16")
    .withVolume("pgdata", mountedAt: "/var/lib/postgresql/data")
    .withExposedPort(5432)

// Example 2: Read-only configuration volume
let request = ContainerRequest(image: "nginx:alpine")
    .withVolume("nginx-config", mountedAt: "/etc/nginx/conf.d", readOnly: true)
    .withExposedPort(80)

// Example 3: Multiple volumes
let request = ContainerRequest(image: "app:latest")
    .withVolume("app-data", mountedAt: "/data")
    .withVolume("app-logs", mountedAt: "/var/log/app")
    .withVolume("app-cache", mountedAt: "/cache", readOnly: false)

// Example 4: Using VolumeMount directly
let mount = VolumeMount(volumeName: "shared-data", containerPath: "/mnt/data", readOnly: true)
let request = ContainerRequest(image: "alpine:3")
    .withVolumeMount(mount)
```

---

## Implementation Steps

### Step 1: Add VolumeMount Type
**File**: `/Sources/TestContainers/ContainerRequest.swift`

1. Add `VolumeMount` struct before `ContainerRequest` definition
2. Implement `dockerFlag` computed property
3. Ensure conformance to `Hashable` and `Sendable`

**Acceptance**:
- `VolumeMount` compiles
- `dockerFlag` returns correct format for read-write and read-only

### Step 2: Update ContainerRequest
**File**: `/Sources/TestContainers/ContainerRequest.swift`

1. Add `volumes: [VolumeMount]` property
2. Initialize `volumes = []` in `init(image:)`
3. Add `withVolume(_:mountedAt:readOnly:)` builder method
4. Add `withVolumeMount(_:)` builder method

**Acceptance**:
- `ContainerRequest` compiles with new property
- Builder methods return `Self` correctly
- Hashable still works (volumes are Hashable)

### Step 3: Integrate with DockerClient
**File**: `/Sources/TestContainers/DockerClient.swift`

1. In `runContainer(_:)` method (around line 46, after labels loop)
2. Add volume mount argument loop:
   ```swift
   for mount in request.volumes {
       args += ["-v", mount.dockerFlag]
   }
   ```
3. Sort volumes by name for deterministic ordering:
   ```swift
   for mount in request.volumes.sorted(by: { $0.volumeName < $1.volumeName }) {
       args += ["-v", mount.dockerFlag]
   }
   ```

**Acceptance**:
- Docker CLI args include `-v volumeName:path` for each mount
- Args are in deterministic order

### Step 4: Unit Tests
**File**: `/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests for:

```swift
@Test func volumeMountDockerFlag() {
    let mount = VolumeMount(volumeName: "data", containerPath: "/mnt/data")
    #expect(mount.dockerFlag == "data:/mnt/data")
}

@Test func volumeMountDockerFlagReadOnly() {
    let mount = VolumeMount(volumeName: "config", containerPath: "/etc/app", readOnly: true)
    #expect(mount.dockerFlag == "config:/etc/app:ro")
}

@Test func buildsContainerRequestWithVolumes() {
    let request = ContainerRequest(image: "alpine:3")
        .withVolume("data", mountedAt: "/data")
        .withVolume("logs", mountedAt: "/logs", readOnly: true)

    #expect(request.volumes.count == 2)
    #expect(request.volumes.contains(VolumeMount(volumeName: "data", containerPath: "/data")))
    #expect(request.volumes.contains(VolumeMount(volumeName: "logs", containerPath: "/logs", readOnly: true)))
}

@Test func volumeMountBuilderReturnsNewInstance() {
    let original = ContainerRequest(image: "alpine:3")
    let modified = original.withVolume("data", mountedAt: "/data")

    #expect(original.volumes.isEmpty)
    #expect(modified.volumes.count == 1)
}
```

**Acceptance**: All unit tests pass

### Step 5: Integration Tests
**File**: `/Tests/TestContainersTests/DockerIntegrationTests.swift`

Add Docker integration test (opt-in via environment variable):

```swift
@Test func canMountNamedVolume_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Test scenario: Create volume, write data in one container, read in another
    let volumeName = "test-volume-\(UUID().uuidString)"

    // Create volume (docker volume create)
    let docker = DockerClient()
    _ = try await docker.runDocker(["volume", "create", volumeName])

    defer {
        // Cleanup volume
        Task {
            try? await docker.runDocker(["volume", "rm", volumeName])
        }
    }

    // Write data to volume
    let writeRequest = ContainerRequest(image: "alpine:3")
        .withVolume(volumeName, mountedAt: "/data")
        .withCommand(["sh", "-c", "echo 'test content' > /data/test.txt"])

    try await withContainer(writeRequest) { _ in
        // Container runs command and exits
    }

    // Read data from volume in new container
    let readRequest = ContainerRequest(image: "alpine:3")
        .withVolume(volumeName, mountedAt: "/data", readOnly: true)
        .withCommand(["cat", "/data/test.txt"])

    try await withContainer(readRequest) { container in
        let logs = try await container.logs()
        #expect(logs.contains("test content"))
    }
}

@Test func canMountReadOnlyVolume_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let volumeName = "test-readonly-\(UUID().uuidString)"
    let docker = DockerClient()
    _ = try await docker.runDocker(["volume", "create", volumeName])

    defer {
        Task { try? await docker.runDocker(["volume", "rm", volumeName]) }
    }

    // Attempt to write to read-only volume should fail
    let request = ContainerRequest(image: "alpine:3")
        .withVolume(volumeName, mountedAt: "/data", readOnly: true)
        .withCommand(["sh", "-c", "echo 'fail' > /data/test.txt"])

    do {
        try await withContainer(request) { container in
            let logs = try await container.logs()
            // Should see permission denied or read-only filesystem error
            #expect(logs.contains("Read-only") || logs.contains("read-only") || logs.contains("Permission denied"))
        }
    } catch {
        // Container may exit with error, which is expected behavior
    }
}
```

**Acceptance**: Integration tests pass when Docker is available

### Step 6: Documentation
**Files**:
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/README.md`
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md`

1. Update README.md with volume mount example
2. Update FEATURES.md to move "Volume mounts (named volumes)" to Implemented section
3. Add code examples showing common use cases

**Acceptance**: Documentation is clear and includes working examples

---

## Testing Plan

### Unit Tests
Location: `/Tests/TestContainersTests/ContainerRequestTests.swift`

| Test Case | Purpose | Expected Result |
|-----------|---------|-----------------|
| `volumeMountDockerFlag` | Verify basic flag format | Returns `"volumeName:/path"` |
| `volumeMountDockerFlagReadOnly` | Verify read-only flag | Returns `"volumeName:/path:ro"` |
| `buildsContainerRequestWithVolumes` | Verify builder adds volumes | Request contains expected VolumeMount instances |
| `volumeMountBuilderReturnsNewInstance` | Verify immutability | Original request unchanged, new request has volume |
| `volumeMountsAreSorted` | Verify deterministic ordering | Multiple volumes sorted by name |
| `volumeMountHashable` | Verify Hashable conformance | Same volumes hash equally |

### Integration Tests
Location: `/Tests/TestContainersTests/DockerIntegrationTests.swift`

| Test Case | Purpose | Setup | Verification |
|-----------|---------|-------|--------------|
| `canMountNamedVolume_whenOptedIn` | End-to-end volume persistence | Create volume, write in container A, read in container B | Data persists across containers |
| `canMountReadOnlyVolume_whenOptedIn` | Read-only enforcement | Mount volume with `readOnly: true`, attempt write | Write fails with permission error |
| `canMountMultipleVolumes_whenOptedIn` | Multiple mounts work | Container with 3 different volumes | All mount points accessible |

### Manual Testing Scenarios

1. **PostgreSQL with persistent data**:
   ```swift
   let request = ContainerRequest(image: "postgres:16")
       .withVolume("pgdata", mountedAt: "/var/lib/postgresql/data")
       .withEnvironment(["POSTGRES_PASSWORD": "test"])
       .withExposedPort(5432)
       .waitingFor(.tcpPort(5432))
   ```

2. **Nginx with configuration volume**:
   ```swift
   let request = ContainerRequest(image: "nginx:alpine")
       .withVolume("nginx-conf", mountedAt: "/etc/nginx/conf.d", readOnly: true)
       .withExposedPort(80)
   ```

3. **Application with data, logs, and cache**:
   ```swift
   let request = ContainerRequest(image: "myapp:latest")
       .withVolume("app-data", mountedAt: "/app/data")
       .withVolume("app-logs", mountedAt: "/var/log/app")
       .withVolume("app-cache", mountedAt: "/tmp/cache")
   ```

---

## Acceptance Criteria

### Definition of Done

- [x] `VolumeMount` struct implemented with `dockerFlag` property
- [x] `ContainerRequest` has `volumes` property and builder methods
- [x] `DockerClient.runContainer` includes `-v` flags for volumes
- [x] Unit tests pass for `VolumeMount` and `ContainerRequest` builders
- [x] Integration tests pass (when Docker available)
- [x] Volumes are sorted deterministically for Hashable consistency
- [x] Code follows existing patterns (builder methods, sorted collections, Sendable/Hashable)
- [x] Documentation updated in FEATURES.md
- [x] Feature works with real Docker containers (verified via integration tests)

### Success Metrics

1. **API Usability**: Developer can add volume mounts with single builder call
2. **Type Safety**: Invalid configurations caught at compile time
3. **Reliability**: Integration tests demonstrate data persistence
4. **Consistency**: Code matches existing patterns in ContainerRequest
5. **Performance**: No measurable overhead vs manual `docker run -v`

---

## Future Enhancements

### Bind Mounts (Separate Feature)
- Mount host filesystem paths into containers
- API: `.withBindMount(hostPath:containerPath:readOnly:)`
- Flag: `-v /host/path:/container/path[:ro]`

### Tmpfs Mounts (Separate Feature)
- In-memory temporary filesystems
- API: `.withTmpfs(containerPath:options:)`
- Flag: `--tmpfs /path[:options]`

### Volume Driver Options
- Support custom volume drivers
- API: `.withVolume(_:mountedAt:driver:driverOpts:)`
- Requires volume creation with driver specification

### Volume Lifecycle Management
- `DockerClient.createVolume(name:driver:labels:)`
- `DockerClient.removeVolume(name:force:)`
- `DockerClient.listVolumes(filters:)`
- Scoped helper: `withVolume(name:_:)` auto-cleanup

### Mount Options
- SELinux labels (`:z`, `:Z`)
- Volume propagation modes (`rprivate`, `shared`, etc.)
- Copy mode (`nocopy`)

---

## References

### Docker CLI Documentation
- `docker run -v` flag: https://docs.docker.com/engine/reference/commandline/run/#volume
- Volume management: https://docs.docker.com/storage/volumes/

### Existing Code Patterns
- **Builder pattern**: `/Sources/TestContainers/ContainerRequest.swift:47-87`
- **Docker flag generation**: `/Sources/TestContainers/ContainerRequest.swift:12-17` (ContainerPort.dockerFlag)
- **DockerClient arg building**: `/Sources/TestContainers/DockerClient.swift:28-54`
- **Sorted collections**: `/Sources/TestContainers/DockerClient.swift:35` (environment), line 43 (labels)

### Related Features
- Feature 011: Bind Mounts (host path → container path)
- Feature 013: Tmpfs Mounts
- Feature 014: Volume Lifecycle Management

---

## Implementation Checklist

- [x] Create `VolumeMount` struct in ContainerRequest.swift
- [x] Add `volumes` property to `ContainerRequest`
- [x] Implement `withVolume(_:mountedAt:readOnly:)` method
- [x] Implement `withVolumeMount(_:)` method
- [x] Update `DockerClient.runContainer` to add `-v` flags
- [x] Write unit tests for VolumeMount.dockerFlag
- [x] Write unit tests for ContainerRequest builders
- [x] Write integration test for volume persistence
- [x] Write integration test for read-only volumes
- [x] Update FEATURES.md to mark as implemented
- [ ] Manual testing with PostgreSQL
- [ ] Manual testing with Nginx
- [x] Code review and refinement
- [x] Merge to main branch

---

**Created**: 2025-12-15
**Last Updated**: 2025-12-15
**Assignee**: TBD
**Target Version**: 0.2.0
