# Feature #029: Container Lifecycle Hooks

**Status**: ✅ Implemented

## Summary

Implement lifecycle hooks that allow users to register async callbacks at various points in a container's lifecycle. This enables custom setup, validation, cleanup, and resource management operations that need to run at specific times during container initialization and teardown.

Lifecycle hooks implemented:
- **PreStart**: Before `docker run` is executed
- **PostStart**: After container is started and ready
- **PreStop**: Reserved for future explicit stop operations
- **PostStop**: Reserved for future explicit stop operations
- **PreTerminate**: Before `docker rm -f` is executed (useful for cleanup/inspection)
- **PostTerminate**: After `docker rm -f` completes

## Implementation

### Files Created/Modified

- `Sources/TestContainers/LifecycleHook.swift` - New file with:
  - `LifecyclePhase` enum (preStart, postStart, preStop, postStop, preTerminate, postTerminate)
  - `LifecycleContext` struct with container, request, docker, and `requireContainer()` method
  - `LifecycleHook` struct with UUID identifier and async closure
  - `executeLifecycleHooks()` function for sequential hook execution

- `Sources/TestContainers/ContainerRequest.swift` - Added:
  - Six hook storage arrays: `preStartHooks`, `postStartHooks`, etc.
  - Builder methods: `onPreStart()`, `onPostStart()`, `onPreStop()`, `onPostStop()`, `onPreTerminate()`, `onPostTerminate()`
  - Generic `withLifecycleHook(_:phase:)` method

- `Sources/TestContainers/TestContainersError.swift` - Added:
  - `lifecycleHookFailed(phase:hookIndex:underlyingError:)` error case
  - `lifecycleError(String)` error case

- `Sources/TestContainers/WithContainer.swift` - Integrated hooks:
  - PreStart hooks execute before container creation
  - PostStart hooks execute after container is ready
  - PreTerminate/PostTerminate hooks execute during cleanup
  - Errors in PreStart/PostStart prevent operation; terminate hooks always run

- `Tests/TestContainersTests/LifecycleHooksTests.swift` - 35 tests covering:
  - Hook identity and hashability
  - Context access and `requireContainer()`
  - ContainerRequest hook registration
  - Hook execution order
  - Error handling for all phases
  - Integration tests with real containers

### API Usage

```swift
// Basic usage with multiple hooks
let request = ContainerRequest(image: "alpine:3")
    .withCommand(["sleep", "30"])
    .onPreStart { context in
        print("Container about to start...")
    }
    .onPostStart { context in
        let container = try context.requireContainer()
        print("Container \(await container.id) is ready")
    }
    .onPreTerminate { context in
        let container = try context.requireContainer()
        let logs = try await container.logs()
        // Save logs before container is removed
    }
    .onPostTerminate { context in
        print("Container removed, cleaning up...")
    }

try await withContainer(request) { container in
    // Your test code here
}
```

---

## Original Specification

## Current State

### Container Lifecycle Flow

The current container lifecycle is managed primarily in three locations:

1. **`/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`** (lines 7-30):
   ```swift
   let id = try await docker.runContainer(request)
   let container = Container(id: id, request: request, docker: docker)

   try await container.waitUntilReady()
   let result = try await operation(container)
   try await container.terminate()
   ```

2. **`/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`**:
   - `waitUntilReady()` (lines 36-52): Executes wait strategy after container starts
   - `terminate()` (line 32-34): Calls `docker.removeContainer(id: id)`

3. **`/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`**:
   - `runContainer()` (lines 28-54): Creates and starts the container
   - `removeContainer()` (lines 56-58): Forcefully removes the container

### Current Limitations

- No way to execute custom logic before/after container creation
- No way to inspect or modify container state between lifecycle phases
- No mechanism for cleanup operations before termination (e.g., saving logs, exporting data)
- No ability to perform health checks beyond the built-in wait strategies
- Cannot implement custom resource management (e.g., network setup, volume initialization)

### Similar Patterns in Codebase

The codebase uses a fluent builder pattern for configuration (`ContainerRequest`):
- Methods like `withName()`, `withCommand()`, `withEnvironment()` (lines 47-87 in `ContainerRequest.swift`)
- All methods return `Self` for chaining
- All properties are stored in the `ContainerRequest` struct which conforms to `Sendable` and `Hashable`

## Requirements

### Functional Requirements

1. **Hook Types**: Support all six lifecycle hooks (PreStart, PostStart, PreStop, PostStop, PreTerminate, PostTerminate)

2. **Async Hook Support**: All hooks must support async operations since they may need to:
   - Interact with external services
   - Perform I/O operations
   - Call Docker commands
   - Wait for conditions

3. **Multiple Hooks Per Stage**: Allow registering multiple hooks for the same lifecycle stage, executed in registration order

4. **Error Handling**:
   - Errors in PreStart hooks should prevent container creation
   - Errors in PostStart hooks should trigger immediate cleanup
   - Errors in PreStop hooks should be logged but not prevent termination
   - Errors in PostStop/PreTerminate/PostTerminate should be logged but not thrown
   - All errors should be reported via Swift's structured error handling

5. **Access to Container Context**: Hooks should receive:
   - The `Container` instance (for PostStart onwards)
   - The `ContainerRequest` (for PreStart)
   - The `DockerClient` (for all hooks, to allow custom Docker operations)

6. **Cancellation Support**: Hooks must respect Swift's task cancellation

### Non-Functional Requirements

1. **Type Safety**: Leverage Swift's type system to prevent invalid hook usage
2. **Sendable Conformance**: All hook-related types must be `Sendable` for actor safety
3. **Performance**: Hook execution should not significantly impact container startup/teardown time
4. **Backward Compatibility**: Existing code without hooks should continue to work unchanged

## API Design

### Hook Type Definition

```swift
/// Represents a lifecycle hook that executes at a specific point in the container lifecycle.
public struct LifecycleHook: Sendable, Hashable {
    internal let id: UUID
    internal let execute: @Sendable (LifecycleContext) async throws -> Void

    public init(_ hook: @Sendable @escaping (LifecycleContext) async throws -> Void) {
        self.id = UUID()
        self.execute = hook
    }

    // Hashable conformance using id
    public static func == (lhs: LifecycleHook, rhs: LifecycleHook) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Context provided to lifecycle hooks.
public struct LifecycleContext: Sendable {
    public let container: Container?
    public let request: ContainerRequest
    public let docker: DockerClient

    /// Available only in PostStart and later hooks
    public func requireContainer() throws -> Container {
        guard let container = container else {
            throw TestContainersError.lifecycleError("Container not available in this lifecycle phase")
        }
        return container
    }
}
```

### ContainerRequest Extension

```swift
public struct ContainerRequest: Sendable, Hashable {
    // ... existing properties ...

    public var preStartHooks: [LifecycleHook]
    public var postStartHooks: [LifecycleHook]
    public var preStopHooks: [LifecycleHook]
    public var postStopHooks: [LifecycleHook]
    public var preTerminateHooks: [LifecycleHook]
    public var postTerminateHooks: [LifecycleHook]

    public init(image: String) {
        // ... existing initialization ...
        self.preStartHooks = []
        self.postStartHooks = []
        self.preStopHooks = []
        self.postStopHooks = []
        self.preTerminateHooks = []
        self.postTerminateHooks = []
    }

    // Fluent API methods
    public func onPreStart(_ hook: @Sendable @escaping (LifecycleContext) async throws -> Void) -> Self {
        var copy = self
        copy.preStartHooks.append(LifecycleHook(hook))
        return copy
    }

    public func onPostStart(_ hook: @Sendable @escaping (LifecycleContext) async throws -> Void) -> Self {
        var copy = self
        copy.postStartHooks.append(LifecycleHook(hook))
        return copy
    }

    public func onPreStop(_ hook: @Sendable @escaping (LifecycleContext) async throws -> Void) -> Self {
        var copy = self
        copy.preStopHooks.append(LifecycleHook(hook))
        return copy
    }

    public func onPostStop(_ hook: @Sendable @escaping (LifecycleContext) async throws -> Void) -> Self {
        var copy = self
        copy.postStopHooks.append(LifecycleHook(hook))
        return copy
    }

    public func onPreTerminate(_ hook: @Sendable @escaping (LifecycleContext) async throws -> Void) -> Self {
        var copy = self
        copy.preTerminateHooks.append(LifecycleHook(hook))
        return copy
    }

    public func onPostTerminate(_ hook: @Sendable @escaping (LifecycleContext) async throws -> Void) -> Self {
        var copy = self
        copy.postTerminateHooks.append(LifecycleHook(hook))
        return copy
    }
}
```

### Usage Examples

```swift
// Example 1: Database initialization hook
let request = ContainerRequest(image: "postgres:15")
    .withExposedPort(5432)
    .withEnvironment(["POSTGRES_PASSWORD": "test"])
    .waitingFor(.tcpPort(5432))
    .onPostStart { context in
        let container = try context.requireContainer()
        // Run database migrations after container is ready
        try await runMigrations(on: container)
    }

// Example 2: Save logs before termination
let request = ContainerRequest(image: "myapp:latest")
    .withExposedPort(8080)
    .onPreTerminate { context in
        let container = try context.requireContainer()
        let logs = try await container.logs()
        try logs.write(to: URL(fileURLWithPath: "/tmp/container-logs.txt"))
    }

// Example 3: Multiple hooks in sequence
let request = ContainerRequest(image: "redis:7")
    .withExposedPort(6379)
    .onPreStart { context in
        print("About to start Redis container...")
    }
    .onPostStart { context in
        print("Redis container started, running health check...")
        let container = try context.requireContainer()
        try await verifyRedisHealth(container)
    }
    .onPostStart { context in
        print("Loading initial data...")
        let container = try context.requireContainer()
        try await loadRedisData(container)
    }
    .onPreTerminate { context in
        print("Saving Redis snapshot before shutdown...")
        let container = try context.requireContainer()
        try await container.docker.exec(id: container.id, command: ["redis-cli", "SAVE"])
    }

// Example 4: Custom network setup (PreStart)
let request = ContainerRequest(image: "nginx:latest")
    .onPreStart { context in
        // Create custom Docker network before container starts
        _ = try await context.docker.runDocker(["network", "create", "test-network"])
    }
    .onPostTerminate { context in
        // Clean up network after container is removed
        try? await context.docker.runDocker(["network", "rm", "test-network"])
    }
```

## Implementation Steps

### Step 1: Add LifecycleHook and LifecycleContext Types
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/LifecycleHooks.swift` (new)

- Create `LifecycleHook` struct with `id: UUID` and closure
- Create `LifecycleContext` struct with container, request, and docker properties
- Implement `Sendable` and `Hashable` conformance
- Add `requireContainer()` helper method

### Step 2: Extend ContainerRequest with Hook Storage
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

- Add six arrays for storing hooks: `preStartHooks`, `postStartHooks`, etc.
- Initialize hook arrays to empty in `init(image:)`
- Add six fluent API methods: `onPreStart()`, `onPostStart()`, etc.
- Each method appends a new `LifecycleHook` and returns modified copy

### Step 3: Add Hook Execution Logic to Container
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

- Add `executeHooks(_:context:)` internal method
- Iterates through hooks and executes each with proper error handling
- Logs execution and errors appropriately

```swift
internal func executeHooks(
    _ hooks: [LifecycleHook],
    context: LifecycleContext,
    phase: String
) async throws {
    for (index, hook) in hooks.enumerated() {
        do {
            try await hook.execute(context)
        } catch {
            throw TestContainersError.lifecycleHookFailed(
                phase: phase,
                hookIndex: index,
                underlyingError: error
            )
        }
    }
}
```

### Step 4: Integrate Hooks into withContainer Flow
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`

Update the container lifecycle flow:

```swift
public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable("`docker` CLI not found or Docker engine not running.")
    }

    // Execute PreStart hooks
    let preStartContext = LifecycleContext(container: nil, request: request, docker: docker)
    try await executeHooksWithErrorHandling(request.preStartHooks, context: preStartContext, phase: "PreStart")

    let id = try await docker.runContainer(request)
    let container = Container(id: id, request: request, docker: docker)
    let context = LifecycleContext(container: container, request: request, docker: docker)

    let cleanup: () -> Void = { _ = Task { try? await container.terminate() } }

    return try await withTaskCancellationHandler {
        do {
            // Execute PostStart hooks
            try await executeHooksWithErrorHandling(request.postStartHooks, context: context, phase: "PostStart")

            try await container.waitUntilReady()
            let result = try await operation(container)

            // Execute PreStop hooks (log errors but don't fail)
            await executeHooksWithLogging(request.preStopHooks, context: context, phase: "PreStop")

            // Execute PreTerminate hooks
            await executeHooksWithLogging(request.preTerminateHooks, context: context, phase: "PreTerminate")

            try await container.terminate()

            // Execute PostStop and PostTerminate hooks
            await executeHooksWithLogging(request.postStopHooks, context: context, phase: "PostStop")
            await executeHooksWithLogging(request.postTerminateHooks, context: context, phase: "PostTerminate")

            return result
        } catch {
            // Execute PreTerminate hooks even on error
            await executeHooksWithLogging(request.preTerminateHooks, context: context, phase: "PreTerminate")
            try? await container.terminate()
            await executeHooksWithLogging(request.postTerminateHooks, context: context, phase: "PostTerminate")
            throw error
        }
    } onCancel: {
        cleanup()
    }
}
```

### Step 5: Add Error Types
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

Add new error cases:

```swift
case lifecycleHookFailed(phase: String, hookIndex: Int, underlyingError: Error)
case lifecycleError(String)
```

Update the `description` property to handle these cases.

### Step 6: Update DockerClient Visibility
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

- Make `runDocker(_:)` method `public` so hooks can execute custom Docker commands
- Consider adding helper methods for common Docker operations that hooks might need:
  - `exec(id: String, command: [String])` for executing commands in running containers
  - `inspect(id: String)` for getting container details

### Step 7: Documentation and Examples
**Files**: Add inline documentation and example code

- Document each hook type with use cases
- Add examples in doc comments
- Create integration test examples demonstrating common patterns

## Testing Plan

### Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/LifecycleHooksTests.swift` (new)

1. **Hook Registration Tests**:
   - Test that hooks are stored in correct arrays
   - Test that multiple hooks can be registered for the same phase
   - Test that hooks maintain order of registration
   - Test fluent API chaining

2. **LifecycleContext Tests**:
   - Test `requireContainer()` throws when container is nil (PreStart)
   - Test `requireContainer()` returns container when available
   - Test that context provides access to request and docker client

3. **Hook Execution Tests**:
   - Test that hooks are called in the correct order
   - Test that errors in PreStart prevent container creation
   - Test that errors in PostStart trigger cleanup
   - Test that errors in later hooks are logged but don't fail the operation
   - Test task cancellation during hook execution

### Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/LifecycleHooksIntegrationTests.swift` (new)

These tests should be gated by the `TESTCONTAINERS_RUN_DOCKER_TESTS` environment variable (similar to `DockerIntegrationTests.swift`):

1. **PreStart Hook Test**:
   ```swift
   @Test func preStartHookExecutesBeforeContainerCreation() async throws {
       guard ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1" else { return }

       var preStartCalled = false
       let request = ContainerRequest(image: "alpine:3")
           .withCommand(["sleep", "5"])
           .onPreStart { _ in
               preStartCalled = true
           }

       try await withContainer(request) { _ in
           #expect(preStartCalled)
       }
   }
   ```

2. **PostStart Hook Test**:
   ```swift
   @Test func postStartHookCanAccessContainer() async throws {
       guard ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1" else { return }

       var containerId: String?
       let request = ContainerRequest(image: "alpine:3")
           .withCommand(["sleep", "5"])
           .onPostStart { context in
               let container = try context.requireContainer()
               containerId = container.id
           }

       try await withContainer(request) { container in
           #expect(containerId == container.id)
       }
   }
   ```

3. **PreTerminate Hook Test**:
   ```swift
   @Test func preTerminateHookExecutesBeforeTermination() async throws {
       guard ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1" else { return }

       var logsCaptured = false
       let request = ContainerRequest(image: "alpine:3")
           .withCommand(["echo", "test output"])
           .onPreTerminate { context in
               let container = try context.requireContainer()
               let logs = try await container.logs()
               logsCaptured = logs.contains("test output")
           }

       try await withContainer(request) { _ in }
       #expect(logsCaptured)
   }
   ```

4. **Multiple Hooks Test**:
   ```swift
   @Test func multipleHooksExecuteInOrder() async throws {
       guard ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1" else { return }

       var executionOrder: [String] = []
       let request = ContainerRequest(image: "alpine:3")
           .withCommand(["sleep", "5"])
           .onPreStart { _ in executionOrder.append("preStart1") }
           .onPreStart { _ in executionOrder.append("preStart2") }
           .onPostStart { _ in executionOrder.append("postStart1") }
           .onPostStart { _ in executionOrder.append("postStart2") }

       try await withContainer(request) { _ in }
       #expect(executionOrder == ["preStart1", "preStart2", "postStart1", "postStart2"])
   }
   ```

5. **Error Handling Test**:
   ```swift
   @Test func errorInPostStartHookTriggersCleanup() async throws {
       guard ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1" else { return }

       struct HookError: Error {}

       let request = ContainerRequest(image: "alpine:3")
           .withCommand(["sleep", "5"])
           .onPostStart { _ in
               throw HookError()
           }

       await #expect(throws: HookError.self) {
           try await withContainer(request) { _ in }
       }

       // Verify container was cleaned up (no containers with testcontainers.swift label)
       let docker = DockerClient()
       let output = try await docker.runDocker(["ps", "-a", "--filter", "label=testcontainers.swift=true", "-q"])
       #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
   }
   ```

6. **Real-world Scenario Tests**:
   - Test Redis with data loading in PostStart
   - Test PostgreSQL with schema migration in PostStart
   - Test saving container logs to file in PreTerminate
   - Test custom health check in PostStart that throws on failure

## Acceptance Criteria

### Must Have

- [ ] All six lifecycle hook types are implemented (PreStart, PostStart, PreStop, PostStop, PreTerminate, PostTerminate)
- [ ] Hooks can be registered using fluent API methods on `ContainerRequest`
- [ ] Multiple hooks can be registered for the same phase and execute in order
- [ ] Hooks are async and can perform I/O operations
- [ ] `LifecycleContext` provides access to container (when available), request, and docker client
- [ ] Errors in PreStart hooks prevent container creation
- [ ] Errors in PostStart hooks trigger immediate cleanup
- [ ] Errors in PreStop/PostStop/PreTerminate/PostTerminate are logged but don't fail operations
- [ ] All types are `Sendable` and work with Swift's actor system
- [ ] Hooks respect task cancellation
- [ ] Backward compatibility: existing code without hooks continues to work
- [ ] Comprehensive unit tests for hook execution logic
- [ ] Integration tests demonstrating real Docker container scenarios

### Should Have

- [ ] Helper methods on `DockerClient` for common hook operations (exec, inspect)
- [ ] Clear documentation with examples for each hook type
- [ ] Error messages that clearly identify which hook failed and why
- [ ] Performance impact is negligible for containers without hooks

### Nice to Have

- [ ] Hook timing/duration logging for debugging
- [ ] Ability to conditionally execute hooks based on environment
- [ ] Built-in common hooks (e.g., log saver, health checker) as factory methods
- [ ] Support for hook timeouts to prevent hanging

## Dependencies

- No external dependencies required
- Uses existing Swift concurrency features (async/await, Sendable)
- Builds on existing `ContainerRequest` fluent API pattern
- Integrates with existing error handling via `TestContainersError`

## Risks and Mitigations

### Risk 1: Breaking Sendable Conformance
**Impact**: High
**Mitigation**: Use `@Sendable` closures and ensure all captured variables are `Sendable`. Store hooks with `UUID` for identity rather than comparing closures.

### Risk 2: Hook Execution Performance
**Impact**: Medium
**Mitigation**: Hooks are opt-in; containers without hooks have zero overhead. Document performance best practices.

### Risk 3: Complex Error Handling Logic
**Impact**: Medium
**Mitigation**: Clearly document which hooks can fail operations vs. which only log errors. Implement comprehensive tests for all error paths.

### Risk 4: Hooks Interfering with Container Lifecycle
**Impact**: High
**Mitigation**: Hooks receive read-only context. Document that hooks should not call terminate() or other lifecycle methods. Consider protecting against this programmatically.

## Future Enhancements

- **Conditional Hooks**: Add `.onPostStart(condition: Bool)` to conditionally execute hooks
- **Built-in Hooks Library**: Provide common hooks like `Hooks.saveLogsTo(path:)`, `Hooks.waitForHealthCheck()`
- **Hook Composition**: Allow combining multiple hooks into one
- **Async Sequences**: Support hooks that yield values over time for monitoring
- **Hook Timeouts**: Add per-hook timeout configuration
- **Hook Retries**: Support automatic retry with backoff for specific hooks

## References

- Java Testcontainers lifecycle callbacks: https://www.testcontainers.org/features/startup_and_waits/#container-lifecycle-callbacks
- Swift Concurrency: https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html
- Existing codebase patterns:
  - `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` - Fluent API pattern
  - `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift` - Lifecycle management
  - `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift` - Async waiting pattern
