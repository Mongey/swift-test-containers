# Feature 007: Container Exec

**Status**: Complete
**Priority**: Tier 1 (High Priority)
**Complexity**: Medium
**Estimated Effort**: 4-6 hours

---

## Summary

Add the ability to execute commands inside a running container and capture the results (exit code, stdout, stderr). This feature will enable users to:

- Run diagnostic commands for debugging tests
- Verify container internal state
- Perform setup/configuration operations after container start
- Implement exec-based wait strategies

The feature will provide both synchronous and asynchronous execution APIs consistent with Swift's modern concurrency model.

---

## Current State

### Docker CLI Interaction Pattern

The project currently uses the `DockerClient` actor to execute Docker CLI commands via `ProcessRunner`:

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

```swift
// Current pattern for Docker CLI execution
func runDocker(_ args: [String]) async throws -> CommandOutput {
    let output = try await runner.run(executable: dockerPath, arguments: args)
    if output.exitCode != 0 {
        throw TestContainersError.commandFailed(
            command: [dockerPath] + args,
            exitCode: output.exitCode,
            stdout: output.stdout,
            stderr: output.stderr
        )
    }
    return output
}
```

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ProcessRunner.swift`

```swift
struct CommandOutput: Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

actor ProcessRunner {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> CommandOutput
}
```

### Container Actor Structure

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

The `Container` actor currently provides:
- `hostPort(_:)` - Port resolution
- `endpoint(for:)` - Endpoint construction
- `logs()` - Container log retrieval
- `terminate()` - Container removal

All methods delegate to `DockerClient` and are `async throws`.

---

## Requirements

### Functional Requirements

1. **Execute commands in running containers**
   - Run arbitrary commands inside the container
   - Support commands with arguments
   - Return structured output (exit code, stdout, stderr)

2. **Execution options**
   - Working directory override
   - Environment variable injection
   - User specification (run as specific user/UID)
   - Interactive mode (attach stdin, allocate TTY)
   - Detached mode (fire-and-forget)

3. **Output handling**
   - Capture stdout and stderr separately
   - Return actual exit code (don't automatically throw on non-zero)
   - Handle large output gracefully

4. **Error handling**
   - Distinguish between exec failures and command failures
   - Include full context in errors (command, container ID)
   - Handle cases where container is not running

### Non-Functional Requirements

1. **Consistency**: API follows existing patterns (`async throws`, actor isolation)
2. **Sendable**: All types must be `Sendable` for Swift concurrency
3. **Testability**: Unit and integration tests required
4. **Documentation**: Public API must be documented

---

## API Design

### Public Container API

Add the following methods to the `Container` actor:

```swift
public actor Container {
    // ... existing methods ...

    /// Execute a command in the running container.
    ///
    /// - Parameters:
    ///   - command: The command and arguments to execute
    ///   - options: Execution options (user, working directory, environment)
    /// - Returns: Command output including exit code, stdout, and stderr
    /// - Throws: `TestContainersError.commandFailed` if exec setup fails
    ///
    /// Example:
    /// ```swift
    /// let result = try await container.exec(["ls", "-la", "/app"])
    /// print("Exit code: \(result.exitCode)")
    /// print("Output:\n\(result.stdout)")
    /// ```
    public func exec(
        _ command: [String],
        options: ExecOptions = ExecOptions()
    ) async throws -> ExecResult

    /// Execute a command in the running container with a custom user.
    ///
    /// Convenience method for running commands as a specific user.
    ///
    /// - Parameters:
    ///   - command: The command and arguments to execute
    ///   - user: User specification (username, UID, or UID:GID)
    /// - Returns: Command output including exit code, stdout, and stderr
    public func exec(
        _ command: [String],
        user: String
    ) async throws -> ExecResult

    /// Execute a command and return only stdout.
    ///
    /// Convenience method that throws if exit code is non-zero.
    ///
    /// - Parameters:
    ///   - command: The command and arguments to execute
    ///   - options: Execution options
    /// - Returns: Standard output as a string
    /// - Throws: `TestContainersError.execCommandFailed` if exit code != 0
    public func execOutput(
        _ command: [String],
        options: ExecOptions = ExecOptions()
    ) async throws -> String
}
```

### Supporting Types

```swift
/// Options for executing commands in a container.
public struct ExecOptions: Sendable, Hashable {
    /// User to run the command as (username, UID, or UID:GID)
    public var user: String?

    /// Working directory for command execution
    public var workingDirectory: String?

    /// Environment variables to set for the command
    public var environment: [String: String]

    /// Allocate a pseudo-TTY
    public var tty: Bool

    /// Keep STDIN open (for interactive commands)
    public var interactive: Bool

    /// Run in detached mode (don't wait for completion)
    public var detached: Bool

    /// Create a default ExecOptions with sensible defaults
    public init(
        user: String? = nil,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        tty: Bool = false,
        interactive: Bool = false,
        detached: Bool = false
    )

    // Fluent builder methods
    public func withUser(_ user: String) -> Self
    public func withWorkingDirectory(_ workingDirectory: String) -> Self
    public func withEnvironment(_ environment: [String: String]) -> Self
    public func withTTY(_ tty: Bool = true) -> Self
    public func withInteractive(_ interactive: Bool = true) -> Self
    public func withDetached(_ detached: Bool = true) -> Self
}

/// Result of executing a command in a container.
public struct ExecResult: Sendable, Hashable {
    /// The exit code returned by the command
    public let exitCode: Int32

    /// Standard output from the command
    public let stdout: String

    /// Standard error from the command
    public let stderr: String

    /// Whether the command succeeded (exit code 0)
    public var succeeded: Bool { exitCode == 0 }

    /// Whether the command failed (exit code != 0)
    public var failed: Bool { exitCode != 0 }
}
```

### DockerClient Implementation

```swift
// In DockerClient actor
func exec(
    id: String,
    command: [String],
    options: ExecOptions
) async throws -> ExecResult {
    var args: [String] = ["exec"]

    if options.detached {
        args.append("-d")
    }

    if options.interactive {
        args.append("-i")
    }

    if options.tty {
        args.append("-t")
    }

    if let user = options.user {
        args += ["-u", user]
    }

    if let workdir = options.workingDirectory {
        args += ["-w", workdir]
    }

    for (key, value) in options.environment.sorted(by: { $0.key < $1.key }) {
        args += ["-e", "\(key)=\(value)"]
    }

    args.append(id)
    args += command

    // Note: Don't use runDocker() because we want to capture non-zero exit codes
    let output = try await runner.run(executable: dockerPath, arguments: args)

    // docker exec itself failing is an error, but the command returning non-zero is not
    // We can't easily distinguish these cases with CLI, so we accept all exit codes
    return ExecResult(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
}
```

### Error Handling Enhancement

Add new error case to `TestContainersError`:

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    // ... existing cases ...

    case execCommandFailed(
        command: [String],
        exitCode: Int32,
        stdout: String,
        stderr: String,
        containerID: String
    )

    public var description: String {
        switch self {
        // ... existing cases ...

        case let .execCommandFailed(command, exitCode, stdout, stderr, containerID):
            return """
            Exec command failed in container \(containerID) (exit \(exitCode)): \
            \(command.joined(separator: " "))
            stdout:
            \(stdout)
            stderr:
            \(stderr)
            """
        }
    }
}
```

---

## Implementation Steps

### Step 1: Define Types (1 hour)

1. Create `ExecOptions` struct in new file or add to `ContainerRequest.swift`
   - Add all properties (user, workingDirectory, environment, etc.)
   - Implement `init` with defaults
   - Add fluent builder methods (`.withUser()`, etc.)
   - Ensure `Sendable` and `Hashable` conformance

2. Create `ExecResult` struct in same file
   - Add `exitCode`, `stdout`, `stderr` properties
   - Add `succeeded` and `failed` computed properties
   - Ensure `Sendable` and `Hashable` conformance

3. Add `execCommandFailed` case to `TestContainersError`
   - Include all relevant context fields
   - Update `description` property

### Step 2: Implement DockerClient.exec() (2 hours)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

1. Add `exec()` method to `DockerClient` actor
   - Build argument array from options
   - Handle all flags: `-d`, `-i`, `-t`, `-u`, `-w`, `-e`
   - Call `runner.run()` directly (not `runDocker()` to preserve exit codes)
   - Return `ExecResult` with all output

2. Test argument construction manually:
   ```swift
   // Should produce: ["exec", "-u", "root", "-w", "/app", "-e", "FOO=bar", "container_id", "ls", "-la"]
   ```

### Step 3: Implement Container.exec() Methods (1 hour)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

1. Add `exec(_:options:)` method
   - Delegate to `docker.exec(id: id, command: command, options: options)`
   - Mark as `public`

2. Add `exec(_:user:)` convenience method
   - Create `ExecOptions` with user set
   - Call main `exec()` method

3. Add `execOutput(_:options:)` convenience method
   - Call main `exec()` method
   - Check if `result.failed` and throw `TestContainersError.execCommandFailed`
   - Return `result.stdout` trimmed

### Step 4: Unit Tests (1 hour)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ExecOptionsTests.swift` (new)

1. Test `ExecOptions` builder pattern
   ```swift
   @Test func execOptionsBuilder() {
       let options = ExecOptions()
           .withUser("root")
           .withWorkingDirectory("/app")
           .withEnvironment(["FOO": "bar"])

       #expect(options.user == "root")
       #expect(options.workingDirectory == "/app")
       #expect(options.environment == ["FOO": "bar"])
   }
   ```

2. Test `ExecResult` computed properties
   ```swift
   @Test func execResultSucceeded() {
       let result = ExecResult(exitCode: 0, stdout: "ok", stderr: "")
       #expect(result.succeeded)
       #expect(!result.failed)
   }

   @Test func execResultFailed() {
       let result = ExecResult(exitCode: 1, stdout: "", stderr: "error")
       #expect(!result.succeeded)
       #expect(result.failed)
   }
   ```

### Step 5: Integration Tests (1-2 hours)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerExecTests.swift` (new)

1. Test basic exec
   ```swift
   @Test func execSimpleCommand() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let request = ContainerRequest(image: "alpine:3.19")
           .withCommand(["sleep", "30"])

       try await withContainer(request) { container in
           let result = try await container.exec(["echo", "hello"])
           #expect(result.exitCode == 0)
           #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
           #expect(result.succeeded)
       }
   }
   ```

2. Test exec with non-zero exit code
   ```swift
   @Test func execNonZeroExitCode() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let request = ContainerRequest(image: "alpine:3.19")
           .withCommand(["sleep", "30"])

       try await withContainer(request) { container in
           let result = try await container.exec(["sh", "-c", "exit 42"])
           #expect(result.exitCode == 42)
           #expect(result.failed)
       }
   }
   ```

3. Test exec with working directory
   ```swift
   @Test func execWithWorkingDirectory() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let request = ContainerRequest(image: "alpine:3.19")
           .withCommand(["sleep", "30"])

       try await withContainer(request) { container in
           let result = try await container.exec(
               ["pwd"],
               options: ExecOptions().withWorkingDirectory("/tmp")
           )
           #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp")
       }
   }
   ```

4. Test exec with environment variables
   ```swift
   @Test func execWithEnvironment() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let request = ContainerRequest(image: "alpine:3.19")
           .withCommand(["sleep", "30"])

       try await withContainer(request) { container in
           let result = try await container.exec(
               ["sh", "-c", "echo $MY_VAR"],
               options: ExecOptions().withEnvironment(["MY_VAR": "test123"])
           )
           #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "test123")
       }
   }
   ```

5. Test exec with user
   ```swift
   @Test func execWithUser() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let request = ContainerRequest(image: "alpine:3.19")
           .withCommand(["sleep", "30"])

       try await withContainer(request) { container in
           let result = try await container.exec(["whoami"], user: "root")
           #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "root")
       }
   }
   ```

6. Test execOutput convenience method
   ```swift
   @Test func execOutputSuccess() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let request = ContainerRequest(image: "alpine:3.19")
           .withCommand(["sleep", "30"])

       try await withContainer(request) { container in
           let output = try await container.execOutput(["echo", "test"])
           #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "test")
       }
   }

   @Test func execOutputThrowsOnFailure() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let request = ContainerRequest(image: "alpine:3.19")
           .withCommand(["sleep", "30"])

       try await withContainer(request) { container in
           await #expect(throws: TestContainersError.self) {
               try await container.execOutput(["sh", "-c", "exit 1"])
           }
       }
   }
   ```

7. Test stderr capture
   ```swift
   @Test func execCapturesStderr() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let request = ContainerRequest(image: "alpine:3.19")
           .withCommand(["sleep", "30"])

       try await withContainer(request) { container in
           let result = try await container.exec(["sh", "-c", "echo error >&2"])
           #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == "error")
       }
   }
   ```

### Step 6: Documentation (30 minutes)

1. Add documentation comments to all public APIs
2. Update `FEATURES.md` to mark exec as implemented
3. Add example to `README.md` (optional, but recommended)

---

## Testing Plan

### Unit Tests

- **ExecOptions builder pattern**: Verify all fluent methods work correctly
- **ExecOptions defaults**: Verify sensible defaults (no user, no workdir, etc.)
- **ExecResult properties**: Verify `succeeded` and `failed` computed properties
- **Error descriptions**: Verify `execCommandFailed` formats properly

### Integration Tests (Docker required)

All integration tests gated by `TESTCONTAINERS_RUN_DOCKER_TESTS=1`:

1. **Basic execution**: Simple commands (echo, ls, pwd)
2. **Exit codes**: Commands with various exit codes (0, 1, 42, 127)
3. **Output capture**: Verify stdout and stderr are captured separately
4. **Working directory**: Verify `-w` flag works
5. **Environment variables**: Verify `-e` flag works
6. **User specification**: Verify `-u` flag works
7. **Multiple arguments**: Commands with spaces and special characters
8. **Long output**: Commands producing large stdout/stderr
9. **Convenience methods**: Test `exec(_:user:)` and `execOutput(_:)`
10. **Error handling**: Test `execOutput` throwing on non-zero exit

### Manual Testing

Run against real containers to verify:
- Commands execute in correct container
- No interference between parallel execs (if supported by Docker)
- Cleanup works properly (no leaked processes)

---

## Acceptance Criteria

### Must Have

- [x] `Container.exec(_:options:)` method implemented
- [x] `ExecOptions` supports: user, workingDirectory, environment
- [x] `ExecResult` captures: exitCode, stdout, stderr
- [x] Non-zero exit codes are returned, not thrown (in main `exec()`)
- [x] `execOutput()` convenience method throws on non-zero exit
- [x] All types are `Sendable` and `Hashable`
- [x] Integration tests pass with Redis/Alpine containers
- [x] Error messages include container ID and command details
- [x] Public APIs have documentation comments

### Nice to Have

- [ ] `detached` mode for fire-and-forget commands
- [ ] `interactive` and `tty` modes for advanced use cases
- [ ] Example in README showing exec usage
- [ ] Performance testing with many sequential execs

### Out of Scope (Future)

- Streaming exec output (requires SDK or background process)
- Sending stdin to exec processes (requires SDK)
- Exec-based wait strategy (depends on this feature)
- Timeout support for exec commands (could use `Task.timeout` externally)

---

## Docker CLI Reference

The implementation will use `docker exec`:

```bash
# Basic usage
docker exec <container_id> <command> [args...]

# With options
docker exec -u <user> -w <workdir> -e KEY=VALUE <container_id> <command>

# Flags we'll support initially:
#   -u, --user         User to run as (username or UID[:GID])
#   -w, --workdir      Working directory inside the container
#   -e, --env          Set environment variables
#   -d, --detach       Detached mode (run in background)
#   -i, --interactive  Keep STDIN open
#   -t, --tty          Allocate a pseudo-TTY

# Exit code behavior:
#   - Exit code 0: docker exec succeeded, command succeeded
#   - Exit code 1-255: docker exec succeeded, command failed with this code
#   - Exit code 126: docker exec failed (command cannot execute)
#   - Exit code 127: docker exec failed (command not found)
```

Examples:
```bash
# Run as root
docker exec -u root my-container whoami

# Set working directory
docker exec -w /app my-container pwd

# Pass environment variables
docker exec -e FOO=bar my-container sh -c 'echo $FOO'

# Combine options
docker exec -u root -w /tmp -e DEBUG=1 my-container ls -la
```

---

## Related Features

This feature enables:

1. **Exec-based wait strategy** (Feature 008)
   - Wait until a command succeeds
   - Example: `waitingFor(.exec(["pg_isready"]))`

2. **Container initialization** (Future)
   - Run setup commands after container starts
   - Example: Database schema creation

3. **Health checks** (Future)
   - Custom health check logic via exec
   - Example: Application-specific readiness checks

4. **Debugging utilities** (Future)
   - Inspect running containers during test failures
   - Example: Capture diagnostic info on timeout

---

## References

### Testcontainers Go Implementation

https://github.com/testcontainers/testcontainers-go/blob/main/exec.go

```go
type ExecOptions struct {
    User         []string
    WorkingDir   string
    Env          map[string]string
}

func (c *DockerContainer) Exec(ctx context.Context, cmd []string, opts ...ExecOption) (int, io.Reader, error)
```

### Docker Exec Documentation

- https://docs.docker.com/engine/reference/commandline/exec/
- https://docs.docker.com/engine/api/v1.43/#tag/Exec

### Existing Codebase Patterns

- **Actor isolation**: `DockerClient` and `Container` are actors
- **Async/throws**: All operations are `async throws`
- **Fluent builders**: `ContainerRequest` uses `.withX()` pattern
- **Sendable types**: All public types conform to `Sendable`
- **Error handling**: Structured errors via `TestContainersError`
- **CLI delegation**: All Docker operations via `ProcessRunner`
- **Output capture**: Using `CommandOutput` struct

---

## Implementation Checklist

- [x] Define `ExecOptions` struct with builder methods
- [x] Define `ExecResult` struct with computed properties
- [x] Add `execCommandFailed` to `TestContainersError`
- [x] Implement `DockerClient.exec(id:command:options:)`
- [x] Implement `Container.exec(_:options:)`
- [x] Implement `Container.exec(_:user:)` convenience
- [x] Implement `Container.execOutput(_:options:)` convenience
- [x] Write unit tests for types
- [x] Write integration tests for all scenarios
- [x] Add documentation comments
- [x] Update `FEATURES.md`
- [x] Manual testing with real containers
- [x] Code review and refinement

---

## Estimated Timeline

| Phase | Time | Description |
|-------|------|-------------|
| Design & Types | 1 hour | Define structs, enums, protocols |
| DockerClient impl | 2 hours | Implement exec in DockerClient |
| Container API | 1 hour | Add methods to Container actor |
| Unit tests | 1 hour | Test types and builders |
| Integration tests | 1-2 hours | Docker-based tests |
| Documentation | 30 min | Comments, README, FEATURES.md |
| **Total** | **6-7 hours** | End-to-end implementation |

---

## Notes

- The Docker CLI doesn't easily distinguish between "docker exec failed" and "command returned non-zero". We accept all exit codes in the main `exec()` method and let callers decide how to handle them.
- Interactive (`-i`) and TTY (`-t`) modes are included in `ExecOptions` but may have limitations when used via `ProcessRunner`. These are primarily for future SDK support.
- Detached mode (`-d`) is useful for background tasks but returns immediately with no output. Callers must handle this case.
- The `execOutput()` convenience method is designed for the common case: "run this command and give me the output, or throw if it fails".
