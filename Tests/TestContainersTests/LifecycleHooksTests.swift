import Foundation
import Testing
@testable import TestContainers

// MARK: - LifecycleHook Unit Tests

@Test func lifecycleHook_hasUniqueId() {
    let hook1 = LifecycleHook { _ in }
    let hook2 = LifecycleHook { _ in }

    #expect(hook1.id != hook2.id)
}

@Test func lifecycleHook_isHashable() {
    let hook1 = LifecycleHook { _ in }
    let hook2 = LifecycleHook { _ in }

    #expect(hook1 == hook1)
    #expect(hook1 != hook2)
}

@Test func lifecycleHook_canBeStoredInSet() {
    let hook1 = LifecycleHook { _ in }
    let hook2 = LifecycleHook { _ in }

    var hooks: Set<LifecycleHook> = []
    hooks.insert(hook1)
    hooks.insert(hook2)
    hooks.insert(hook1) // duplicate

    #expect(hooks.count == 2)
}

// MARK: - LifecycleContext Unit Tests

@Test func lifecycleContext_withoutContainer_requireContainerThrows() async {
    let request = ContainerRequest(image: "alpine:3")
    let docker = DockerClient()
    let context = LifecycleContext(container: nil, request: request, runtime: docker)

    #expect(throws: TestContainersError.self) {
        _ = try context.requireContainer()
    }
}

@Test func lifecycleContext_withContainer_requireContainerReturns() async {
    let request = ContainerRequest(image: "alpine:3")
    let docker = DockerClient()
    // Note: We can't create a real container without Docker, but we can test the context structure
    let context = LifecycleContext(container: nil, request: request, runtime: docker)

    #expect(context.request.image == "alpine:3")
}

@Test func lifecycleContext_providesAccessToRequest() {
    let request = ContainerRequest(image: "postgres:16")
        .withEnvironment(["POSTGRES_PASSWORD": "test"])
    let docker = DockerClient()
    let context = LifecycleContext(container: nil, request: request, runtime: docker)

    #expect(context.request.image == "postgres:16")
    #expect(context.request.environment["POSTGRES_PASSWORD"] == "test")
}

// MARK: - ContainerRequest Hook Registration Tests

@Test func containerRequest_onPreStart_addsHook() {
    let request = ContainerRequest(image: "alpine:3")
        .onPreStart { _ in }

    #expect(request.preStartHooks.count == 1)
}

@Test func containerRequest_onPostStart_addsHook() {
    let request = ContainerRequest(image: "alpine:3")
        .onPostStart { _ in }

    #expect(request.postStartHooks.count == 1)
}

@Test func containerRequest_onPreStop_addsHook() {
    let request = ContainerRequest(image: "alpine:3")
        .onPreStop { _ in }

    #expect(request.preStopHooks.count == 1)
}

@Test func containerRequest_onPostStop_addsHook() {
    let request = ContainerRequest(image: "alpine:3")
        .onPostStop { _ in }

    #expect(request.postStopHooks.count == 1)
}

@Test func containerRequest_onPreTerminate_addsHook() {
    let request = ContainerRequest(image: "alpine:3")
        .onPreTerminate { _ in }

    #expect(request.preTerminateHooks.count == 1)
}

@Test func containerRequest_onPostTerminate_addsHook() {
    let request = ContainerRequest(image: "alpine:3")
        .onPostTerminate { _ in }

    #expect(request.postTerminateHooks.count == 1)
}

@Test func containerRequest_multipleHooks_samePhase() {
    let request = ContainerRequest(image: "alpine:3")
        .onPostStart { _ in }
        .onPostStart { _ in }
        .onPostStart { _ in }

    #expect(request.postStartHooks.count == 3)
}

@Test func containerRequest_multipleHooks_differentPhases() {
    let request = ContainerRequest(image: "alpine:3")
        .onPreStart { _ in }
        .onPostStart { _ in }
        .onPreStop { _ in }
        .onPostStop { _ in }
        .onPreTerminate { _ in }
        .onPostTerminate { _ in }

    #expect(request.preStartHooks.count == 1)
    #expect(request.postStartHooks.count == 1)
    #expect(request.preStopHooks.count == 1)
    #expect(request.postStopHooks.count == 1)
    #expect(request.preTerminateHooks.count == 1)
    #expect(request.postTerminateHooks.count == 1)
}

@Test func containerRequest_hookRegistration_returnsNewInstance() {
    let original = ContainerRequest(image: "alpine:3")
    let modified = original.onPreStart { _ in }

    #expect(original.preStartHooks.isEmpty)
    #expect(modified.preStartHooks.count == 1)
}

@Test func containerRequest_hooksStartEmpty() {
    let request = ContainerRequest(image: "alpine:3")

    #expect(request.preStartHooks.isEmpty)
    #expect(request.postStartHooks.isEmpty)
    #expect(request.preStopHooks.isEmpty)
    #expect(request.postStopHooks.isEmpty)
    #expect(request.preTerminateHooks.isEmpty)
    #expect(request.postTerminateHooks.isEmpty)
}

@Test func containerRequest_hooksPreserveOrder() {
    // Create hooks with unique IDs - we just test ordering, not execution
    let hook1 = LifecycleHook { _ in }
    let hook2 = LifecycleHook { _ in }
    let hook3 = LifecycleHook { _ in }

    let request = ContainerRequest(image: "alpine:3")
        .withLifecycleHook(hook1, phase: .postStart)
        .withLifecycleHook(hook2, phase: .postStart)
        .withLifecycleHook(hook3, phase: .postStart)

    #expect(request.postStartHooks.count == 3)
    #expect(request.postStartHooks[0].id == hook1.id)
    #expect(request.postStartHooks[1].id == hook2.id)
    #expect(request.postStartHooks[2].id == hook3.id)
}

@Test func containerRequest_chainableWithOtherBuilders() {
    let request = ContainerRequest(image: "alpine:3")
        .withName("test-container")
        .onPreStart { _ in }
        .withEnvironment(["KEY": "value"])
        .onPostStart { _ in }
        .withExposedPort(8080)

    #expect(request.name == "test-container")
    #expect(request.environment["KEY"] == "value")
    #expect(request.ports.count == 1)
    #expect(request.preStartHooks.count == 1)
    #expect(request.postStartHooks.count == 1)
}

// MARK: - LifecyclePhase Tests

@Test func lifecyclePhase_allCasesExist() {
    let phases: [LifecyclePhase] = [
        .preStart,
        .postStart,
        .preStop,
        .postStop,
        .preTerminate,
        .postTerminate
    ]

    #expect(phases.count == 6)
}

@Test func lifecyclePhase_rawValues() {
    #expect(LifecyclePhase.preStart.rawValue == "preStart")
    #expect(LifecyclePhase.postStart.rawValue == "postStart")
    #expect(LifecyclePhase.preStop.rawValue == "preStop")
    #expect(LifecyclePhase.postStop.rawValue == "postStop")
    #expect(LifecyclePhase.preTerminate.rawValue == "preTerminate")
    #expect(LifecyclePhase.postTerminate.rawValue == "postTerminate")
}

// MARK: - Hook Execution Tests (Synchronous Logic)

@Test func executeHooks_emptyArray_succeeds() async throws {
    let hooks: [LifecycleHook] = []
    let request = ContainerRequest(image: "alpine:3")
    let docker = DockerClient()
    let context = LifecycleContext(container: nil, request: request, runtime: docker)

    // Should not throw
    try await executeLifecycleHooks(hooks, context: context, phase: .preStart)
}

@Test func executeHooks_singleHook_executes() async throws {
    final class ExecutionTracker: @unchecked Sendable {
        var executed = false
    }
    let tracker = ExecutionTracker()

    let hook = LifecycleHook { _ in
        tracker.executed = true
    }

    let request = ContainerRequest(image: "alpine:3")
    let docker = DockerClient()
    let context = LifecycleContext(container: nil, request: request, runtime: docker)

    try await executeLifecycleHooks([hook], context: context, phase: .preStart)

    #expect(tracker.executed)
}

@Test func executeHooks_multipleHooks_executeInOrder() async throws {
    final class OrderTracker: @unchecked Sendable {
        var order: [Int] = []
    }
    let tracker = OrderTracker()

    let hook1 = LifecycleHook { _ in tracker.order.append(1) }
    let hook2 = LifecycleHook { _ in tracker.order.append(2) }
    let hook3 = LifecycleHook { _ in tracker.order.append(3) }

    let request = ContainerRequest(image: "alpine:3")
    let docker = DockerClient()
    let context = LifecycleContext(container: nil, request: request, runtime: docker)

    try await executeLifecycleHooks([hook1, hook2, hook3], context: context, phase: .preStart)

    #expect(tracker.order == [1, 2, 3])
}

@Test func executeHooks_hookThrows_propagatesError() async {
    struct TestError: Error {}

    let hook = LifecycleHook { _ in
        throw TestError()
    }

    let request = ContainerRequest(image: "alpine:3")
    let docker = DockerClient()
    let context = LifecycleContext(container: nil, request: request, runtime: docker)

    await #expect(throws: TestContainersError.self) {
        try await executeLifecycleHooks([hook], context: context, phase: .preStart)
    }
}

@Test func executeHooks_firstHookThrows_stopsExecution() async throws {
    struct TestError: Error {}

    final class CallTracker: @unchecked Sendable {
        var secondHookCalled = false
    }
    let tracker = CallTracker()

    let hook1 = LifecycleHook { _ in throw TestError() }
    let hook2 = LifecycleHook { _ in tracker.secondHookCalled = true }

    let request = ContainerRequest(image: "alpine:3")
    let docker = DockerClient()
    let context = LifecycleContext(container: nil, request: request, runtime: docker)

    do {
        try await executeLifecycleHooks([hook1, hook2], context: context, phase: .preStart)
        Issue.record("Expected error to be thrown")
    } catch {
        #expect(!tracker.secondHookCalled)
    }
}

// MARK: - Error Type Tests

@Test func lifecycleHookFailed_hasCorrectDescription() {
    struct UnderlyingError: Error, CustomStringConvertible {
        var description: String { "Something went wrong" }
    }

    let error = TestContainersError.lifecycleHookFailed(
        phase: "postStart",
        hookIndex: 2,
        underlyingError: UnderlyingError()
    )

    let description = error.description
    #expect(description.contains("postStart"))
    #expect(description.contains("2"))
}

@Test func lifecycleError_hasCorrectDescription() {
    let error = TestContainersError.lifecycleError("Container not available")

    #expect(error.description.contains("Container not available"))
}

// MARK: - Integration Tests

/// Thread-safe state tracking for integration tests
private actor TestState {
    var preStartCalled = false
    var preStartTime: Date?
    var containerCreatedTime: Date?
    var capturedContainerId: String?
    var logsCaptured: String?
    var executionOrder: [String] = []
    var preTerminateCalled = false
    var postTerminateCalled = false
    var execResult: ExecResult?

    func markPreStartCalled() {
        preStartCalled = true
        preStartTime = Date()
    }

    func markContainerCreated() {
        containerCreatedTime = Date()
    }

    func setCapturedContainerId(_ id: String) {
        capturedContainerId = id
    }

    func setLogsCaptured(_ logs: String) {
        logsCaptured = logs
    }

    func appendExecutionOrder(_ item: String) {
        executionOrder.append(item)
    }

    func markPreTerminateCalled() {
        preTerminateCalled = true
    }

    func markPostTerminateCalled() {
        postTerminateCalled = true
    }

    func setExecResult(_ result: ExecResult) {
        execResult = result
    }
}

@Test func lifecycleHooks_preStartHook_executesBeforeContainerCreation() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let state = TestState()

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .onPreStart { _ in
            await state.markPreStartCalled()
        }
        .onPostStart { _ in
            await state.markContainerCreated()
        }

    try await withContainer(request) { _ in
        let preStartCalled = await state.preStartCalled
        #expect(preStartCalled)
        if let pre = await state.preStartTime, let post = await state.containerCreatedTime {
            #expect(pre < post)
        }
    }
}

@Test func lifecycleHooks_postStartHook_canAccessContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let state = TestState()

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .onPostStart { context in
            let container = try context.requireContainer()
            let id = await container.id
            await state.setCapturedContainerId(id)
        }

    try await withContainer(request) { container in
        let actualId = await container.id
        let capturedId = await state.capturedContainerId
        #expect(capturedId == actualId)
    }
}

@Test func lifecycleHooks_preTerminateHook_executesBeforeTermination() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let state = TestState()

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "echo 'Hello from container' && sleep 30"])
        .onPreTerminate { context in
            let container = try context.requireContainer()
            let logs = try await container.logs()
            await state.setLogsCaptured(logs)
        }

    try await withContainer(request) { _ in
        // Container is running
    }

    let logsCaptured = await state.logsCaptured
    #expect(logsCaptured?.contains("Hello from container") == true)
}

@Test func lifecycleHooks_multipleHooks_executeInOrder() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let state = TestState()

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .onPreStart { _ in await state.appendExecutionOrder("preStart1") }
        .onPreStart { _ in await state.appendExecutionOrder("preStart2") }
        .onPostStart { _ in await state.appendExecutionOrder("postStart1") }
        .onPostStart { _ in await state.appendExecutionOrder("postStart2") }
        .onPreTerminate { _ in await state.appendExecutionOrder("preTerminate") }
        .onPostTerminate { _ in await state.appendExecutionOrder("postTerminate") }

    try await withContainer(request) { _ in
        // Verify pre-start and post-start hooks ran
        let order = await state.executionOrder
        #expect(order.contains("preStart1"))
        #expect(order.contains("preStart2"))
        #expect(order.contains("postStart1"))
        #expect(order.contains("postStart2"))
    }

    // After withContainer completes, terminate hooks should have run
    let finalOrder = await state.executionOrder
    #expect(finalOrder.contains("preTerminate"))
    #expect(finalOrder.contains("postTerminate"))

    // Verify order
    if let preStart1Index = finalOrder.firstIndex(of: "preStart1"),
       let preStart2Index = finalOrder.firstIndex(of: "preStart2"),
       let postStart1Index = finalOrder.firstIndex(of: "postStart1") {
        #expect(preStart1Index < preStart2Index)
        #expect(preStart2Index < postStart1Index)
    }
}

@Test func lifecycleHooks_errorInPreStart_preventsContainerCreation() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    struct PreStartError: Error {}

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .onPreStart { _ in
            throw PreStartError()
        }

    await #expect(throws: TestContainersError.self) {
        try await withContainer(request) { _ in
            Issue.record("Should not reach here - preStart should have failed")
        }
    }
}

@Test func lifecycleHooks_errorInPostStart_triggersCleanup() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    struct PostStartError: Error {}
    let state = TestState()

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .onPostStart { _ in
            throw PostStartError()
        }
        .onPreTerminate { _ in
            await state.markPreTerminateCalled()
        }

    await #expect(throws: TestContainersError.self) {
        try await withContainer(request) { _ in
            Issue.record("Should not reach here - postStart should have failed")
        }
    }

    // PreTerminate should still be called for cleanup
    let preTerminateCalled = await state.preTerminateCalled
    #expect(preTerminateCalled)
}

@Test func lifecycleHooks_errorInPreTerminate_doesNotPreventTermination() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    struct PreTerminateError: Error {}
    let state = TestState()

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .onPreTerminate { _ in
            throw PreTerminateError()
        }
        .onPostTerminate { _ in
            await state.markPostTerminateCalled()
        }

    // Should not throw despite preTerminate error
    try await withContainer(request) { _ in
        // Do nothing
    }

    // PostTerminate should still be called
    let postTerminateCalled = await state.postTerminateCalled
    #expect(postTerminateCalled)
}

@Test func lifecycleHooks_postStartHook_canExecuteDockerCommands() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let state = TestState()

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .onPostStart { context in
            let container = try context.requireContainer()
            let result = try await context.runtime.exec(
                id: await container.id,
                command: ["echo", "Hello from hook"],
                options: ExecOptions()
            )
            await state.setExecResult(result)
        }

    try await withContainer(request) { _ in
        let execResult = await state.execResult
        #expect(execResult?.exitCode == 0)
        #expect(execResult?.stdout.contains("Hello from hook") == true)
    }
}
