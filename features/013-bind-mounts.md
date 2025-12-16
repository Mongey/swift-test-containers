# Feature 013: Bind Mounts

**Status**: Implemented
**Priority**: Tier 2 (Medium Priority)
**Estimated Complexity**: Medium

---

## Summary

Enable mounting host directories and files into containers by adding bind mount support to `ContainerRequest`. This allows tests to:
- Provide configuration files from the host filesystem
- Share test fixtures and data files with containers
- Extract artifacts and logs from containers to the host
- Customize container behavior with host-based resources

Bind mounts create a mapping from a host filesystem path to a container path, with optional read-only mode and consistency settings for cross-platform performance (macOS/Linux).

---

## Current State

### ContainerRequest Capabilities (v0.1.0)

The `ContainerRequest` struct currently supports:

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

**Builder methods** (following established pattern):
- `withName(_:)` - Container name
- `withCommand(_:)` - Override CMD/ENTRYPOINT
- `withEnvironment(_:)` - Environment variables (merged)
- `withLabel(_:_:)` - Single label addition
- `withExposedPort(_:hostPort:)` - Port mappings
- `waitingFor(_:)` - Wait strategy selection
- `withHost(_:)` - Override default host

**Relevant implementation pattern** (from `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`):

```swift
// Example: ContainerPort with dockerFlag property
public struct ContainerPort: Hashable, Sendable {
    public var containerPort: Int
    public var hostPort: Int?

    var dockerFlag: String {
        if let hostPort {
            return "\(hostPort):\(containerPort)"
        }
        return "\(containerPort)"
    }
}

// Example: Builder pattern
public func withExposedPort(_ containerPort: Int, hostPort: Int? = nil) -> Self {
    var copy = self
    copy.ports.append(ContainerPort(containerPort: containerPort, hostPort: hostPort))
    return copy
}
```

**DockerClient integration** (from `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`):

The `runContainer(_:)` method builds Docker CLI arguments:

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    // Name
    if let name = request.name {
        args += ["--name", name]
    }

    // Environment (sorted for determinism)
    for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
        args += ["-e", "\(key)=\(value)"]
    }

    // Port mappings
    for mapping in request.ports {
        args += ["-p", mapping.dockerFlag]
    }

    // Labels (sorted)
    for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
        args += ["--label", "\(key)=\(value)"]
    }

    args.append(request.image)
    args += request.command

    let output = try await runDocker(args)
    // ...
}
```

### Missing Capability

There's currently no way to mount host directories or files into containers. This blocks use cases like:
- Loading test data from fixtures directory
- Providing custom config files (nginx.conf, postgresql.conf, etc.)
- Extracting logs or artifacts after test completion
- Sharing source code for live-reload scenarios

---

## Requirements

### Functional Requirements

1. **Host path specification**
   - Absolute paths required (Docker requirement)
   - Validation: path must exist on host (optional, configurable)
   - Support both files and directories

2. **Container path specification**
   - Absolute paths in container filesystem
   - Path will be created if it doesn't exist (Docker default behavior)

3. **Read-write mode control**
   - Default: read-write (`rw`)
   - Option: read-only (`ro`)
   - Prevents accidental container modifications to host files

4. **Consistency modes** (macOS performance optimization)
   - `default` - No explicit consistency mode
   - `cached` - Host is authoritative (fastest for read-heavy workloads)
   - `delegated` - Container is authoritative (fastest for write-heavy workloads)
   - `consistent` - Perfect consistency (slowest, rarely needed)
   - Reference: https://docs.docker.com/storage/bind-mounts/#configure-mount-consistency-for-macos

5. **Multiple bind mounts**
   - Support mounting multiple paths in a single container
   - No conflicts between mount paths (validation optional)

### Non-Functional Requirements

1. **API ergonomics**
   - Follow existing builder pattern (`withBindMount(...)`)
   - Fluent chaining with other request modifiers
   - Type-safe Swift API

2. **Cross-platform compatibility**
   - macOS: Full support including consistency modes
   - Linux: Full support (consistency modes ignored, no-op)
   - Docker Desktop: Works on all platforms

3. **Error handling**
   - Use existing `TestContainersError` enum
   - Clear error messages for invalid paths
   - Fail fast on Docker CLI errors

4. **Testing**
   - Unit tests for builder pattern and flag generation
   - Integration tests (gated by `TESTCONTAINERS_RUN_DOCKER_TESTS=1`)
   - Cross-platform validation (macOS + Linux CI)

---

## API Design

### Proposed Types

```swift
// Sources/TestContainers/ContainerRequest.swift

/// Represents bind mount consistency mode for cross-platform performance tuning
public enum BindMountConsistency: String, Sendable, Hashable {
    case `default` = ""        // No explicit mode
    case cached = "cached"     // Host is authoritative (read-heavy)
    case delegated = "delegated" // Container is authoritative (write-heavy)
    case consistent = "consistent" // Perfect consistency
}

/// Represents a bind mount from host path to container path
public struct BindMount: Sendable, Hashable {
    public var hostPath: String
    public var containerPath: String
    public var readOnly: Bool
    public var consistency: BindMountConsistency

    public init(
        hostPath: String,
        containerPath: String,
        readOnly: Bool = false,
        consistency: BindMountConsistency = .default
    ) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.readOnly = readOnly
        self.consistency = consistency
    }

    /// Generates Docker CLI flag for this bind mount
    /// Examples:
    ///   - `/host/path:/container/path`
    ///   - `/host/path:/container/path:ro`
    ///   - `/host/path:/container/path:cached`
    ///   - `/host/path:/container/path:ro,cached`
    var dockerFlag: String {
        var parts = [hostPath, containerPath]
        var options: [String] = []

        if readOnly {
            options.append("ro")
        }

        if consistency != .default {
            options.append(consistency.rawValue)
        }

        if !options.isEmpty {
            parts.append(options.joined(separator: ","))
        }

        return parts.joined(separator: ":")
    }
}
```

### ContainerRequest Extension

```swift
// Add to ContainerRequest struct
public struct ContainerRequest: Sendable, Hashable {
    // ... existing properties ...
    public var bindMounts: [BindMount]

    public init(image: String) {
        // ... existing initialization ...
        self.bindMounts = []
    }
}

// Builder methods
extension ContainerRequest {
    /// Adds a bind mount from host path to container path
    ///
    /// - Parameters:
    ///   - hostPath: Absolute path on the host filesystem (must exist)
    ///   - containerPath: Absolute path in the container filesystem
    ///   - readOnly: If true, container cannot modify the mounted path (default: false)
    ///   - consistency: Performance tuning for macOS (default: .default)
    ///
    /// - Returns: Updated ContainerRequest with the bind mount added
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "nginx:alpine")
    ///     .withBindMount(
    ///         hostPath: "/Users/dev/config/nginx.conf",
    ///         containerPath: "/etc/nginx/nginx.conf",
    ///         readOnly: true
    ///     )
    /// ```
    public func withBindMount(
        hostPath: String,
        containerPath: String,
        readOnly: Bool = false,
        consistency: BindMountConsistency = .default
    ) -> Self {
        var copy = self
        copy.bindMounts.append(BindMount(
            hostPath: hostPath,
            containerPath: containerPath,
            readOnly: readOnly,
            consistency: consistency
        ))
        return copy
    }

    /// Adds a bind mount using a pre-constructed BindMount value
    ///
    /// - Parameter mount: The bind mount configuration
    /// - Returns: Updated ContainerRequest with the bind mount added
    ///
    /// Example:
    /// ```swift
    /// let mount = BindMount(
    ///     hostPath: "/tmp/data",
    ///     containerPath: "/data",
    ///     readOnly: false,
    ///     consistency: .cached
    /// )
    /// let request = ContainerRequest(image: "alpine:3")
    ///     .withBindMount(mount)
    /// ```
    public func withBindMount(_ mount: BindMount) -> Self {
        var copy = self
        copy.bindMounts.append(mount)
        return copy
    }
}
```

### DockerClient Integration

```swift
// Modify DockerClient.runContainer(_:) method
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    // ... existing code (name, env, ports, labels) ...

    // Bind mounts (sorted by host path for determinism)
    for mount in request.bindMounts.sorted(by: { $0.hostPath < $1.hostPath }) {
        args += ["-v", mount.dockerFlag]
    }

    args.append(request.image)
    args += request.command

    // ... rest of implementation ...
}
```

---

## Implementation Steps

### Step 1: Add BindMount Types

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

1. Add `BindMountConsistency` enum before `ContainerRequest` struct
2. Add `BindMount` struct with `dockerFlag` computed property
3. Ensure both types conform to `Sendable` and `Hashable`

**Rationale:** Follow the pattern established by `ContainerPort` which also has a `dockerFlag` property.

### Step 2: Extend ContainerRequest

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

1. Add `public var bindMounts: [BindMount]` property to struct
2. Initialize to `[]` in `init(image:)`
3. Add `withBindMount(hostPath:containerPath:readOnly:consistency:)` builder method
4. Add `withBindMount(_:)` convenience builder method

**Rationale:** Consistent with existing builder pattern using copy-on-write semantics.

### Step 3: Update DockerClient

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

1. In `runContainer(_:)` method, add bind mount argument generation
2. Insert after labels, before image name
3. Sort bind mounts by `hostPath` for deterministic ordering
4. Use `-v` flag (traditional syntax) or `--mount type=bind` (modern syntax)

**Docker CLI Reference:**
```bash
# Traditional -v syntax (recommended for simplicity)
docker run -v /host/path:/container/path:ro,cached alpine:3

# Modern --mount syntax (alternative)
docker run --mount type=bind,source=/host/path,target=/container/path,readonly,consistency=cached alpine:3
```

**Recommendation:** Use `-v` syntax for consistency with existing port mapping approach.

### Step 4: Unit Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests for:

```swift
@Test func buildsBindMountFlags() {
    let mount1 = BindMount(
        hostPath: "/tmp/data",
        containerPath: "/data"
    )
    #expect(mount1.dockerFlag == "/tmp/data:/data")

    let mount2 = BindMount(
        hostPath: "/host/config.yml",
        containerPath: "/etc/config.yml",
        readOnly: true
    )
    #expect(mount2.dockerFlag == "/host/config.yml:/etc/config.yml:ro")

    let mount3 = BindMount(
        hostPath: "/Users/dev/src",
        containerPath: "/app/src",
        readOnly: false,
        consistency: .cached
    )
    #expect(mount3.dockerFlag == "/Users/dev/src:/app/src:cached")

    let mount4 = BindMount(
        hostPath: "/host/readonly",
        containerPath: "/readonly",
        readOnly: true,
        consistency: .delegated
    )
    #expect(mount4.dockerFlag == "/host/readonly:/readonly:ro,delegated")
}

@Test func addsBindMountsToRequest() {
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(
            hostPath: "/tmp/test",
            containerPath: "/test",
            readOnly: true
        )
        .withBindMount(
            hostPath: "/tmp/config",
            containerPath: "/etc/config",
            readOnly: false,
            consistency: .cached
        )

    #expect(request.bindMounts.count == 2)
    #expect(request.bindMounts[0].hostPath == "/tmp/test")
    #expect(request.bindMounts[0].readOnly == true)
    #expect(request.bindMounts[1].consistency == .cached)
}

@Test func addsBindMountUsingStruct() {
    let mount = BindMount(
        hostPath: "/data",
        containerPath: "/mnt/data",
        readOnly: false,
        consistency: .delegated
    )

    let request = ContainerRequest(image: "postgres:16")
        .withBindMount(mount)

    #expect(request.bindMounts == [mount])
}
```

### Step 5: Integration Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

Add Docker integration test (gated by environment variable):

```swift
@Test func canMountHostDirectory_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create temporary directory with test file
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-bind-mount-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    let testFile = tempDir.appendingPathComponent("test.txt")
    let testContent = "Hello from host filesystem!"
    try testContent.write(to: testFile, atomically: true, encoding: .utf8)

    // Mount directory and read file from container
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(
            hostPath: tempDir.path,
            containerPath: "/mnt/host",
            readOnly: true
        )
        .withCommand(["cat", "/mnt/host/test.txt"])

    try await withContainer(request) { container in
        // Give container time to execute cat command
        try await Task.sleep(for: .seconds(1))

        let logs = try await container.logs()
        #expect(logs.contains(testContent))
    }
}

@Test func canWriteToHostDirectory_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create temporary directory
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-write-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // Mount directory read-write and create file from container
    let outputFile = "output.txt"
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(
            hostPath: tempDir.path,
            containerPath: "/mnt/output",
            readOnly: false
        )
        .withCommand(["sh", "-c", "echo 'Container was here' > /mnt/output/\(outputFile)"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .seconds(1))
    }

    // Verify file was created on host
    let outputPath = tempDir.appendingPathComponent(outputFile)
    #expect(FileManager.default.fileExists(atPath: outputPath.path))

    let content = try String(contentsOf: outputPath, encoding: .utf8)
    #expect(content.contains("Container was here"))
}

@Test func readOnlyMountPreventsWrites_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-readonly-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // Attempt to write to read-only mount (should fail)
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(
            hostPath: tempDir.path,
            containerPath: "/mnt/readonly",
            readOnly: true
        )
        .withCommand(["sh", "-c", "echo 'test' > /mnt/readonly/test.txt || echo 'Write failed as expected'"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .seconds(1))

        let logs = try await container.logs()
        #expect(logs.contains("Write failed as expected"))
    }

    // Verify no file was created
    let testPath = tempDir.appendingPathComponent("test.txt")
    #expect(!FileManager.default.fileExists(atPath: testPath.path))
}
```

### Step 6: Documentation

Update relevant documentation files:

1. **FEATURES.md**
   - Move "Bind mounts (host path → container path)" from Tier 2 to Implemented
   - Add checkmark: `- [x] Bind mounts (host path → container path, read-only, consistency modes)`

2. **README.md** (if exists)
   - Add example usage in "Features" or "Usage" section

3. **Inline documentation**
   - Ensure all public APIs have doc comments with examples

---

## Testing Plan

### Unit Tests (Fast, No Docker Required)

**File:** `Tests/TestContainersTests/ContainerRequestTests.swift`

- [ ] `BindMount.dockerFlag` generates correct flags for all combinations:
  - Read-write, no consistency: `/host:/container`
  - Read-only, no consistency: `/host:/container:ro`
  - Read-write, cached: `/host:/container:cached`
  - Read-only, delegated: `/host:/container:ro,delegated`
  - All consistency modes tested
- [ ] `withBindMount(hostPath:containerPath:...)` builder appends to array
- [ ] `withBindMount(_:)` convenience builder works
- [ ] Multiple bind mounts accumulate correctly
- [ ] Hashable and Sendable conformance (compile-time)

### Integration Tests (Requires Docker)

**File:** `Tests/TestContainersTests/DockerIntegrationTests.swift`

**Gating:** All tests use `TESTCONTAINERS_RUN_DOCKER_TESTS=1` guard

- [ ] Mount host directory, read file from container (read-only)
- [ ] Mount host directory, write file from container (read-write)
- [ ] Read-only mount prevents container writes (verify failure)
- [ ] Multiple bind mounts in single container
- [ ] Bind mount a single file (not just directories)
- [ ] Consistency modes don't break container startup (macOS + Linux)

### Manual Testing Scenarios

1. **PostgreSQL with custom config:**
   ```swift
   let configPath = "/path/to/postgresql.conf"
   let request = ContainerRequest(image: "postgres:16")
       .withBindMount(
           hostPath: configPath,
           containerPath: "/etc/postgresql/postgresql.conf",
           readOnly: true
       )
       .withEnvironment(["POSTGRES_PASSWORD": "test"])
   ```

2. **Nginx with custom site config:**
   ```swift
   let request = ContainerRequest(image: "nginx:alpine")
       .withBindMount(
           hostPath: "/Users/dev/nginx/conf.d",
           containerPath: "/etc/nginx/conf.d",
           readOnly: true
       )
       .withExposedPort(80)
   ```

3. **Extract logs after test:**
   ```swift
   let logsDir = FileManager.default.temporaryDirectory
       .appendingPathComponent("app-logs")
   try FileManager.default.createDirectory(at: logsDir, ...)

   let request = ContainerRequest(image: "myapp:latest")
       .withBindMount(
           hostPath: logsDir.path,
           containerPath: "/var/log/app",
           readOnly: false
       )

   try await withContainer(request) { container in
       // Run tests
       // Logs are written to logsDir on host
   }
   // Inspect logs after container cleanup
   ```

### CI/CD Considerations

- Unit tests run on every commit (no Docker required)
- Integration tests run on pull requests (Docker available in CI)
- Test on macOS (GitHub Actions `macos-latest`) and Linux (`ubuntu-latest`)
- Verify consistency modes work on macOS, no-op on Linux

---

## Acceptance Criteria

### Must Have (MVP)

- [ ] `BindMount` struct with `hostPath`, `containerPath`, `readOnly`, `consistency` properties
- [ ] `BindMountConsistency` enum with `default`, `cached`, `delegated`, `consistent` cases
- [ ] `BindMount.dockerFlag` generates correct `-v` flag format
- [ ] `ContainerRequest.bindMounts` property (array)
- [ ] `withBindMount(hostPath:containerPath:readOnly:consistency:)` builder method
- [ ] `withBindMount(_:)` convenience builder
- [ ] `DockerClient.runContainer(_:)` includes bind mount flags
- [ ] Unit tests for flag generation pass
- [ ] Unit tests for builder pattern pass
- [ ] At least one Docker integration test passes (mount + read file)

### Should Have

- [ ] Multiple integration tests covering:
  - Read-only enforcement
  - Read-write file creation
  - Single file mount (not just directories)
  - Multiple mounts in one container
- [ ] Documentation examples in doc comments
- [ ] FEATURES.md updated (bind mounts marked as implemented)
- [ ] Tests pass on both macOS and Linux

### Nice to Have

- [ ] Path validation (warning or error if host path doesn't exist)
- [ ] Example in README.md showing real-world use case
- [ ] Performance comparison of consistency modes (documented in comments)

### Out of Scope (Future Features)

- **Named volumes** - Different feature, requires `docker volume create/rm`
- **Tmpfs mounts** - In-memory mounts, separate feature
- **Volume drivers** - Advanced feature requiring plugin support
- **SELinux/AppArmor labels** - `:z` and `:Z` suffixes, platform-specific
- **Automatic path expansion** - `~` → home directory, relative → absolute
- **Bind mount propagation** - `shared`, `slave`, `private`, `rshared`, etc.

---

## Technical Notes

### Docker CLI Flag Formats

**Traditional `-v` syntax** (recommended):
```bash
-v /host/path:/container/path[:options]
```

**Modern `--mount` syntax** (more explicit):
```bash
--mount type=bind,source=/host/path,target=/container/path[,readonly][,consistency=cached]
```

**Decision:** Use `-v` syntax for simplicity and consistency with current port mapping approach.

### Consistency Modes Deep Dive

Docker Desktop for Mac uses `osxfs` (or VirtioFS on newer versions) which has performance implications:

| Mode | Behavior | Use Case |
|------|----------|----------|
| `consistent` | Perfect consistency, slowest | When correctness > performance |
| `cached` | Host authoritative, container reads may lag | Read-heavy (loading config files) |
| `delegated` | Container authoritative, host reads may lag | Write-heavy (build artifacts, logs) |
| `default` | No explicit mode, uses Docker default | Most cases, simplest |

**Note:** Linux ignores consistency modes (native filesystem, no virtualization layer).

### Path Requirements

- **Host paths:** Must be absolute. Docker doesn't resolve relative paths.
- **Container paths:** Must be absolute. Linux convention.
- **Path existence:** Docker creates container path if missing (empty directory).
- **Host path missing:** Docker may create it or error depending on version (test needed).

### Common Pitfalls

1. **Mounting over existing container paths:** If you mount `/app` in a container that already has `/app`, the mount shadows the original content.
2. **Permissions:** Host file ownership may differ from container user, causing permission errors.
3. **Symlinks:** Behavior varies by platform; test thoroughly.
4. **Nested mounts:** Multiple mounts with overlapping paths can be confusing.

---

## References

### Docker Documentation
- Bind mounts: https://docs.docker.com/storage/bind-mounts/
- Mount consistency (macOS): https://docs.docker.com/storage/bind-mounts/#configure-mount-consistency-for-macos
- `docker run -v`: https://docs.docker.com/engine/reference/commandline/run/#mount-volume--v---read-only

### Testcontainers Implementations
- testcontainers-go: https://github.com/testcontainers/testcontainers-go
  - GenericContainerRequest: `Mounts` field (ContainerMounts type)
  - Supports `BindMount`, `VolumeMount`, `TmpfsMount`
- testcontainers-java: https://java.testcontainers.org/features/files/
  - `withFileSystemBind(hostPath, containerPath, mode)`

### Swift-Specific
- FileManager for path validation
- URL for path manipulation
- Temporary directory: `FileManager.default.temporaryDirectory`

---

## Implementation Checklist

### Phase 1: Core Types
- [ ] Add `BindMountConsistency` enum
- [ ] Add `BindMount` struct with `dockerFlag`
- [ ] Add unit tests for `dockerFlag` generation
- [ ] Verify Hashable and Sendable conformance

### Phase 2: ContainerRequest Integration
- [ ] Add `bindMounts` property to `ContainerRequest`
- [ ] Implement `withBindMount(hostPath:containerPath:readOnly:consistency:)`
- [ ] Implement `withBindMount(_:)` convenience
- [ ] Add unit tests for builders

### Phase 3: DockerClient Changes
- [ ] Update `runContainer(_:)` to include `-v` flags
- [ ] Sort bind mounts for deterministic output
- [ ] Manually test with real Docker

### Phase 4: Integration Testing
- [ ] Add read-only mount test
- [ ] Add read-write mount test
- [ ] Add multiple mounts test
- [ ] Add single file mount test
- [ ] Run tests on macOS and Linux

### Phase 5: Documentation & Cleanup
- [ ] Add doc comments to all public APIs
- [ ] Update FEATURES.md
- [ ] Add usage example to README (optional)
- [ ] Review code for edge cases

---

## Success Metrics

- Zero breaking changes to existing API
- All unit tests pass (< 1 second execution)
- All integration tests pass when Docker available
- Code coverage > 90% for new types
- Feature used successfully in at least one example (PostgreSQL or Nginx)

---

## Future Enhancements

### Related Features (Separate Tickets)

1. **Named Volumes** (`docker volume create`)
   - Persistent storage across container restarts
   - Managed by Docker, not host filesystem
   - Requires volume lifecycle management

2. **Tmpfs Mounts**
   - In-memory mounts for temporary data
   - Fast, but limited by RAM
   - Lost on container stop

3. **Path Validation**
   - Optional host path existence check before `docker run`
   - Clear error messages for missing paths
   - Helper to create host directories if needed

4. **Copy Operations** (via Docker CLI)
   - `docker cp` to copy files into running container
   - `docker cp` to extract files from container
   - Complements bind mounts for one-time file transfers

5. **Mount Point Inspection**
   - Parse `docker inspect` to list active mounts
   - Useful for debugging and validation
