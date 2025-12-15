# Feature 003: Exec Wait Strategy

**Status: ✅ Implemented**

## Implementation Notes

This feature was implemented on 2025-12-15. Key implementation details:

### Files Modified
- `Sources/TestContainers/ContainerRequest.swift` - Added `.exec([String], timeout:, pollInterval:)` case to `WaitStrategy` enum
- `Sources/TestContainers/DockerClient.swift` - Added `exec(id:command:)` method that returns exit code
- `Sources/TestContainers/Container.swift` - Added exec case handler in `waitUntilReady()`
- `Tests/TestContainersTests/ContainerRequestTests.swift` - Unit tests for configuration
- `Tests/TestContainersTests/DockerIntegrationTests.swift` - Integration tests with Docker

### Test Coverage
- 4 unit tests for configuration and defaults
- 5 integration tests covering:
  - Command succeeding after delay
  - Immediately successful commands
  - Timeout scenarios
  - PostgreSQL pg_isready
  - Shell command execution

## Summary

Implement an exec-based wait strategy that determines container readiness by executing a command inside the container and checking its exit code. This strategy is useful for containers that are ready when a specific command succeeds (e.g., database readiness checks, health check scripts).

## Current State

The codebase currently supports two wait strategies defined in `/Sources/TestContainers/ContainerRequest.swift`:

```swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
}
```

**TCP Port Strategy** (`/Sources/TestContainers/Container.swift`, lines 45-50):
- Polls a TCP port using `TCPProbe.canConnect()` until it accepts connections
- Uses the generic `Waiter.wait()` function with a predicate

**Log Contains Strategy** (`/Sources/TestContainers/Container.swift`, lines 40-44):
- Polls container logs using `docker logs` until a specific string appears
- Uses the generic `Waiter.wait()` function with a predicate

Both strategies follow a consistent pattern:
1. Accept timeout and pollInterval parameters (with sensible defaults)
2. Use `Waiter.wait()` for polling logic
3. Implement a predicate that returns `Bool` to indicate readiness

## Requirements

### Functional Requirements

1. **Command Execution**: Execute arbitrary commands inside a running container using `docker exec`
2. **Exit Code Checking**: Determine success based on exit code (0 = success, non-zero = failure)
3. **Timeout Support**: Configurable timeout with default of 60 seconds
4. **Poll Interval**: Configurable polling interval with default of 200ms
5. **Error Handling**: Clear error messages on timeout or failure
6. **Sendable & Hashable**: Must conform to `Sendable` and `Hashable` like other wait strategies

### Non-Functional Requirements

1. **Consistency**: Follow existing wait strategy patterns and conventions
2. **Testability**: Support both unit and integration testing
3. **Performance**: Minimal overhead from polling

## API Design

### Proposed WaitStrategy Enum Addition

Add a new case to the `WaitStrategy` enum in `/Sources/TestContainers/ContainerRequest.swift`:

```swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case exec([String], timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
}
```

**Parameters**:
- `[String]`: Command and arguments to execute (e.g., `["pg_isready", "-U", "postgres"]`)
- `timeout`: Maximum time to wait for the command to succeed
- `pollInterval`: Time between command execution attempts

### Usage Examples

```swift
// PostgreSQL readiness check
let request = ContainerRequest(image: "postgres:16")
    .withEnvironment(["POSTGRES_PASSWORD": "test"])
    .withExposedPort(5432)
    .waitingFor(.exec(["pg_isready", "-U", "postgres"]))

// Custom health check script
let request = ContainerRequest(image: "myapp:latest")
    .waitingFor(.exec(["/app/healthcheck.sh"], timeout: .seconds(120)))

// MySQL readiness check
let request = ContainerRequest(image: "mysql:8")
    .withEnvironment(["MYSQL_ROOT_PASSWORD": "root"])
    .waitingFor(.exec([
        "mysqladmin", "ping", "-h", "localhost", "-proot"
    ], timeout: .seconds(90)))
```

## Implementation Steps

### Step 1: Add Docker Exec Support to DockerClient

**File**: `/Sources/TestContainers/DockerClient.swift`

Add a new method to execute commands in containers:

```swift
func exec(id: String, command: [String]) async throws -> Int32 {
    var args = ["exec", id]
    args += command

    let output = try await runner.run(executable: dockerPath, arguments: args)
    return output.exitCode
}
```

**Notes**:
- This method returns the raw exit code (not `CommandOutput`) for simplicity
- No need to throw on non-zero exit codes (unlike `runDocker()`) since we expect commands to fail during polling
- The method can be `package` visibility initially since it's only used internally

**Estimated Effort**: 30 minutes

### Step 2: Add Exec Case to WaitStrategy Enum

**File**: `/Sources/TestContainers/ContainerRequest.swift`

Add the new enum case as shown in the API Design section above.

**Estimated Effort**: 5 minutes

### Step 3: Implement Exec Wait Logic in Container

**File**: `/Sources/TestContainers/Container.swift`

Add a new case to the switch statement in `waitUntilReady()` (after line 44):

```swift
case let .exec(command, timeout, pollInterval):
    try await Waiter.wait(
        timeout: timeout,
        pollInterval: pollInterval,
        description: "command '\(command.joined(separator: " "))' to exit with code 0"
    ) { [docker, id] in
        let exitCode = try await docker.exec(id: id, command: command)
        return exitCode == 0
    }
```

**Notes**:
- Follows the exact same pattern as existing wait strategies
- Uses closure capture for `docker` and `id` (consistent with `logContains`)
- Provides descriptive error messages for timeout cases

**Estimated Effort**: 15 minutes

### Step 4: Add Unit Tests

**File**: `/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests to verify the wait strategy can be configured:

```swift
@Test func configuresExecWaitStrategy() {
    let request = ContainerRequest(image: "alpine:3")
        .waitingFor(.exec(["test", "-f", "/ready"]))

    #expect(request.waitStrategy == .exec(["test", "-f", "/ready"]))
}

@Test func configuresExecWaitStrategyWithCustomTimeout() {
    let request = ContainerRequest(image: "alpine:3")
        .waitingFor(.exec(
            ["pg_isready"],
            timeout: .seconds(90),
            pollInterval: .milliseconds(500)
        ))

    if case let .exec(cmd, timeout, interval) = request.waitStrategy {
        #expect(cmd == ["pg_isready"])
        #expect(timeout == .seconds(90))
        #expect(interval == .milliseconds(500))
    } else {
        Issue.record("Expected exec wait strategy")
    }
}
```

**Estimated Effort**: 30 minutes

### Step 5: Add Integration Tests

**File**: `/Tests/TestContainersTests/DockerIntegrationTests.swift` or new file

Add integration tests that run real containers:

```swift
@Test func execWaitStrategy_succeeds_whenCommandExitsZero() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Alpine container with a file creation after delay
    let request = ContainerRequest(image: "alpine:3")
        .withCommand([
            "sh", "-c",
            "sleep 2 && touch /tmp/ready && sleep 30"
        ])
        .waitingFor(.exec(
            ["test", "-f", "/tmp/ready"],
            timeout: .seconds(10)
        ))

    try await withContainer(request) { container in
        // If we get here, the wait strategy succeeded
        #expect(container.id.isEmpty == false)
    }
}

@Test func execWaitStrategy_timesOut_whenCommandNeverSucceeds() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .waitingFor(.exec(
            ["test", "-f", "/nonexistent"],
            timeout: .seconds(2),
            pollInterval: .milliseconds(100)
        ))

    await #expect(throws: TestContainersError.self) {
        try await withContainer(request) { _ in }
    }
}

@Test func execWaitStrategy_withPostgres() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "postgres:16-alpine")
        .withEnvironment(["POSTGRES_PASSWORD": "test"])
        .withExposedPort(5432)
        .waitingFor(.exec(
            ["pg_isready", "-U", "postgres"],
            timeout: .seconds(30)
        ))

    try await withContainer(request) { container in
        let port = try await container.hostPort(5432)
        #expect(port > 0)
    }
}
```

**Notes**:
- Tests verify both success and timeout scenarios
- Include real-world example with PostgreSQL
- Follow existing pattern of opt-in via `TESTCONTAINERS_RUN_DOCKER_TESTS`

**Estimated Effort**: 1 hour

### Step 6: Documentation

Add usage examples to README or documentation:
- Example with PostgreSQL `pg_isready`
- Example with MySQL `mysqladmin ping`
- Example with custom health check scripts
- Note about command availability in container

**Estimated Effort**: 30 minutes

## Dependencies

### Critical Dependency: Container Exec Runtime Operation

This feature **depends on** the ability to execute commands in running containers via `docker exec`. The implementation assumes:

1. **Docker Exec API**: The `docker exec` command works reliably
2. **Container State**: The container is running when exec is called
3. **Command Availability**: Commands must exist in the container image
4. **Exit Code Reliability**: `docker exec` correctly propagates exit codes

**Mitigation**: The `ProcessRunner` and `DockerClient` infrastructure already exists and is proven to work with other Docker commands, so this is a low-risk dependency.

### Related Features

- **Feature 001** (if exists): Basic container lifecycle management
- **Feature 002** (if exists): Wait strategy infrastructure (already implemented)

## Testing Plan

### Unit Tests

Location: `/Tests/TestContainersTests/ContainerRequestTests.swift`

1. Test wait strategy enum configuration
2. Test parameter defaults
3. Test `Hashable` and `Equatable` conformance
4. Test `Sendable` conformance (compile-time check)

### Integration Tests

Location: `/Tests/TestContainersTests/DockerIntegrationTests.swift`

1. **Success scenario**: Command exits with 0 after delay
2. **Timeout scenario**: Command never succeeds
3. **Real-world example**: PostgreSQL `pg_isready`
4. **Real-world example**: MySQL `mysqladmin ping`
5. **Shell command**: Test with `sh -c` for complex commands
6. **Fast success**: Command succeeds immediately

### Manual Testing

1. Test with various container images (Alpine, PostgreSQL, MySQL, Redis)
2. Test with custom application health checks
3. Verify error messages are clear and actionable
4. Test with very short timeouts (< 1 second)
5. Test with long-running health checks

## Acceptance Criteria

### Functional

- [x] `WaitStrategy.exec` case added to enum with command, timeout, and pollInterval parameters
- [x] `DockerClient.exec()` method executes commands and returns exit code
- [x] `Container.waitUntilReady()` handles exec wait strategy
- [x] Polling continues until command exits with code 0
- [x] Timeout error thrown when command doesn't succeed within timeout
- [x] Default timeout is 60 seconds
- [x] Default poll interval is 200ms

### Code Quality

- [x] Follows existing code patterns (same structure as tcpPort and logContains)
- [x] Proper error handling with descriptive messages
- [x] `Sendable` and `Hashable` conformance maintained
- [x] No new compiler warnings

### Testing

- [x] Unit tests verify configuration and parameters
- [x] Integration tests verify success and timeout scenarios
- [x] Real-world examples tested (PostgreSQL)
- [ ] All tests pass in CI/CD pipeline (pending CI run)

### Documentation

- [x] API documentation added for new enum case (inline in code)
- [x] Usage examples provided (in this document)
- [ ] README updated with exec wait strategy examples
- [x] Notes about command availability in containers (in this document)

## Open Questions

1. **Command output**: Should we optionally capture stdout/stderr for debugging?
   - **Recommendation**: No, keep it simple initially. Can add in a future enhancement.

2. **Working directory**: Should we support specifying a working directory for exec?
   - **Recommendation**: No, use `docker exec` defaults. Can add later if needed.

3. **Environment variables**: Should exec commands inherit container environment?
   - **Recommendation**: Yes, they do by default with `docker exec`.

4. **User specification**: Should we support running as a specific user?
   - **Recommendation**: No, run as container's default user. Can add later if needed.

5. **Multiple commands**: Should we support OR logic (any of multiple commands succeeds)?
   - **Recommendation**: No, keep it simple. Users can write shell scripts for complex logic.

## Risks and Mitigations

### Risk: Command Not Found

**Impact**: Commands might not exist in all container images.

**Mitigation**:
- Document that commands must be available in the container
- Provide clear error messages
- Recommend testing with container's actual image

### Risk: Command Hangs

**Impact**: Command might hang indefinitely, blocking the wait strategy.

**Mitigation**:
- The poll interval timeout in `Waiter.wait()` already handles this
- Each `docker exec` call is independent, so a hung command won't affect subsequent attempts
- Overall timeout will eventually trigger

### Risk: Performance Overhead

**Impact**: Executing commands repeatedly might be expensive.

**Mitigation**:
- Use reasonable default poll interval (200ms)
- Allow users to configure poll interval based on their needs
- Docker exec is generally fast for simple commands

## Future Enhancements

1. **Exec options**: Support for working directory, user, environment variables
2. **Output capturing**: Optionally capture and log command output for debugging
3. **Exit code ranges**: Accept any exit code in a specified range (not just 0)
4. **Regex matching**: Match stdout/stderr against regex patterns
5. **Composite strategies**: Combine multiple wait strategies (AND/OR logic)

## References

- **Existing code**: `/Sources/TestContainers/Container.swift` (lines 36-52)
- **Wait infrastructure**: `/Sources/TestContainers/Waiter.swift`
- **Docker client**: `/Sources/TestContainers/DockerClient.swift`
- **Process execution**: `/Sources/TestContainers/ProcessRunner.swift`
- **Similar projects**:
  - Testcontainers Java: `WaitForExecStrategy`
  - Testcontainers Go: `exec.WaitStrategy`
