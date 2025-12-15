# Feature: Regex Log Wait Strategy

**Status:** Implemented
**Priority:** Tier 1 (High)
**Tracking:** [FEATURES.md#L23](../FEATURES.md)
**Created:** 2025-12-15
**Implemented:** 2025-12-15

## Summary

Add a regex-based log wait strategy (`.logMatches(regex, ...)`) that allows containers to wait until their logs match a regular expression pattern. This provides more flexible pattern matching than the current `.logContains(string, ...)` strategy, enabling users to:

- Match complex log patterns (e.g., "Server started on port [0-9]+")
- Extract dynamic values from logs using capture groups (e.g., port numbers, IDs, tokens)
- Validate log format compliance during startup
- Handle case-sensitive/insensitive matching with regex flags

## Current State

### Existing Log Wait Implementation

The codebase currently supports basic string matching via `.logContains`:

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

```swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
}
```

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

```swift
func waitUntilReady() async throws {
    switch request.waitStrategy {
    case .none:
        return
    case let .logContains(needle, timeout, pollInterval):
        try await Waiter.wait(timeout: timeout, pollInterval: pollInterval, description: "container logs to contain '\(needle)'") { [docker, id] in
            let text = try await docker.logs(id: id)
            return text.contains(needle)
        }
    case let .tcpPort(containerPort, timeout, pollInterval):
        // ...
    }
}
```

**How it works:**
1. `WaitStrategy` is an enum with associated values for timeout and poll interval
2. `Container.waitUntilReady()` executes the wait strategy after container start
3. `Waiter.wait()` polls a predicate function at regular intervals until timeout
4. `DockerClient.logs(id:)` fetches container logs via `docker logs <id>`

**Limitations:**
- Only exact substring matching (no pattern support)
- Cannot extract dynamic values from logs
- Cannot validate complex log formats
- No support for multi-line pattern matching

## Requirements

### Functional Requirements

1. **Regex Pattern Matching**
   - Support Foundation's `Regex` type (Swift 5.7+)
   - Match logs against user-provided regex patterns
   - Support both single-line and multi-line matching modes
   - Provide clear error messages when regex is invalid

2. **Timeout and Polling**
   - Default timeout: 60 seconds (consistent with `.logContains`)
   - Default poll interval: 200ms (consistent with `.logContains`)
   - User-configurable timeout and poll interval
   - Descriptive timeout error messages including regex pattern

3. **Capture Groups Support**
   - Extract matched capture groups from logs
   - Return captured values to caller (e.g., dynamic port, token, ID)
   - Support named capture groups
   - Handle multiple matches (first match vs. all matches)

4. **API Consistency**
   - Follow existing `WaitStrategy` pattern
   - Conform to `Sendable` and `Hashable` protocols
   - Use Swift concurrency (`async/await`)
   - Match naming conventions of existing strategies

### Non-Functional Requirements

1. **Performance**
   - Avoid re-compiling regex on every poll iteration
   - Minimize memory allocations during polling
   - Efficient log retrieval (leverage existing `DockerClient.logs()`)

2. **Error Handling**
   - Invalid regex patterns should fail at compile-time when using regex literals
   - Invalid regex strings should fail early during container start
   - Timeout errors should include helpful context (pattern, duration)

3. **Testing**
   - Unit tests for regex matching logic
   - Integration tests with real containers
   - Edge cases: empty logs, no match, multiple matches, capture groups

## API Design

### Proposed Implementation

#### Option 1: String Pattern (Simple)

```swift
// In ContainerRequest.swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logMatches(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    //              ^^^^^^ regex pattern as String
}
```

**Usage:**
```swift
let request = ContainerRequest(image: "postgres:16")
    .waitingFor(.logMatches("database system is ready to accept connections", timeout: .seconds(30)))
```

**Pros:**
- Simple API, minimal changes
- Pattern can be constructed dynamically
- Conforms to `Hashable` easily

**Cons:**
- Regex errors only discovered at runtime
- No compile-time validation
- Cannot extract capture groups easily

#### Option 2: Regex Type with Capture Groups (Advanced)

```swift
// In ContainerRequest.swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logMatches(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logMatchesWithCapture(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
}

// New type for captured values
public struct LogMatch: Sendable, Hashable {
    public let fullMatch: String
    public let captures: [String?]

    public func capture(_ index: Int) -> String? {
        guard index < captures.count else { return nil }
        return captures[index]
    }
}
```

**Extended Container API:**
```swift
public actor Container {
    // ... existing methods ...

    private var _logMatch: LogMatch?

    public func logMatch() -> LogMatch? {
        _logMatch
    }
}
```

**Usage:**
```swift
let request = ContainerRequest(image: "nginx:latest")
    .waitingFor(.logMatchesWithCapture(
        #"server started on port (\d+)"#,
        timeout: .seconds(30)
    ))

try await withContainer(request) { container in
    if let match = await container.logMatch() {
        let port = match.capture(1) // "8080"
        print("Server listening on port: \(port)")
    }
}
```

**Pros:**
- Supports capture group extraction
- Useful for dynamic values (ports, tokens, IDs)
- More powerful for complex scenarios

**Cons:**
- More complex implementation
- Requires storing match state in Container
- Hashable conformance requires storing pattern string

#### Option 3: Hybrid Approach (Recommended)

Start with Option 1 (simple string pattern) for MVP, then add capture group support in a follow-up iteration if needed.

```swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logMatches(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
}
```

### Regex Compilation Strategy

To avoid re-compiling regex on every poll:

```swift
// In Container.swift
func waitUntilReady() async throws {
    switch request.waitStrategy {
    // ... existing cases ...
    case let .logMatches(pattern, timeout, pollInterval):
        // Compile regex once outside polling loop
        let regex: Regex<Substring>
        do {
            regex = try Regex(pattern)
        } catch {
            throw TestContainersError.invalidRegexPattern(pattern, error: error)
        }

        try await Waiter.wait(
            timeout: timeout,
            pollInterval: pollInterval,
            description: "container logs to match pattern '\(pattern)'"
        ) { [docker, id] in
            let text = try await docker.logs(id: id)
            return text.contains(regex)
        }
    }
}
```

## Implementation Steps

### Step 1: Update Error Types

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    // ... existing cases ...
    case invalidRegexPattern(String, error: Error)

    public var description: String {
        switch self {
        // ... existing cases ...
        case let .invalidRegexPattern(pattern, error):
            return "Invalid regex pattern '\(pattern)': \(error.localizedDescription)"
        }
    }
}
```

### Step 2: Add WaitStrategy Case

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

```swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logMatches(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
}
```

### Step 3: Implement Wait Logic

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

Add case to `waitUntilReady()`:

```swift
func waitUntilReady() async throws {
    switch request.waitStrategy {
    case .none:
        return
    case let .logContains(needle, timeout, pollInterval):
        try await Waiter.wait(timeout: timeout, pollInterval: pollInterval, description: "container logs to contain '\(needle)'") { [docker, id] in
            let text = try await docker.logs(id: id)
            return text.contains(needle)
        }
    case let .logMatches(pattern, timeout, pollInterval):
        // Compile regex once before polling
        let regex: Regex<Substring>
        do {
            regex = try Regex(pattern)
        } catch {
            throw TestContainersError.invalidRegexPattern(pattern, error: error)
        }

        try await Waiter.wait(
            timeout: timeout,
            pollInterval: pollInterval,
            description: "container logs to match regex '\(pattern)'"
        ) { [docker, id] in
            let text = try await docker.logs(id: id)
            return text.contains(regex)
        }
    case let .tcpPort(containerPort, timeout, pollInterval):
        // ... existing implementation ...
        let hostPort = try await docker.port(id: id, containerPort: containerPort)
        let host = request.host
        try await Waiter.wait(timeout: timeout, pollInterval: pollInterval, description: "TCP port \(host):\(hostPort) to accept connections") {
            TCPProbe.canConnect(host: host, port: hostPort, timeout: .milliseconds(200))
        }
    }
}
```

### Step 4: Add Unit Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

```swift
import Testing
@testable import TestContainers

@Test func waitStrategy_logMatches_configuresCorrectly() {
    let request = ContainerRequest(image: "test:latest")
        .waitingFor(.logMatches("ready.*accept", timeout: .seconds(45), pollInterval: .milliseconds(300)))

    if case let .logMatches(pattern, timeout, pollInterval) = request.waitStrategy {
        #expect(pattern == "ready.*accept")
        #expect(timeout == .seconds(45))
        #expect(pollInterval == .milliseconds(300))
    } else {
        Issue.record("Expected .logMatches wait strategy")
    }
}

@Test func waitStrategy_logMatches_defaultValues() {
    let request = ContainerRequest(image: "test:latest")
        .waitingFor(.logMatches("pattern"))

    if case let .logMatches(pattern, timeout, pollInterval) = request.waitStrategy {
        #expect(pattern == "pattern")
        #expect(timeout == .seconds(60))
        #expect(pollInterval == .milliseconds(200))
    } else {
        Issue.record("Expected .logMatches wait strategy")
    }
}

@Test func waitStrategy_logMatches_conformsToHashable() {
    let strategy1 = WaitStrategy.logMatches("pattern", timeout: .seconds(30))
    let strategy2 = WaitStrategy.logMatches("pattern", timeout: .seconds(30))
    let strategy3 = WaitStrategy.logMatches("different", timeout: .seconds(30))

    #expect(strategy1 == strategy2)
    #expect(strategy1 != strategy3)
}
```

### Step 5: Add Integration Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

```swift
@Test func canWaitForLogMatch_postgres() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "postgres:16-alpine")
        .withEnvironment(["POSTGRES_PASSWORD": "test"])
        .waitingFor(.logMatches(
            #"database system is ready to accept connections"#,
            timeout: .seconds(60)
        ))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("database system is ready"))
    }
}

@Test func canWaitForLogMatch_complexPattern() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "nginx:alpine")
        .waitingFor(.logMatches(
            #"nginx/.* \[notice\].*start worker process"#,
            timeout: .seconds(30)
        ))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("worker process"))
    }
}

@Test func logMatch_failsOnInvalidRegex() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7-alpine")
        .waitingFor(.logMatches(
            #"[invalid(regex"#,  // Invalid regex pattern
            timeout: .seconds(10)
        ))

    await #expect(throws: TestContainersError.self) {
        try await withContainer(request) { _ in }
    }
}

@Test func logMatch_timesOutWhenPatternNeverMatches() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7-alpine")
        .waitingFor(.logMatches(
            #"this will never appear in redis logs"#,
            timeout: .seconds(3)
        ))

    await #expect(throws: TestContainersError.timeout(_:)) {
        try await withContainer(request) { _ in }
    }
}
```

### Step 6: Update Documentation

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md`

Update the implemented features list:

```markdown
**Wait strategies**
- [x] `.none`
- [x] `.tcpPort(port, timeout, pollInterval)`
- [x] `.logContains(string, timeout, pollInterval)`
- [x] `.logMatches(regex, timeout, pollInterval)`
```

## Testing Plan

### Unit Tests

**Coverage:**
- [x] WaitStrategy configuration with custom timeout/poll interval
- [x] WaitStrategy configuration with default values
- [x] WaitStrategy Hashable conformance
- [x] WaitStrategy Sendable conformance (compile-time)

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

### Integration Tests

**Test Scenarios:**

| Test Case | Image | Pattern | Expected Outcome |
|-----------|-------|---------|------------------|
| Simple match | `postgres:16-alpine` | `database system is ready` | Success |
| Complex regex | `nginx:alpine` | `nginx/.* \[notice\].*worker` | Success |
| Case sensitivity | `redis:7-alpine` | `Ready to accept connections` | Success |
| Multi-line pattern | Custom image | Pattern spanning lines | Success |
| Invalid regex | Any | `[invalid(` | Throws error early |
| No match timeout | `redis:7-alpine` | `impossible pattern` | Timeout error |
| Early match | `redis:7-alpine` | `Ready` | Fast success |

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

**Opt-in:** All integration tests respect `TESTCONTAINERS_RUN_DOCKER_TESTS=1` environment variable.

### Edge Cases

1. **Empty logs:** Container has no output yet - should keep polling
2. **Very long logs:** Pattern appears after thousands of lines - should work
3. **Pattern at start:** Match in first log line - should succeed immediately
4. **Pattern at end:** Match in last log line before timeout - should succeed
5. **Multiple matches:** Pattern appears multiple times - should succeed on first match
6. **Special characters:** Pattern with special regex chars properly escaped
7. **Unicode:** Pattern with emoji and international characters

### Performance Tests

1. **Regex compilation overhead:** Verify regex is compiled once, not per poll
2. **Log retrieval frequency:** Verify polling respects poll interval
3. **Memory usage:** Ensure no memory leaks during long-running waits

## Acceptance Criteria

### Definition of Done

- [x] `WaitStrategy.logMatches` case added to enum with default parameters
- [x] `Container.waitUntilReady()` implements regex matching logic
- [x] Invalid regex patterns throw `TestContainersError.invalidRegexPattern`
- [x] Timeout errors include the regex pattern in error message
- [x] Regex is compiled once before polling loop (not per iteration)
- [x] All unit tests pass (configuration, defaults, Hashable/Sendable)
- [x] All integration tests pass (real containers, various patterns)
- [x] Edge cases tested (invalid regex, timeout, early match)
- [x] FEATURES.md updated to mark regex log waits as implemented
- [x] Code follows existing patterns (async/await, Sendable, Hashable)
- [x] No breaking changes to existing API

### Quality Gates

**Code Review:**
- Consistent with existing `WaitStrategy` patterns
- Uses Swift concurrency best practices
- Error messages are clear and actionable
- Regex compilation is efficient (compiled once)

**Testing:**
- Unit test coverage for all new code paths
- Integration tests with real Docker containers
- Edge cases covered (invalid regex, timeout, empty logs)
- Tests are deterministic and don't flake

**Documentation:**
- FEATURES.md updated with checkbox
- Code comments explain regex compilation strategy
- Test code demonstrates API usage patterns

## Future Enhancements

*Not in scope for this ticket, but potential follow-ups:*

1. **Capture Groups (v2)**
   - Add `.logMatchesWithCapture` variant
   - Store captured values in Container
   - Expose via `container.logMatch()` API

2. **Multi-line Matching**
   - Add flag for multi-line mode
   - Support patterns spanning log lines

3. **Case Insensitivity**
   - Add flag for case-insensitive matching
   - API: `.logMatches(pattern, caseInsensitive: true)`

4. **Multiple Patterns**
   - Wait for ANY of multiple patterns
   - Wait for ALL of multiple patterns
   - API: `.logMatches(anyOf: [pattern1, pattern2])`

5. **Negative Matching**
   - Fail if pattern appears in logs
   - API: `.logNotMatches(pattern)`

6. **Streaming Logs**
   - Stream logs instead of fetching all on each poll
   - More efficient for containers with high log volume
   - Requires `docker logs -f` or Docker SDK

## References

### Existing Code Patterns

- **WaitStrategy enum:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift#L20-L24`
- **Wait implementation:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift#L36-L52`
- **Waiter utility:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift#L3-L20`
- **Error types:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift#L3-L21`
- **Integration test pattern:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift#L5-L19`

### External References

- [Swift Regex Documentation](https://developer.apple.com/documentation/swift/regex)
- [testcontainers-go wait strategies](https://golang.testcontainers.org/features/wait/)
- [testcontainers-java log wait strategy](https://java.testcontainers.org/features/startup_and_waits/#log-output-wait-strategy)

## Related Features

- **Composite Wait Strategies:** `.all([.logMatches(...), .tcpPort(...)])` - track multiple conditions
- **HTTP Wait Strategy:** Similar polling pattern, different predicate
- **Exec Wait Strategy:** Run command, check exit code - another polling use case
- **Better Diagnostics:** Include log snippet in timeout errors

---

**Estimated Effort:** 4-6 hours
**Dependencies:** None (uses Foundation's Regex, available in Swift 5.7+)
**Risk:** Low (follows established patterns, minimal API surface)
