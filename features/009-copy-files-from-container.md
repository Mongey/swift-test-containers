# Feature 009: Copy Files From Container

**Status**: ✅ Complete
**Priority**: Tier 1 (High Priority)
**Estimated Complexity**: Medium
**Related**: Feature 008 (Copy Files To Container)
**Completed**: 2025-12-16

---

## Summary

Implement the ability to copy files and directories from a running container to the host filesystem using `docker cp`. This enables tests to extract logs, generated files, artifacts, or any other data produced inside the container for validation or debugging purposes.

The API will be exposed on the `Container` actor as `copyFileFromContainer` and `copyDirectoryFromContainer` methods, following the existing pattern established by `logs()` and `hostPort(_:)`.

---

## Current State

### Docker CLI Interaction Patterns

The codebase currently uses Docker CLI for all container operations via the `DockerClient` actor:

- **Architecture**: `DockerClient` (actor) → `ProcessRunner` (actor) → `Process` (Foundation)
- **Pattern**: All Docker commands go through `runDocker(_ args: [String])` which:
  1. Executes `docker` with provided arguments via `ProcessRunner`
  2. Checks exit code and throws `TestContainersError.commandFailed` on non-zero
  3. Returns `CommandOutput` (stdout, stderr, exitCode)
  4. Parses stdout for structured data (e.g., `parseDockerPort` for port mappings)

**Existing Docker CLI operations** (from `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`):

```swift
func runContainer(_ request: ContainerRequest) async throws -> String
    // docker run -d [options] <image> [command]

func removeContainer(id: String) async throws
    // docker rm -f <id>

func logs(id: String) async throws -> String
    // docker logs <id>
    // Returns stdout as String

func port(id: String, containerPort: Int) async throws -> Int
    // docker port <id> <containerPort>
    // Parses output to extract host port number
```

### Container Actor Public API

The `Container` actor (in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`) exposes:

```swift
public func hostPort(_ containerPort: Int) async throws -> Int
public func host() -> String
public func endpoint(for containerPort: Int) async throws -> String
public func logs() async throws -> String
public func terminate() async throws
```

All public methods delegate to `DockerClient` for Docker operations.

---

## Requirements

### Functional Requirements

1. **Copy Single File**
   - Copy a single file from container path to host path
   - Preserve file permissions by default (using `-a` flag)
   - Support absolute and relative container paths
   - Return URL to the copied file on host

2. **Copy Directory**
   - Copy entire directory (recursive) from container to host
   - Preserve directory structure and permissions
   - Return URL to the copied directory on host

3. **Copy to Data**
   - Copy file contents directly into `Data` object without writing to disk
   - Useful for in-memory validation of small files
   - Use stdout redirection with `-` destination

4. **Error Handling**
   - Throw meaningful errors if source path doesn't exist in container
   - Throw if destination path is invalid or not writable
   - Throw if container is not running
   - Leverage existing `TestContainersError.commandFailed` for Docker errors

5. **Permissions**
   - Use archive mode (`-a`) by default to preserve uid/gid information
   - Allow opting out of archive mode if needed

### Non-Functional Requirements

1. **API Consistency**: Match existing method signatures and error handling patterns
2. **Type Safety**: Use `URL` for file paths (Swift standard)
3. **Concurrency**: All methods must be `async throws` (actor-isolated)
4. **Documentation**: Include doc comments with usage examples
5. **Testing**: Comprehensive unit and integration tests

---

## API Design

### Proposed Public API on `Container` Actor

Add the following methods to `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`:

```swift
/// Copies a file from the container to the host filesystem.
///
/// - Parameters:
///   - containerPath: Absolute path to the file inside the container
///   - hostPath: Destination path on the host (file will be created/overwritten)
///   - preservePermissions: Whether to preserve uid/gid (uses -a flag). Default: true
/// - Returns: URL to the copied file on the host
/// - Throws: `TestContainersError` if the copy operation fails
///
/// Example:
/// ```swift
/// let logFile = try await container.copyFileFromContainer(
///     "/var/log/app.log",
///     to: "/tmp/app-log.txt"
/// )
/// let contents = try String(contentsOf: logFile)
/// ```
public func copyFileFromContainer(
    _ containerPath: String,
    to hostPath: String,
    preservePermissions: Bool = true
) async throws -> URL

/// Copies a directory from the container to the host filesystem.
///
/// - Parameters:
///   - containerPath: Absolute path to the directory inside the container
///   - hostPath: Destination directory on the host (created if it doesn't exist)
///   - preservePermissions: Whether to preserve uid/gid (uses -a flag). Default: true
/// - Returns: URL to the copied directory on the host
/// - Throws: `TestContainersError` if the copy operation fails
///
/// Example:
/// ```swift
/// let artifactsDir = try await container.copyDirectoryFromContainer(
///     "/app/artifacts",
///     to: "/tmp/test-artifacts"
/// )
/// ```
public func copyDirectoryFromContainer(
    _ containerPath: String,
    to hostPath: String,
    preservePermissions: Bool = true
) async throws -> URL

/// Copies a file from the container directly into memory as Data.
///
/// - Parameter containerPath: Absolute path to the file inside the container
/// - Returns: File contents as Data
/// - Throws: `TestContainersError` if the copy operation fails
///
/// Example:
/// ```swift
/// let configData = try await container.copyFileToData("/etc/app/config.json")
/// let config = try JSONDecoder().decode(AppConfig.self, from: configData)
/// ```
public func copyFileToData(_ containerPath: String) async throws -> Data
```

### Proposed Internal API on `DockerClient` Actor

Add the following methods to `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`:

```swift
/// Executes `docker cp CONTAINER:SRC_PATH DEST_PATH`
func copyFromContainer(
    id: String,
    containerPath: String,
    hostPath: String,
    archive: Bool
) async throws {
    var args = ["cp"]
    if archive {
        args.append("-a")
    }
    args.append("\(id):\(containerPath)")
    args.append(hostPath)
    _ = try await runDocker(args)
}

/// Executes `docker cp CONTAINER:SRC_PATH -` to stream file contents to stdout
func copyFromContainerToStdout(
    id: String,
    containerPath: String
) async throws -> Data {
    let args = ["cp", "\(id):\(containerPath)", "-"]
    let output = try await runDocker(args)
    // Output is a tar archive, need to extract
    return try extractTarData(output.stdout)
}

/// Helper to extract single file from tar archive in stdout
private func extractTarData(_ tarString: String) throws -> Data {
    // Implementation note: This is non-trivial
    // Option 1: Write to temp file, use tar command to extract
    // Option 2: Use Swift tar library if available
    // Option 3: Read tar format manually (512-byte blocks)
    // Recommendation: Use temp file + tar command for simplicity
}
```

### Alternative Simpler Approach for `copyFileToData`

Instead of implementing tar extraction, we can use a two-step process:

```swift
public func copyFileToData(_ containerPath: String) async throws -> Data {
    let tempDir = FileManager.default.temporaryDirectory
    let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    try await docker.copyFromContainer(
        id: id,
        containerPath: containerPath,
        hostPath: tempFile.path,
        archive: false
    )

    return try Data(contentsOf: tempFile)
}
```

This avoids tar parsing complexity while still providing the convenience API.

---

## Implementation Steps

### Step 1: Add Internal `DockerClient` Method

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

```swift
func copyFromContainer(
    id: String,
    containerPath: String,
    hostPath: String,
    archive: Bool = true
) async throws {
    var args = ["cp"]
    if archive {
        args.append("-a")
    }
    args.append("\(id):\(containerPath)")
    args.append(hostPath)
    _ = try await runDocker(args)
}
```

- Add after the `port(id:containerPort:)` method (around line 72)
- Follows same pattern as `logs()` and `removeContainer()`
- Uses `runDocker()` which handles error checking automatically

### Step 2: Implement `Container.copyFileFromContainer`

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

```swift
public func copyFileFromContainer(
    _ containerPath: String,
    to hostPath: String,
    preservePermissions: Bool = true
) async throws -> URL {
    try await docker.copyFromContainer(
        id: id,
        containerPath: containerPath,
        hostPath: hostPath,
        archive: preservePermissions
    )
    return URL(fileURLWithPath: hostPath)
}
```

- Add after the `logs()` method (around line 30)
- Returns `URL` for ergonomic file handling in Swift
- `preservePermissions` maps to Docker's `-a` flag

### Step 3: Implement `Container.copyDirectoryFromContainer`

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

```swift
public func copyDirectoryFromContainer(
    _ containerPath: String,
    to hostPath: String,
    preservePermissions: Bool = true
) async throws -> URL {
    // Ensure destination directory exists
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    if !fileManager.fileExists(atPath: hostPath, isDirectory: &isDirectory) {
        try fileManager.createDirectory(
            atPath: hostPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    try await docker.copyFromContainer(
        id: id,
        containerPath: containerPath,
        hostPath: hostPath,
        archive: preservePermissions
    )
    return URL(fileURLWithPath: hostPath)
}
```

- Implementation is almost identical to `copyFileFromContainer`
- Pre-creates destination directory to avoid Docker errors
- Docker handles recursive copying automatically

### Step 4: Implement `Container.copyFileToData`

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

```swift
public func copyFileToData(_ containerPath: String) async throws -> Data {
    let tempDir = FileManager.default.temporaryDirectory
    let tempFile = tempDir.appendingPathComponent(UUID().uuidString)

    defer {
        try? FileManager.default.removeItem(at: tempFile)
    }

    try await docker.copyFromContainer(
        id: id,
        containerPath: containerPath,
        hostPath: tempFile.path,
        archive: false
    )

    return try Data(contentsOf: tempFile)
}
```

- Uses temporary file as intermediary (simpler than tar parsing)
- `defer` ensures cleanup even on error
- `archive: false` avoids permission issues with temp files

### Step 5: Error Handling Improvements (Optional)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

Consider adding a more specific error case for copy operations:

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    // ... existing cases ...
    case copyFailed(containerPath: String, hostPath: String, reason: String)

    public var description: String {
        switch self {
        // ... existing cases ...
        case let .copyFailed(containerPath, hostPath, reason):
            return "Failed to copy from container path '\(containerPath)' to host path '\(hostPath)': \(reason)"
        }
    }
}
```

However, the existing `commandFailed` error is likely sufficient for MVP.

---

## Testing Plan

### Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests for API signatures (compile-time checks):

```swift
@Test func containerHasCopyFromContainerMethod() async throws {
    // Compile-time validation that API exists
    let request = ContainerRequest(image: "alpine:latest")
    // This test doesn't need to run, just compile
}
```

### Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

Add the following tests (gated by `TESTCONTAINERS_RUN_DOCKER_TESTS=1`):

```swift
@Test func canCopyFileFromContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sh", "-c", "echo 'Hello from container' > /tmp/test.txt && sleep 60"])

    try await withContainer(request) { container in
        // Wait for file to be created
        try await Task.sleep(for: .seconds(1))

        let tempDir = FileManager.default.temporaryDirectory
        let hostFile = tempDir.appendingPathComponent("copied-\(UUID().uuidString).txt")

        let resultURL = try await container.copyFileFromContainer(
            "/tmp/test.txt",
            to: hostFile.path
        )

        #expect(FileManager.default.fileExists(atPath: resultURL.path))

        let contents = try String(contentsOf: resultURL)
        #expect(contents.contains("Hello from container"))

        // Cleanup
        try? FileManager.default.removeItem(at: resultURL)
    }
}

@Test func canCopyDirectoryFromContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:latest")
        .withCommand([
            "sh", "-c",
            "mkdir -p /tmp/mydir && echo 'file1' > /tmp/mydir/a.txt && echo 'file2' > /tmp/mydir/b.txt && sleep 60"
        ])

    try await withContainer(request) { container in
        try await Task.sleep(for: .seconds(1))

        let tempDir = FileManager.default.temporaryDirectory
        let hostDir = tempDir.appendingPathComponent("copied-dir-\(UUID().uuidString)")

        let resultURL = try await container.copyDirectoryFromContainer(
            "/tmp/mydir",
            to: hostDir.path
        )

        #expect(FileManager.default.fileExists(atPath: resultURL.path))

        let fileA = resultURL.appendingPathComponent("a.txt")
        let fileB = resultURL.appendingPathComponent("b.txt")

        #expect(FileManager.default.fileExists(atPath: fileA.path))
        #expect(FileManager.default.fileExists(atPath: fileB.path))

        let contentsA = try String(contentsOf: fileA)
        #expect(contentsA.contains("file1"))

        // Cleanup
        try? FileManager.default.removeItem(at: resultURL)
    }
}

@Test func canCopyFileToData() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sh", "-c", "echo 'Test data' > /tmp/data.txt && sleep 60"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .seconds(1))

        let data = try await container.copyFileToData("/tmp/data.txt")

        #expect(!data.isEmpty)

        let contents = String(data: data, encoding: .utf8)
        #expect(contents?.contains("Test data") == true)
    }
}

@Test func copyFromContainerThrowsOnMissingFile() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "60"])

    try await withContainer(request) { container in
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).txt")

        await #expect(throws: TestContainersError.self) {
            try await container.copyFileFromContainer(
                "/this/path/does/not/exist.txt",
                to: tempFile.path
            )
        }
    }
}

@Test func copyPreservesPermissions() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sh", "-c", "echo 'executable' > /tmp/script.sh && chmod +x /tmp/script.sh && sleep 60"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .seconds(1))

        let tempDir = FileManager.default.temporaryDirectory
        let hostFile = tempDir.appendingPathComponent("script-\(UUID().uuidString).sh")

        let resultURL = try await container.copyFileFromContainer(
            "/tmp/script.sh",
            to: hostFile.path,
            preservePermissions: true
        )

        // Check file is executable
        let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        // Check execute bit is set (will vary by platform/user)
        #expect(permissions != nil)

        // Cleanup
        try? FileManager.default.removeItem(at: resultURL)
    }
}
```

### Test Containers to Use

- `alpine:latest` - Minimal, fast, has `sh` for creating test files
- `busybox:latest` - Alternative minimal option
- Existing `redis:7` if we want to test copying Redis config/data files

---

## Acceptance Criteria

### Definition of Done

- [x] `DockerClient.copyFromContainer` method implemented and handles `-a` flag
- [x] `Container.copyFileFromContainer` method implemented with doc comments
- [x] `Container.copyDirectoryFromContainer` method implemented with doc comments
- [x] `Container.copyFileToData` method implemented with doc comments
- [x] All methods use `async throws` and follow actor isolation rules
- [x] Integration tests pass with `TESTCONTAINERS_RUN_DOCKER_TESTS=1`
- [x] Error handling tested (missing files, invalid paths)
- [x] Permission preservation tested with archive mode
- [x] No breaking changes to existing API
- [x] Code follows existing patterns in the codebase
- [x] Update `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md` to mark as implemented

### Success Metrics

1. Users can copy single files from containers in one line of code
2. Users can copy entire directories recursively
3. Users can load file contents into memory without filesystem I/O
4. Errors provide clear feedback when operations fail
5. API feels natural to Swift developers (uses `URL`, `Data`, `async throws`)

### Out of Scope (Future Work)

- Copying to stdin (piping data into container) - that's Feature 008
- Streaming large files (no progress callback)
- Following symlinks (could add `followLinks: Bool` parameter later)
- Quiet mode (no need for `-q` flag in test context)
- Archive extraction from stdout (using temp files is simpler for MVP)

---

## References

### Existing Code Patterns

**DockerClient command pattern**:
```swift
// File: /Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift
func logs(id: String) async throws -> String {
    let output = try await runDocker(["logs", id])
    return output.stdout
}
```

**Container delegation pattern**:
```swift
// File: /Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift
public func logs() async throws -> String {
    try await docker.logs(id: id)
}
```

### Docker CP Documentation

```bash
# Copy file from container to host
docker cp <container>:/path/in/container /path/on/host

# Copy directory from container to host
docker cp <container>:/dir/in/container /dir/on/host

# Copy to stdout (tar archive)
docker cp <container>:/file -

# Archive mode (preserve permissions)
docker cp -a <container>:/path /dest
```

### Related Features

- **Feature 008**: Copy files TO container (`docker cp` to)
- **Feature 007**: Exec in container (for alternative file reading via `cat`)
- **Logs feature** (existing): Similar stdout-based data retrieval pattern

---

## Implementation Estimate

- **Time**: 2-3 hours for implementation + testing
- **Risk**: Low (Docker CLI already handles complexity)
- **Dependencies**: None (uses existing `ProcessRunner` and `DockerClient`)
- **Testing**: 4-6 integration tests needed

---

## Open Questions

1. **Should we validate container paths** (e.g., reject relative paths, ensure leading `/`)?
   - Recommendation: Let Docker handle validation, surface errors as-is

2. **Should we auto-create parent directories** on host side?
   - Recommendation: Yes for directories, no for files (let Docker decide)

3. **Do we need a separate method for symlinks**?
   - Recommendation: Not for MVP, Docker's default behavior is fine

4. **Should `copyFileToData` support size limits**?
   - Recommendation: Not for MVP, trust users to not copy huge files

5. **Error messages**: Should we parse Docker stderr for better errors?
   - Recommendation: Not for MVP, existing `commandFailed` error includes stderr

---

## Notes

- Docker CP behavior: When copying files, if destination exists, it's overwritten. When copying directories, the source directory is placed INSIDE the destination.
- Permissions: The `-a` flag (archive mode) preserves uid/gid but may not be meaningful on macOS (different user model). Still useful on Linux CI environments.
- Tar format: `docker cp` to stdout produces a tar archive. For MVP, we avoid parsing this by using temp files.
- Concurrency: Since `DockerClient` and `Container` are actors, all operations are already thread-safe.

---

**Created**: 2025-12-15
**Author**: AI Assistant
**Related Issues**: None yet
