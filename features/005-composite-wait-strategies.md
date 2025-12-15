# Feature 005: Composite Wait Strategies

**Status**: Implemented
**Priority**: Tier 1 (High Priority)
**Tracking**: FEATURES.md line 39

---

## Summary

Implement composite wait strategies that allow combining multiple wait conditions with logical operators. This enables users to wait for complex readiness scenarios where multiple conditions must be satisfied (`.all([...])`) or where any one of several conditions indicates readiness (`.any([...])`).

**Use cases:**
- Wait for both TCP port **and** log message (database ready + migrations complete)
- Wait for either HTTP endpoint **or** specific log (service starts in different modes)
- Nested combinations for complex multi-service dependencies
- Different timeout requirements for different conditions within the same container

---

## Current State

### Wait Strategy Architecture

Wait strategies are defined as an enum in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`:

```swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
}
```

**Current limitations:**
- Only one wait strategy per container (`ContainerRequest.waitStrategy: WaitStrategy`)
- No way to combine multiple conditions
- Each strategy has its own timeout, but no coordination between strategies

### Wait Strategy Execution

Execution happens in `Container.waitUntilReady()` at `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`:

```swift
func waitUntilReady() async throws {
    switch request.waitStrategy {
    case .none:
        return
    case let .logContains(needle, timeout, pollInterval):
        try await Waiter.wait(timeout: timeout, pollInterval: pollInterval,
                             description: "container logs to contain '\(needle)'") { [docker, id] in
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

### Wait Execution Engine

The generic wait logic is handled by `Waiter.wait()` at `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift`:

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

---

## Requirements

### Functional Requirements

1. **All Strategy** (`.all([...])`)
   - Execute multiple wait strategies in parallel
   - All conditions must succeed for the composite to succeed
   - If any condition fails/times out, the entire composite fails
   - Report which condition failed in error messages

2. **Any Strategy** (`.any([...])`)
   - Execute multiple wait strategies in parallel
   - First condition to succeed causes the composite to succeed
   - All conditions must fail/timeout for the composite to fail
   - Report all failures if all conditions fail

3. **Nested Composition**
   - Composites can contain other composites
   - Example: `.all([.any([...]), .tcpPort(...)])`
   - No arbitrary depth limits (trust Swift's recursion limits)

4. **Timeout Handling**
   - Each strategy in a composite retains its own timeout
   - Composite-level timeout optional (applies to the entire composition)
   - For `.all()`: fail fast on first timeout
   - For `.any()`: continue until one succeeds or all timeout

5. **Poll Interval**
   - Each strategy uses its own poll interval
   - Composite strategies don't introduce additional polling

### Non-Functional Requirements

1. **Sendability**: All types remain `Sendable` for Swift concurrency
2. **Hashability**: Maintain `Hashable` conformance for `WaitStrategy`
3. **Type Safety**: Compile-time guarantees, no runtime type checking
4. **Performance**: Parallel execution where possible, no unnecessary serialization
5. **Error Clarity**: Clear error messages indicating which condition(s) failed

---

## API Design

### Proposed WaitStrategy Enum Changes

```swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))

    // New cases
    case all([WaitStrategy], timeout: Duration? = nil)
    case any([WaitStrategy], timeout: Duration? = nil)
}
```

**Design rationale:**
- Recursive enum pattern (strategy can contain strategies)
- Optional composite timeout overrides individual strategy timeouts
- Empty array handling: `.all([])` succeeds immediately, `.any([])` fails immediately
- Single-element optimization opportunity: `.all([.tcpPort(8080)])` behaves like `.tcpPort(8080)`

### Usage Examples

#### Example 1: Database Ready AND Migrations Complete

```swift
let request = ContainerRequest(image: "postgres:15")
    .withExposedPort(5432)
    .withEnvironment(["POSTGRES_PASSWORD": "test"])
    .waitingFor(.all([
        .tcpPort(5432, timeout: .seconds(30)),
        .logContains("database system is ready to accept connections", timeout: .seconds(45))
    ]))
```

#### Example 2: Service Starts in Multiple Modes

```swift
let request = ContainerRequest(image: "myservice:latest")
    .withExposedPort(8080)
    .waitingFor(.any([
        .logContains("HTTP server listening", timeout: .seconds(20)),
        .logContains("gRPC server listening", timeout: .seconds(20)),
    ]))
```

#### Example 3: Nested Composition

```swift
let request = ContainerRequest(image: "complex-service:latest")
    .withExposedPort(8080)
    .withExposedPort(9090)
    .waitingFor(.all([
        // Either port must be accepting connections
        .any([
            .tcpPort(8080, timeout: .seconds(10)),
            .tcpPort(9090, timeout: .seconds(10))
        ]),
        // AND specific log must appear
        .logContains("All subsystems initialized", timeout: .seconds(30))
    ], timeout: .seconds(60))) // Overall timeout
```

#### Example 4: With Composite-Level Timeout

```swift
let request = ContainerRequest(image: "slow-starter:latest")
    .withExposedPort(8080)
    .waitingFor(.all([
        .tcpPort(8080, timeout: .seconds(120)),  // Individual: 2 minutes
        .logContains("Ready", timeout: .seconds(120))  // Individual: 2 minutes
    ], timeout: .seconds(90)))  // Composite: 1.5 minutes (wins)
```

---

## Implementation Steps

### Step 1: Update WaitStrategy Enum
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

- Add `.all([WaitStrategy], timeout: Duration? = nil)` case
- Add `.any([WaitStrategy], timeout: Duration? = nil)` case
- Verify `Sendable` and `Hashable` conformance still works
- Add validation for empty arrays (optional: could be runtime check in execution)

### Step 2: Implement Composite Wait Logic
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

Add new cases to `waitUntilReady()`:

```swift
case let .all(strategies, compositeTimeout):
    try await waitForAll(strategies, compositeTimeout: compositeTimeout)

case let .any(strategies, compositeTimeout):
    try await waitForAny(strategies, compositeTimeout: compositeTimeout)
```

### Step 3: Implement waitForAll Helper
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

```swift
private func waitForAll(_ strategies: [WaitStrategy], compositeTimeout: Duration?) async throws {
    // Edge case: empty array
    guard !strategies.isEmpty else { return }

    // Single strategy optimization
    if strategies.count == 1 {
        try await waitForStrategy(strategies[0])
        return
    }

    // Parallel execution with composite timeout
    if let timeout = compositeTimeout {
        try await withTimeout(timeout, description: "all wait strategies to complete") {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for strategy in strategies {
                    group.addTask { [weak self] in
                        try await self?.waitForStrategy(strategy)
                    }
                }
                try await group.waitForAll()
            }
        }
    } else {
        // No composite timeout, just run in parallel
        try await withThrowingTaskGroup(of: Void.self) { group in
            for strategy in strategies {
                group.addTask { [weak self] in
                    try await self?.waitForStrategy(strategy)
                }
            }
            try await group.waitForAll()
        }
    }
}
```

**Implementation notes:**
- Use `withThrowingTaskGroup` for parallel execution
- Fail fast: first failure cancels remaining tasks
- Composite timeout wraps the entire group
- Recursive: `waitForStrategy` handles nested composites

### Step 4: Implement waitForAny Helper
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

```swift
private func waitForAny(_ strategies: [WaitStrategy], compositeTimeout: Duration?) async throws {
    // Edge case: empty array should fail
    guard !strategies.isEmpty else {
        throw TestContainersError.timeout("no wait strategies provided to .any([])")
    }

    // Single strategy optimization
    if strategies.count == 1 {
        try await waitForStrategy(strategies[0])
        return
    }

    // Use TaskGroup to race strategies
    let timeout = compositeTimeout ?? strategies.map { $0.maxTimeout() }.max() ?? .seconds(60)

    try await withTimeout(timeout, description: "any wait strategy to complete") {
        try await withThrowingTaskGroup(of: Int.self) { group in
            var errors: [Int: Error] = [:]

            for (index, strategy) in strategies.enumerated() {
                group.addTask { [weak self] in
                    do {
                        try await self?.waitForStrategy(strategy)
                        return index
                    } catch {
                        throw (index, error)
                    }
                }
            }

            while let result = try await group.next() {
                // First success wins
                group.cancelAll()
                return
            }

            // All failed
            throw TestContainersError.allWaitStrategiesFailed(errors)
        }
    }
}
```

**Implementation notes:**
- Race all strategies in parallel
- First success cancels others and returns
- Collect all errors if all fail
- Composite timeout or max of individual timeouts

### Step 5: Refactor waitUntilReady
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

Extract existing switch cases into `waitForStrategy(_ strategy: WaitStrategy)` helper:

```swift
private func waitForStrategy(_ strategy: WaitStrategy) async throws {
    switch strategy {
    case .none:
        return
    case let .logContains(needle, timeout, pollInterval):
        // ... existing logic
    case let .tcpPort(containerPort, timeout, pollInterval):
        // ... existing logic
    case let .all(strategies, compositeTimeout):
        try await waitForAll(strategies, compositeTimeout: compositeTimeout)
    case let .any(strategies, compositeTimeout):
        try await waitForAny(strategies, compositeTimeout: compositeTimeout)
    }
}

func waitUntilReady() async throws {
    try await waitForStrategy(request.waitStrategy)
}
```

### Step 6: Add Timeout Wrapper Utility
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift`

```swift
extension Waiter {
    static func withTimeout<T>(
        _ timeout: Duration,
        description: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestContainersError.timeout(description)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
```

### Step 7: Update Error Types
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

Add new error case for composite failures:

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    case dockerNotAvailable(String)
    case commandFailed(command: [String], exitCode: Int32, stdout: String, stderr: String)
    case unexpectedDockerOutput(String)
    case timeout(String)
    case allWaitStrategiesFailed([Int: Error])  // New case

    public var description: String {
        switch self {
        // ... existing cases
        case let .allWaitStrategiesFailed(errors):
            let details = errors.map { "  [\($0.key)] \($0.value)" }.joined(separator: "\n")
            return "All wait strategies in .any([...]) failed:\n\(details)"
        }
    }
}
```

### Step 8: Add Helper Methods
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

```swift
extension WaitStrategy {
    /// Returns the maximum timeout for this strategy (recursively for composites)
    func maxTimeout() -> Duration {
        switch self {
        case .none:
            return .seconds(0)
        case let .tcpPort(_, timeout, _):
            return timeout
        case let .logContains(_, timeout, _):
            return timeout
        case let .all(strategies, compositeTimeout):
            let maxChild = strategies.map { $0.maxTimeout() }.max() ?? .seconds(0)
            return compositeTimeout ?? maxChild
        case let .any(strategies, compositeTimeout):
            let maxChild = strategies.map { $0.maxTimeout() }.max() ?? .seconds(0)
            return compositeTimeout ?? maxChild
        }
    }
}
```

---

## Testing Plan

### Unit Tests
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/WaitStrategyTests.swift` (new)

1. **Test Hashable/Sendable Conformance**
   ```swift
   @Test func waitStrategyIsHashable() {
       let s1 = WaitStrategy.all([.tcpPort(8080), .logContains("ready")])
       let s2 = WaitStrategy.all([.tcpPort(8080), .logContains("ready")])
       #expect(s1 == s2)
   }
   ```

2. **Test Empty Array Handling**
   ```swift
   @Test func allWithEmptyArraySucceeds() async throws {
       let strategy = WaitStrategy.all([])
       // Should succeed immediately (tested via mock)
   }

   @Test func anyWithEmptyArrayFails() async throws {
       let strategy = WaitStrategy.any([])
       // Should fail immediately (tested via mock)
   }
   ```

3. **Test maxTimeout() Helper**
   ```swift
   @Test func maxTimeoutCalculation() {
       let strategy = WaitStrategy.all([
           .tcpPort(8080, timeout: .seconds(30)),
           .logContains("ready", timeout: .seconds(60))
       ])
       #expect(strategy.maxTimeout() == .seconds(60))
   }

   @Test func compositeTimeoutOverridesChildren() {
       let strategy = WaitStrategy.all([
           .tcpPort(8080, timeout: .seconds(60))
       ], timeout: .seconds(30))
       #expect(strategy.maxTimeout() == .seconds(30))
   }
   ```

4. **Test Nested Composition Structure**
   ```swift
   @Test func nestedCompositionIsHashable() {
       let strategy = WaitStrategy.all([
           .any([
               .tcpPort(8080),
               .tcpPort(9090)
           ]),
           .logContains("ready")
       ])
       #expect(strategy.maxTimeout() > .seconds(0))
   }
   ```

### Integration Tests
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/CompositeWaitIntegrationTests.swift` (new)

**Prerequisites**: All tests opt-in via `TESTCONTAINERS_RUN_DOCKER_TESTS=1`

1. **Test .all() with TCP + Log**
   ```swift
   @Test func waitForAllStrategies() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let request = ContainerRequest(image: "postgres:15")
           .withExposedPort(5432)
           .withEnvironment(["POSTGRES_PASSWORD": "test"])
           .waitingFor(.all([
               .tcpPort(5432, timeout: .seconds(30)),
               .logContains("database system is ready", timeout: .seconds(30))
           ]))

       try await withContainer(request) { container in
           let port = try await container.hostPort(5432)
           #expect(port > 0)
       }
   }
   ```

2. **Test .any() with Multiple Ports**
   ```swift
   @Test func waitForAnyStrategy() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       // Nginx listens on 80, not 8080
       let request = ContainerRequest(image: "nginx:alpine")
           .withExposedPort(80)
           .withExposedPort(443)
           .waitingFor(.any([
               .tcpPort(80, timeout: .seconds(20)),
               .tcpPort(443, timeout: .seconds(20))
           ]))

       try await withContainer(request) { container in
           let port80 = try await container.hostPort(80)
           #expect(port80 > 0)
       }
   }
   ```

3. **Test Nested Composition**
   ```swift
   @Test func nestedCompositeWait() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let request = ContainerRequest(image: "redis:7")
           .withExposedPort(6379)
           .waitingFor(.all([
               .any([
                   .logContains("Ready to accept connections", timeout: .seconds(15)),
                   .tcpPort(6379, timeout: .seconds(15))
               ]),
               .logContains("Server initialized", timeout: .seconds(20))
           ], timeout: .seconds(30)))

       try await withContainer(request) { container in
           #expect(try await container.hostPort(6379) > 0)
       }
   }
   ```

4. **Test Timeout Failure**
   ```swift
   @Test func compositeTimeoutFails() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let request = ContainerRequest(image: "alpine:3")
           .withCommand(["sleep", "infinity"])
           .withExposedPort(9999)  // Port never opens
           .waitingFor(.all([
               .tcpPort(9999, timeout: .seconds(5))
           ]))

       await #expect(throws: TestContainersError.self) {
           try await withContainer(request) { _ in }
       }
   }
   ```

5. **Test .any() All Fail**
   ```swift
   @Test func anyStrategyAllFail() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let request = ContainerRequest(image: "alpine:3")
           .withCommand(["sleep", "infinity"])
           .withExposedPort(9999)
           .withExposedPort(9998)
           .waitingFor(.any([
               .tcpPort(9999, timeout: .seconds(3)),
               .tcpPort(9998, timeout: .seconds(3)),
               .logContains("NEVER_APPEARS", timeout: .seconds(3))
           ]))

       await #expect(throws: TestContainersError.self) {
           try await withContainer(request) { _ in }
       }
   }
   ```

6. **Test Performance: .all() is Parallel**
   ```swift
   @Test func allStrategiesRunInParallel() async throws {
       let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
       guard optedIn else { return }

       let start = ContinuousClock.now

       let request = ContainerRequest(image: "redis:7")
           .withExposedPort(6379)
           .waitingFor(.all([
               .tcpPort(6379, timeout: .seconds(30)),
               .logContains("Ready to accept connections", timeout: .seconds(30))
           ]))

       try await withContainer(request) { _ in }

       let elapsed = start.duration(to: ContinuousClock.now)
       // Should be close to single wait time, not sum of both
       // (Redis typically ready in 1-3 seconds)
       #expect(elapsed < .seconds(10))
   }
   ```

### Edge Case Tests

1. Single strategy in composite (optimization)
2. Deeply nested composites (5+ levels)
3. Composite timeout shorter than individual timeouts
4. Composite timeout longer than individual timeouts
5. Mix of .none with other strategies

---

## Acceptance Criteria

### Definition of Done

- [x] `WaitStrategy` enum includes `.all([WaitStrategy], timeout: Duration? = nil)` case
- [x] `WaitStrategy` enum includes `.any([WaitStrategy], timeout: Duration? = nil)` case
- [x] `WaitStrategy` maintains `Sendable` and `Hashable` conformance
- [x] `.all([...])` executes strategies in parallel and fails if any fail
- [x] `.any([...])` executes strategies in parallel and succeeds on first success
- [x] Nested composition works (composites containing composites)
- [x] Composite-level timeout correctly overrides individual strategy timeouts
- [x] Empty array handling: `.all([])` succeeds, `.any([])` fails
- [x] Error messages clearly indicate which strategy failed in composites
- [x] All unit tests pass (Hashable, maxTimeout, edge cases)
- [x] All integration tests pass with real Docker containers
- [x] Performance test confirms `.all()` runs in parallel (not serialized)
- [x] Documentation updated: inline code comments for new cases
- [ ] README.md includes example of `.all()` and `.any()` usage
- [ ] FEATURES.md updated to mark "Composite/multiple waits" as implemented

### Success Metrics

1. **Correctness**: All integration tests pass against real Docker images
2. **Performance**: `.all([...])` with 3 strategies completes in O(max) time, not O(sum)
3. **Usability**: Users can express complex wait conditions in 3-5 lines of fluent API
4. **Error Clarity**: Timeout errors include description of which strategy/strategies failed

---

## Implementation Risks & Mitigations

### Risk 1: Swift Concurrency Complexity
**Problem**: Parallel execution with task groups and proper cancellation is non-trivial.
**Mitigation**: Start with serial execution for `.all()`, optimize to parallel in follow-up PR. Use structured concurrency primitives (`withThrowingTaskGroup`).

### Risk 2: Error Message Clarity
**Problem**: Nested composites could produce unclear timeout messages.
**Mitigation**: Include strategy index and description in error. Consider breadcrumb trail for nested composites.

### Risk 3: Hashable Conformance
**Problem**: Recursive enum with arrays might complicate `Hashable` (especially if arrays contain floating-point durations).
**Mitigation**: Swift should auto-synthesize `Hashable` for recursive enums. If issues arise, manually implement using strategy description.

### Risk 4: Performance Regression
**Problem**: Parallel execution overhead might be worse than serial for fast strategies.
**Mitigation**: Add single-strategy optimization (`.all([single])` → execute directly). Benchmark with integration tests.

---

## Future Enhancements

### Beyond Initial Implementation

1. **Startup Probe Pattern** (`.startup(...)`)
   - Higher timeout/longer poll interval
   - Falls back to stricter readiness/liveness checks

2. **Short-Circuit Optimization**
   - `.all()` with fast-fail on first timeout (already planned)
   - `.any()` early termination on first success (already planned)

3. **Weighted Strategies**
   - Some conditions more critical than others
   - Example: `.all([(.tcpPort(8080), weight: 1.0), (.logContains("ready"), weight: 0.5)])`

4. **Retry Strategies**
   - `.retry(.tcpPort(8080), attempts: 3, backoff: .exponential)`
   - Different from poll interval (entire strategy retries)

5. **Conditional Composition**
   - `.allIf(condition, [...])`
   - `.anyUnless(condition, [...])`

6. **Observability Hooks**
   - Callback on each strategy attempt
   - Metrics: attempts, time to ready, which strategy succeeded first in `.any()`

---

## Related Work

### References
- **testcontainers-go**: `wait.ForAll()`, `wait.ForAny()` in `wait/multi.go`
- **testcontainers-java**: `WaitStrategy` composition via chaining
- **Swift Structured Concurrency**: `withThrowingTaskGroup` for parallel execution

### Dependencies
- Existing `Waiter.wait()` for polling logic
- Existing `TCPProbe` and log fetching for atomic strategies
- Swift 5.9+ structured concurrency

---

## Questions & Decisions

### Open Questions
1. Should `.all([])` succeed or throw at construction time?
   - **Decision**: Succeed (vacuous truth, easier for programmatic generation)

2. Should `.any([])` fail or throw at construction time?
   - **Decision**: Fail with clear error at execution time (easier to detect bugs)

3. How deep should nested composition go?
   - **Decision**: No artificial limit, trust Swift's recursion handling

4. Should we add `.not()` for negation?
   - **Decision**: Deferred to future. Use case unclear (wait for port to close?).

### Decided
- Use `Duration?` for composite timeout (nil = no override)
- Parallel execution for both `.all()` and `.any()`
- Fail fast for `.all()` on first error
- Race to success for `.any()` with first win
- Maintain enum pattern (no protocol/type erasure) for simplicity

---

## Sign-off

**Proposed by**: Feature request (FEATURES.md Tier 1)
**Reviewed by**: TBD
**Approved by**: TBD
**Target milestone**: MVP+

---

**Last updated**: 2025-12-15
