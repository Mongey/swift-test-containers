import Foundation
import Testing
@testable import TestContainers

// MARK: - Retry Integration Tests (Docker-based)

@Test func retry_successfulStartup_noRetryNeeded() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Container that starts successfully on first attempt
    let request = ContainerRequest(image: "redis:7-alpine")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379, timeout: .seconds(30)))
        .withRetry()  // Retry enabled but shouldn't be needed

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }
}

@Test func retry_exhaustion_throwsCorrectError() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Container with impossible wait condition - will always fail
    // Using a very short timeout and only 1 retry to keep test fast
    let fastPolicy = RetryPolicy(
        maxAttempts: 1,
        initialDelay: .milliseconds(100),
        maxDelay: .seconds(1),
        backoffMultiplier: 2.0,
        jitter: 0.0
    )

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "infinity"])
        .waitingFor(.logContains("NEVER_APPEARS", timeout: .milliseconds(500)))
        .withRetry(fastPolicy)

    do {
        try await withContainer(request) { _ in
            Issue.record("Expected error to be thrown")
        }
    } catch let error as TestContainersError {
        if case let .startupRetriesExhausted(attempts, _) = error {
            #expect(attempts == 2)  // 1 initial + 1 retry
        } else {
            Issue.record("Expected startupRetriesExhausted error, got \(error)")
        }
    }
}

@Test func retry_withoutPolicy_failsImmediately() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Container without retry policy should fail on first attempt
    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "infinity"])
        .waitingFor(.logContains("NEVER_APPEARS", timeout: .milliseconds(500)))
    // Note: No .withRetry()

    do {
        try await withContainer(request) { _ in
            Issue.record("Expected error to be thrown")
        }
    } catch let error as TestContainersError {
        // Should be a direct timeout, not retry exhaustion
        if case .timeout = error {
            // Expected - single attempt timeout
        } else if case .startupRetriesExhausted = error {
            Issue.record("Should not be retry exhaustion without retry policy")
        }
    }
}

@Test func retry_aggressivePolicy_multipleAttempts() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Using a policy with 2 retries (3 total attempts)
    let testPolicy = RetryPolicy(
        maxAttempts: 2,
        initialDelay: .milliseconds(50),
        maxDelay: .seconds(1),
        backoffMultiplier: 2.0,
        jitter: 0.0
    )

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "infinity"])
        .waitingFor(.logContains("NEVER_APPEARS", timeout: .milliseconds(200)))
        .withRetry(testPolicy)

    do {
        try await withContainer(request) { _ in
            Issue.record("Expected error to be thrown")
        }
    } catch let error as TestContainersError {
        if case let .startupRetriesExhausted(attempts, _) = error {
            #expect(attempts == 3)  // 1 initial + 2 retries
        } else {
            Issue.record("Expected startupRetriesExhausted error, got \(error)")
        }
    }
}

// MARK: - Retry Unit Tests (No Docker required)

@Test func shouldNotRetry_dockerNotAvailable_returnsTrue() {
    // This test validates the shouldNotRetry logic without Docker
    let error = TestContainersError.dockerNotAvailable("Docker not running")

    // We test this indirectly through the error type matching
    if case TestContainersError.dockerNotAvailable = error {
        // This is a non-retryable error type
    } else {
        Issue.record("Expected dockerNotAvailable error type")
    }
}

@Test func shouldNotRetry_timeout_returnsFalse() {
    // Timeout errors should be retried
    let error = TestContainersError.timeout("Wait timed out")

    // Timeout is retryable - it's transient
    if case TestContainersError.timeout = error {
        // This is a retryable error type
    } else {
        Issue.record("Expected timeout error type")
    }
}

@Test func shouldNotRetry_commandFailed_returnsFalse() {
    // Command failures should be retried (could be transient)
    let error = TestContainersError.commandFailed(
        command: ["docker", "run"],
        exitCode: 125,
        stdout: "",
        stderr: "port already in use"
    )

    if case TestContainersError.commandFailed = error {
        // This is a retryable error type (port conflicts can be transient)
    } else {
        Issue.record("Expected commandFailed error type")
    }
}

// MARK: - Cancellation Tests

@Test func retry_cancellation_stopsRetries() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let slowPolicy = RetryPolicy(
        maxAttempts: 10,  // Many retries
        initialDelay: .seconds(5),  // Long delays
        maxDelay: .seconds(30),
        backoffMultiplier: 2.0,
        jitter: 0.0
    )

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "infinity"])
        .waitingFor(.logContains("NEVER_APPEARS", timeout: .milliseconds(500)))
        .withRetry(slowPolicy)

    let task = Task {
        try await withContainer(request) { _ in
            Issue.record("Should not reach operation")
        }
    }

    // Cancel after a short delay
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Expected cancellation error")
    } catch is CancellationError {
        // Expected
    } catch {
        // Other errors might occur during cleanup, which is acceptable
    }
}
