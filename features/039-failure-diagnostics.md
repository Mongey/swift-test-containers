# Feature 039: Enhanced Failure Diagnostics

## Summary

Enhance error reporting in swift-test-containers by automatically capturing and including diagnostic information when container operations fail. When timeouts occur or containers fail to start, include the last N lines of container logs, container state information, and relevant Docker metadata to help developers quickly diagnose issues without manually inspecting containers.

**Use case:** When a container fails to become ready or times out during wait strategies, developers currently receive minimal context. They must manually run `docker logs` and `docker inspect` to diagnose the issue. This feature automatically captures and surfaces this diagnostic information in error messages, significantly improving the debugging experience.

## Current State

### Error Handling Architecture

The current error handling is defined in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`:

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    case dockerNotAvailable(String)
    case commandFailed(command: [String], exitCode: Int32, stdout: String, stderr: String)
    case unexpectedDockerOutput(String)
    case timeout(String)

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
        }
    }
}
```

### Current Timeout Handling

Timeouts are thrown from `Waiter.wait()` in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift`:

```swift
enum Waiter {
    static func wait(
        timeout: Duration,
        pollInterval: Duration,
        description: String,
        _ predicate: @Sendable () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            if try await predicate() { return }
            if start.duration(to: clock.now) >= timeout {
                throw TestContainersError.timeout(description)
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}
```

Wait strategies call this from `Container.waitUntilReady()` in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`:

```swift
func waitUntilReady() async throws {
    switch request.waitStrategy {
    case .none:
        return
    case let .logContains(needle, timeout, pollInterval):
        try await Waiter.wait(timeout: timeout, pollInterval: pollInterval,
                             description: "container logs to contain '\(needle)'") {
            let text = try await docker.logs(id: id)
            return text.contains(needle)
        }
    case let .tcpPort(containerPort, timeout, pollInterval):
        let hostPort = try await docker.port(id: id, containerPort: containerPort)
        let host = request.host
        try await Waiter.wait(timeout: timeout, pollInterval: pollInterval,
                             description: "TCP port \(host):\(hostPort) to accept connections") {
            TCPProbe.canConnect(host: host, port: hostPort, timeout: .milliseconds(200))
        }
    }
}
```

### Available Docker Operations

The `DockerClient` actor (in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`) provides:

- `logs(id: String) async throws -> String` - Fetches all container logs
- `runDocker(_ args: [String]) async throws -> CommandOutput` - Executes arbitrary docker commands
- No current support for `docker inspect` or log tailing

### Current Error Messages

Example current timeout error:
```
Timed out: container logs to contain 'ready'
```

Problems with current approach:
- No container logs included
- No container state information (running, exited, exit code)
- No image or configuration details
- Developers must manually inspect containers that may have already been removed
- Container cleanup happens before diagnostics can be collected

## Requirements

### Core Functionality

1. **Automatic Log Capture on Timeout**
   - Capture last N lines of container logs when timeout occurs
   - Default to 50 lines, configurable
   - Include both stdout and stderr
   - Handle cases where logs are empty or unavailable

2. **Container State Information**
   - Capture container state via `docker inspect`
   - Include: running status, exit code (if stopped), restart count
   - Include OOMKilled status and other critical state flags
   - Include health check status if available

3. **Enhanced Timeout Errors**
   - New `TestContainersError.timeoutWithDiagnostics` case
   - Include original timeout description
   - Include captured logs (last N lines)
   - Include container state information
   - Include image name and container ID for reference
   - Format output for readability

4. **Configurable Diagnostics**
   - Add `DiagnosticsConfig` to `ContainerRequest`
   - Configure log tail size (lines to capture)
   - Configure whether to capture state information
   - Option to disable diagnostics for performance-sensitive scenarios
   - Reasonable defaults that work for most cases

5. **Safe Diagnostic Collection**
   - Never fail the test just because diagnostic collection fails
   - Catch and log diagnostic collection errors
   - Continue with basic error if diagnostics unavailable
   - Don't delay cleanup significantly

6. **Diagnostic Collection on Other Failures**
   - Capture diagnostics when container fails to start
   - Capture diagnostics when wait strategy validation fails
   - Include diagnostics in `commandFailed` errors where relevant

### Non-Functional Requirements

1. **Performance**
   - Diagnostic collection should add minimal overhead to failure path
   - Async operations should not block unnecessarily
   - Limit log capture to prevent memory issues with verbose containers

2. **Usability**
   - Error messages should be readable and actionable
   - Include suggestions for common issues (port conflicts, missing environment variables)
   - Format logs with clear delimiters

3. **Maintainability**
   - Diagnostic collection should be centralized and reusable
   - Follow existing patterns in codebase
   - Support future diagnostic enhancements (metrics, events)

4. **Compatibility**
   - Work with Docker CLI output formats
   - Handle Docker Engine version differences gracefully
   - Cross-platform (macOS, Linux)

## API Design

### Enhanced Error Type

```swift
// Add to TestContainersError.swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    case dockerNotAvailable(String)
    case commandFailed(command: [String], exitCode: Int32, stdout: String, stderr: String)
    case unexpectedDockerOutput(String)
    case timeout(String)
    case timeoutWithDiagnostics(TimeoutDiagnostics)

    public var description: String {
        switch self {
        // ... existing cases ...
        case let .timeoutWithDiagnostics(diagnostics):
            return diagnostics.formatErrorMessage()
        }
    }
}

public struct TimeoutDiagnostics: Sendable {
    public let description: String
    public let containerId: String
    public let image: String
    public let containerState: ContainerState?
    public let recentLogs: String?
    public let logLineCount: Int

    public func formatErrorMessage() -> String {
        var message = "Timed out: \(description)\n"
        message += "\nContainer: \(containerId.prefix(12))"
        message += "\nImage: \(image)"

        if let state = containerState {
            message += "\n\nContainer State:"
            message += "\n  Status: \(state.status)"
            if let exitCode = state.exitCode {
                message += "\n  Exit Code: \(exitCode)"
            }
            if state.oomKilled {
                message += "\n  OOM Killed: true (container ran out of memory)"
            }
            if state.restartCount > 0 {
                message += "\n  Restart Count: \(state.restartCount)"
            }
            if let health = state.health {
                message += "\n  Health Status: \(health)"
            }
        }

        if let logs = recentLogs, !logs.isEmpty {
            message += "\n\nContainer Logs (last \(logLineCount) lines):"
            message += "\n" + String(repeating: "-", count: 80)
            message += "\n\(logs)"
            message += "\n" + String(repeating: "-", count: 80)
        } else {
            message += "\n\nContainer Logs: (empty or unavailable)"
        }

        message += "\n\nTroubleshooting:"
        message += "\n  - Check container logs above for errors"
        message += "\n  - Verify the container starts correctly with: docker run \(image)"
        if containerState?.status == "exited" {
            message += "\n  - Container exited; check exit code and logs for failure reason"
        }

        return message
    }
}

public struct ContainerState: Sendable {
    public let status: String  // "running", "exited", "created", etc.
    public let running: Bool
    public let exitCode: Int?
    public let oomKilled: Bool
    public let restartCount: Int
    public let health: String?  // "healthy", "unhealthy", "starting", or nil
}
```

### Diagnostics Configuration

```swift
// Add to ContainerRequest.swift
public struct DiagnosticsConfig: Sendable, Hashable {
    public var captureLogsOnFailure: Bool
    public var logTailLines: Int
    public var captureStateOnFailure: Bool
    public var maxLogCaptureDuration: Duration

    public static let `default` = DiagnosticsConfig(
        captureLogsOnFailure: true,
        logTailLines: 50,
        captureStateOnFailure: true,
        maxLogCaptureDuration: .seconds(2)
    )

    public static let disabled = DiagnosticsConfig(
        captureLogsOnFailure: false,
        logTailLines: 0,
        captureStateOnFailure: false,
        maxLogCaptureDuration: .seconds(0)
    )

    public static let verbose = DiagnosticsConfig(
        captureLogsOnFailure: true,
        logTailLines: 200,
        captureStateOnFailure: true,
        maxLogCaptureDuration: .seconds(5)
    )

    public init(
        captureLogsOnFailure: Bool = true,
        logTailLines: Int = 50,
        captureStateOnFailure: Bool = true,
        maxLogCaptureDuration: Duration = .seconds(2)
    ) {
        self.captureLogsOnFailure = captureLogsOnFailure
        self.logTailLines = max(0, logTailLines)
        self.captureStateOnFailure = captureStateOnFailure
        self.maxLogCaptureDuration = maxLogCaptureDuration
    }
}

// Add to ContainerRequest struct
public struct ContainerRequest: Sendable, Hashable {
    // ... existing fields ...
    public var diagnostics: DiagnosticsConfig

    public init(image: String) {
        // ... existing initialization ...
        self.diagnostics = .default
    }

    public func withDiagnostics(_ config: DiagnosticsConfig) -> Self {
        var copy = self
        copy.diagnostics = config
        return copy
    }

    public func withLogTailLines(_ lines: Int) -> Self {
        var copy = self
        copy.diagnostics.logTailLines = lines
        return copy
    }
}
```

### Docker Client Enhancements

```swift
// Add to DockerClient.swift
extension DockerClient {
    /// Fetches the last N lines of container logs
    func logsTail(id: String, lines: Int) async throws -> String {
        let output = try await runDocker(["logs", "--tail", "\(lines)", id])
        return output.stdout
    }

    /// Fetches container state information via docker inspect
    func inspectState(id: String) async throws -> ContainerState {
        let output = try await runDocker([
            "inspect",
            "--format",
            "{{json .State}}",
            id
        ])
        return try parseContainerState(output.stdout)
    }

    private func parseContainerState(_ json: String) throws -> ContainerState {
        // Parse JSON output from docker inspect
        // Handle fields: Status, Running, ExitCode, OOMKilled, RestartCount, Health.Status
        guard let data = json.data(using: .utf8) else {
            throw TestContainersError.unexpectedDockerOutput("Invalid UTF-8 in inspect output")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromPascalCase

        let state = try decoder.decode(InspectState.self, from: data)

        return ContainerState(
            status: state.status,
            running: state.running,
            exitCode: state.exitCode,
            oomKilled: state.oomKilled,
            restartCount: state.restartCount,
            health: state.health?.status
        )
    }
}

// Internal struct for JSON decoding
private struct InspectState: Decodable {
    let status: String
    let running: Bool
    let exitCode: Int?
    let oomKilled: Bool
    let restartCount: Int
    let health: HealthStatus?

    struct HealthStatus: Decodable {
        let status: String
    }

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case running = "Running"
        case exitCode = "ExitCode"
        case oomKilled = "OOMKilled"
        case restartCount = "RestartCount"
        case health = "Health"
    }
}
```

### Diagnostic Collection Utility

```swift
// New file: Sources/TestContainers/DiagnosticCollector.swift
actor DiagnosticCollector {
    private let docker: DockerClient

    init(docker: DockerClient) {
        self.docker = docker
    }

    /// Collects diagnostic information from a container
    func collectDiagnostics(
        containerId: String,
        image: String,
        config: DiagnosticsConfig,
        timeoutDescription: String
    ) async -> TimeoutDiagnostics {
        var containerState: ContainerState?
        var recentLogs: String?

        // Collect with timeout to prevent hanging on diagnostic collection
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    guard config.captureStateOnFailure else { return }
                    containerState = try? await self.docker.inspectState(id: containerId)
                }

                group.addTask {
                    guard config.captureLogsOnFailure, config.logTailLines > 0 else { return }
                    recentLogs = try? await self.docker.logsTail(id: containerId, lines: config.logTailLines)
                }

                // Wait for all tasks or timeout
                try await withTimeout(config.maxLogCaptureDuration) {
                    try await group.waitForAll()
                }
            }
        } catch {
            // Diagnostic collection failed, but don't propagate the error
            // We'll return whatever we managed to collect
        }

        return TimeoutDiagnostics(
            description: timeoutDescription,
            containerId: containerId,
            image: image,
            containerState: containerState,
            recentLogs: recentLogs,
            logLineCount: config.logTailLines
        )
    }
}

// Helper for timeout
private func withTimeout<T>(
    _ duration: Duration,
    operation: @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError()
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private struct TimeoutError: Error {}
```

### Enhanced Waiter with Diagnostics

```swift
// Update Waiter.swift to support diagnostic collection
enum Waiter {
    static func wait(
        timeout: Duration,
        pollInterval: Duration,
        description: String,
        _ predicate: @Sendable () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            if try await predicate() { return }
            if start.duration(to: clock.now) >= timeout {
                throw TestContainersError.timeout(description)
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    // New overload for wait strategies that can provide diagnostics
    static func waitWithDiagnostics(
        timeout: Duration,
        pollInterval: Duration,
        description: String,
        onTimeout: @Sendable () async -> TimeoutDiagnostics,
        _ predicate: @Sendable () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            if try await predicate() { return }
            if start.duration(to: clock.now) >= timeout {
                let diagnostics = await onTimeout()
                throw TestContainersError.timeoutWithDiagnostics(diagnostics)
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}
```

### Updated Container Wait Logic

```swift
// Update Container.swift to use diagnostic-enabled waiting
func waitUntilReady() async throws {
    let diagnosticCollector = DiagnosticCollector(docker: docker)

    switch request.waitStrategy {
    case .none:
        return

    case let .logContains(needle, timeout, pollInterval):
        try await Waiter.waitWithDiagnostics(
            timeout: timeout,
            pollInterval: pollInterval,
            description: "container logs to contain '\(needle)'"
        ) {
            await diagnosticCollector.collectDiagnostics(
                containerId: id,
                image: request.image,
                config: request.diagnostics,
                timeoutDescription: "waiting for log message '\(needle)'"
            )
        } predicate: {
            let text = try await docker.logs(id: id)
            return text.contains(needle)
        }

    case let .tcpPort(containerPort, timeout, pollInterval):
        let hostPort = try await docker.port(id: id, containerPort: containerPort)
        let host = request.host

        try await Waiter.waitWithDiagnostics(
            timeout: timeout,
            pollInterval: pollInterval,
            description: "TCP port \(host):\(hostPort) to accept connections"
        ) {
            await diagnosticCollector.collectDiagnostics(
                containerId: id,
                image: request.image,
                config: request.diagnostics,
                timeoutDescription: "waiting for TCP port \(host):\(hostPort)"
            )
        } predicate: {
            TCPProbe.canConnect(host: host, port: hostPort, timeout: .milliseconds(200))
        }
    }
}
```

### Usage Examples

```swift
// Default behavior - diagnostics automatically included
let request = ContainerRequest(image: "postgres:16")
    .withEnvironment(["POSTGRES_PASSWORD": "secret"])
    .withExposedPort(5432)
    .waitingFor(.tcpPort(5432, timeout: .seconds(30)))

try await withContainer(request) { container in
    // If timeout occurs, error will include:
    // - Last 50 lines of logs
    // - Container state (running/exited/exit code)
    // - Image name and container ID
}

// Custom diagnostics configuration
let request = ContainerRequest(image: "myapp:latest")
    .withExposedPort(8080)
    .waitingFor(.logContains("Server started", timeout: .seconds(60)))
    .withLogTailLines(100)  // Capture more log lines

// Disable diagnostics for performance
let request = ContainerRequest(image: "redis:7")
    .withExposedPort(6379)
    .waitingFor(.tcpPort(6379))
    .withDiagnostics(.disabled)

// Verbose diagnostics for debugging
let request = ContainerRequest(image: "complex-app:latest")
    .withExposedPort(8080)
    .waitingFor(.logContains("ready"))
    .withDiagnostics(.verbose)  // 200 lines of logs, longer timeout
```

### Example Error Output

Before (current):
```
Timed out: container logs to contain 'Server started'
```

After (with diagnostics):
```
Timed out: container logs to contain 'Server started'

Container: a3b2c1d4e5f6
Image: myapp:latest

Container State:
  Status: exited
  Exit Code: 1
  OOM Killed: false
  Restart Count: 0

Container Logs (last 50 lines):
--------------------------------------------------------------------------------
2025-12-15 10:30:22 INFO  Starting application...
2025-12-15 10:30:23 INFO  Loading configuration from /app/config.yml
2025-12-15 10:30:23 ERROR Failed to connect to database: connection refused
2025-12-15 10:30:23 ERROR Required environment variable DB_HOST not set
2025-12-15 10:30:23 FATAL Startup failed, exiting
--------------------------------------------------------------------------------

Troubleshooting:
  - Check container logs above for errors
  - Verify the container starts correctly with: docker run myapp:latest
  - Container exited; check exit code and logs for failure reason
```

## Implementation Steps

### Step 1: Extend TestContainersError

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

- Add `TimeoutDiagnostics` struct with all diagnostic fields
- Add `ContainerState` struct for container state information
- Add `.timeoutWithDiagnostics(TimeoutDiagnostics)` case to error enum
- Implement `formatErrorMessage()` with readable formatting
- Include troubleshooting hints based on state
- Add tests for error formatting

### Step 2: Add DiagnosticsConfig to ContainerRequest

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

- Define `DiagnosticsConfig` struct with configuration options
- Add predefined configs: `.default`, `.disabled`, `.verbose`
- Add `diagnostics` field to `ContainerRequest`
- Add builder methods: `withDiagnostics()`, `withLogTailLines()`
- Ensure `Sendable` and `Hashable` conformance
- Document configuration options

### Step 3: Enhance DockerClient with Diagnostic Methods

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

- Add `logsTail(id:lines:)` method using `docker logs --tail`
- Add `inspectState(id:)` method using `docker inspect --format`
- Add JSON parsing for container state
- Define internal `InspectState` struct for decoding
- Handle missing or null fields gracefully
- Add error handling for invalid JSON
- Test with various container states

**Key implementation details:**
- Use `--format '{{json .State}}'` for structured output
- Handle both running and stopped containers
- Parse health status only if present
- Use `JSONDecoder` with `KeyDecodingStrategy.convertFromPascalCase`

### Step 4: Create DiagnosticCollector

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DiagnosticCollector.swift`

- Implement `DiagnosticCollector` actor
- Add `collectDiagnostics()` method with timeout protection
- Parallel collection of state and logs using `TaskGroup`
- Timeout wrapper to prevent hanging
- Graceful degradation if collection fails
- Return partial diagnostics if some operations fail
- Never throw errors from diagnostic collection

**Key implementation details:**
- Use structured concurrency for parallel collection
- Apply `maxLogCaptureDuration` timeout
- Catch all errors and continue with partial results
- Log diagnostic collection failures for debugging

### Step 5: Enhance Waiter with Diagnostic Support

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift`

- Keep existing `wait()` method for backward compatibility
- Add new `waitWithDiagnostics()` method
- Accept `onTimeout` closure that provides diagnostics
- Call closure only when timeout occurs
- Throw enhanced error with diagnostics

**Backward compatibility:**
- Existing wait strategies can continue using `wait()`
- New strategies use `waitWithDiagnostics()`
- No breaking changes to public API

### Step 6: Update Container.waitUntilReady()

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

- Create `DiagnosticCollector` instance
- Update each wait strategy case to use `waitWithDiagnostics()`
- Provide diagnostic collection closures for each strategy
- Include strategy-specific context in diagnostics
- Maintain existing behavior for `.none` case

**Implementation for each strategy:**
- `.logContains`: Include expected vs actual log content hints
- `.tcpPort`: Include port and connectivity information
- Future strategies: Custom diagnostic context

### Step 7: Add Unit Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DiagnosticsTests.swift`

Test coverage:
- `DiagnosticsConfig` defaults and builders
- `TimeoutDiagnostics` formatting with various states
- `ContainerState` representation
- Error message formatting readability
- Edge cases: empty logs, missing state, null health

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DiagnosticCollectorTests.swift`

Test coverage:
- Successful diagnostic collection
- Partial collection when logs fail
- Partial collection when inspect fails
- Timeout during collection
- Empty logs handling
- Missing health check handling

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerClientDiagnosticsTests.swift`

Test coverage:
- `logsTail()` with various line counts
- `inspectState()` JSON parsing
- Handle exited containers
- Handle running containers
- Handle containers with health checks
- Handle OOMKilled containers
- Handle malformed JSON gracefully

### Step 8: Add Integration Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/FailureDiagnosticsIntegrationTests.swift`

Test scenarios:
- Container that exits immediately (capture exit code and logs)
- Container with timeout on TCP wait (capture running state)
- Container with timeout on log wait (capture actual logs)
- Container with custom diagnostics config
- Container with diagnostics disabled
- Verbose diagnostics configuration

**Example tests:**
```swift
@Test func diagnostics_containerExitsImmediately() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Container that exits immediately due to missing env var
    let request = ContainerRequest(image: "postgres:16")
        .withExposedPort(5432)
        .waitingFor(.tcpPort(5432, timeout: .seconds(5)))

    await #expect(throws: TestContainersError.timeoutWithDiagnostics(_:)) {
        try await withContainer(request) { _ in }
    }

    // Verify error includes diagnostics
    do {
        try await withContainer(request) { _ in }
    } catch let TestContainersError.timeoutWithDiagnostics(diag) {
        #expect(diag.containerState?.status == "exited")
        #expect(diag.containerState?.exitCode != nil)
        #expect(diag.recentLogs?.contains("database") == true)
    }
}

@Test func diagnostics_timeoutIncludesLogs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Container that runs but never becomes "ready"
    let request = ContainerRequest(image: "nginx:latest")
        .withExposedPort(80)
        .waitingFor(.logContains("NEVER_APPEARS", timeout: .seconds(3)))
        .withLogTailLines(10)

    do {
        try await withContainer(request) { _ in }
        Issue.record("Should have timed out")
    } catch let TestContainersError.timeoutWithDiagnostics(diag) {
        #expect(diag.recentLogs != nil)
        #expect(diag.containerState?.running == true)
        #expect(diag.logLineCount == 10)
    }
}

@Test func diagnostics_canBeDisabled() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "nginx:latest")
        .withExposedPort(80)
        .waitingFor(.logContains("NEVER", timeout: .seconds(2)))
        .withDiagnostics(.disabled)

    do {
        try await withContainer(request) { _ in }
    } catch {
        // Should get basic timeout error, not diagnostics
        #expect(error as? TestContainersError == .timeout(_:))
    }
}
```

### Step 9: Documentation

- Add doc comments to all public APIs
- Document `DiagnosticsConfig` options and tradeoffs
- Update README.md with diagnostics section
- Add examples of error output
- Document how to interpret diagnostic information
- Add troubleshooting guide for common errors

**README additions:**
- Section on "Error Diagnostics"
- Examples of enhanced error messages
- How to configure diagnostic collection
- Performance considerations

## Testing Plan

### Unit Tests

1. **DiagnosticsConfig Tests**
   - Default values are correct
   - Builder methods work correctly
   - Predefined configs (.default, .disabled, .verbose)
   - Validation (e.g., negative line counts become 0)

2. **TimeoutDiagnostics Formatting Tests**
   - Message includes all components
   - Handles nil state gracefully
   - Handles nil logs gracefully
   - Formatting is readable
   - Troubleshooting hints are appropriate
   - Edge cases: very long logs, special characters

3. **ContainerState Tests**
   - All fields correctly represented
   - Optional fields handled correctly
   - String formatting matches Docker output

4. **DockerClient Diagnostic Methods Tests**
   - `logsTail()` returns correct number of lines
   - `logsTail()` handles empty logs
   - `inspectState()` parses running containers
   - `inspectState()` parses exited containers
   - `inspectState()` handles missing health
   - `inspectState()` handles OOMKilled
   - JSON parsing errors handled gracefully

5. **DiagnosticCollector Tests**
   - Successful collection of all diagnostics
   - Partial success when logs fail
   - Partial success when inspect fails
   - Timeout protection works
   - No errors thrown on collection failure
   - Config respected (disabled, line counts)

6. **Waiter Tests**
   - `waitWithDiagnostics()` calls onTimeout
   - `waitWithDiagnostics()` includes diagnostics in error
   - Original `wait()` still works (backward compatibility)
   - Timing is correct

### Integration Tests

1. **Failing Container Tests**
   - Container that exits immediately
   - Error includes exit code
   - Error includes failure logs
   - Container state shows "exited"

2. **Timeout Tests**
   - TCP port timeout includes diagnostics
   - Log contains timeout includes diagnostics
   - Diagnostics show running container
   - Logs are captured and included

3. **Configuration Tests**
   - Custom line count respected
   - Disabled diagnostics omits extra info
   - Verbose config captures more data
   - Default config works as expected

4. **Edge Cases**
   - Container with no logs
   - Container that never starts
   - Container removed before diagnostics
   - Very verbose container (log truncation)

5. **Real-World Scenarios**
   - PostgreSQL without password (exits with error)
   - Redis timeout (running but port not ready)
   - nginx custom config error (syntax error in logs)
   - Application with slow startup

### Manual Testing Checklist

- [ ] Test with containers that exit due to configuration errors
- [ ] Test with containers that timeout while running
- [ ] Verify error messages are readable and helpful
- [ ] Test on macOS and Linux
- [ ] Test with various Docker Engine versions
- [ ] Verify performance impact is minimal
- [ ] Test diagnostic collection timeout protection
- [ ] Verify logs are properly truncated
- [ ] Test with containers that have health checks
- [ ] Test with containers that OOM

## Acceptance Criteria

### Must Have

- [x] `TimeoutDiagnostics` struct implemented with all fields
- [x] `ContainerStateDiagnostics` struct implemented (reuses existing `ContainerInspection` for state)
- [x] `TestContainersError.timeoutWithDiagnostics` case added
- [x] Error message formatting implemented and readable
- [x] `DiagnosticsConfig` with reasonable defaults (`.default`, `.disabled`, `.verbose`)
- [x] Diagnostic collection in `Container.collectDiagnostics()` (uses existing `inspect()` + new `logsTail()`)
- [x] `DockerClient.logsTail()` method implemented
- [x] Container state retrieved via existing `DockerClient.inspect()` / `ContainerInspection`
- [x] JSON parsing for container state working (reuses existing `ContainerInspection.parse()`)
- [x] `Waiter.waitWithDiagnostics()` method implemented
- [x] All wait strategies use enhanced diagnostics (when enabled)
- [x] Diagnostic collection never fails the test (uses `try?`)
- [x] Builder methods for configuration added to `ContainerRequest` (`.withDiagnostics()`, `.withLogTailLines()`)
- [x] Unit tests (29 tests covering all diagnostic types and formatting)
- [x] Documentation in code (doc comments)
- [x] No breaking changes to existing API

### Should Have

- [x] Troubleshooting hints in error messages
- [x] Support for containers with health checks (via existing inspect)
- [x] OOMKilled detection and reporting
- [x] Graceful degradation on partial failures (uses `try?` for all diagnostic collection)
- [ ] Configuration presets (.default, .disabled, .verbose)
- [ ] Performance optimization (collection timeout)
- [ ] Integration tests for edge cases
- [ ] Manual testing on both platforms

### Nice to Have

- [ ] Suggest common fixes based on error patterns
- [ ] Include container start time in diagnostics
- [ ] Include environment variable info (sanitized)
- [ ] Include port mapping info in diagnostics
- [ ] Metrics on diagnostic collection time
- [ ] Option to write diagnostics to file
- [ ] Include resource usage info (memory, CPU)
- [ ] Link to documentation for common errors

### Definition of Done

- All "Must Have" and "Should Have" criteria completed
- All tests passing on macOS and Linux
- Code review completed
- Documentation reviewed and accurate
- Error messages manually verified for readability
- Performance impact measured and acceptable (<100ms overhead)
- No regressions in existing functionality
- Follows existing code patterns and style
- All public APIs have comprehensive doc comments
- README updated with diagnostics examples
- Integration tests cover real failure scenarios
- Manual testing completed with at least 5 different failure scenarios

## Performance Considerations

### Diagnostic Collection Overhead

- Collection only happens on failure (happy path unaffected)
- Timeout protection prevents hanging (max 2 seconds default)
- Parallel collection of state and logs minimizes delay
- Configurable to disable if needed

### Memory Usage

- Log tail limits prevent unbounded memory growth
- Default 50 lines is ~2-5KB typical
- Verbose mode 200 lines is ~10-20KB typical
- State information is small (<1KB)

### Trade-offs

**Pros:**
- Dramatically improves debugging experience
- Saves developer time (no manual inspection needed)
- Catches information before container cleanup
- Configurable for different needs

**Cons:**
- Adds 0.5-2 seconds to failure path
- Minor memory overhead for diagnostic storage
- Additional Docker API calls on failure

**Mitigation:**
- Only collect on failure (not success)
- Timeout protection prevents runaway collection
- Option to disable entirely
- Parallel collection minimizes wall-clock time

## References

### Related Files

- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift` - Error types
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift` - Timeout mechanism
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift` - Wait strategy execution
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift` - Docker operations
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` - Request configuration

### Similar Implementations

- **Testcontainers Java**: Captures logs on failure via `ContainerState` and `LogConsumer`
- **Testcontainers Go**: Includes container logs in timeout errors via `StartupError`
- **Testcontainers Node**: Captures logs and state on failure via enhanced error messages
- **Docker Compose**: Shows logs on startup failures with `docker-compose up`

### Docker CLI References

- `docker logs --tail N <container>` - Tail last N lines
- `docker inspect --format '{{json .State}}' <container>` - Get container state
- `docker inspect --format '{{.State.Status}}' <container>` - Get status only
- Container states: `created`, `running`, `paused`, `restarting`, `removing`, `exited`, `dead`

### Swift API References

- `JSONDecoder` - JSON parsing
- `TaskGroup` - Parallel async operations
- `withTimeout` pattern - Timeout protection
- Structured concurrency - Error handling
