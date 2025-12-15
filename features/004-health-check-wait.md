# Feature 004: Health Check Wait Strategy

**Status: ✅ IMPLEMENTED**

## Summary

Implement a `.healthCheck()` wait strategy that polls Docker's built-in HEALTHCHECK status until the container reports as healthy. This leverages the `HEALTHCHECK` directive defined in Dockerfiles or passed via `--health-cmd` at runtime, allowing tests to wait for containers that have native health monitoring configured.

**Use case:** Many production Docker images (postgres, redis, nginx, etc.) include HEALTHCHECK instructions. This strategy provides a Docker-native way to determine when a container is truly ready, often more reliable than TCP or log-based strategies.

## Current State

The library currently supports three wait strategies (defined in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`):

```swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration, pollInterval: Duration)
    case logContains(String, timeout: Duration, pollInterval: Duration)
}
```

Wait strategies are executed in `Container.waitUntilReady()` (in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`), which uses the `Waiter` utility to poll until the condition is met or a timeout occurs.

### How existing strategies work:

1. **`.tcpPort`**: Resolves the container port to a host port using `docker port`, then uses `TCPProbe` to attempt TCP connections until successful.
2. **`.logContains`**: Calls `docker logs <id>` repeatedly and checks if the output contains a specific string.
3. **`.none`**: Returns immediately without waiting.

All strategies follow the same pattern:
- Accept configurable `timeout: Duration` (default 60s) and `pollInterval: Duration` (default 200ms)
- Use `Waiter.wait()` to poll a predicate
- Throw `TestContainersError.timeout()` on timeout

## Requirements

### Functional Requirements

1. **Poll Docker health status**: Use `docker inspect` to query the container's health status
2. **Health status detection**: Parse JSON output to extract `.State.Health.Status` field
3. **Wait until healthy**: Continue polling until status is `"healthy"`
4. **Timeout handling**: Respect configurable timeout with appropriate error message
5. **Poll interval**: Use configurable poll interval between checks
6. **Handle missing health checks**: Fail fast with clear error if container has no HEALTHCHECK configured
7. **Status awareness**: Distinguish between:
   - `starting` - initial state, keep waiting
   - `healthy` - success, return
   - `unhealthy` - container failed health check, consider timeout or fail immediately
   - `null`/missing - no health check configured, fail with descriptive error

### Non-Functional Requirements

1. **Consistency**: API should match existing wait strategy patterns
2. **Performance**: Minimize overhead from JSON parsing
3. **Error messages**: Provide clear diagnostics when health check fails or is missing
4. **Testability**: Design to allow both unit and integration testing

## API Design

### Proposed Addition to WaitStrategy

```swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case healthCheck(timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
}
```

### Usage Example

```swift
let request = ContainerRequest(image: "postgres:16")
    .withEnvironment(["POSTGRES_PASSWORD": "secret"])
    .withExposedPort(5432)
    .waitingFor(.healthCheck(timeout: .seconds(120)))

try await withContainer(request) { container in
    // Container is healthy and ready to use
    let endpoint = try await container.endpoint(for: 5432)
    // ... run tests
}
```

### Alternative: Support custom health check command (future enhancement)

```swift
// Phase 2: Allow specifying health check at runtime
case healthCheck(
    timeout: Duration = .seconds(60),
    pollInterval: Duration = .milliseconds(200),
    command: [String]? = nil  // Override/add health check command
)
```

## Implementation Steps

### Step 1: Add Docker inspect method to DockerClient

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Add a new method to query container health status:

```swift
struct ContainerHealthStatus: Sendable {
    enum Status: String, Sendable {
        case starting
        case healthy
        case unhealthy
    }

    let status: Status?
    let hasHealthCheck: Bool
}

func healthStatus(id: String) async throws -> ContainerHealthStatus {
    let output = try await runDocker([
        "inspect",
        "--format", "{{json .State.Health}}",
        id
    ])
    return try parseHealthStatus(output.stdout)
}

private func parseHealthStatus(_ json: String) throws -> ContainerHealthStatus {
    // Parse JSON to extract health status
    // Handle cases: null (no healthcheck), {Status: "starting|healthy|unhealthy"}
    // Implementation details TBD based on JSON parsing approach
}
```

**Considerations:**
- Use `Foundation.JSONDecoder` for parsing (already imported)
- The format `{{json .State.Health}}` returns `null` if no health check exists
- Create minimal decodable struct to extract just the `Status` field

### Step 2: Add healthCheck case to WaitStrategy enum

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

```swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case healthCheck(timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
}
```

### Step 3: Implement health check wait logic in Container

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

Add a new case to the `waitUntilReady()` switch statement:

```swift
case let .healthCheck(timeout, pollInterval):
    // First check if container has health check configured
    let initialStatus = try await docker.healthStatus(id: id)
    guard initialStatus.hasHealthCheck else {
        throw TestContainersError.healthCheckNotConfigured(
            "Container \(id) does not have a HEALTHCHECK configured. " +
            "Ensure the image has a HEALTHCHECK instruction or specify one via --health-cmd."
        )
    }

    try await Waiter.wait(
        timeout: timeout,
        pollInterval: pollInterval,
        description: "container health status to be 'healthy'"
    ) { [docker, id] in
        let status = try await docker.healthStatus(id: id)

        // If status becomes unhealthy, we could optionally fail fast
        // For now, keep waiting (timeout will eventually trigger)

        return status.status == .healthy
    }
```

### Step 4: Add new error case to TestContainersError

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    case dockerNotAvailable(String)
    case commandFailed(command: [String], exitCode: Int32, stdout: String, stderr: String)
    case unexpectedDockerOutput(String)
    case timeout(String)
    case healthCheckNotConfigured(String)  // NEW

    public var description: String {
        switch self {
        // ... existing cases ...
        case let .healthCheckNotConfigured(message):
            return "Health check not configured: \(message)"
        }
    }
}
```

### Step 5: Documentation

Update inline documentation for the new wait strategy enum case with usage examples and requirements.

## Testing Plan

### Unit Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

Add test to verify wait strategy can be configured:

```swift
@Test func configuresHealthCheckWaitStrategy() {
    let request = ContainerRequest(image: "postgres:16")
        .waitingFor(.healthCheck(timeout: .seconds(120), pollInterval: .milliseconds(500)))

    #expect(request.waitStrategy == .healthCheck(timeout: .seconds(120), pollInterval: .milliseconds(500)))
}

@Test func healthCheckWaitStrategy_usesDefaultValues() {
    let request = ContainerRequest(image: "postgres:16")
        .waitingFor(.healthCheck())

    #expect(request.waitStrategy == .healthCheck(timeout: .seconds(60), pollInterval: .milliseconds(200)))
}
```

### Integration Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

Add integration tests that run when `TESTCONTAINERS_RUN_DOCKER_TESTS=1`:

```swift
@Test func healthCheckWaitStrategy_withPostgres() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Postgres 16+ includes built-in HEALTHCHECK
    let request = ContainerRequest(image: "postgres:16")
        .withEnvironment(["POSTGRES_PASSWORD": "test"])
        .withExposedPort(5432)
        .waitingFor(.healthCheck(timeout: .seconds(60)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(5432)
        #expect(port > 0)

        // Container should be healthy at this point
        let logs = try await container.logs()
        #expect(logs.contains("database system is ready to accept connections"))
    }
}

@Test func healthCheckWaitStrategy_failsWithoutHealthCheck() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Alpine has no HEALTHCHECK
    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .waitingFor(.healthCheck())

    await #expect(throws: TestContainersError.healthCheckNotConfigured("")) {
        try await withContainer(request) { _ in }
    }
}

@Test func healthCheckWaitStrategy_timeoutIfUnhealthy() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Container with health check that always fails
    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        // TODO: Need to figure out how to set health-cmd via docker run
        // May need to add support for --health-cmd flag in ContainerRequest
        .waitingFor(.healthCheck(timeout: .seconds(5)))

    // Should timeout because health check never becomes healthy
    await #expect(throws: TestContainersError.timeout("")) {
        try await withContainer(request) { _ in }
    }
}
```

### Test Container Images

Need Docker images with HEALTHCHECK for testing:

1. **With built-in health check**: `postgres:16`, `nginx:alpine`, `redis:7-alpine`
2. **Without health check**: `alpine:3`, `ubuntu:22.04`
3. **Custom health check** (future): Build test image with Dockerfile:
   ```dockerfile
   FROM alpine:3
   HEALTHCHECK --interval=1s --timeout=1s --retries=3 \
     CMD test -f /tmp/healthy || exit 1
   CMD ["sh", "-c", "sleep 2 && touch /tmp/healthy && sleep 100"]
   ```

## Acceptance Criteria

### Feature Complete When:

- [x] `WaitStrategy.healthCheck(timeout:pollInterval:)` enum case added
- [x] `DockerClient.healthStatus(id:)` method implemented
- [x] `Container.waitUntilReady()` handles `.healthCheck` case
- [x] `TestContainersError.healthCheckNotConfigured` error case added
- [x] JSON parsing correctly extracts health status from `docker inspect`
- [x] Container without HEALTHCHECK fails fast with clear error message
- [x] Container with `starting` status continues polling
- [x] Container with `healthy` status returns successfully
- [x] Timeout is respected and throws appropriate error
- [x] Poll interval is respected between checks

### Testing Complete When:

- [x] Unit tests verify wait strategy configuration
- [x] Integration test passes with runtime health check (using `withHealthCheck()`)
- [x] Integration test fails appropriately with `alpine:3` (no HEALTHCHECK)
- [x] All tests pass in CI environment

### Documentation Complete When:

- [x] Inline documentation added to enum case
- [x] Error messages are clear and actionable

### Additional Features Implemented:

- [x] `HealthCheckConfig` struct for runtime health check configuration
- [x] `withHealthCheck()` builder method supporting `--health-cmd`, `--health-interval`, etc.
- [x] Unit tests for JSON parsing logic

## References

### Docker Health Check Documentation
- Docker HEALTHCHECK: https://docs.docker.com/engine/reference/builder/#healthcheck
- Docker inspect format: `docker inspect --format '{{json .State.Health}}' <container>`

### Existing Code References
- **Wait strategy enum**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` (lines 20-24)
- **Wait implementation**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift` (lines 36-52)
- **Waiter utility**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift` (lines 3-20)
- **DockerClient methods**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`
- **Error definitions**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

### Similar Implementations
- testcontainers-go: `wait.ForHealthCheck()` strategy
- testcontainers-java: `Wait.forHealthcheck()` strategy

## Implementation Notes

### Health Status JSON Format

The output of `docker inspect --format '{{json .State.Health}}'` looks like:

**Container with health check:**
```json
{
  "Status": "healthy",
  "FailingStreak": 0,
  "Log": [...]
}
```

**Container without health check:**
```
null
```

### Parsing Approach

Use Foundation's JSONDecoder with optional properties:

```swift
private struct HealthCheckResponse: Decodable {
    let Status: String?
}

func parseHealthStatus(_ json: String) throws -> ContainerHealthStatus {
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)

    // Handle "null" case (no health check)
    if trimmed == "null" {
        return ContainerHealthStatus(status: nil, hasHealthCheck: false)
    }

    let data = Data(trimmed.utf8)
    let response = try JSONDecoder().decode(HealthCheckResponse.self, from: data)

    guard let statusString = response.Status else {
        return ContainerHealthStatus(status: nil, hasHealthCheck: false)
    }

    let status = ContainerHealthStatus.Status(rawValue: statusString)
    return ContainerHealthStatus(status: status, hasHealthCheck: true)
}
```

### Edge Cases to Handle

1. **Container exits before becoming healthy**: Will likely fail with docker inspect error, which will propagate as `commandFailed`
2. **Health check exists but status is nil**: Treat as missing health check
3. **Unknown status values**: If Docker adds new status types, treat as "keep waiting" (until timeout)
4. **Unhealthy status**: Current design keeps waiting (relies on timeout). Could add option to fail fast.

### Future Enhancements

1. **Fail fast on unhealthy**: Add parameter to immediately throw when status becomes `unhealthy`
2. ~~**Runtime health command**: Support `--health-cmd` flag in ContainerRequest~~ ✅ Implemented via `withHealthCheck()`
3. ~~**Health check configuration**: Expose `--health-interval`, `--health-timeout`, `--health-retries`, `--health-start-period`~~ ✅ Implemented via `HealthCheckConfig`
4. **Include health check logs in error**: On timeout, include the last health check log entry for debugging

## Priority & Effort Estimate

**Priority**: Tier 1 (High Priority - listed in FEATURES.md line 38)

**Effort Estimate**:
- Implementation: 4-6 hours
- Testing: 2-3 hours
- Documentation: 1 hour
- **Total**: 1-2 days

**Dependencies**: None - can be implemented independently

**Complexity**: Medium
- JSON parsing is straightforward with Foundation
- Pattern matches existing wait strategies
- Main complexity is handling edge cases (missing health check, various statuses)
