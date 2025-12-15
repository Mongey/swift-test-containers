# Feature 006: Startup Retries with Exponential Backoff and Jitter

**Status:** Implemented
**Priority:** High (Tier 1)
**Complexity:** Medium
**Implemented:** 2025-12-15

---

## Summary

Implement automatic retry logic for container startup failures with configurable exponential backoff and jitter. When a container fails to start or satisfy its wait strategy, the system will automatically retry the operation with increasing delays between attempts, improving reliability in environments with transient failures (network issues, image pull delays, resource contention).

This feature builds on the existing wait strategy infrastructure (`/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift`) and integrates into the container lifecycle managed by `withContainer(_:_:)` in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`.

---

## Current State

### Container Startup Flow

Currently, container startup follows this sequence in `withContainer(_:_:)`:

1. **Docker availability check** (`DockerClient.isAvailable()`)
2. **Run container** (`DockerClient.runContainer()`) - executes `docker run -d ...`
3. **Wait until ready** (`Container.waitUntilReady()`) - applies configured `WaitStrategy`
4. **Execute user operation** or **cleanup on failure**

**No retry logic exists.** If any step fails (e.g., image pull timeout, port binding conflict, wait strategy timeout), the entire operation fails immediately with an error.

### Wait Strategies

Wait strategies are defined in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`:

```swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration, pollInterval: Duration)
    case logContains(String, timeout: Duration, pollInterval: Duration)
}
```

The `Waiter.wait()` function in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift` polls a predicate until success or timeout:

```swift
static func wait(
    timeout: Duration,
    pollInterval: Duration,
    description: String,
    _ predicate: @Sendable () async throws -> Bool
) async throws
```

### Error Handling

Errors are defined in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`:

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    case dockerNotAvailable(String)
    case commandFailed(command: [String], exitCode: Int32, stdout: String, stderr: String)
    case unexpectedDockerOutput(String)
    case timeout(String)
}
```

**Gap:** No retry-specific error cases exist for tracking retry attempts or exhaustion.

---

## Requirements

### Functional Requirements

1. **Configurable Retry Policy**
   - Maximum number of retry attempts (default: 3)
   - Initial delay between retries (default: 1 second)
   - Maximum delay cap (default: 30 seconds)
   - Backoff multiplier (default: 2.0 for exponential)
   - Jitter factor (default: 0.1 for +/- 10% randomization)

2. **Retry Conditions**
   - Retry on container start failures (`docker run` errors)
   - Retry on wait strategy timeouts
   - Retry on specific Docker errors (port conflicts, resource unavailable)
   - Do NOT retry on user cancellation
   - Do NOT retry on Docker daemon unavailable (fail fast)

3. **Backoff Algorithm**
   - Exponential backoff: `delay = min(initialDelay * (multiplier ^ attempt), maxDelay)`
   - Jitter: `actualDelay = delay * (1 + random(-jitter...jitter))`
   - Example: With defaults, delays would be ~1s, ~2s, ~4s (with jitter variation)

4. **Observability**
   - Log each retry attempt with attempt number and reason
   - Include delay duration in retry messages
   - Provide final error with total attempts made
   - Preserve original error details from failed attempts

### Non-Functional Requirements

1. **Backward Compatibility:** Retries disabled by default (opt-in via `withRetry()` builder)
2. **Performance:** Minimal overhead when retries disabled
3. **Testability:** Retry logic testable without Docker (unit tests with mock failures)
4. **Concurrency Safety:** Thread-safe retry state tracking (use Swift 6 concurrency)

---

## API Design

### 1. Retry Configuration Struct

Add to `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`:

```swift
/// Configuration for automatic container startup retries with exponential backoff
public struct RetryPolicy: Sendable, Hashable {
    /// Maximum number of retry attempts (excluding initial attempt)
    public var maxAttempts: Int

    /// Initial delay before first retry
    public var initialDelay: Duration

    /// Maximum delay cap for exponential backoff
    public var maxDelay: Duration

    /// Multiplier for exponential backoff (delay *= multiplier per attempt)
    public var backoffMultiplier: Double

    /// Jitter factor for randomizing delays (0.0 = no jitter, 0.1 = +/- 10%)
    public var jitter: Double

    /// Default retry policy: 3 attempts, 1s initial, 30s max, 2x backoff, 10% jitter
    public static let `default` = RetryPolicy(
        maxAttempts: 3,
        initialDelay: .seconds(1),
        maxDelay: .seconds(30),
        backoffMultiplier: 2.0,
        jitter: 0.1
    )

    /// Aggressive retry policy: 5 attempts, 500ms initial, 10s max
    public static let aggressive = RetryPolicy(
        maxAttempts: 5,
        initialDelay: .milliseconds(500),
        maxDelay: .seconds(10),
        backoffMultiplier: 2.0,
        jitter: 0.1
    )

    /// Conservative retry policy: 2 attempts, 2s initial, 60s max
    public static let conservative = RetryPolicy(
        maxAttempts: 2,
        initialDelay: .seconds(2),
        maxDelay: .seconds(60),
        backoffMultiplier: 2.0,
        jitter: 0.15
    )

    public init(
        maxAttempts: Int,
        initialDelay: Duration,
        maxDelay: Duration,
        backoffMultiplier: Double,
        jitter: Double
    ) {
        precondition(maxAttempts > 0, "maxAttempts must be positive")
        precondition(initialDelay > .zero, "initialDelay must be positive")
        precondition(maxDelay >= initialDelay, "maxDelay must be >= initialDelay")
        precondition(backoffMultiplier > 1.0, "backoffMultiplier must be > 1.0")
        precondition(jitter >= 0.0 && jitter <= 1.0, "jitter must be in [0.0, 1.0]")

        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
        self.jitter = jitter
    }

    /// Calculate delay for a specific attempt (0-indexed)
    func delay(for attempt: Int) -> Duration {
        guard attempt > 0 else { return .zero }

        // Exponential backoff: initialDelay * (multiplier ^ attempt)
        let baseDelay = Double(initialDelay.components.seconds)
            * pow(backoffMultiplier, Double(attempt))
        let cappedDelay = min(baseDelay, Double(maxDelay.components.seconds))

        // Apply jitter: +/- (jitter * 100)%
        let jitterFactor = 1.0 + Double.random(in: -jitter...jitter)
        let finalDelay = cappedDelay * jitterFactor

        return .seconds(Int(finalDelay))
    }
}
```

### 2. ContainerRequest Extension

```swift
extension ContainerRequest {
    /// Optional retry policy for container startup
    public var retryPolicy: RetryPolicy?

    /// Enable automatic retries with the default retry policy
    public func withRetry() -> Self {
        withRetry(.default)
    }

    /// Enable automatic retries with a custom retry policy
    public func withRetry(_ policy: RetryPolicy) -> Self {
        var copy = self
        copy.retryPolicy = policy
        return copy
    }
}
```

### 3. Error Extension

Add to `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`:

```swift
extension TestContainersError {
    /// Startup failed after exhausting all retry attempts
    case startupRetriesExhausted(attempts: Int, lastError: Error)

    // Update description property to handle new case
    public var description: String {
        switch self {
        // ... existing cases ...
        case let .startupRetriesExhausted(attempts, lastError):
            return "Container startup failed after \(attempts) attempts. Last error: \(lastError)"
        }
    }
}
```

### 4. Usage Examples

```swift
// Example 1: Use default retry policy
let request = ContainerRequest(image: "postgres:15")
    .withExposedPort(5432)
    .waitingFor(.tcpPort(5432))
    .withRetry()  // 3 attempts, exponential backoff

try await withContainer(request) { container in
    // Use container
}

// Example 2: Custom aggressive retry for flaky CI environments
let request = ContainerRequest(image: "redis:7")
    .withExposedPort(6379)
    .waitingFor(.tcpPort(6379))
    .withRetry(.aggressive)  // 5 attempts, faster retries

// Example 3: Custom retry policy
let customPolicy = RetryPolicy(
    maxAttempts: 4,
    initialDelay: .milliseconds(500),
    maxDelay: .seconds(15),
    backoffMultiplier: 1.5,
    jitter: 0.2
)

let request = ContainerRequest(image: "mongodb:6")
    .withRetry(customPolicy)
```

---

## Implementation Steps

### Phase 1: Core Retry Logic

**File:** Create `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/RetryPolicy.swift`

1. Implement `RetryPolicy` struct with:
   - Configuration properties
   - Static presets (`.default`, `.aggressive`, `.conservative`)
   - `delay(for:)` calculation method with exponential backoff + jitter
   - Input validation in initializer

2. Add unit tests for `RetryPolicy`:
   - Test delay calculations for various attempt numbers
   - Verify jitter produces values within expected range
   - Validate max delay capping works
   - Test precondition failures for invalid inputs

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

3. Add `retryPolicy: RetryPolicy?` property to `ContainerRequest`
4. Add `withRetry()` and `withRetry(_:)` builder methods
5. Update `Hashable` conformance to include `retryPolicy`

### Phase 2: Retry Orchestration

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`

6. Create `retryableContainerStartup()` function:
   ```swift
   private func retryableContainerStartup(
       _ request: ContainerRequest,
       docker: DockerClient
   ) async throws -> Container {
       guard let policy = request.retryPolicy else {
           // No retry policy - single attempt
           let id = try await docker.runContainer(request)
           let container = Container(id: id, request: request, docker: docker)
           try await container.waitUntilReady()
           return container
       }

       var lastError: Error?

       for attempt in 0...policy.maxAttempts {
           do {
               if attempt > 0 {
                   let delay = policy.delay(for: attempt)
                   // Log retry attempt (future: use logging hooks)
                   try await Task.sleep(for: delay)
               }

               let id = try await docker.runContainer(request)
               let container = Container(id: id, request: request, docker: docker)

               do {
                   try await container.waitUntilReady()
                   return container
               } catch {
                   // Wait failed - cleanup and retry
                   try? await container.terminate()
                   throw error
               }

           } catch {
               lastError = error

               // Don't retry on certain errors
               if shouldNotRetry(error) {
                   throw error
               }

               // Continue to next attempt if available
               if attempt < policy.maxAttempts {
                   continue
               }
           }
       }

       // All retries exhausted
       throw TestContainersError.startupRetriesExhausted(
           attempts: policy.maxAttempts + 1,
           lastError: lastError!
       )
   }

   private func shouldNotRetry(_ error: Error) -> Bool {
       switch error {
       case TestContainersError.dockerNotAvailable:
           return true  // Fail fast - Docker not available
       case is CancellationError:
           return true  // Don't retry on user cancellation
       default:
           return false  // Retry on other errors
       }
   }
   ```

7. Update `withContainer(_:docker:operation:)` to use `retryableContainerStartup()`:
   ```swift
   public func withContainer<T>(
       _ request: ContainerRequest,
       docker: DockerClient = DockerClient(),
       operation: @Sendable (Container) async throws -> T
   ) async throws -> T {
       if !(await docker.isAvailable()) {
           throw TestContainersError.dockerNotAvailable(
               "`docker` CLI not found or Docker engine not running."
           )
       }

       let container = try await retryableContainerStartup(request, docker: docker)

       let cleanup: () -> Void = { _ = Task { try? await container.terminate() } }

       return try await withTaskCancellationHandler {
           do {
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

### Phase 3: Error Handling

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

8. Add `startupRetriesExhausted(attempts:lastError:)` case
9. Update `description` property to format retry exhaustion message
10. Ensure error preserves original failure context

### Phase 4: Testing

**File:** Create `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/RetryPolicyTests.swift`

11. Unit tests for `RetryPolicy`:
    - `test_defaultPolicyValues()`
    - `test_delayCalculation_exponentialBackoff()`
    - `test_delayCalculation_respectsMaxDelay()`
    - `test_delayCalculation_appliesJitter()`
    - `test_staticPresets_haveValidValues()`
    - `test_init_rejectsInvalidInputs()`

**File:** Create `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/RetryIntegrationTests.swift`

12. Integration tests (opt-in via environment variable):
    - `test_retrySucceedsAfterTransientFailure()`
    - `test_retryExhaustion_throwsCorrectError()`
    - `test_noRetryPolicy_failsImmediately()`
    - `test_cancellation_stopsRetries()`
    - `test_dockerUnavailable_doesNotRetry()`

13. Mock-based tests for retry logic:
    - Create mock `DockerClient` that fails N times then succeeds
    - Verify correct number of attempts
    - Verify delays are applied
    - Verify cleanup happens on each failed attempt

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

14. Add tests for builder methods:
    - `test_withRetry_setsDefaultPolicy()`
    - `test_withRetry_customPolicy()`
    - `test_withRetry_preservesOtherConfiguration()`

### Phase 5: Documentation

15. Add inline documentation (DocC comments) to all public APIs
16. Create usage examples in tests
17. Update `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md` to mark retry feature as implemented
18. Add migration guide for users (optional feature, no breaking changes)

---

## Testing Plan

### Unit Tests

**Target:** `RetryPolicy` delay calculation and validation
- Test exponential backoff formula
- Test jitter randomization (statistical validation)
- Test max delay capping
- Test input validation (preconditions)
- Test static preset values

**Target:** `ContainerRequest` builder methods
- Test `withRetry()` sets default policy
- Test `withRetry(_:)` sets custom policy
- Test fluent API chaining preserves retry policy
- Test Hashable conformance includes retry policy

### Integration Tests (Mock-Based)

**Target:** Retry orchestration logic
- Mock `DockerClient` that fails predictably
- Verify retry attempts match policy
- Verify delays are applied between attempts
- Verify cleanup on each failed attempt
- Verify final error contains all attempts info

### Integration Tests (Docker-Based, Opt-In)

**Target:** Real Docker container retries
- Test with flaky container (use script that fails randomly)
- Test with slow-starting container (delays accepting connections)
- Test retry exhaustion with never-ready container
- Test cancellation during retry loop
- Test no-retry baseline behavior

### Performance Tests

**Target:** Overhead validation
- Benchmark container startup with retries disabled (baseline)
- Benchmark container startup with retries enabled but not triggered
- Verify overhead is < 1ms when retries not needed

### Edge Cases

- Retry policy with `maxAttempts = 1` (should behave like no retry)
- Extremely short delays (milliseconds)
- Extremely long delays (minutes)
- Jitter factor = 0.0 (deterministic delays)
- Jitter factor = 1.0 (maximum randomization)
- Concurrent retry operations (multiple containers with retries)

---

## Acceptance Criteria

### Must Have

- [x] `RetryPolicy` struct with configurable backoff parameters
- [x] `RetryPolicy.default`, `.aggressive`, `.conservative` presets
- [x] `ContainerRequest.withRetry()` and `withRetry(_:)` methods
- [x] Exponential backoff calculation with jitter
- [x] Automatic retry of `docker run` failures
- [x] Automatic retry of wait strategy timeouts
- [x] Cleanup of failed containers between retry attempts
- [x] `TestContainersError.startupRetriesExhausted` with attempt count
- [x] No retry on `dockerNotAvailable` error (fail fast)
- [x] No retry on user cancellation
- [x] Backward compatible (retries opt-in, default behavior unchanged)
- [x] Unit tests with 100% coverage of retry logic
- [x] Integration tests demonstrating retry success and exhaustion
- [x] DocC documentation for all public APIs

### Should Have

- [x] Mock-based tests for retry orchestration (no Docker required)
- [x] Statistical validation of jitter distribution
- [ ] Performance benchmarks showing minimal overhead
- [x] Examples in test suite demonstrating common patterns
- [ ] Logging/observability for retry attempts (future: logging hooks)

### Nice to Have

- [ ] Retry condition predicates (custom logic for which errors to retry)
- [ ] Per-error backoff strategies (different delays for different failures)
- [ ] Retry metrics/telemetry hooks
- [ ] Exponential backoff visualization tool (for debugging policies)
- [ ] Support for linear backoff (in addition to exponential)

---

## Future Enhancements

### Beyond Initial Implementation

1. **Retry Hooks:** Callbacks for observability
   ```swift
   public struct RetryPolicy {
       var onRetryAttempt: (@Sendable (Int, Error) async -> Void)?
       var onRetryExhausted: (@Sendable (Int, Error) async -> Void)?
   }
   ```

2. **Conditional Retries:** Custom predicates for retryable errors
   ```swift
   public struct RetryPolicy {
       var shouldRetry: (@Sendable (Error) -> Bool)?
   }
   ```

3. **Circuit Breaker:** Stop retries globally after repeated failures
   ```swift
   public actor RetryCircuitBreaker {
       func recordFailure()
       func isOpen() -> Bool
   }
   ```

4. **Adaptive Backoff:** Adjust delays based on failure patterns
   ```swift
   public struct AdaptiveRetryPolicy: RetryPolicy {
       // Learns optimal delays from failure history
   }
   ```

5. **Retry Budget:** Global limit on retry attempts across all containers
   ```swift
   public actor RetryBudget {
       let maxConcurrentRetries: Int
       func acquireRetrySlot() async throws
   }
   ```

---

## Dependencies

**Internal:**
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` - Add retry policy property
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift` - Add retry orchestration
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift` - Add retry error case
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift` - No changes needed

**External:**
- Swift 6 concurrency (already required by codebase)
- Swift Testing framework (already in use)

**Related Features:**
- This feature is independent but complements future logging hooks
- Works with all existing wait strategies (`.tcpPort`, `.logContains`, `.none`)
- Foundation for future circuit breaker patterns

---

## Risk Assessment

### Low Risk
- **Backward compatibility:** Feature is opt-in, no breaking changes
- **Isolation:** Retry logic contained in new functions, minimal changes to existing code
- **Testing:** Comprehensive unit tests possible without Docker

### Medium Risk
- **Performance:** Need to verify minimal overhead when retries disabled
- **Resource leaks:** Must ensure containers cleaned up on each failed attempt
- **Timing:** Jitter and backoff calculations must be correct

### Mitigation Strategies
- **Performance:** Benchmark before/after with retries disabled
- **Resource leaks:** Add container tracking assertions in tests
- **Timing:** Extensive unit tests for delay calculations
- **Code review:** Focus on cleanup paths and error handling

---

## References

### Code References
- Wait strategy implementation: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift`
- Container lifecycle: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`
- Request builder pattern: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`
- Error handling: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

### External References
- Exponential backoff best practices: [Google Cloud - Exponential Backoff](https://cloud.google.com/iot/docs/how-tos/exponential-backoff)
- Jitter in distributed systems: [AWS Architecture Blog - Exponential Backoff And Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)
- testcontainers-go startup strategies: [testcontainers-go Wait Strategies](https://golang.testcontainers.org/features/wait/)

---

## Implementation Checklist

### Before Starting
- [x] Review existing wait strategy and container lifecycle code
- [x] Design retry policy API (this document)
- [x] Get feedback on API design

### During Implementation
- [x] Implement `RetryPolicy` struct with delay calculation
- [x] Add unit tests for delay calculation and validation
- [x] Add retry policy to `ContainerRequest`
- [x] Implement retry orchestration in `withContainer()`
- [x] Add retry exhaustion error case
- [x] Write integration tests (mock-based)
- [x] Write integration tests (Docker-based, opt-in)
- [x] Add DocC documentation
- [ ] Performance benchmarks

### Before Merge
- [x] All tests passing (unit + integration)
- [x] Code review completed
- [x] Documentation complete
- [ ] Performance validated (no regression when retries disabled)
- [x] Update FEATURES.md to mark as implemented
- [ ] Add usage examples to README if applicable

---

**Created:** 2025-12-15
**Last Updated:** 2025-12-15
**Tracking:** [FEATURES.md Line 40](file:///Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md#L40)
