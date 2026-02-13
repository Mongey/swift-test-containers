# Feature: Structured Logging Hooks

## Summary

Implement a structured logging system for swift-test-containers that provides visibility into library operations including container lifecycle events, Docker command execution, wait strategy progress, and errors. The logging system should support multiple backends (OSLog, swift-log, custom handlers) while remaining completely optional to maintain zero-dependency philosophy for users who don't need logging.

## Current State

### No Logging Infrastructure

The codebase currently has **no logging capabilities**. Key operations happen silently:

1. **Docker CLI Invocations** (`/Sources/TestContainers/ProcessRunner.swift:10-42`): Process execution provides no visibility into commands being run or their timing.

2. **Container Lifecycle** (`/Sources/TestContainers/WithContainer.swift:3-30`): Container creation, waiting, operation execution, and cleanup happen without any diagnostic output.

3. **Wait Strategies** (`/Sources/TestContainers/Container.swift:36-52`): Polling loops provide no feedback on progress, retry attempts, or why waits might be taking longer than expected.

4. **Error Context** (`/Sources/TestContainers/TestContainersError.swift:1-22`): Errors include command details but no context about what the library was attempting when the error occurred.

### Existing Error Handling

The library uses a custom error enum that provides good error messages but lacks operational context:

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    case dockerNotAvailable(String)
    case commandFailed(command: [String], exitCode: Int32, stdout: String, stderr: String)
    case unexpectedDockerOutput(String)
    case timeout(String)
}
```

### Current Architecture

Key actors and types that would emit logs:

- **`DockerClient`** (actor): Docker CLI operations (`isAvailable`, `runDocker`, `runContainer`, `removeContainer`, `logs`, `port`)
- **`ProcessRunner`** (actor): Low-level process execution
- **`Container`** (actor): Container operations and wait strategy execution
- **`Waiter`** (enum with static methods): Polling with timeout logic
- **`withContainer(_:docker:operation:)`**: Scoped container lifecycle management

## Requirements

### Functional Requirements

1. **Log Levels**: Support standard severity levels
   - `trace`: Very detailed debugging (every polling attempt, raw output)
   - `debug`: Detailed debugging (command execution, timing)
   - `info`: Normal operations (container started, wait complete)
   - `notice`: Significant events (container ready, cleanup triggered)
   - `warning`: Recoverable issues (slow operations, retries)
   - `error`: Failures (command failures, timeouts)
   - `critical`: Severe failures (should rarely be used)

2. **Structured Fields**: All log messages should include contextual metadata
   - `containerId`: Docker container ID (when available)
   - `containerImage`: Image name from request
   - `containerName`: Container name (if set)
   - `operation`: High-level operation (e.g., "start_container", "wait_tcp_port")
   - `command`: Docker CLI command being executed
   - `duration`: Time taken for operations
   - `attempt`: Retry/poll attempt number
   - `error`: Error details when applicable

3. **Pluggable Backends**: Support multiple logging implementations
   - **OSLog**: Apple's unified logging system (default on Apple platforms)
   - **swift-log**: Popular Swift logging API (optional dependency)
   - **Custom Handler**: User-defined logging callbacks
   - **Null Handler**: Silent mode (default when no backend configured)

4. **Zero-Cost Abstraction**: When logging is disabled (default), there should be minimal runtime overhead

5. **Thread-Safe**: Must work correctly with actors and structured concurrency

### Non-Functional Requirements

1. **Backward Compatibility**: Adding logging must not break existing API
2. **Optional Dependencies**: OSLog and swift-log support should be conditional/optional
3. **Performance**: Logging should not significantly impact container operations
4. **Test Coverage**: Comprehensive unit tests for logging infrastructure

## API Design

### Core Logging Protocol

```swift
// /Sources/TestContainers/Logging/LogLevel.swift
public enum LogLevel: Int, Sendable, Comparable {
    case trace = 0
    case debug = 1
    case info = 2
    case notice = 3
    case warning = 4
    case error = 5
    case critical = 6

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// /Sources/TestContainers/Logging/LogHandler.swift
public protocol LogHandler: Sendable {
    func log(
        level: LogLevel,
        message: String,
        metadata: [String: String],
        source: String,
        file: String,
        function: String,
        line: UInt
    )

    var minimumLevel: LogLevel { get }
}

// /Sources/TestContainers/Logging/Logger.swift
public struct Logger: Sendable {
    private let handler: LogHandler?

    public init(handler: LogHandler?) {
        self.handler = handler
    }

    public static let null = Logger(handler: nil)

    public func trace(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .trace, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    public func debug(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .debug, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    public func info(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .info, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    public func notice(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .notice, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    public func warning(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .warning, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    public func error(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .error, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    public func critical(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .critical, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    private func log(
        level: LogLevel,
        message: String,
        metadata: [String: String],
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        guard let handler = handler else { return }
        guard level >= handler.minimumLevel else { return }
        handler.log(
            level: level,
            message: message,
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }
}
```

### Built-in Handlers

```swift
// /Sources/TestContainers/Logging/PrintLogHandler.swift
public struct PrintLogHandler: LogHandler {
    public let minimumLevel: LogLevel

    public init(minimumLevel: LogLevel = .info) {
        self.minimumLevel = minimumLevel
    }

    public func log(
        level: LogLevel,
        message: String,
        metadata: [String: String],
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let levelStr = String(describing: level).uppercased()
        let metadataStr = metadata.isEmpty ? "" : " " + metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[\(timestamp)] [\(levelStr)] [\(source)] \(message)\(metadataStr)")
    }
}

// /Sources/TestContainers/Logging/OSLogHandler.swift
#if canImport(os)
import os

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public struct OSLogHandler: LogHandler {
    private let logger: os.Logger
    public let minimumLevel: LogLevel

    public init(subsystem: String = "com.testcontainers.swift", category: String = "TestContainers", minimumLevel: LogLevel = .info) {
        self.logger = os.Logger(subsystem: subsystem, category: category)
        self.minimumLevel = minimumLevel
    }

    public func log(
        level: LogLevel,
        message: String,
        metadata: [String: String],
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let osLogType = level.toOSLogType()
        let metadataStr = metadata.isEmpty ? "" : " " + metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        logger.log(level: osLogType, "\(message, privacy: .public)\(metadataStr, privacy: .public)")
    }
}

private extension LogLevel {
    func toOSLogType() -> OSLogType {
        switch self {
        case .trace, .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .error
        case .error, .critical: return .fault
        }
    }
}
#endif
```

### Custom Handler Example (for documentation)

```swift
// User-defined handler example
struct CustomLogHandler: LogHandler {
    let minimumLevel: LogLevel = .debug

    func log(
        level: LogLevel,
        message: String,
        metadata: [String: String],
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        // Send to custom logging service
        MyLoggingService.send(
            level: level,
            message: message,
            context: metadata
        )
    }
}
```

### Integration with Existing API

```swift
// /Sources/TestContainers/DockerClient.swift
public actor DockerClient {
    private let dockerPath: String
    private let runner: ProcessRunner
    private let logger: Logger  // NEW

    public init(dockerPath: String = "docker", logger: Logger = .null) {
        self.dockerPath = dockerPath
        self.runner = ProcessRunner(logger: logger)
        self.logger = logger
    }

    public func isAvailable() async -> Bool {
        logger.debug("Checking if Docker is available", metadata: ["dockerPath": dockerPath])
        let start = ContinuousClock.now

        do {
            let result = try await runner.run(executable: dockerPath, arguments: ["version", "--format", "{{.Server.Version}}"])
            let available = result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let duration = ContinuousClock.now.duration(since: start)

            if available {
                logger.info("Docker is available", metadata: [
                    "version": result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    "duration": "\(duration)"
                ])
            } else {
                logger.warning("Docker check failed", metadata: [
                    "exitCode": "\(result.exitCode)",
                    "duration": "\(duration)"
                ])
            }

            return available
        } catch {
            let duration = ContinuousClock.now.duration(since: start)
            logger.error("Docker availability check threw error", metadata: [
                "error": "\(error)",
                "duration": "\(duration)"
            ])
            return false
        }
    }

    func runContainer(_ request: ContainerRequest) async throws -> String {
        logger.info("Starting container", metadata: [
            "image": request.image,
            "name": request.name ?? "auto",
            "ports": request.ports.map { "\($0.containerPort)" }.joined(separator: ",")
        ])

        // ... existing implementation with added logging ...

        logger.notice("Container started", metadata: [
            "containerId": id,
            "image": request.image,
            "duration": "\(duration)"
        ])

        return id
    }

    // ... other methods updated similarly
}

// /Sources/TestContainers/WithContainer.swift
public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    logger: Logger = .null,  // NEW parameter
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    let dockerWithLogger = DockerClient(logger: logger)  // Pass logger to docker client

    logger.debug("Checking Docker availability")
    if !(await dockerWithLogger.isAvailable()) {
        logger.error("Docker not available")
        throw TestContainersError.dockerNotAvailable("`docker` CLI not found or Docker engine not running.")
    }

    logger.info("Starting container lifecycle", metadata: ["image": request.image])
    let id = try await dockerWithLogger.runContainer(request)
    let container = Container(id: id, request: request, docker: dockerWithLogger, logger: logger)

    let cleanup: () -> Void = {
        _ = Task {
            logger.info("Cleanup triggered (async)", metadata: ["containerId": id])
            try? await container.terminate()
        }
    }

    return try await withTaskCancellationHandler {
        do {
            logger.debug("Waiting for container to be ready", metadata: ["containerId": id])
            try await container.waitUntilReady()
            logger.notice("Container is ready", metadata: ["containerId": id])

            logger.debug("Executing user operation", metadata: ["containerId": id])
            let result = try await operation(container)

            logger.debug("User operation completed, terminating container", metadata: ["containerId": id])
            try await container.terminate()
            logger.info("Container lifecycle completed successfully", metadata: ["containerId": id])

            return result
        } catch {
            logger.error("Container lifecycle failed", metadata: [
                "containerId": id,
                "error": "\(error)"
            ])
            try? await container.terminate()
            throw error
        }
    } onCancel: {
        logger.warning("Container lifecycle cancelled", metadata: ["containerId": id])
        cleanup()
    }
}

// /Sources/TestContainers/Container.swift
public actor Container {
    // ... existing properties ...
    private let logger: Logger  // NEW

    init(id: String, request: ContainerRequest, docker: DockerClient, logger: Logger) {
        self.id = id
        self.request = request
        self.docker = docker
        self.logger = logger
    }

    func waitUntilReady() async throws {
        let start = ContinuousClock.now

        switch request.waitStrategy {
        case .none:
            logger.debug("No wait strategy configured", metadata: ["containerId": id])
            return

        case let .logContains(needle, timeout, pollInterval):
            logger.info("Waiting for log message", metadata: [
                "containerId": id,
                "needle": needle,
                "timeout": "\(timeout)"
            ])

            var attempt = 0
            try await Waiter.wait(timeout: timeout, pollInterval: pollInterval, description: "container logs to contain '\(needle)'") { [docker, id, logger] in
                attempt += 1
                logger.trace("Checking container logs", metadata: [
                    "containerId": id,
                    "attempt": "\(attempt)"
                ])

                let text = try await docker.logs(id: id)
                let found = text.contains(needle)

                if found {
                    logger.debug("Log message found", metadata: [
                        "containerId": id,
                        "attempt": "\(attempt)",
                        "duration": "\(ContinuousClock.now.duration(since: start))"
                    ])
                }

                return found
            }

        case let .tcpPort(containerPort, timeout, pollInterval):
            let hostPort = try await docker.port(id: id, containerPort: containerPort)
            let host = request.host

            logger.info("Waiting for TCP port", metadata: [
                "containerId": id,
                "host": host,
                "hostPort": "\(hostPort)",
                "containerPort": "\(containerPort)",
                "timeout": "\(timeout)"
            ])

            var attempt = 0
            try await Waiter.wait(timeout: timeout, pollInterval: pollInterval, description: "TCP port \(host):\(hostPort) to accept connections") {
                attempt += 1
                logger.trace("Probing TCP port", metadata: [
                    "containerId": id,
                    "host": host,
                    "port": "\(hostPort)",
                    "attempt": "\(attempt)"
                ])

                let canConnect = TCPProbe.canConnect(host: host, port: hostPort, timeout: .milliseconds(200))

                if canConnect {
                    logger.debug("TCP port accepting connections", metadata: [
                        "containerId": id,
                        "host": host,
                        "port": "\(hostPort)",
                        "attempt": "\(attempt)",
                        "duration": "\(ContinuousClock.now.duration(since: start))"
                    ])
                }

                return canConnect
            }
        }
    }
}

// /Sources/TestContainers/Waiter.swift
enum Waiter {
    static func wait(
        timeout: Duration,
        pollInterval: Duration,
        description: String,
        logger: Logger = .null,  // NEW parameter
        _ predicate: @Sendable () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now

        logger.debug("Starting wait", metadata: [
            "description": description,
            "timeout": "\(timeout)",
            "pollInterval": "\(pollInterval)"
        ])

        while true {
            if try await predicate() {
                let duration = start.duration(to: clock.now)
                logger.debug("Wait condition met", metadata: [
                    "description": description,
                    "duration": "\(duration)"
                ])
                return
            }

            let elapsed = start.duration(to: clock.now)
            if elapsed >= timeout {
                logger.error("Wait timed out", metadata: [
                    "description": description,
                    "timeout": "\(timeout)",
                    "elapsed": "\(elapsed)"
                ])
                throw TestContainersError.timeout(description)
            }

            try await Task.sleep(for: pollInterval)
        }
    }
}
```

### Usage Examples

```swift
// Example 1: Using OSLog (Apple platforms)
import TestContainers

let logger = Logger(handler: OSLogHandler(minimumLevel: .debug))

let request = ContainerRequest(image: "redis:7")
    .withExposedPort(6379)
    .waitingFor(.tcpPort(6379))

try await withContainer(request, logger: logger) { container in
    let port = try await container.hostPort(6379)
    // OSLog will show all operations
}

// Example 2: Using PrintLogHandler
let printLogger = Logger(handler: PrintLogHandler(minimumLevel: .info))

try await withContainer(request, logger: printLogger) { container in
    // Console output:
    // [2025-12-15T10:30:00Z] [INFO] [TestContainers] Checking Docker availability dockerPath=docker
    // [2025-12-15T10:30:00Z] [INFO] [TestContainers] Docker is available version=27.3.1 duration=0.15s
    // [2025-12-15T10:30:00Z] [INFO] [TestContainers] Starting container lifecycle image=redis:7
    // ...
}

// Example 3: Custom handler
struct TestLogHandler: LogHandler {
    var capturedLogs: [(LogLevel, String, [String: String])] = []
    let minimumLevel: LogLevel = .trace

    mutating func log(level: LogLevel, message: String, metadata: [String: String], ...) {
        capturedLogs.append((level, message, metadata))
    }
}

var testLogger = TestLogHandler()
let logger = Logger(handler: testLogger)

try await withContainer(request, logger: logger) { container in
    // All logs captured in testLogger.capturedLogs for assertions
}

// Example 4: Environment-based configuration
func createLogger() -> Logger {
    if let level = ProcessInfo.processInfo.environment["TESTCONTAINERS_LOG_LEVEL"] {
        let logLevel = LogLevel(string: level) ?? .info
        #if canImport(os)
        if #available(macOS 11.0, *) {
            return Logger(handler: OSLogHandler(minimumLevel: logLevel))
        }
        #endif
        return Logger(handler: PrintLogHandler(minimumLevel: logLevel))
    }
    return .null  // Silent by default
}
```

## Implementation Steps

### Phase 1: Core Infrastructure (Week 1)

1. **Create logging module structure**
   - [ ] Create `/Sources/TestContainers/Logging/` directory
   - [ ] Add `LogLevel.swift` with severity enum
   - [ ] Add `LogHandler.swift` protocol
   - [ ] Add `Logger.swift` struct with convenience methods
   - [ ] Add `PrintLogHandler.swift` for simple console output

2. **Add basic unit tests**
   - [ ] Create `/Tests/TestContainersTests/Logging/LoggerTests.swift`
   - [ ] Test log level filtering
   - [ ] Test metadata passing
   - [ ] Test null logger (no-op behavior)
   - [ ] Test PrintLogHandler output formatting

3. **Update Package.swift**
   - [ ] No changes needed (logging is part of main target)

### Phase 2: OSLog Integration (Week 1)

4. **Add OSLog handler**
   - [ ] Create `OSLogHandler.swift` with `#if canImport(os)` guards
   - [ ] Map LogLevel to OSLogType appropriately
   - [ ] Test on macOS/iOS
   - [ ] Document OSLog viewer usage

5. **Test OSLog handler**
   - [ ] Create `/Tests/TestContainersTests/Logging/OSLogHandlerTests.swift`
   - [ ] Test handler creation and level mapping
   - [ ] Verify compilation on non-Apple platforms (should be skipped)

### Phase 3: DockerClient Integration (Week 2)

6. **Add logging to ProcessRunner**
   - [ ] Add `logger: Logger` parameter to `ProcessRunner.init`
   - [ ] Log command execution (debug level): executable, arguments
   - [ ] Log command completion (trace level): exit code, stdout/stderr length, duration
   - [ ] Log command failures (error level): full details

7. **Add logging to DockerClient**
   - [ ] Add `logger: Logger` parameter to `DockerClient.init`
   - [ ] Pass logger to ProcessRunner
   - [ ] Add logging to `isAvailable()`: check start, result, duration
   - [ ] Add logging to `runContainer()`: container config, start, ID, duration
   - [ ] Add logging to `removeContainer()`: ID, duration
   - [ ] Add logging to `logs()`: ID, log length
   - [ ] Add logging to `port()`: ID, container port, host port, duration

8. **Test DockerClient logging**
   - [ ] Create test with mock log handler to capture logs
   - [ ] Verify all operations emit expected log messages
   - [ ] Verify metadata includes correct context

### Phase 4: Container Lifecycle Integration (Week 2)

9. **Add logging to Container**
   - [ ] Add `logger: Logger` parameter to `Container.init`
   - [ ] Add logging to `waitUntilReady()`: wait strategy details, polling attempts
   - [ ] Add logging to `terminate()`: container ID
   - [ ] Add detailed trace logs for polling attempts

10. **Add logging to Waiter**
    - [ ] Add optional `logger: Logger` parameter to `wait()`
    - [ ] Log wait start: description, timeout, poll interval
    - [ ] Log wait success: description, duration
    - [ ] Log timeout: description, elapsed time

11. **Add logging to withContainer**
    - [ ] Add `logger: Logger = .null` parameter
    - [ ] Pass logger through to DockerClient and Container
    - [ ] Log lifecycle stages: check, start, wait, operation, cleanup
    - [ ] Log cancellation events
    - [ ] Log errors with full context

12. **Test container lifecycle logging**
    - [ ] Create integration test that captures logs during full lifecycle
    - [ ] Verify all expected log messages appear
    - [ ] Verify log ordering
    - [ ] Verify metadata accuracy

### Phase 5: Error Enrichment (Week 3)

13. **Enhance error messages with log context**
    - [ ] Consider adding "last N log lines" to timeout errors
    - [ ] Add structured error metadata
    - [ ] Document how to enable verbose logging for debugging

### Phase 6: Documentation & Examples (Week 3)

14. **Write comprehensive documentation**
    - [ ] Create `Documentation/Logging.md` guide
    - [ ] Document all log handlers
    - [ ] Provide usage examples for each backend
    - [ ] Document environment variable conventions
    - [ ] Add troubleshooting section

15. **Add examples to README**
    - [ ] Add "Logging" section to README.md
    - [ ] Show basic usage with OSLog
    - [ ] Show environment-based configuration
    - [ ] Link to detailed documentation

16. **Update FEATURES.md**
    - [ ] Move "Structured logging hooks" from Tier 3 to Implemented
    - [ ] Document available backends

### Phase 7: Advanced Features (Optional - Week 4)

17. **Add swift-log integration (optional)**
    - [ ] Create separate target `TestContainersSwiftLog`
    - [ ] Add swift-log dependency as optional
    - [ ] Create SwiftLogHandler bridge
    - [ ] Test integration
    - [ ] Document usage

18. **Performance testing**
    - [ ] Benchmark logging overhead
    - [ ] Verify null logger has zero cost
    - [ ] Optimize hot paths if needed

## Testing Plan

### Unit Tests

1. **Logger Core Tests** (`Tests/TestContainersTests/Logging/LoggerTests.swift`)
   - Test null logger (all methods are no-ops)
   - Test log level filtering (handler only receives logs >= minimum level)
   - Test metadata passing (metadata correctly passed to handler)
   - Test all convenience methods (trace, debug, info, notice, warning, error, critical)
   - Test file/function/line capture (source location macros work correctly)

2. **PrintLogHandler Tests** (`Tests/TestContainersTests/Logging/PrintLogHandlerTests.swift`)
   - Test log formatting (timestamp, level, message, metadata)
   - Test metadata serialization (key=value pairs)
   - Test level filtering
   - Capture stdout for verification

3. **OSLogHandler Tests** (`Tests/TestContainersTests/Logging/OSLogHandlerTests.swift`)
   - Test handler creation with custom subsystem/category
   - Test log level mapping to OSLogType
   - Test availability guards compile correctly
   - Note: Actual OSLog output verification is difficult, focus on API correctness

4. **Mock Handler Tests**
   - Create `MockLogHandler` that captures all calls
   - Verify handler receives correct parameters
   - Test concurrent logging (actor safety)

### Integration Tests

5. **DockerClient Logging Tests** (`Tests/TestContainersTests/Logging/DockerClientLoggingTests.swift`)
   - Capture logs during `isAvailable()` call
   - Verify command execution logs include docker path
   - Verify timing metadata is present
   - Test error scenarios produce error logs

6. **Container Lifecycle Logging Tests** (requires Docker)
   - Create container with logging enabled
   - Capture all logs during full lifecycle
   - Verify expected log sequence:
     1. Docker check
     2. Container start
     3. Wait strategy begin
     4. Polling attempts (trace)
     5. Wait strategy complete
     6. User operation
     7. Container terminate
   - Verify metadata consistency (container ID, image name)
   - Verify timing information accuracy

7. **Wait Strategy Logging Tests**
   - Test `.tcpPort` strategy logs (initial log, polling, success)
   - Test `.logContains` strategy logs (initial log, polling, success)
   - Test timeout scenario (timeout error log)
   - Verify attempt counters increment correctly

8. **Error Logging Tests**
   - Trigger command failure, verify error log
   - Trigger timeout, verify error log
   - Trigger cancellation, verify warning log
   - Verify error metadata includes relevant context

### Manual Testing Scenarios

9. **Real-world Testing**
   - Run example with OSLog, view in Console.app
   - Run example with PrintLogHandler, verify console output
   - Test with various log levels (trace, debug, info)
   - Test with containers that timeout (verify error logs helpful)
   - Test with parallel containers (verify log isolation)

10. **Performance Testing**
    - Benchmark container start time with null logger
    - Benchmark container start time with OSLog handler
    - Benchmark container start time with PrintLogHandler
    - Verify overhead is acceptable (<5%)

## Acceptance Criteria

### Must Have

1. **Core Infrastructure**
   - [ ] `Logger`, `LogHandler`, `LogLevel` types implemented and tested
   - [ ] `PrintLogHandler` works correctly for console output
   - [ ] Null logger has zero runtime cost when used
   - [ ] All types are `Sendable` and work with actors

2. **OSLog Integration**
   - [ ] `OSLogHandler` implemented with platform guards
   - [ ] Logs appear in Console.app on macOS
   - [ ] Compiles successfully on non-Apple platforms (skips OSLog)

3. **Library Integration**
   - [ ] `DockerClient` accepts and uses logger
   - [ ] `Container` accepts and uses logger
   - [ ] `withContainer` accepts and passes logger
   - [ ] All major operations emit appropriate log messages
   - [ ] No breaking changes to existing API (logger is optional)

4. **Log Quality**
   - [ ] All logs include structured metadata (no raw string interpolation of IDs/values)
   - [ ] Log levels are appropriate (trace for verbose, info for normal, error for failures)
   - [ ] Messages are actionable and clear
   - [ ] Timing information included for slow operations

5. **Testing**
   - [ ] Unit tests achieve >90% coverage of logging code
   - [ ] Integration tests verify logs during container lifecycle
   - [ ] Tests demonstrate log handler implementations
   - [ ] Performance tests show minimal overhead

6. **Documentation**
   - [ ] Usage examples in README.md
   - [ ] Detailed logging guide in documentation
   - [ ] API documentation on all public logging types
   - [ ] FEATURES.md updated

### Should Have

7. **Enhanced Debugging**
   - [ ] Environment variable support (e.g., `TESTCONTAINERS_LOG_LEVEL=debug`)
   - [ ] Helpful error messages reference logging for troubleshooting
   - [ ] Example of custom log handler in documentation

8. **Code Quality**
   - [ ] No warnings in logging code
   - [ ] Consistent naming conventions
   - [ ] Clear separation of concerns (Logger, Handler, backends)

### Nice to Have

9. **Advanced Features**
   - [ ] swift-log integration (separate target)
   - [ ] Log filtering by operation type
   - [ ] Structured error context in TestContainersError
   - [ ] Performance comparison metrics in documentation

10. **Developer Experience**
    - [ ] Logger configuration helper for common setups
    - [ ] Example test fixtures with logging enabled
    - [ ] Xcode console output formatting tips

## Related Features

- **Feature 011**: Stream logs - Future log streaming feature could use same handler infrastructure
- **Lifecycle hooks** (Tier 2): Logging will complement lifecycle hooks by providing visibility into events
- **Better diagnostics on failures** (Tier 3): Logging is the foundation for improved error diagnostics

## Open Questions

1. **Default Behavior**: Should library log anything by default, or require explicit opt-in?
   - **Recommendation**: Null logger by default (silent), users explicitly opt-in. Rationale: test output should be clean by default, users enable when debugging.

2. **Log Sampling**: Should we implement log sampling for very verbose operations (e.g., log every Nth poll)?
   - **Recommendation**: Not in initial implementation. Use log levels appropriately instead (trace for very verbose).

3. **Async Logging**: Should log handlers support async?
   - **Recommendation**: No. Handlers should be fast/non-blocking. If async needed, handler implementation should manage queue internally.

4. **Log Aggregation**: Should we support multiple handlers simultaneously?
   - **Recommendation**: Not initially. Users can create wrapper handler if needed.

5. **Metadata Standardization**: Should we define standard metadata keys as constants?
   - **Recommendation**: Yes. Define `LogMetadataKey` enum with standard keys for consistency.

## Implementation Notes

### Code Style Consistency

Follow existing patterns from `/Sources/TestContainers/`:
- Use `public` for API surface, internal/private for implementation
- Use `actor` for thread-safety when managing state
- Use `Sendable` protocols for concurrency
- Follow fluent builder pattern for configuration
- Use `Duration` type for time values
- Prefer `async/await` over callbacks

### Testing Patterns

Follow existing test patterns from `/Tests/TestContainersTests/`:
- Use `import Testing` framework (`@Test` attribute)
- Use `#expect` for assertions
- Use environment variable gating for Docker integration tests
- Create focused unit tests for each component
- Keep tests fast (mock heavy operations)

### Documentation Style

Follow existing documentation patterns:
- Concise code examples in docstrings
- Real-world usage examples in README
- Detailed guides in separate documentation files
- Reference existing code locations with absolute paths

## References

### Existing Codebase References

- `/Sources/TestContainers/DockerClient.swift` - Docker operations to instrument
- `/Sources/TestContainers/Container.swift` - Container lifecycle to instrument
- `/Sources/TestContainers/ProcessRunner.swift` - Process execution to instrument
- `/Sources/TestContainers/WithContainer.swift` - Entry point for logger injection
- `/Sources/TestContainers/Waiter.swift` - Polling logic to instrument
- `/Sources/TestContainers/ContainerRequest.swift` - Builder pattern reference
- `/Tests/TestContainersTests/DockerIntegrationTests.swift` - Integration test pattern

### Similar Implementations

- [testcontainers-go logging](https://github.com/testcontainers/testcontainers-go/blob/main/logging.go) - Reference implementation
- [swift-log](https://github.com/apple/swift-log) - Swift logging API standard
- [OSLog](https://developer.apple.com/documentation/os/logging) - Apple's unified logging

### Related Documentation

- Swift Concurrency and Sendable: https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html
- OSLog best practices: https://developer.apple.com/documentation/os/logging/generating_log_messages_from_your_code
