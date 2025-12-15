# Feature 008: Copy Files into Container

## Summary

Add ability to copy files and directories from the host machine into a running container using `docker cp`. This enables test scenarios that require dynamic file injection after container startup, such as:
- Uploading test data files into databases
- Injecting configuration files after initial setup
- Copying test fixtures into web servers
- Provisioning application code for testing

This feature implements the "to container" direction of `docker cp` (host → container). The reverse direction (container → host) will be covered in a separate feature.

## Status

**IMPLEMENTED** - Feature completed and merged.

## Current State

### Docker CLI Interaction Pattern

The codebase uses a clean, actor-based architecture for Docker CLI interactions:

**Core Components:**
- `DockerClient` (actor) - Encapsulates all Docker CLI operations
- `ProcessRunner` (actor) - Low-level process execution with async/await
- `Container` (actor) - Public API for container operations

**Existing Docker Operations:**

1. **Container Lifecycle** (`/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`):
   ```swift
   func runContainer(_ request: ContainerRequest) async throws -> String
   func removeContainer(id: String) async throws
   ```

2. **Runtime Operations** (`/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`):
   ```swift
   func logs(id: String) async throws -> String
   func port(id: String, containerPort: Int) async throws -> Int
   ```

3. **Public Container API** (`/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`):
   ```swift
   public func hostPort(_ containerPort: Int) async throws -> Int
   public func host() -> String
   public func endpoint(for containerPort: Int) async throws -> String
   public func logs() async throws -> String
   public func terminate() async throws
   ```

**Pattern Observed:**
- DockerClient methods are internal/package-private
- Container actor provides public, user-facing API
- All operations use `async throws` for error handling
- Commands use `runDocker(_ args: [String])` helper that validates exit codes
- Output parsing is done in DockerClient (e.g., `parseDockerPort`)

**Error Handling:**
- `TestContainersError.commandFailed` for non-zero exit codes
- `TestContainersError.unexpectedDockerOutput` for parsing failures

## Requirements

### Functional Requirements

1. **Copy Single File**
   - Copy a file from host filesystem to container path
   - Preserve file permissions by default
   - Support both absolute and relative container paths

2. **Copy Directory**
   - Copy entire directory tree recursively
   - Preserve directory structure and permissions
   - Handle trailing slashes correctly (Docker cp semantics)

3. **Copy from Data**
   - Accept `Foundation.Data` and write to container path
   - Useful for generated content without filesystem intermediaries

4. **Copy from String**
   - Accept `String` content and write to container path
   - Automatic UTF-8 encoding
   - Common use case for config files, scripts, etc.

5. **Permission Preservation**
   - Default: preserve source file permissions
   - Optional: set specific permissions via chmod after copy

6. **Error Handling**
   - Validate source paths exist (for file/directory sources)
   - Provide clear errors for missing files
   - Surface Docker cp errors with context

### Non-Functional Requirements

1. **API Consistency**
   - Follow existing Container actor method patterns
   - Use `async throws` for all operations
   - Return `Void` on success (no output to parse)

2. **Performance**
   - Single docker cp call per operation (no multi-step workarounds)
   - Efficient for both small files and large directories

3. **Safety**
   - Validate inputs before invoking Docker
   - No temporary file cleanup required for Data/String sources

## API Design

### Proposed Public API on Container Actor

Add the following methods to `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`:

```swift
/// Copy a file from the host filesystem into the container
/// - Parameters:
///   - hostPath: Absolute path to file on host
///   - containerPath: Destination path in container (absolute or relative to workdir)
/// - Throws: TestContainersError if copy fails
public func copyFileToContainer(from hostPath: String, to containerPath: String) async throws {
    try await docker.copyToContainer(id: id, sourcePath: hostPath, destinationPath: containerPath)
}

/// Copy a directory from the host filesystem into the container
/// - Parameters:
///   - hostPath: Absolute path to directory on host
///   - containerPath: Destination path in container
/// - Note: Follows docker cp semantics - trailing slash matters for merge behavior
/// - Throws: TestContainersError if copy fails
public func copyDirectoryToContainer(from hostPath: String, to containerPath: String) async throws {
    try await docker.copyToContainer(id: id, sourcePath: hostPath, destinationPath: containerPath)
}

/// Copy data directly into a file in the container
/// - Parameters:
///   - data: Data to write to the container
///   - containerPath: Destination file path in container
/// - Throws: TestContainersError if copy fails
public func copyDataToContainer(_ data: Data, to containerPath: String) async throws {
    try await docker.copyDataToContainer(id: id, data: data, destinationPath: containerPath)
}

/// Copy string content into a file in the container
/// - Parameters:
///   - content: String content to write (will be UTF-8 encoded)
///   - containerPath: Destination file path in container
/// - Throws: TestContainersError if copy fails
public func copyToContainer(_ content: String, to containerPath: String) async throws {
    guard let data = content.data(using: .utf8) else {
        throw TestContainersError.invalidInput("Failed to encode string as UTF-8")
    }
    try await copyDataToContainer(data, to: containerPath)
}
```

### Proposed Internal API on DockerClient Actor

Add to `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`:

```swift
/// Copy a file or directory to a container
func copyToContainer(id: String, sourcePath: String, destinationPath: String) async throws {
    // Validate source exists
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: sourcePath, isDirectory: &isDirectory) else {
        throw TestContainersError.invalidInput("Source path does not exist: \(sourcePath)")
    }

    // docker cp <src> <container>:<dest>
    let target = "\(id):\(destinationPath)"
    _ = try await runDocker(["cp", sourcePath, target])
}

/// Copy data to a file in the container via temporary file
func copyDataToContainer(id: String, data: Data, destinationPath: String) async throws {
    // Create temporary file
    let tempDir = FileManager.default.temporaryDirectory
    let tempFileName = "testcontainers-\(UUID().uuidString)"
    let tempFileURL = tempDir.appendingPathComponent(tempFileName)

    do {
        // Write data to temp file
        try data.write(to: tempFileURL)

        // Copy temp file to container
        try await copyToContainer(id: id, sourcePath: tempFileURL.path, destinationPath: destinationPath)

        // Clean up temp file
        try FileManager.default.removeItem(at: tempFileURL)
    } catch {
        // Ensure cleanup even on failure
        try? FileManager.default.removeItem(at: tempFileURL)
        throw error
    }
}
```

### Error Type Addition

Add to `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`:

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    case dockerNotAvailable(String)
    case commandFailed(command: [String], exitCode: Int32, stdout: String, stderr: String)
    case unexpectedDockerOutput(String)
    case timeout(String)
    case invalidInput(String)  // NEW

    public var description: String {
        switch self {
        case let .dockerNotAvailable(message):
            return "Docker not available: \(message)"
        case let .commandFailed(command, exitCode, stdout, stderr):
            return "Command failed (exit \(exitCode)): \(command.joined(separator: " "))\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
        case let .unexpectedDockerOutput(output):
            return "Unexpected Docker output: \(output)"
        case let .timeout(message):
            return "Timed out: \(message)"
        case let .invalidInput(message):  // NEW
            return "Invalid input: \(message)"
        }
    }
}
```

## Implementation Steps

### Step 1: Add Error Type
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

1. Add `.invalidInput(String)` case to enum
2. Add corresponding description in switch statement
3. Ensure `Sendable` conformance is maintained

### Step 2: Implement DockerClient Methods
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

1. Implement `copyToContainer(id:sourcePath:destinationPath:)`
   - Validate source path exists using FileManager
   - Construct docker cp command: `["cp", sourcePath, "\(id):\(destinationPath)"]`
   - Call `runDocker()` (error handling built-in)

2. Implement `copyDataToContainer(id:data:destinationPath:)`
   - Generate unique temp filename with UUID
   - Write data to temp file
   - Call `copyToContainer()` with temp file path
   - Clean up temp file (even on error)

### Step 3: Add Container Public API
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

1. Add `copyFileToContainer(from:to:)` - delegates to docker.copyToContainer()
2. Add `copyDirectoryToContainer(from:to:)` - delegates to docker.copyToContainer()
3. Add `copyDataToContainer(_:to:)` - delegates to docker.copyDataToContainer()
4. Add `copyToContainer(_:to:)` - converts String to Data, delegates to copyDataToContainer()

### Step 4: Unit Tests
**New File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/CopyToContainerTests.swift`

Create unit tests for:
1. Error handling for non-existent source paths
2. String to Data encoding validation
3. API method signatures and basic validation

### Step 5: Integration Tests
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

Add opt-in integration tests:

```swift
@Test func canCopyFileToContainer_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create temp file on host
    let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-\(UUID().uuidString).txt")
    try "Hello from host".write(to: tempFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        // Copy file to container
        try await container.copyFileToContainer(from: tempFile.path, to: "/tmp/test.txt")

        // Verify file exists and has correct content (requires exec - defer to feature 007)
        // For now, just verify the copy command succeeds without error
    }
}

@Test func canCopyStringToContainer_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let content = "#!/bin/sh\necho 'test script'\n"
        try await container.copyToContainer(content, to: "/tmp/script.sh")

        // Verify copy succeeded (full verification requires exec)
    }
}

@Test func canCopyDirectoryToContainer_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create temp directory with files
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-dir-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try "file1".write(to: tempDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
    try "file2".write(to: tempDir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        try await container.copyDirectoryToContainer(from: tempDir.path, to: "/tmp/testdir")
        // Verify copy succeeded
    }
}
```

### Step 6: Documentation
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md`

Move "Copy files into container (`docker cp` to)" from "Not Implemented" to "Implemented" section under "Runtime operations".

## Testing Plan

### Unit Tests
**File:** `Tests/TestContainersTests/CopyToContainerTests.swift`

1. **Input Validation Tests:**
   - Test error thrown for non-existent source file path
   - Test error thrown for invalid UTF-8 string encoding (edge case)
   - Test temp file cleanup on error

2. **API Contract Tests:**
   - Verify all public methods have correct signatures
   - Verify async throws behavior
   - Verify methods are public and accessible

### Integration Tests
**File:** `Tests/TestContainersTests/DockerIntegrationTests.swift`

Opt-in via `TESTCONTAINERS_RUN_DOCKER_TESTS=1`:

1. **Copy Single File:**
   - Create temp file with known content
   - Copy to container
   - Verify copy succeeds (full verification requires exec - feature 007)

2. **Copy Directory:**
   - Create temp directory with multiple files and subdirectories
   - Copy to container with trailing slash
   - Copy to container without trailing slash (verify merge behavior)
   - Verify structure preserved

3. **Copy String Content:**
   - Copy string with newlines and special characters
   - Verify UTF-8 encoding handled correctly
   - Test script file creation

4. **Copy Data:**
   - Copy binary data (e.g., small image file)
   - Verify Data variant works correctly

5. **Error Scenarios:**
   - Copy to non-existent container path (expect Docker error)
   - Copy with permission issues (if testable)

### Manual Testing

Test with real-world scenarios:
```bash
# Run integration tests
TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test

# Verify docker cp calls with verbose Docker logging
export DOCKER_API_VERSION=1.41
TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test --filter canCopy
```

## Acceptance Criteria

### Must Have

- [x] `Container.copyFileToContainer(from:to:)` copies single file successfully
- [x] `Container.copyDirectoryToContainer(from:to:)` copies directory tree recursively
- [x] `Container.copyToContainer(_:to:)` copies string content to file
- [x] `Container.copyDataToContainer(_:to:)` copies Data to file
- [x] Non-existent source paths throw `TestContainersError.invalidInput`
- [x] Docker cp failures throw `TestContainersError.commandFailed` with context
- [x] Temporary files are cleaned up after Data/String copies (even on error)
- [x] All public methods are documented with doc comments
- [x] Integration tests pass when opted in
- [x] FEATURES.md updated to mark feature as implemented

### Should Have

- [x] Examples in doc comments show common usage patterns
- [x] Integration tests cover edge cases (empty files, binary data, special characters)
- [x] Error messages are clear and actionable

### Nice to Have

- [x] Performance test for large file/directory copies (1MB test included)
- [ ] Example in README.md or examples directory
- [ ] Support for setting file permissions via optional chmod parameter

## Dependencies

### Prerequisite Features
None - this is a standalone feature using existing infrastructure.

### Enables Future Features
- **Feature 007: Exec in Container** - Combined with exec, enables full E2E testing (copy file → exec command → verify output)
- **Database Module Features** - PostgresContainer can copy init scripts before startup
- **Configuration Injection** - Modules can inject configs dynamically during setup

## Docker cp Semantics Reference

Important `docker cp` behaviors to preserve:

1. **Trailing Slash on Source Directory:**
   - `docker cp /hostdir/ container:/dest` → copies contents of hostdir into dest
   - `docker cp /hostdir container:/dest` → copies hostdir itself into dest

2. **Destination Behavior:**
   - If dest exists and is a directory, source is copied into it
   - If dest doesn't exist, source is copied as dest

3. **Permissions:**
   - By default, preserves source permissions
   - Follows symlinks on host (copies target, not link)

4. **Limitations:**
   - Cannot copy to container paths while container is stopped
   - Parent directory of destination must exist in container

## Notes

- This feature uses `FileManager` for host filesystem validation
- Temporary files are stored in `FileManager.default.temporaryDirectory`
- UUID is used for temp file naming to avoid collisions
- The API separates file/directory methods for clarity, but both use same underlying docker cp
- String encoding explicitly uses UTF-8 (most common for config/script files)
- Error on encoding failure rather than silently using replacement characters

## References

- Existing pattern: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift` (lines 60-72 for logs/port methods)
- Error handling: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`
- Public API pattern: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift` (lines 15-34)
- Docker cp documentation: https://docs.docker.com/engine/reference/commandline/cp/
