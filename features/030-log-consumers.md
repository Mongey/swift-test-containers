# Feature 030: Log Consumers

## Summary

Implement log consumers that allow users to register callbacks to receive container log output in real-time as it's produced. This enables streaming logs to custom handlers during container execution, supporting use cases like debugging, monitoring, log aggregation, and test diagnostics without requiring manual polling via `container.logs()`.

## Current State

The codebase currently supports **one-shot log retrieval** defined in `/Sources/TestContainers/Container.swift`:

```swift
public func logs() async throws -> String {
    try await docker.logs(id: id)
}
```

And in `/Sources/TestContainers/DockerClient.swift`:

```swift
func logs(id: String) async throws -> String {
    let output = try await runDocker(["logs", id])
    return output.stdout
}
```

**Current Behavior**:
- Logs are retrieved as a complete string via `docker logs <id>`
- This is a blocking operation that returns all accumulated logs up to that point
- No way to stream logs in real-time as they're produced
- Used by `logContains` wait strategy (lines 40-44 in `Container.swift`), which polls repeatedly

**Limitations**:
1. **No streaming**: Must repeatedly call `logs()` to get new output
2. **No stdout/stderr separation**: All logs mixed together in stdout
3. **Memory overhead**: Large log outputs are loaded entirely into memory
4. **Polling overhead**: Wait strategies repeatedly fetch entire log history
5. **No real-time visibility**: Can't observe container behavior as it happens

## Requirements

### Functional Requirements

1. **Callback Registration**: Register one or more log consumers on a container or container request
2. **Real-time Streaming**: Receive log lines as they're produced by the container
3. **Stream Separation**: Distinguish between stdout and stderr
4. **Asynchronous Callbacks**: Callbacks should be async-capable to support async operations (e.g., writing to files, network calls)
5. **Multiple Consumers**: Support registering multiple log consumers on the same container
6. **Lifecycle Management**:
   - Start consuming logs when container starts
   - Continue during wait strategy execution
   - Stop when container terminates or is explicitly stopped
7. **Error Handling**: Handle consumer failures without crashing container execution
8. **Line-based Processing**: Deliver complete log lines (not partial chunks)

### Non-Functional Requirements

1. **Sendable Conformance**: All types must be `Sendable` for Swift concurrency
2. **Performance**: Minimal overhead on container startup and execution
3. **Memory Efficiency**: Stream logs without loading entire history
4. **Thread Safety**: Support concurrent access via actor isolation
5. **Testability**: Support unit and integration testing
6. **Backwards Compatibility**: Don't break existing `logs()` API

## API Design

### Proposed LogConsumer Protocol

**File**: `/Sources/TestContainers/LogConsumer.swift` (new)

```swift
import Foundation

/// Represents the source stream of a log line
public enum LogStream: Sendable, Hashable {
    case stdout
    case stderr
}

/// A consumer that receives log output from a running container
public protocol LogConsumer: Sendable {
    /// Called when a new log line is produced by the container
    /// - Parameters:
    ///   - stream: The stream that produced the log line (stdout or stderr)
    ///   - line: The log line content (without trailing newline)
    func accept(stream: LogStream, line: String) async
}
```

### Built-in Consumer Implementations

```swift
/// Prints log lines to standard output with optional prefix
public struct PrintLogConsumer: LogConsumer {
    private let prefix: String?
    private let includeStream: Bool

    public init(prefix: String? = nil, includeStream: Bool = true) {
        self.prefix = prefix
        self.includeStream = includeStream
    }

    public func accept(stream: LogStream, line: String) async {
        let streamLabel = includeStream ? "[\(stream)]" : ""
        let prefixLabel = prefix.map { "[\($0)]" } ?? ""
        print("\(prefixLabel)\(streamLabel) \(line)")
    }
}

/// Collects log lines into an array for testing/debugging
public actor CollectingLogConsumer: LogConsumer {
    public struct LogEntry: Sendable, Equatable {
        public let stream: LogStream
        public let line: String
        public let timestamp: Date
    }

    private var entries: [LogEntry] = []

    public init() {}

    public func accept(stream: LogStream, line: String) async {
        entries.append(LogEntry(stream: stream, line: line, timestamp: Date()))
    }

    public func getEntries() -> [LogEntry] {
        entries
    }

    public func getLines(from stream: LogStream? = nil) -> [String] {
        if let stream {
            return entries.filter { $0.stream == stream }.map { $0.line }
        }
        return entries.map { $0.line }
    }
}

/// Writes log lines to a file
public actor FileLogConsumer: LogConsumer {
    private let fileHandle: FileHandle
    private let includeStream: Bool

    public init(url: URL, includeStream: Bool = true) throws {
        self.includeStream = includeStream

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        self.fileHandle = try FileHandle(forWritingTo: url)
        try fileHandle.seekToEnd()
    }

    public func accept(stream: LogStream, line: String) async {
        let streamLabel = includeStream ? "[\(stream)] " : ""
        let text = "\(streamLabel)\(line)\n"
        if let data = text.data(using: .utf8) {
            try? fileHandle.write(contentsOf: data)
        }
    }

    deinit {
        try? fileHandle.close()
    }
}

/// Combines multiple log consumers
public struct CompositeLogConsumer: LogConsumer {
    private let consumers: [any LogConsumer]

    public init(_ consumers: [any LogConsumer]) {
        self.consumers = consumers
    }

    public func accept(stream: LogStream, line: String) async {
        for consumer in consumers {
            await consumer.accept(stream: stream, line: line)
        }
    }
}
```

### ContainerRequest Extension

**File**: `/Sources/TestContainers/ContainerRequest.swift`

```swift
public struct ContainerRequest: Sendable, Hashable {
    // ... existing properties ...
    public var logConsumers: [any LogConsumer]

    public init(image: String) {
        // ... existing initialization ...
        self.logConsumers = []
    }

    public func withLogConsumer(_ consumer: any LogConsumer) -> Self {
        var copy = self
        copy.logConsumers.append(consumer)
        return copy
    }

    public func withLogConsumers(_ consumers: [any LogConsumer]) -> Self {
        var copy = self
        copy.logConsumers.append(contentsOf: consumers)
        return copy
    }
}
```

**Note**: Making `logConsumers` conform to `Hashable` requires special handling since `LogConsumer` is a protocol. We may need to:
1. Remove `Hashable` from `ContainerRequest` (breaking change), or
2. Exclude `logConsumers` from hash/equality (document that two requests with different consumers are considered equal), or
3. Store consumers separately in `Container` instead of `ContainerRequest`

**Recommendation**: Store consumers in `Container` to avoid breaking `Hashable` conformance.

### Container Extension

**File**: `/Sources/TestContainers/Container.swift`

```swift
public actor Container {
    // ... existing properties ...
    private var logConsumers: [any LogConsumer] = []
    private var logFollowTask: Task<Void, Never>?

    // ... existing init ...

    public func addLogConsumer(_ consumer: any LogConsumer) {
        logConsumers.append(consumer)
    }

    func startLogStreaming() async {
        guard !logConsumers.isEmpty else { return }

        logFollowTask = Task { [docker, id, logConsumers] in
            await docker.followLogs(id: id, consumers: logConsumers)
        }
    }

    func stopLogStreaming() async {
        logFollowTask?.cancel()
        logFollowTask = nil
    }
}
```

### DockerClient Extension

**File**: `/Sources/TestContainers/DockerClient.swift`

```swift
public actor DockerClient {
    // ... existing code ...

    /// Follow container logs and stream to consumers
    /// Runs until cancelled or container stops
    func followLogs(id: String, consumers: [any LogConsumer]) async {
        do {
            // Use docker logs --follow to stream logs
            // This requires process streaming support
            await streamDockerLogs(id: id, consumers: consumers)
        } catch {
            // Log error but don't crash
            print("Log streaming error: \(error)")
        }
    }

    private func streamDockerLogs(id: String, consumers: [any LogConsumer]) async {
        // Implementation will use Process with real-time output streaming
        // See implementation steps for details
    }
}
```

### Usage Examples

```swift
// Example 1: Print logs to console
let request = ContainerRequest(image: "redis:7")
    .withExposedPort(6379)
    .withLogConsumer(PrintLogConsumer(prefix: "redis"))
    .waitingFor(.tcpPort(6379))

try await withContainer(request) { container in
    // Logs are printed in real-time to console
    let port = try await container.hostPort(6379)
    // ... use container ...
}

// Example 2: Collect logs for testing
let collector = CollectingLogConsumer()
let request = ContainerRequest(image: "alpine:3")
    .withCommand(["sh", "-c", "echo hello && echo world >&2"])
    .withLogConsumer(collector)

try await withContainer(request) { container in
    // Wait for logs to be collected
    try await Task.sleep(for: .seconds(1))

    let stdoutLines = await collector.getLines(from: .stdout)
    let stderrLines = await collector.getLines(from: .stderr)

    #expect(stdoutLines.contains("hello"))
    #expect(stderrLines.contains("world"))
}

// Example 3: Write logs to file
let logFile = URL(fileURLWithPath: "/tmp/container.log")
let fileConsumer = try FileLogConsumer(url: logFile, includeStream: true)

let request = ContainerRequest(image: "postgres:16")
    .withEnvironment(["POSTGRES_PASSWORD": "test"])
    .withLogConsumer(fileConsumer)
    .waitingFor(.logContains("database system is ready"))

// Example 4: Multiple consumers
let request = ContainerRequest(image: "nginx:latest")
    .withLogConsumers([
        PrintLogConsumer(prefix: "nginx"),
        CollectingLogConsumer(),
        try FileLogConsumer(url: logFileURL)
    ])

// Example 5: Add consumer to running container
try await withContainer(request) { container in
    // Add additional consumer after start
    await container.addLogConsumer(PrintLogConsumer())
    // ... container continues running ...
}

// Example 6: Custom consumer for monitoring
struct MetricsLogConsumer: LogConsumer {
    let metrics: MetricsCollector

    func accept(stream: LogStream, line: String) async {
        if line.contains("ERROR") {
            await metrics.recordError()
        }
        if line.contains("REQUEST") {
            await metrics.recordRequest()
        }
    }
}
```

## Implementation Steps

### Step 1: Create LogConsumer Protocol and Types

**File**: `/Sources/TestContainers/LogConsumer.swift` (new)

**Tasks**:
1. Define `LogStream` enum (stdout/stderr)
2. Define `LogConsumer` protocol with `accept(stream:line:)` method
3. Implement `PrintLogConsumer`
4. Implement `CollectingLogConsumer` as actor
5. Implement `FileLogConsumer` as actor
6. Implement `CompositeLogConsumer`

**Considerations**:
- Mark all types as `Sendable`
- Use actors for stateful consumers (collecting, file writing)
- Make consumers robust to errors (catch and log, don't crash)

**Estimated Effort**: 3 hours

### Step 2: Add Process Streaming Support

**File**: `/Sources/TestContainers/ProcessRunner.swift`

**Current limitation**: The `ProcessRunner.run()` method uses `terminationHandler` which only provides output after the process completes. We need real-time streaming.

**New Method**:
```swift
/// Stream process output line-by-line to handlers
func stream(
    executable: String,
    arguments: [String],
    environment: [String: String] = [:],
    stdoutHandler: @escaping @Sendable (String) async -> Void,
    stderrHandler: @escaping @Sendable (String) async -> Void
) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    if !environment.isEmpty {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        process.environment = env
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Create tasks to read from pipes line by line
    let stdoutTask = Task {
        await readLines(from: stdoutPipe.fileHandleForReading, handler: stdoutHandler)
    }

    let stderrTask = Task {
        await readLines(from: stderrPipe.fileHandleForReading, handler: stderrHandler)
    }

    try process.run()

    await withTaskCancellationHandler {
        await stdoutTask.value
        await stderrTask.value
        process.waitUntilExit()
    } onCancel: {
        process.terminate()
        stdoutTask.cancel()
        stderrTask.cancel()
    }
}

private func readLines(
    from fileHandle: FileHandle,
    handler: @escaping @Sendable (String) async -> Void
) async {
    var buffer = Data()

    while true {
        let chunk = fileHandle.availableData
        if chunk.isEmpty { break }

        buffer.append(chunk)

        // Process complete lines
        while let newlineRange = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer.prefix(upTo: newlineRange)
            buffer.removeSubrange(...newlineRange)

            if let line = String(data: lineData, encoding: .utf8) {
                await handler(line)
            }
        }
    }

    // Process remaining data in buffer
    if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
        await handler(line)
    }
}
```

**Considerations**:
- Handle partial lines correctly (buffer until newline)
- Support cancellation properly
- Don't block on handler execution (handlers are async)
- Handle both UTF-8 and binary data gracefully

**Estimated Effort**: 4 hours

### Step 3: Add Log Following to DockerClient

**File**: `/Sources/TestContainers/DockerClient.swift`

**Implementation**:
```swift
/// Follow container logs and deliver to consumers
/// Continues until cancelled or container stops
func followLogs(id: String, consumers: [any LogConsumer]) async {
    let composite = CompositeLogConsumer(consumers)

    do {
        try await runner.stream(
            executable: dockerPath,
            arguments: ["logs", "--follow", "--timestamps", id],
            stdoutHandler: { line in
                await composite.accept(stream: .stdout, line: line)
            },
            stderrHandler: { line in
                await composite.accept(stream: .stderr, line: line)
            }
        )
    } catch {
        // Container stopped or docker command failed
        // This is expected behavior when container terminates
    }
}
```

**Docker flags**:
- `--follow` (`-f`): Stream logs in real-time
- `--timestamps`: Include timestamp prefix (optional, can parse or strip)

**Alternative without timestamps**:
```swift
arguments: ["logs", "-f", id]
```

**Considerations**:
- `docker logs --follow` blocks until container stops
- Cancellation should terminate the docker process cleanly
- Don't throw errors on normal termination

**Estimated Effort**: 2 hours

### Step 4: Integrate with Container Lifecycle

**File**: `/Sources/TestContainers/Container.swift`

**Changes**:
1. Add `logConsumers` storage
2. Add `addLogConsumer()` method
3. Start log streaming after container starts
4. Stop log streaming on termination

```swift
public actor Container {
    // ... existing properties ...
    private var logConsumers: [any LogConsumer] = []
    private var logFollowTask: Task<Void, Never>?

    init(id: String, request: ContainerRequest, docker: DockerClient) {
        self.id = id
        self.request = request
        self.docker = docker
        self.logConsumers = [] // Initialize from request if we store there
    }

    public func addLogConsumer(_ consumer: any LogConsumer) {
        logConsumers.append(consumer)
    }

    func startLogStreaming() async {
        guard !logConsumers.isEmpty else { return }

        logFollowTask = Task { [docker, id, logConsumers] in
            await docker.followLogs(id: id, consumers: logConsumers)
        }
    }

    func stopLogStreaming() async {
        logFollowTask?.cancel()
        logFollowTask = nil
    }

    public func terminate() async throws {
        await stopLogStreaming()
        try await docker.removeContainer(id: id)
    }
}
```

**File**: `/Sources/TestContainers/WithContainer.swift`

**Integration**:
```swift
public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable("`docker` CLI not found or Docker engine not running.")
    }

    let id = try await docker.runContainer(request)
    let container = Container(id: id, request: request, docker: docker)

    // Transfer log consumers from request to container
    for consumer in request.logConsumers {
        await container.addLogConsumer(consumer)
    }

    // Start streaming logs before waiting
    await container.startLogStreaming()

    let cleanup: () -> Void = { _ = Task { try? await container.terminate() } }

    return try await withTaskCancellationHandler {
        do {
            try await container.waitUntilReady()
            let result = try await operation(container)
            try await container.terminate()
            return result
        } catch {
            try? await container.terminate()
            throw error
        }
    } onCancel: {
        cleanup()
    }
}
```

**Considerations**:
- Start log streaming **before** `waitUntilReady()` to capture all logs
- Ensure streaming stops on all exit paths (success, error, cancellation)
- Don't let streaming failures crash container lifecycle

**Estimated Effort**: 2 hours

### Step 5: Handle ContainerRequest Integration

**Decision Required**: Where to store log consumers?

**Option A: Store in ContainerRequest** (breaks Hashable)
- Pro: Fluent API, consumers configured with request
- Con: Breaks `Hashable` conformance (protocols aren't hashable)

**Option B: Store only in Container**
- Pro: Maintains `Hashable` conformance
- Con: Less fluent, must add after container creation

**Option C: Store in both, transfer during creation**
- Pro: Best of both worlds
- Con: Most complex, need to handle erasure

**Recommendation**: Option C with custom handling

```swift
// ContainerRequest stores type-erased consumers
public struct ContainerRequest: Sendable {
    // Internal storage as array of closures
    internal var _logConsumerFactories: [@Sendable () -> any LogConsumer]

    public func withLogConsumer(_ consumer: @escaping @autoclosure @Sendable () -> any LogConsumer) -> Self {
        var copy = self
        copy._logConsumerFactories.append(consumer)
        return copy
    }
}

// During container creation, instantiate consumers
let container = Container(id: id, request: request, docker: docker)
for factory in request._logConsumerFactories {
    await container.addLogConsumer(factory())
}
```

**Estimated Effort**: 2 hours

### Step 6: Add Unit Tests

**File**: `/Tests/TestContainersTests/LogConsumerTests.swift` (new)

**Test Cases**:
```swift
@Test func printLogConsumer_formatsOutput() {
    // Test output formatting with different options
}

@Test func collectingLogConsumer_storesLines() async {
    let collector = CollectingLogConsumer()
    await collector.accept(stream: .stdout, line: "test1")
    await collector.accept(stream: .stderr, line: "test2")

    let entries = await collector.getEntries()
    #expect(entries.count == 2)
    #expect(entries[0].stream == .stdout)
    #expect(entries[0].line == "test1")
}

@Test func collectingLogConsumer_filtersStreams() async {
    let collector = CollectingLogConsumer()
    await collector.accept(stream: .stdout, line: "out1")
    await collector.accept(stream: .stderr, line: "err1")
    await collector.accept(stream: .stdout, line: "out2")

    let stdoutLines = await collector.getLines(from: .stdout)
    let stderrLines = await collector.getLines(from: .stderr)

    #expect(stdoutLines == ["out1", "out2"])
    #expect(stderrLines == ["err1"])
}

@Test func fileLogConsumer_writesToFile() async throws {
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("log")

    let consumer = try FileLogConsumer(url: tempURL)
    await consumer.accept(stream: .stdout, line: "test line")

    // Give time for write
    try await Task.sleep(for: .milliseconds(100))

    let content = try String(contentsOf: tempURL)
    #expect(content.contains("test line"))

    try? FileManager.default.removeItem(at: tempURL)
}

@Test func compositeLogConsumer_sendsToAll() async {
    let collector1 = CollectingLogConsumer()
    let collector2 = CollectingLogConsumer()
    let composite = CompositeLogConsumer([collector1, collector2])

    await composite.accept(stream: .stdout, line: "test")

    let lines1 = await collector1.getLines()
    let lines2 = await collector2.getLines()

    #expect(lines1 == ["test"])
    #expect(lines2 == ["test"])
}
```

**Estimated Effort**: 2 hours

### Step 7: Add Integration Tests

**File**: `/Tests/TestContainersTests/LogConsumerIntegrationTests.swift` (new)

**Test Cases**:
```swift
@Test func logConsumer_receivesStdoutLines() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let collector = CollectingLogConsumer()

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "echo line1 && sleep 1 && echo line2"])
        .withLogConsumer(collector)

    try await withContainer(request) { container in
        // Wait for logs
        try await Task.sleep(for: .seconds(2))

        let lines = await collector.getLines(from: .stdout)
        #expect(lines.contains("line1"))
        #expect(lines.contains("line2"))
    }
}

@Test func logConsumer_separatesStdoutAndStderr() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let collector = CollectingLogConsumer()

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "echo stdout && echo stderr >&2"])
        .withLogConsumer(collector)

    try await withContainer(request) { container in
        try await Task.sleep(for: .seconds(1))

        let stdoutLines = await collector.getLines(from: .stdout)
        let stderrLines = await collector.getLines(from: .stderr)

        #expect(stdoutLines.contains("stdout"))
        #expect(stderrLines.contains("stderr"))
    }
}

@Test func logConsumer_worksWithWaitStrategies() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let collector = CollectingLogConsumer()

    let request = ContainerRequest(image: "redis:7-alpine")
        .withExposedPort(6379)
        .withLogConsumer(collector)
        .waitingFor(.logContains("Ready to accept connections"))

    try await withContainer(request) { container in
        // After wait strategy completes, logs should be collected
        let lines = await collector.getLines()
        #expect(lines.contains { $0.contains("Ready to accept connections") })
        #expect(lines.contains { $0.contains("Redis") })
    }
}

@Test func multipleLogConsumers_allReceiveLogs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let collector1 = CollectingLogConsumer()
    let collector2 = CollectingLogConsumer()

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "echo test && sleep 1"])
        .withLogConsumers([collector1, collector2])

    try await withContainer(request) { container in
        try await Task.sleep(for: .seconds(2))

        let lines1 = await collector1.getLines()
        let lines2 = await collector2.getLines()

        #expect(lines1.contains("test"))
        #expect(lines2.contains("test"))
    }
}

@Test func addLogConsumerAfterStart() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "while true; do echo tick; sleep 1; done"])

    try await withContainer(request) { container in
        let collector = CollectingLogConsumer()

        // Add consumer after container is running
        await container.addLogConsumer(collector)
        await container.startLogStreaming()

        try await Task.sleep(for: .seconds(3))

        let lines = await collector.getLines()
        #expect(lines.count >= 2) // Should have multiple "tick" lines
    }
}

@Test func logConsumer_handlesLargeOutput() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let collector = CollectingLogConsumer()

    // Generate 1000 lines of output
    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "for i in $(seq 1 1000); do echo line$i; done"])
        .withLogConsumer(collector)

    try await withContainer(request) { container in
        try await Task.sleep(for: .seconds(2))

        let lines = await collector.getLines()
        #expect(lines.count == 1000)
        #expect(lines.first == "line1")
        #expect(lines.last == "line1000")
    }
}
```

**Estimated Effort**: 3 hours

### Step 8: Documentation and Examples

**Files**:
- Update `README.md` with log consumer examples
- Add API documentation to all public types
- Create `Examples/LogConsumers.swift` with common patterns

**Content**:
```markdown
## Log Consumers

Stream container logs in real-time to custom handlers:

### Basic Usage

```swift
let collector = CollectingLogConsumer()
let request = ContainerRequest(image: "postgres:16")
    .withLogConsumer(collector)

try await withContainer(request) { container in
    // Logs are collected in real-time
    let logs = await collector.getLines()
}
```

### Built-in Consumers

- **PrintLogConsumer**: Print logs to console with optional prefix
- **CollectingLogConsumer**: Collect logs in memory for testing
- **FileLogConsumer**: Write logs to a file
- **CompositeLogConsumer**: Send logs to multiple consumers

### Custom Consumers

Implement the `LogConsumer` protocol:

```swift
struct MetricsConsumer: LogConsumer {
    func accept(stream: LogStream, line: String) async {
        // Process log line
    }
}
```
```

**Estimated Effort**: 2 hours

## Dependencies

### Critical Dependencies

1. **Process Streaming**: Requires enhancing `ProcessRunner` to support real-time output streaming
   - Current implementation only provides output after process completion
   - Need async line-by-line reading from pipes
   - Must handle cancellation correctly

2. **Docker Logs Follow**: Requires `docker logs --follow` command
   - Already available in Docker CLI
   - Blocks until container stops (expected behavior)
   - Properly handles cancellation

3. **Swift Concurrency**: Heavy reliance on async/await and actors
   - Need Swift 5.9+ for full `Sendable` support
   - Actors for thread-safe state management

### Related Features

- **Feature 003**: Exec wait strategy (similar pattern of interacting with running containers)
- **Future: Lifecycle hooks**: Log consumers could be implemented as a specific type of lifecycle hook

## Testing Plan

### Unit Tests

Location: `/Tests/TestContainersTests/LogConsumerTests.swift`

1. Test each built-in consumer implementation
2. Test `CompositeLogConsumer` with multiple consumers
3. Test stream filtering (stdout vs stderr)
4. Test error handling in consumers
5. Test `Sendable` conformance (compile-time)

### Integration Tests

Location: `/Tests/TestContainersTests/LogConsumerIntegrationTests.swift`

1. Test log streaming from real containers
2. Test stdout/stderr separation with real output
3. Test with different container images (Alpine, Redis, Postgres)
4. Test with various output volumes (small, large)
5. Test adding consumers after container start
6. Test multiple consumers on same container
7. Test interaction with wait strategies
8. Test cancellation and cleanup

### Performance Tests

1. Test streaming overhead with high-volume logs
2. Test memory usage with long-running containers
3. Test with multiple concurrent containers each with consumers

### Manual Testing

1. Test with various Docker versions
2. Test with different terminal types (for `PrintLogConsumer`)
3. Test file permissions with `FileLogConsumer`
4. Test with very long log lines (>1MB)
5. Test with binary/non-UTF8 output

## Acceptance Criteria

### Functional

- [ ] `LogConsumer` protocol defined with `accept(stream:line:)` method
- [ ] `LogStream` enum with `.stdout` and `.stderr` cases
- [ ] Built-in consumers implemented:
  - [ ] `PrintLogConsumer`
  - [ ] `CollectingLogConsumer`
  - [ ] `FileLogConsumer`
  - [ ] `CompositeLogConsumer`
- [ ] `ProcessRunner` supports streaming output line-by-line
- [ ] `DockerClient.followLogs()` streams logs to consumers
- [ ] `Container.addLogConsumer()` allows adding consumers
- [ ] `Container.startLogStreaming()` starts streaming
- [ ] `Container.stopLogStreaming()` stops streaming gracefully
- [ ] Log streaming starts before wait strategies execute
- [ ] Log streaming stops on container termination
- [ ] Multiple consumers can be registered on same container
- [ ] Stdout and stderr are properly separated

### API Design

- [ ] Fluent API via `ContainerRequest.withLogConsumer()`
- [ ] Consumers can be added after container creation
- [ ] All types conform to `Sendable`
- [ ] Stateful consumers use actors for thread safety
- [ ] Backwards compatible with existing `logs()` API

### Code Quality

- [ ] Follows existing code patterns and conventions
- [ ] Proper error handling (don't crash on consumer errors)
- [ ] Clean cancellation support
- [ ] Memory efficient (streaming, not buffering)
- [ ] No compiler warnings
- [ ] All public APIs documented

### Testing

- [ ] Unit tests for all consumer implementations
- [ ] Integration tests with real containers
- [ ] Tests verify stdout/stderr separation
- [ ] Tests verify multiple consumers work
- [ ] Tests verify interaction with wait strategies
- [ ] All tests pass locally and in CI

### Documentation

- [ ] API documentation on all public types
- [ ] Usage examples in README
- [ ] Examples for each built-in consumer
- [ ] Example of custom consumer implementation
- [ ] Notes about performance considerations
- [ ] Update FEATURES.md to mark log consumers as implemented

## Open Questions

### 1. Should log consumers receive historical logs?

**Question**: When a consumer is added, should it receive logs that were already produced?

**Options**:
- **A**: Only receive new logs from point of registration
- **B**: Optionally receive historical logs via parameter
- **C**: Always receive all logs from container start

**Recommendation**: Option A (new logs only) for simplicity. Historical logs can be retrieved via existing `logs()` API if needed.

---

### 2. How to handle `Hashable` conformance?

**Question**: `ContainerRequest` is `Hashable`, but protocols can't be hashed.

**Options**:
- **A**: Remove `Hashable` from `ContainerRequest` (breaking change)
- **B**: Exclude `logConsumers` from hash/equality
- **C**: Store consumers only in `Container`, not `ContainerRequest`
- **D**: Store type-erased factories/closures that can be hashed by identity

**Recommendation**: Option D with factories, or Option C if too complex.

---

### 3. Should we support filtering log lines?

**Question**: Should consumers be able to filter which lines they receive?

**Options**:
- **A**: No filtering, consumers receive all lines
- **B**: Consumers can return `Bool` to indicate interest
- **C**: Separate `FilteringLogConsumer` protocol

**Recommendation**: Option A. Users can implement filtering in their consumer's `accept()` method.

---

### 4. What about timestamps?

**Question**: Docker can include timestamps with `--timestamps` flag. Should we expose these?

**Options**:
- **A**: Strip timestamps, only deliver log content
- **B**: Parse and include timestamp in `accept()` signature
- **C**: Make it configurable per consumer
- **D**: Deliver raw line with timestamp prefix

**Recommendation**: Option B with parsed `Date` parameter for maximum flexibility.

**Updated Signature**:
```swift
func accept(stream: LogStream, line: String, timestamp: Date?) async
```

---

### 5. How to handle consumer errors?

**Question**: If a consumer throws or fails, what should happen?

**Options**:
- **A**: Ignore and continue with other consumers
- **B**: Stop streaming on first error
- **C**: Track errors and report at end
- **D**: Let errors propagate and crash container

**Recommendation**: Option A (ignore and continue). Log error to stderr. Consumers shouldn't crash container lifecycle.

---

### 6. Should we support pausing/resuming?

**Question**: Should log streaming be pausable/resumable?

**Options**:
- **A**: No, streaming is all-or-nothing
- **B**: Yes, via `pauseLogStreaming()` / `resumeLogStreaming()`

**Recommendation**: Option A for MVP. Can add in future if needed.

---

### 7. What about log size limits?

**Question**: Should we limit memory usage of collecting consumers?

**Options**:
- **A**: No limits, user's responsibility
- **B**: Built-in limit with oldest-first eviction
- **C**: Configurable limit per consumer

**Recommendation**: Option A for MVP. Document memory implications. Users can implement size-limited consumers if needed.

## Risks and Mitigations

### Risk: Process Streaming Complexity

**Impact**: Reading from pipes in real-time while handling cancellation is complex and error-prone.

**Mitigation**:
- Use established patterns from Foundation's `Process` APIs
- Extensive testing with various output patterns
- Handle partial lines correctly with buffering
- Test cancellation thoroughly

---

### Risk: Docker Logs Performance

**Impact**: `docker logs --follow` might have overhead, especially for high-volume logs.

**Mitigation**:
- Benchmark with realistic workloads
- Document performance characteristics
- Consider rate limiting in consumers if needed
- Make log consumers optional (off by default)

---

### Risk: Memory Leaks

**Impact**: Long-running containers with consumers might leak memory if not properly managed.

**Mitigation**:
- Use actors for state management
- Careful task cancellation
- Test with long-running containers
- Document cleanup requirements

---

### Risk: Breaking Changes

**Impact**: Adding `logConsumers` to `ContainerRequest` might break `Hashable`.

**Mitigation**:
- Store consumers separately in `Container`
- Or use type-erasure techniques
- Or exclude from hash (document behavior)
- Thorough testing of affected code

---

### Risk: Consumer Errors

**Impact**: Badly written consumers could crash container lifecycle.

**Mitigation**:
- Catch and log consumer errors
- Continue with other consumers on failure
- Document error handling expectations
- Provide examples of robust consumers

## Future Enhancements

### Phase 2: Enhanced Features

1. **Timestamp Parsing**: Parse Docker timestamps and include in log entries
2. **Log Filtering**: Built-in filter consumers (regex, level, etc.)
3. **Log Rotation**: Built-in file consumer with size/time rotation
4. **Structured Logging**: Parse JSON logs into structured data
5. **Log Buffering**: Buffer logs when consumers are slow

### Phase 3: Advanced Features

1. **Log Aggregation**: Send logs to external systems (Elasticsearch, Splunk)
2. **Real-time Search**: Search logs as they're produced
3. **Log Analytics**: Built-in consumers for metrics and alerting
4. **Multi-container Correlation**: Correlate logs from multiple containers
5. **Performance Monitoring**: Track log volume, consumer performance

### Integration with Other Features

1. **Lifecycle Hooks**: Implement consumers as post-start hooks
2. **Health Checks**: Use logs for health status determination
3. **Auto-diagnostics**: Save logs automatically on container failure
4. **Reaper Integration**: Collect logs before cleanup

## References

### Existing Code

- `/Sources/TestContainers/Container.swift` - Current log retrieval (line 28-30)
- `/Sources/TestContainers/DockerClient.swift` - Docker logs implementation (lines 60-63)
- `/Sources/TestContainers/ProcessRunner.swift` - Process execution infrastructure
- `/Sources/TestContainers/Waiter.swift` - Pattern for async polling operations
- `/Sources/TestContainers/WithContainer.swift` - Container lifecycle management

### Similar Projects

- **Testcontainers Java**: `LogConsumer` interface, `Slf4jLogConsumer`, `ToStringConsumer`
- **Testcontainers Go**: `LogConsumer` interface, `TestLogger` consumer
- **Docker SDK for Go**: `ContainerLogs` streaming API
- **Kubernetes Go Client**: Log streaming implementation

### Docker Documentation

- [docker logs](https://docs.docker.com/engine/reference/commandline/logs/) - Log retrieval command
- [docker logs --follow](https://docs.docker.com/engine/reference/commandline/logs/#follow) - Log streaming

### Related RFCs/Tickets

- Feature 003: Exec wait strategy (similar container interaction patterns)
- FEATURES.md line 76: Log consumers listed as Tier 2 feature
