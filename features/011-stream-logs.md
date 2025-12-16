# Feature 011: Stream Container Logs (Follow Mode)

**Status**: IMPLEMENTED

**Implementation Date**: 2025-12-16

## Summary

Add support for streaming container logs in real-time using follow mode (equivalent to `docker logs -f`). This feature allows consumers to continuously monitor container output as it happens, rather than fetching all logs at once.

## Implementation

### Files Added/Modified

- **Sources/TestContainers/LogStreaming.swift** (new) - `LogStreamOptions` and `LogEntry` types
- **Sources/TestContainers/ProcessRunner.swift** - Added `streamLines()` method for streaming process output
- **Sources/TestContainers/DockerClient.swift** - Added `streamLogs()` method
- **Sources/TestContainers/Container.swift** - Added public `streamLogs()` method
- **Tests/TestContainersTests/LogStreamingTests.swift** (new) - Unit tests for types
- **Tests/TestContainersTests/LogStreamingIntegrationTests.swift** (new) - Integration tests

### API

```swift
// Container.swift - streaming method
public nonisolated func streamLogs(
    options: LogStreamOptions = .default
) -> AsyncThrowingStream<LogEntry, Error>

// LogStreaming.swift - supporting types
public struct LogStreamOptions: Sendable, Hashable {
    public var follow: Bool        // Follow mode (like -f)
    public var stdout: Bool        // Include stdout
    public var stderr: Bool        // Include stderr
    public var timestamps: Bool    // Include timestamps
    public var since: Date?        // Only logs after this time
    public var until: Date?        // Only logs before this time
    public var tail: Int?          // Number of lines from end

    public static let `default` = LogStreamOptions()
}

public struct LogEntry: Sendable, Hashable {
    public enum Stream: Sendable, Hashable {
        case stdout
        case stderr
    }

    public var stream: Stream
    public var message: String
    public var timestamp: Date?
}
```

### Usage Examples

```swift
// Example 1: Basic streaming (default follows logs)
try await withContainer(request) { container in
    for try await entry in container.streamLogs() {
        print("[\(entry.stream)] \(entry.message)")
    }
}

// Example 2: Tail last 100 lines without following
let options = LogStreamOptions(follow: false, tail: 100)
for try await entry in container.streamLogs(options: options) {
    print(entry.message)
}

// Example 3: With timestamps
let options = LogStreamOptions(timestamps: true)
for try await entry in container.streamLogs(options: options) {
    if let ts = entry.timestamp {
        print("\(ts): \(entry.message)")
    }
}

// Example 4: Early termination
for try await entry in container.streamLogs() {
    print(entry.message)
    if entry.message.contains("ready") {
        break // Stream terminates cleanly
    }
}
```

## Acceptance Criteria

### Must Have - COMPLETED

- [x] `LogStreamOptions` struct with all relevant fields defined
- [x] `LogEntry` struct with stream type, message, and optional timestamp
- [x] `Container.streamLogs(options:)` returns `AsyncThrowingStream<LogEntry, Error>`
- [x] `DockerClient.streamLogs()` implements streaming using `docker logs -f`
- [x] Line buffering correctly handles partial data and produces complete lines
- [x] Task cancellation terminates the underlying Docker process
- [x] Follow mode (`-f`) streams logs in real-time
- [x] `--tail` option limits initial output
- [x] `--timestamps` option includes timestamps in LogEntry
- [x] Integration tests pass with real Docker containers
- [x] Documentation includes usage examples
- [x] Existing `logs()` method remains unchanged (backward compatibility)

### Should Have - COMPLETED

- [x] `--since` and `--until` time filters supported
- [x] Stream ends gracefully when container stops
- [x] Error handling for Docker process failures

### Could Have - NOT IMPLEMENTED

- [ ] Enhance `.logContains()` wait strategy to use streaming
- [ ] Support for Docker Engine API (proper stdout/stderr separation)
- [ ] Configurable buffer sizes and backpressure handling
- [ ] Structured logging output (JSON format)

### Won't Have (This Iteration)

- [ ] Stdout/stderr separation using CLI (requires Docker API)
- [ ] Log filtering by regex pattern
- [ ] Log aggregation from multiple containers
- [ ] Persistent log storage or replay functionality

## Implementation Notes

### Stream Separation Limitation

The Docker CLI's `docker logs -f` combines stdout and stderr into a single stream. The current implementation defaults all entries to `.stdout`. Accurate stream separation would require the Docker Engine API.

### Line Buffering

Uses swift-subprocess's built-in `AsyncBufferSequence.lines()` method for efficient line-by-line streaming. Newlines are trimmed from the output.

### Actor Isolation

`Container.streamLogs()` is marked `nonisolated` since it returns a stream without needing to access actor-isolated state synchronously. This allows calling the method from outside the actor without `await`.

### Cancellation Support

The streaming implementation properly handles task cancellation via `AsyncThrowingStream.onTermination`, which cancels the underlying Task when the consumer breaks out of the loop or the stream is otherwise terminated.

## Test Coverage

### Unit Tests (27 tests)
- LogStreamOptions default values and builders
- LogStreamOptions to Docker args conversion
- LogEntry creation and parsing
- Timestamp parsing with various formats
- Sendable/Hashable conformance

### Integration Tests (10 tests)
- Basic output capture
- Tail limiting
- Timestamp inclusion
- Real-time following
- Early break/cancellation
- Empty output handling
- Stderr capture
- Multiline output
- Long lines
- Default options behavior

## Future Enhancements

### Docker Engine API Integration

Replace CLI-based approach with Docker Engine API HTTP client:
- Accurate stdout/stderr stream separation
- Better performance (no process spawning overhead)
- More reliable streaming with proper HTTP/2 multiplexing
- Access to additional log drivers and formats

### Enhanced Wait Strategy

Consider updating `.logContains()` to use streaming instead of polling for better efficiency.

## References

- Docker CLI: `docker logs --help`
- Swift Concurrency: AsyncSequence, AsyncThrowingStream
- swift-subprocess: AsyncBufferSequence.lines()
