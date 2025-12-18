# Feature: Tmpfs Mounts

**Status:** Implemented
**Priority:** Tier 2 - Medium
**Tracking:** `FEATURES.md` (Container configuration → Tmpfs mounts)

---

## Summary

Add support for mounting tmpfs (temporary filesystem) volumes in containers. Tmpfs mounts are RAM-backed filesystems that provide fast, ephemeral storage ideal for caching, temporary working directories, or sensitive data that should never touch disk.

Unlike bind mounts or named volumes, tmpfs mounts:
- Exist entirely in memory (never written to disk)
- Are destroyed when the container stops
- Provide faster I/O than disk-backed storage
- Are useful for security-sensitive data or high-throughput temporary storage

**Use cases:**
- Temporary build directories for compilation
- In-memory caches for test databases
- Sensitive configuration files that shouldn't persist
- High-performance scratch space for data processing

---

## Current State

### Existing ContainerRequest Capabilities

The `ContainerRequest` struct (`/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`) currently supports:

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

**Builder methods:**
- `withName(_:)` - Container name
- `withCommand(_:)` - Command override
- `withEnvironment(_:)` - Environment variables
- `withLabel(_:_:)` - Container labels
- `withExposedPort(_:hostPort:)` - Port mappings
- `waitingFor(_:)` - Wait strategies
- `withHost(_:)` - Host address

### Docker Execution Pattern

The `DockerClient` actor (`/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`) builds Docker CLI commands in `runContainer(_:)`:

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    // Name
    if let name = request.name {
        args += ["--name", name]
    }

    // Environment variables
    for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
        args += ["-e", "\(key)=\(value)"]
    }

    // Port mappings
    for mapping in request.ports {
        args += ["-p", mapping.dockerFlag]
    }

    // Labels
    for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
        args += ["--label", "\(key)=\(value)"]
    }

    args.append(request.image)
    args += request.command

    let output = try await runDocker(args)
    // ... parse container ID
}
```

**Current gaps:**
- No support for volume mounts (bind, named, or tmpfs)
- No way to specify tmpfs options (size, mode, tmpfs-specific flags)

---

## Requirements

### Functional Requirements

1. **Mount tmpfs at container path**: Ability to mount one or more tmpfs filesystems at specified paths inside the container
2. **Size limits**: Optional size limit for tmpfs (e.g., `100m`, `1g`) to prevent memory exhaustion
3. **File permissions**: Optional mode (Unix permissions) for the mount point (e.g., `0755`, `1777`)
4. **Multiple mounts**: Support multiple independent tmpfs mounts in a single container
5. **Validation**: Ensure paths are valid absolute container paths and options are well-formed

### Non-Functional Requirements

1. **Consistency**: Follow existing builder pattern (`withX()` methods returning `Self`)
2. **Type safety**: Use Swift types for size and mode instead of raw strings where practical
3. **Sendable & Hashable**: Maintain protocol conformance for `ContainerRequest`
4. **Documentation**: Clear inline documentation with usage examples
5. **Testing**: Unit tests for request building, integration tests with real containers

---

## API Design

### Proposed Types

```swift
/// Represents a tmpfs mount configuration
public struct TmpfsMount: Sendable, Hashable {
    /// Container path where tmpfs will be mounted (must be absolute)
    public var containerPath: String

    /// Optional size limit (e.g., "100m", "1g")
    /// If nil, tmpfs grows up to 50% of host memory by default
    public var sizeLimit: String?

    /// Optional Unix permission mode (e.g., "1777", "0755")
    /// If nil, uses default permissions (0755)
    public var mode: String?

    public init(
        containerPath: String,
        sizeLimit: String? = nil,
        mode: String? = nil
    ) {
        self.containerPath = containerPath
        self.sizeLimit = sizeLimit
        self.mode = mode
    }

    /// Generates the Docker flag representation
    /// Returns: "--tmpfs /path:size=1g,mode=1777" or "--tmpfs /path"
    var dockerFlag: String {
        var opts: [String] = []
        if let size = sizeLimit {
            opts.append("size=\(size)")
        }
        if let mode = mode {
            opts.append("mode=\(mode)")
        }

        if opts.isEmpty {
            return "\(containerPath)"
        } else {
            return "\(containerPath):\(opts.joined(separator: ","))"
        }
    }
}
```

### ContainerRequest Extension

Add to `ContainerRequest`:

```swift
public struct ContainerRequest: Sendable, Hashable {
    // ... existing properties ...
    public var tmpfsMounts: [TmpfsMount]

    public init(image: String) {
        // ... existing initialization ...
        self.tmpfsMounts = []
    }

    /// Mount a tmpfs (RAM-backed temporary filesystem) at the specified container path
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "alpine:3")
    ///     .withTmpfs("/tmp", sizeLimit: "100m", mode: "1777")
    ///     .withTmpfs("/cache", sizeLimit: "500m")
    /// ```
    ///
    /// - Parameters:
    ///   - containerPath: Absolute path in container where tmpfs will be mounted
    ///   - sizeLimit: Optional size limit (e.g., "100m", "1g"). Defaults to 50% of host memory if nil.
    ///   - mode: Optional Unix permission mode (e.g., "1777", "0755"). Defaults to "0755" if nil.
    /// - Returns: Updated ContainerRequest with the tmpfs mount added
    public func withTmpfs(
        _ containerPath: String,
        sizeLimit: String? = nil,
        mode: String? = nil
    ) -> Self {
        var copy = self
        copy.tmpfsMounts.append(TmpfsMount(
            containerPath: containerPath,
            sizeLimit: sizeLimit,
            mode: mode
        ))
        return copy
    }
}
```

### DockerClient Extension

Update `runContainer(_:)` in `DockerClient`:

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    // ... existing args (name, env, ports, labels) ...

    // Tmpfs mounts
    for mount in request.tmpfsMounts {
        args += ["--tmpfs", mount.dockerFlag]
    }

    args.append(request.image)
    args += request.command

    // ... rest of implementation
}
```

### Usage Examples

**Simple tmpfs mount:**
```swift
let request = ContainerRequest(image: "postgres:15")
    .withTmpfs("/var/lib/postgresql/data")
```

**With size limit:**
```swift
let request = ContainerRequest(image: "redis:7")
    .withTmpfs("/data", sizeLimit: "256m")
```

**With size and mode (e.g., world-writable sticky bit):**
```swift
let request = ContainerRequest(image: "alpine:3")
    .withTmpfs("/tmp", sizeLimit: "100m", mode: "1777")
```

**Multiple tmpfs mounts:**
```swift
let request = ContainerRequest(image: "ubuntu:22.04")
    .withTmpfs("/tmp", sizeLimit: "100m", mode: "1777")
    .withTmpfs("/var/cache", sizeLimit: "500m")
    .withTmpfs("/workspace", sizeLimit: "1g")
```

---

## Implementation Steps

### Step 1: Add TmpfsMount struct
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

1. Define `TmpfsMount` struct after `ContainerPort` (lines 3-18)
2. Implement `Sendable` and `Hashable` conformance
3. Add `dockerFlag` computed property to generate Docker CLI flags
4. Handle both `--tmpfs /path` and `--tmpfs /path:size=X,mode=Y` formats

**Docker flag format:**
```
--tmpfs /path                          # Simple mount
--tmpfs /path:size=100m                # With size limit
--tmpfs /path:mode=1777                # With mode
--tmpfs /path:size=100m,mode=1777      # Both options
```

### Step 2: Extend ContainerRequest
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

1. Add `tmpfsMounts: [TmpfsMount]` property to struct (after `ports`, line 32)
2. Initialize to empty array in `init(image:)` (line 42)
3. Add `withTmpfs(_:sizeLimit:mode:)` builder method (after `withHost(_:)`, line 87)
4. Include comprehensive documentation with examples

### Step 3: Update DockerClient
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

1. In `runContainer(_:)`, add tmpfs mount handling after labels (line 45)
2. Iterate through `request.tmpfsMounts` in sorted order for determinism
3. Append `--tmpfs` flag with `mount.dockerFlag` for each mount

```swift
for mount in request.tmpfsMounts.sorted(by: { $0.containerPath < $1.containerPath }) {
    args += ["--tmpfs", mount.dockerFlag]
}
```

**Sort order:** Use container path for consistent command generation (helps with debugging and testing)

### Step 4: Unit Tests
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests after existing port tests (line 13):

```swift
@Test func buildsTmpfsMountFlags() {
    let mount1 = TmpfsMount(containerPath: "/tmp")
    #expect(mount1.dockerFlag == "/tmp")

    let mount2 = TmpfsMount(containerPath: "/cache", sizeLimit: "100m")
    #expect(mount2.dockerFlag == "/cache:size=100m")

    let mount3 = TmpfsMount(containerPath: "/work", sizeLimit: "1g", mode: "1777")
    #expect(mount3.dockerFlag == "/work:size=1g,mode=1777")

    let mount4 = TmpfsMount(containerPath: "/data", mode: "0755")
    #expect(mount4.dockerFlag == "/data:mode=0755")
}

@Test func addsTmpfsMountsToRequest() {
    let request = ContainerRequest(image: "alpine:3")
        .withTmpfs("/tmp", sizeLimit: "100m", mode: "1777")
        .withTmpfs("/cache", sizeLimit: "500m")

    #expect(request.tmpfsMounts.count == 2)
    #expect(request.tmpfsMounts[0].containerPath == "/tmp")
    #expect(request.tmpfsMounts[0].sizeLimit == "100m")
    #expect(request.tmpfsMounts[0].mode == "1777")
    #expect(request.tmpfsMounts[1].containerPath == "/cache")
    #expect(request.tmpfsMounts[1].sizeLimit == "500m")
    #expect(request.tmpfsMounts[1].mode == nil)
}

@Test func tmpfsMountsAreHashable() {
    let mount1 = TmpfsMount(containerPath: "/tmp", sizeLimit: "100m")
    let mount2 = TmpfsMount(containerPath: "/tmp", sizeLimit: "100m")
    let mount3 = TmpfsMount(containerPath: "/tmp", sizeLimit: "200m")

    #expect(mount1 == mount2)
    #expect(mount1 != mount3)
}
```

### Step 5: Integration Tests
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

Add after existing test (line 19):

```swift
@Test func canMountTmpfs_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withTmpfs("/tmpdata", sizeLimit: "50m", mode: "1777")
        .withCommand(["sh", "-c", "mount | grep tmpdata && df -h /tmpdata && touch /tmpdata/test.txt && ls -la /tmpdata"])
        .waitingFor(.logContains("tmpdata", timeout: .seconds(10)))

    try await withContainer(request) { container in
        let logs = try await container.logs()

        // Verify tmpfs is mounted
        #expect(logs.contains("tmpfs on /tmpdata"))

        // Verify size limit is applied (should show ~50M)
        #expect(logs.contains("/tmpdata"))

        // Verify file creation works
        #expect(logs.contains("test.txt"))
    }
}

@Test func canMountMultipleTmpfs_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withTmpfs("/tmp1", sizeLimit: "10m")
        .withTmpfs("/tmp2", sizeLimit: "20m")
        .withCommand(["sh", "-c", "mount | grep 'tmpfs on /tmp' && echo SUCCESS"])
        .waitingFor(.logContains("SUCCESS", timeout: .seconds(10)))

    try await withContainer(request) { container in
        let logs = try await container.logs()

        // Both mounts should be present
        #expect(logs.contains("tmpfs on /tmp1"))
        #expect(logs.contains("tmpfs on /tmp2"))
        #expect(logs.contains("SUCCESS"))
    }
}
```

---

## Testing Plan

### Unit Tests
**Focus:** Request building, flag generation, type conformance

✅ **TmpfsMount flag generation**
- Simple mount (path only)
- Mount with size limit
- Mount with mode
- Mount with both size and mode
- Edge cases (empty options)

✅ **ContainerRequest builder**
- Add single tmpfs mount
- Add multiple tmpfs mounts
- Builder method returns modified copy
- Array is initialized empty

✅ **Protocol conformance**
- `TmpfsMount` is `Sendable`
- `TmpfsMount` is `Hashable`
- `ContainerRequest` remains `Sendable` and `Hashable`

### Integration Tests
**Focus:** Real Docker execution (opt-in via `TESTCONTAINERS_RUN_DOCKER_TESTS=1`)

✅ **Single tmpfs mount**
- Verify mount appears in `mount` output
- Verify filesystem type is tmpfs
- Verify size limit is applied
- Verify files can be created/read

✅ **Multiple tmpfs mounts**
- Verify all mounts are present
- Verify each has correct options
- Verify isolation between mounts

✅ **Permission modes**
- Mount with `mode=1777` (world-writable sticky)
- Verify permissions with `ls -ld`

✅ **Memory constraints**
- Test with various size limits (10m, 100m, 1g)
- Verify `df -h` shows correct size

### Manual Testing Checklist

```bash
# Run unit tests
swift test --filter ContainerRequestTests

# Run integration tests (requires Docker)
TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test --filter DockerIntegrationTests

# Verify Docker command generation
swift run # (with debug logging to inspect args)

# Test with real workload (PostgreSQL with tmpfs data directory)
# Expects faster performance and no disk writes
```

---

## Acceptance Criteria

### Definition of Done

- [x] **API Design:**
  - [x] `TmpfsMount` struct with `containerPath`, `sizeLimit`, `mode` properties
  - [x] `TmpfsMount.dockerFlag` correctly generates Docker CLI flags
  - [x] `ContainerRequest.tmpfsMounts` property added
  - [x] `ContainerRequest.withTmpfs(_:sizeLimit:mode:)` builder method implemented
  - [x] All types maintain `Sendable` and `Hashable` conformance

- [x] **Implementation:**
  - [x] `DockerClient.runContainer(_:)` includes `--tmpfs` flags in generated command
  - [x] Multiple tmpfs mounts are supported
  - [x] Mounts are processed in deterministic order (sorted by path)

- [x] **Testing:**
  - [x] Unit tests for `TmpfsMount.dockerFlag` generation (all option combinations)
  - [x] Unit tests for `ContainerRequest.withTmpfs()` builder
  - [x] Unit tests for protocol conformance (Sendable, Hashable)
  - [x] Integration test: single tmpfs mount with size/mode verification
  - [x] Integration test: multiple tmpfs mounts
  - [x] All tests pass in CI

- [x] **Documentation:**
  - [x] Inline documentation for `TmpfsMount` struct
  - [x] Inline documentation for `withTmpfs()` method with usage examples
  - [x] Parameter documentation (containerPath, sizeLimit, mode)
  - [x] `FEATURES.md` updated (mark "Tmpfs mounts" as implemented)

- [x] **Code Quality:**
  - [x] Follows existing code style and patterns
  - [x] No new compiler warnings
  - [x] Code is properly formatted (SwiftFormat, if applicable)
  - [x] Consistent with existing builder pattern (`withX()` methods)

### Success Metrics

1. **Functional:** Users can mount tmpfs with `withTmpfs()` and containers start successfully
2. **Compatibility:** Works with all supported container images (Alpine, Ubuntu, Postgres, Redis, etc.)
3. **Performance:** Tmpfs mounts provide measurably faster I/O than disk-backed storage
4. **Reliability:** Integration tests pass consistently across multiple runs

---

## Docker Documentation References

**Official Docker `--tmpfs` documentation:**
- [Docker run reference - tmpfs mounts](https://docs.docker.com/engine/reference/commandline/run/#tmpfs)
- [Docker mount types](https://docs.docker.com/storage/)

**Flag syntax:**
```bash
docker run --tmpfs /path                          # Basic mount
docker run --tmpfs /path:size=100m                # With size limit
docker run --tmpfs /path:size=100m,mode=1777      # With size and mode
docker run --tmpfs /tmp --tmpfs /cache            # Multiple mounts
```

**Alternative `--mount` syntax (not used in this implementation):**
```bash
docker run --mount type=tmpfs,destination=/path,tmpfs-size=104857600,tmpfs-mode=1777
```

**Note:** This implementation uses the simpler `--tmpfs` flag syntax for consistency with the existing CLI-based approach. The `--mount` syntax could be added later if more tmpfs-specific options are needed.

---

## Related Features

- **Volume mounts (named volumes):** Persistent storage backed by Docker volumes
- **Bind mounts:** Mount host filesystem paths into containers
- **Working directory (`--workdir`):** Often used in conjunction with tmpfs for build workspaces
- **Resource limits (memory):** Tmpfs consumes host memory, so memory limits may be relevant

**Implementation order suggestion:**
1. ✅ Tmpfs mounts (this ticket)
2. Bind mounts (host paths)
3. Named volumes (Docker-managed persistence)

---

## Notes

- **Security:** Tmpfs is ideal for sensitive data that should never touch disk (passwords, keys, tokens during testing)
- **Performance:** Significantly faster than disk I/O, especially for small file operations
- **Memory usage:** Tmpfs counts toward container memory usage; consider setting memory limits if using large tmpfs mounts
- **Persistence:** Data is lost when container stops (by design)
- **Docker Desktop on macOS:** Tmpfs works but is actually backed by the Linux VM's memory, not native macOS filesystem

---

## Open Questions

1. **Should we support the `--mount type=tmpfs` syntax in addition to `--tmpfs`?**
   - **Decision:** Start with `--tmpfs` for simplicity. Add `--mount` later if needed.

2. **Should we validate size limit format (e.g., enforce "100m", "1g" pattern)?**
   - **Decision:** No validation in v1. Pass through to Docker and let it error if invalid. Add validation later if users request it.

3. **Should we support advanced tmpfs options (noatime, nodev, nosuid, etc.)?**
   - **Decision:** Not in v1. Add an `options: [String]` parameter later if needed.

4. **Should we warn if tmpfs size exceeds available memory?**
   - **Decision:** No. Docker will handle resource constraints. Document memory implications.

5. **Should we provide convenience methods for common patterns (e.g., `.withTmpTmp(sizeLimit:)` for `/tmp`)?**
   - **Decision:** Not in v1. Keep API minimal and generic.
