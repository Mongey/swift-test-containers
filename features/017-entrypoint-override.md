# Feature 017: Entrypoint Override

## Summary

Add support for overriding the default entrypoint of a container image using the `--entrypoint` flag in Docker. This feature allows users to replace the image's default entrypoint with a custom executable or script, providing flexibility when the default entrypoint is not suitable for testing scenarios.

**Use Case Example**: An image might have a default entrypoint that starts a web server, but for testing, you may want to override it to run a shell script that performs setup tasks or runs a different command entirely.

## Current State

The `ContainerRequest` struct currently supports the following configuration capabilities:

- **Image selection**: Specify the Docker image to use
- **Command arguments** (`withCommand`): Pass arguments that are appended after the image's entrypoint
- **Environment variables** (`withEnvironment`): Set environment variables
- **Port mappings** (`withExposedPort`): Map container ports to host ports
- **Labels** (`withLabel`): Attach metadata labels
- **Container naming** (`withName`): Assign a specific name
- **Wait strategies** (`waitingFor`): Define readiness checks
- **Host configuration** (`withHost`): Configure the host address

### How Command Currently Works

In `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`:

```swift
public var command: [String]

public func withCommand(_ command: [String]) -> Self {
    var copy = self
    copy.command = command
    return copy
}
```

In `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`, the command is appended after the image:

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    // ... other flags ...

    args.append(request.image)
    args += request.command  // Command arguments come after image

    let output = try await runDocker(args)
    // ...
}
```

### Limitation

Without entrypoint override support, users cannot:
- Replace the image's default entrypoint
- Run a different executable than what the image specifies
- Work around problematic default entrypoints
- Test images with entrypoints that require specific initialization sequences

## Requirements

### Functional Requirements

1. **Entrypoint Configuration**
   - Accept entrypoint as a string array (e.g., `["/bin/sh", "-c"]`)
   - Accept entrypoint as a single string (e.g., `"/bin/bash"`)
   - Support empty entrypoint (`[]` or `""`) to disable the default entrypoint

2. **Interaction with Command**
   - When entrypoint is set, command arguments should be passed to the entrypoint
   - When entrypoint is empty, command should become the full executable + args
   - Behavior should match Docker's `docker run --entrypoint` semantics

3. **Docker Semantics Alignment**
   - `docker run --entrypoint /bin/sh image` - sets new entrypoint
   - `docker run --entrypoint "" image cmd args` - disables entrypoint, cmd becomes executable
   - `docker run --entrypoint /bin/sh image -c "echo hello"` - entrypoint receives command args

### Non-Functional Requirements

1. **API Consistency**: Follow the existing builder pattern used throughout `ContainerRequest`
2. **Type Safety**: Leverage Swift's type system to prevent invalid configurations
3. **Backward Compatibility**: Existing code should continue to work without changes
4. **Clear Documentation**: API should be self-documenting with clear parameter names

## API Design

### Proposed Swift API

Add an `entrypoint` property and builder method to `ContainerRequest`:

```swift
public struct ContainerRequest: Sendable, Hashable {
    public var image: String
    public var name: String?
    public var entrypoint: [String]?  // NEW: nil means use default, [] means disable
    public var command: [String]
    public var environment: [String: String]
    // ... existing properties ...

    public init(image: String) {
        self.image = image
        self.name = nil
        self.entrypoint = nil  // NEW: default to image's entrypoint
        self.command = []
        // ... existing defaults ...
    }

    // NEW: Builder method for entrypoint
    public func withEntrypoint(_ entrypoint: [String]) -> Self {
        var copy = self
        copy.entrypoint = entrypoint
        return copy
    }

    // NEW: Convenience method for single string entrypoint
    public func withEntrypoint(_ entrypoint: String) -> Self {
        return withEntrypoint([entrypoint])
    }

    // Existing methods remain unchanged
    public func withCommand(_ command: [String]) -> Self { ... }
    // ... other methods ...
}
```

### Usage Examples

```swift
// Example 1: Override entrypoint to run shell commands
let request = ContainerRequest(image: "alpine:3")
    .withEntrypoint(["/bin/sh", "-c"])
    .withCommand(["echo hello && sleep 5"])
    .waitingFor(.logContains("hello"))

// Example 2: Disable entrypoint and run custom command
let request = ContainerRequest(image: "custom-image:latest")
    .withEntrypoint([])  // Disable default entrypoint
    .withCommand(["/custom/script.sh", "--debug"])

// Example 3: Simple single-string entrypoint
let request = ContainerRequest(image: "ubuntu:22.04")
    .withEntrypoint("/bin/bash")
    .withCommand(["-c", "apt-get update"])
```

### Alternative Considered: Enum-Based API

```swift
public enum Entrypoint: Sendable, Hashable {
    case `default`           // Use image's default
    case override([String])  // Override with custom entrypoint
    case disabled            // Disable entrypoint (empty)
}

public func withEntrypoint(_ entrypoint: Entrypoint) -> Self
```

**Decision**: Using `[String]?` is simpler and more direct, matching Docker's behavior:
- `nil` = use default (no --entrypoint flag)
- `[]` = disable entrypoint (--entrypoint "")
- `["cmd"]` = override (--entrypoint cmd)

## Implementation Steps

### Step 1: Update ContainerRequest Model

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

1. Add `entrypoint` property:
   ```swift
   public var entrypoint: [String]?
   ```

2. Initialize in `init(image:)`:
   ```swift
   self.entrypoint = nil
   ```

3. Add builder methods:
   ```swift
   public func withEntrypoint(_ entrypoint: [String]) -> Self {
       var copy = self
       copy.entrypoint = entrypoint
       return copy
   }

   public func withEntrypoint(_ entrypoint: String) -> Self {
       return withEntrypoint([entrypoint])
   }
   ```

### Step 2: Update DockerClient to Pass --entrypoint Flag

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Modify `runContainer(_ request:)` method to include entrypoint handling:

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    if let name = request.name {
        args += ["--name", name]
    }

    // NEW: Add entrypoint handling
    if let entrypoint = request.entrypoint {
        if entrypoint.isEmpty {
            // Disable entrypoint: --entrypoint ""
            args += ["--entrypoint", ""]
        } else if entrypoint.count == 1 {
            // Single entrypoint: --entrypoint /bin/sh
            args += ["--entrypoint", entrypoint[0]]
        } else {
            // Multiple parts: --entrypoint /bin/sh and rest become args
            // Note: Docker only accepts single value for --entrypoint flag
            // Multiple elements should be handled as: entrypoint[0] is executable,
            // entrypoint[1...] should be prepended to command
            args += ["--entrypoint", entrypoint[0]]
        }
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

    // NEW: Handle multi-part entrypoint
    if let entrypoint = request.entrypoint, entrypoint.count > 1 {
        // entrypoint[1...] becomes command prefix
        args += Array(entrypoint[1...])
    }

    args += request.command

    let output = try await runDocker(args)
    let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { throw TestContainersError.unexpectedDockerOutput(output.stdout) }
    return id
}
```

**Note on Docker --entrypoint flag behavior**:
- `--entrypoint` accepts only a single value (the executable)
- Additional entrypoint arguments must be passed as command arguments
- Example: `docker run --entrypoint /bin/sh alpine -c "echo hello"`
  - Entrypoint: `/bin/sh`
  - Command args: `-c`, `"echo hello"`

### Step 3: Update Hashable/Sendable Conformance

Since `entrypoint` is an optional `[String]`, it automatically conforms to `Hashable` and `Sendable` (as `String` is both). No additional work needed.

### Step 4: Add Documentation Comments

Add Swift documentation comments to the new API:

```swift
/// Overrides the default entrypoint of the container image.
///
/// The entrypoint defines the executable that runs when the container starts.
/// When set, any command arguments (via `withCommand`) are passed to this entrypoint.
///
/// - Parameter entrypoint: An array of strings representing the entrypoint and its arguments.
///   Pass an empty array `[]` to disable the image's default entrypoint.
///
/// - Returns: A new `ContainerRequest` with the entrypoint configured.
///
/// # Example
/// ```swift
/// let request = ContainerRequest(image: "alpine:3")
///     .withEntrypoint(["/bin/sh", "-c"])
///     .withCommand(["echo hello"])
/// ```
public func withEntrypoint(_ entrypoint: [String]) -> Self
```

## Testing Plan

### Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests for builder pattern behavior:

```swift
@Test func setsEntrypointViaBuilder() {
    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint(["/bin/sh", "-c"])

    #expect(request.entrypoint == ["/bin/sh", "-c"])
}

@Test func setsEntrypointWithSingleString() {
    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint("/bin/bash")

    #expect(request.entrypoint == ["/bin/bash"])
}

@Test func disablesEntrypointWithEmptyArray() {
    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint([])

    #expect(request.entrypoint == [])
}

@Test func defaultsToNilEntrypoint() {
    let request = ContainerRequest(image: "alpine:3")

    #expect(request.entrypoint == nil)
}

@Test func builderChaining_entrypointAndCommand() {
    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint(["/bin/sh", "-c"])
        .withCommand(["echo hello"])
        .withEnvironment(["KEY": "value"])

    #expect(request.entrypoint == ["/bin/sh", "-c"])
    #expect(request.command == ["echo hello"])
    #expect(request.environment == ["KEY": "value"])
}
```

### Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

Add Docker integration tests (opt-in via `TESTCONTAINERS_RUN_DOCKER_TESTS=1`):

```swift
@Test func canOverrideEntrypoint() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint(["/bin/sh", "-c"])
        .withCommand(["echo 'Entrypoint override works' && sleep 1"])
        .waitingFor(.logContains("Entrypoint override works"))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Entrypoint override works"))
    }
}

@Test func canDisableEntrypoint() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // alpine's default entrypoint is /bin/sh, we disable it and run echo directly
    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint([])
        .withCommand(["/bin/echo", "Direct command execution"])
        .waitingFor(.logContains("Direct command execution"))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Direct command execution"))
    }
}

@Test func entrypointInteractsWithCommand() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint("/bin/echo")
        .withCommand(["Hello", "from", "entrypoint"])
        .waitingFor(.logContains("Hello from entrypoint"))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Hello from entrypoint"))
    }
}

@Test func multiPartEntrypoint() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Test that multi-part entrypoint works: ["/bin/sh", "-c"]
    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint(["/bin/sh", "-c"])
        .withCommand(["echo 'Multi-part entrypoint' && sleep 1"])
        .waitingFor(.logContains("Multi-part entrypoint"))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Multi-part entrypoint"))
    }
}
```

### Manual Testing Checklist

1. Verify `--entrypoint` flag appears in Docker command when entrypoint is set
2. Verify `--entrypoint ""` appears when entrypoint is empty array
3. Verify no `--entrypoint` flag when entrypoint is nil (default)
4. Test with various Docker images (alpine, ubuntu, custom images with entrypoints)
5. Verify interaction with existing features (environment, ports, wait strategies)
6. Test error handling for invalid entrypoint executables

## Acceptance Criteria

### Definition of Done

- [x] `ContainerRequest` has `entrypoint: [String]?` property
- [x] `withEntrypoint(_ entrypoint: [String]) -> Self` builder method implemented
- [x] `withEntrypoint(_ entrypoint: String) -> Self` convenience method implemented
- [x] `DockerClient.runContainer()` correctly passes `--entrypoint` flag to Docker
- [x] Multi-part entrypoints handled correctly (first element as flag, rest as command prefix)
- [x] Empty entrypoint array (`[]`) correctly translates to `--entrypoint ""`
- [x] Nil entrypoint (default) does not add `--entrypoint` flag
- [x] All unit tests pass
- [x] All integration tests pass (when opted in)
- [x] API documentation added with examples
- [x] Backward compatibility verified: existing tests still pass
- [x] Code follows existing patterns and conventions in the codebase

### Success Metrics

- Users can override container entrypoints for testing scenarios
- API is intuitive and follows Swift/Docker conventions
- No breaking changes to existing API
- Feature is well-tested and documented

## Related References

- Docker documentation: [Entrypoint](https://docs.docker.com/reference/cli/docker/container/run/#entrypoint)
- Testcontainers (other languages) typically support entrypoint override
- Related to command support (existing feature)

## Implementation Notes

### Docker --entrypoint Behavior Details

From Docker documentation:
```bash
# Override entrypoint
docker run --entrypoint /bin/sh alpine

# Disable entrypoint
docker run --entrypoint "" ubuntu /bin/ls

# Entrypoint with args (args become command)
docker run --entrypoint /bin/sh alpine -c "echo hello"
```

### Swift-Specific Considerations

1. **Sendable Conformance**: `[String]?` is Sendable, no issues with actor isolation
2. **Hashable Conformance**: Arrays of Hashable elements are Hashable
3. **Builder Pattern**: Maintains immutability via copy-on-write semantics
4. **Type Safety**: Optional array clearly distinguishes between "not set", "disabled", and "set"

### Edge Cases to Consider

1. **Entrypoint = `nil`, Command = `[]`**: Use image defaults
2. **Entrypoint = `[]`, Command = `[]`**: Container may fail to start (no executable)
3. **Entrypoint = `["/bin/sh", "-c"]`, Command = `["cmd1", "cmd2"]`**: Need to properly quote/escape
4. **Invalid executable path**: Docker will fail, error should be propagated
5. **Entrypoint with spaces**: Requires proper escaping in Docker command

### Future Enhancements

- Validation of entrypoint executable path
- Helper methods for common entrypoints (shell, bash, etc.)
- Support for entrypoint in image build (if/when build support is added)
