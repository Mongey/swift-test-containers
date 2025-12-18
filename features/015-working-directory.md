# Feature #015: Working Directory (`--workdir`)

**Status**: Implemented
**Priority**: Tier 2 (Medium)
**Complexity**: Low
**Estimated Effort**: 1-2 hours

---

## Summary

Add support for setting the working directory inside the container via the `--workdir` flag. This allows users to control the directory in which the container command executes, which is essential for containers that require specific working directories for scripts, applications, or tools to run correctly.

---

## Current State

### ContainerRequest Capabilities

The `ContainerRequest` struct currently supports:

- **Image**: Base image to run (`image: String`)
- **Name**: Optional container name (`name: String?`)
- **Command**: Command and arguments to execute (`command: [String]`)
- **Environment**: Environment variables (`environment: [String: String]`)
- **Labels**: Docker labels (`labels: [String: String]`)
- **Ports**: Port mappings (`ports: [ContainerPort]`)
- **Wait Strategy**: Container readiness detection (`waitStrategy: WaitStrategy`)
- **Host**: Host address for connections (`host: String`)

**Location**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

### DockerClient Implementation

The `DockerClient.runContainer()` method builds Docker CLI arguments for `docker run -d` and currently includes:

- `--name` for container naming
- `-e` for environment variables
- `-p` for port mappings
- `--label` for Docker labels
- Image name and command

**Location**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift` (lines 28-54)

---

## Requirements

### Functional Requirements

1. **Specify Working Directory**: Users must be able to specify a working directory path that will be set inside the container
2. **Optional Configuration**: The working directory should be optional (not required for all containers)
3. **Path Validation**: Accept any valid container path string (validation is delegated to Docker)
4. **Builder Pattern**: Follow existing API patterns using a `with*` builder method

### Non-Functional Requirements

1. **API Consistency**: Match the design patterns of existing builder methods
2. **Type Safety**: Use Swift's type system (String for paths)
3. **Sendable Compliance**: Maintain `Sendable` conformance for actor-isolated usage
4. **Zero Breaking Changes**: Additive-only changes to public API

---

## API Design

### Proposed Swift API

Following the established builder pattern in `ContainerRequest`:

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
    public var workingDirectory: String?  // NEW

    public init(image: String) {
        self.image = image
        self.name = nil
        self.command = []
        self.environment = [:]
        self.labels = ["testcontainers.swift": "true"]
        self.ports = []
        self.waitStrategy = .none
        self.host = "127.0.0.1"
        self.workingDirectory = nil  // NEW
    }

    // NEW: Builder method for working directory
    public func withWorkingDirectory(_ workingDirectory: String) -> Self {
        var copy = self
        copy.workingDirectory = workingDirectory
        return copy
    }

    // ... existing builder methods ...
}
```

### Usage Examples

```swift
// Example 1: Node.js app requiring specific working directory
let nodeRequest = ContainerRequest(image: "node:20")
    .withWorkingDirectory("/app")
    .withCommand(["node", "index.js"])
    .withExposedPort(3000)
    .waitingFor(.tcpPort(3000))

// Example 2: Script execution from specific directory
let scriptRequest = ContainerRequest(image: "alpine:3")
    .withWorkingDirectory("/scripts")
    .withCommand(["sh", "run.sh"])
    .waitingFor(.logContains("Done"))

// Example 3: Build tools requiring working directory
let buildRequest = ContainerRequest(image: "maven:3.9-eclipse-temurin-21")
    .withWorkingDirectory("/workspace")
    .withCommand(["mvn", "test"])
```

### Alternative Names Considered

- `withWorkDir()` - Too abbreviated, not idiomatic Swift
- `withCwd()` - Unix-specific abbreviation, unclear
- `withWorkingDir()` - Slightly abbreviated but still clear
- **`withWorkingDirectory()`** - ✅ Most explicit, matches Swift naming conventions

---

## Implementation Steps

### Step 1: Update ContainerRequest Struct

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

1. Add `workingDirectory` property:
   ```swift
   public var workingDirectory: String?
   ```

2. Update `init()` to set default value:
   ```swift
   self.workingDirectory = nil
   ```

3. Add builder method:
   ```swift
   public func withWorkingDirectory(_ workingDirectory: String) -> Self {
       var copy = self
       copy.workingDirectory = workingDirectory
       return copy
   }
   ```

**Estimated Time**: 10 minutes

---

### Step 2: Update DockerClient.runContainer()

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Modify the `runContainer()` method to include the `--workdir` flag when present.

**Current Implementation** (lines 28-54):
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
    let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { throw TestContainersError.unexpectedDockerOutput(output.stdout) }
    return id
}
```

**Proposed Change** (add after labels, before image):
```swift
    // Add after labels loop, before args.append(request.image)
    if let workingDirectory = request.workingDirectory {
        args += ["--workdir", workingDirectory]
    }
```

**Full Updated Method**:
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

    // NEW: Add working directory if specified
    if let workingDirectory = request.workingDirectory {
        args += ["--workdir", workingDirectory]
    }

    args.append(request.image)
    args += request.command

    let output = try await runDocker(args)
    let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { throw TestContainersError.unexpectedDockerOutput(output.stdout) }
    return id
}
```

**Estimated Time**: 5 minutes

---

### Step 3: Add Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests following the existing pattern (currently only has `buildsDockerPortFlags` test).

```swift
@Test func setsWorkingDirectory() {
    let request = ContainerRequest(image: "alpine:3")
        .withWorkingDirectory("/app")

    #expect(request.workingDirectory == "/app")
}

@Test func workingDirectoryIsNilByDefault() {
    let request = ContainerRequest(image: "alpine:3")

    #expect(request.workingDirectory == nil)
}

@Test func workingDirectoryCanBeChained() {
    let request = ContainerRequest(image: "node:20")
        .withWorkingDirectory("/app")
        .withCommand(["node", "index.js"])
        .withExposedPort(3000)

    #expect(request.workingDirectory == "/app")
    #expect(request.command == ["node", "index.js"])
    #expect(request.ports.count == 1)
}
```

**Estimated Time**: 15 minutes

---

### Step 4: Add Integration Test

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

Add an integration test that verifies the working directory is actually set in the container.

```swift
@Test func canSetWorkingDirectory_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Use alpine with sh to execute pwd command
    let request = ContainerRequest(image: "alpine:3")
        .withWorkingDirectory("/tmp")
        .withCommand(["sh", "-c", "pwd > /tmp/output && sleep 1"])

    try await withContainer(request) { container in
        // Give it a moment to write
        try await Task.sleep(for: .milliseconds(500))

        // Verify working directory by checking logs
        let logs = try await container.logs()
        #expect(logs.contains("/tmp"))
    }
}
```

**Alternative Test** (verifying pwd via exec - requires exec feature):
```swift
// Note: This test would require the exec() feature to be implemented first
// Placeholder for future enhancement
@Test func canVerifyWorkingDirectoryViaExec_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withWorkingDirectory("/usr/local")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        // Requires exec() method - see Feature #016
        // let result = try await container.exec(["pwd"])
        // #expect(result.stdout.contains("/usr/local"))
    }
}
```

**Estimated Time**: 20 minutes

---

### Step 5: Update Documentation

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md`

Move working directory from Tier 2 "Not Implemented" to "Implemented" section:

**Current** (line 57):
```markdown
- [ ] Working directory (`--workdir`)
```

**Updated**:
```markdown
**Container configuration**
- [x] Working directory (`--workdir`)
```

**Estimated Time**: 5 minutes

---

## Testing Plan

### Unit Tests

**File**: `Tests/TestContainersTests/ContainerRequestTests.swift`

| Test Case | Description | Expected Outcome |
|-----------|-------------|------------------|
| `setsWorkingDirectory()` | Verify builder sets property | `request.workingDirectory == "/app"` |
| `workingDirectoryIsNilByDefault()` | Verify default value | `request.workingDirectory == nil` |
| `workingDirectoryCanBeChained()` | Verify builder chaining | All properties set correctly |

### Integration Tests

**File**: `Tests/TestContainersTests/DockerIntegrationTests.swift`

| Test Case | Description | Expected Outcome | Prerequisites |
|-----------|-------------|------------------|---------------|
| `canSetWorkingDirectory_whenOptedIn()` | Start container with workdir, verify via output | Container runs with correct working directory | `TESTCONTAINERS_RUN_DOCKER_TESTS=1` |

### Manual Testing

```bash
# Run unit tests
swift test

# Run integration tests (requires Docker)
TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test

# Manual verification with docker CLI
docker run -d --workdir /tmp alpine:3 sh -c "pwd && sleep 60"
docker logs <container-id>  # Should output: /tmp
docker rm -f <container-id>
```

### Edge Cases to Test

1. **Empty String**: `withWorkingDirectory("")` - Docker should handle or error
2. **Relative Path**: `withWorkingDirectory("app")` - Docker interprets relative to container's default
3. **Non-existent Path**: `withWorkingDirectory("/nonexistent")` - Docker may create or error depending on image
4. **Root Directory**: `withWorkingDirectory("/")` - Should work
5. **Path with Spaces**: `withWorkingDirectory("/my app")` - Should be properly quoted by Docker CLI

**Note**: Path validation is intentionally delegated to Docker for simplicity and to avoid duplicating Docker's path handling logic.

---

## Acceptance Criteria

### Definition of Done

- [x] `ContainerRequest` has `workingDirectory: String?` property
- [x] `ContainerRequest` has `withWorkingDirectory(_:)` builder method
- [x] `DockerClient.runContainer()` includes `--workdir` flag when property is set
- [x] Unit tests pass for builder method and property
- [x] Integration test passes with `TESTCONTAINERS_RUN_DOCKER_TESTS=1`
- [x] All existing tests continue to pass (no regressions)
- [x] `FEATURES.md` updated to reflect implementation
- [x] Code follows existing patterns and conventions
- [x] `Sendable` and `Hashable` conformance maintained

### API Requirements

- [x] Method signature matches Swift naming conventions
- [x] Builder method returns `Self` for chaining
- [x] Property is optional (defaults to `nil`)
- [x] No breaking changes to existing API

### Quality Requirements

- [x] Code compiles without warnings
- [x] Tests run successfully in CI (when enabled)
- [x] No memory leaks or resource leaks
- [x] Documentation comments added (if applicable)

---

## Docker Reference

### CLI Flag Documentation

```bash
docker run --workdir <path> <image> [command]
```

**Description**: Set the working directory inside the container. If the directory doesn't exist, Docker will create it.

**Examples**:
```bash
# Absolute path
docker run --workdir /app node:20 npm start

# Relative path (relative to image's WORKDIR)
docker run --workdir app alpine:3 pwd

# Override Dockerfile WORKDIR
docker run --workdir /override myimage:latest ./run.sh
```

**Docker Documentation**: https://docs.docker.com/engine/reference/run/#workdir

---

## Related Features

### Dependencies
- None - this is a standalone feature

### Future Enhancements
- **Feature #016**: `exec()` in container - would enable better testing of working directory via `pwd` command
- **Feature #042**: Bind mounts - working directory often used with mounted volumes
- **Feature #043**: Volume mounts - containers may need workdir set to volume mount point

### Related Configurations
- `withCommand()` - command executes in the working directory
- `withEntrypoint()` - (planned) entrypoint also respects working directory
- Bind/volume mounts - (planned) often combined with working directory

---

## Implementation Notes

### Design Decisions

1. **Optional Property**: Working directory is optional because many images have sensible defaults via Dockerfile `WORKDIR` directive
2. **String Type**: Use `String` rather than URL/Path types for simplicity and Docker compatibility (paths are container-internal, not host paths)
3. **No Validation**: Delegate path validation to Docker to avoid duplicating complex logic and to support Docker's path creation behavior
4. **Placement in Docker Args**: Place `--workdir` before the image name (Docker CLI requirement)

### Security Considerations

- Working directory paths are not validated or sanitized - they are passed directly to Docker CLI
- No command injection risk as arguments are passed as array (not shell string)
- Users must trust their own container images and working directory choices

### Performance Impact

- Negligible - adds one optional string to struct and one conditional flag to CLI args

### Compatibility

- **Docker Version**: `--workdir` supported in all modern Docker versions
- **Platform**: Works on Linux, macOS, and Windows Docker hosts
- **Container Images**: Universal - all images support working directory

---

## References

- **Docker CLI**: `docker run --workdir` flag
- **Docker Docs**: https://docs.docker.com/engine/reference/run/#workdir
- **Dockerfile WORKDIR**: https://docs.docker.com/engine/reference/builder/#workdir
- **Testcontainers Go**: https://github.com/testcontainers/testcontainers-go (see `ContainerRequest.WorkingDir`)
- **Testcontainers Java**: https://java.testcontainers.org/features/creating_container/#working-directory

---

## Estimated Timeline

| Task | Time | Cumulative |
|------|------|------------|
| Update ContainerRequest struct | 10 min | 10 min |
| Update DockerClient.runContainer() | 5 min | 15 min |
| Add unit tests | 15 min | 30 min |
| Add integration test | 20 min | 50 min |
| Update documentation | 5 min | 55 min |
| Manual testing & verification | 15 min | 70 min |
| Code review & refinement | 20 min | 90 min |

**Total Estimated Time**: 1.5 hours

---

## Questions & Considerations

### Open Questions

1. Should we validate that paths are absolute vs. relative? (Recommendation: No - let Docker handle it)
2. Should we expose multiple working directories? (Recommendation: No - Docker only supports one)
3. Should this be part of a larger "container configuration" feature? (Recommendation: No - keep features atomic)

### Implementation Constraints

- Must maintain `Sendable` conformance for Swift 6 concurrency
- Must maintain `Hashable` conformance for test infrastructure
- Cannot break existing API contracts

### Testing Constraints

- Integration tests require Docker daemon (`TESTCONTAINERS_RUN_DOCKER_TESTS=1`)
- Some edge cases (non-existent paths) may behave differently across Docker versions
- Cannot test on CI without Docker environment configured

---

**Ticket Created**: 2025-12-15
**Last Updated**: 2025-12-15
**Assignee**: TBD
**Labels**: enhancement, tier-2, low-complexity, docker-cli
