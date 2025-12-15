import Testing
@testable import TestContainers

// MARK: - TestContainersError.startupRetriesExhausted Tests

@Test func testContainersError_startupRetriesExhausted_description() {
    let underlyingError = TestContainersError.timeout("Wait timed out")
    let error = TestContainersError.startupRetriesExhausted(attempts: 4, lastError: underlyingError)

    let description = error.description
    #expect(description.contains("Container startup failed after 4 attempts"))
    #expect(description.contains("Wait timed out"))
}

@Test func testContainersError_startupRetriesExhausted_preservesLastError() {
    let commandError = TestContainersError.commandFailed(
        command: ["docker", "run"],
        exitCode: 1,
        stdout: "",
        stderr: "port already in use"
    )
    let error = TestContainersError.startupRetriesExhausted(attempts: 3, lastError: commandError)

    if case let .startupRetriesExhausted(attempts, lastError) = error {
        #expect(attempts == 3)
        #expect("\(lastError)".contains("port already in use"))
    } else {
        Issue.record("Expected startupRetriesExhausted error")
    }
}

// MARK: - RetryPolicy Default Values Tests

@Test func retryPolicy_defaultValues() {
    let policy = RetryPolicy.default

    #expect(policy.maxAttempts == 3)
    #expect(policy.initialDelay == .seconds(1))
    #expect(policy.maxDelay == .seconds(30))
    #expect(policy.backoffMultiplier == 2.0)
    #expect(policy.jitter == 0.1)
}

@Test func retryPolicy_aggressivePreset() {
    let policy = RetryPolicy.aggressive

    #expect(policy.maxAttempts == 5)
    #expect(policy.initialDelay == .milliseconds(500))
    #expect(policy.maxDelay == .seconds(10))
    #expect(policy.backoffMultiplier == 2.0)
    #expect(policy.jitter == 0.1)
}

@Test func retryPolicy_conservativePreset() {
    let policy = RetryPolicy.conservative

    #expect(policy.maxAttempts == 2)
    #expect(policy.initialDelay == .seconds(2))
    #expect(policy.maxDelay == .seconds(60))
    #expect(policy.backoffMultiplier == 2.0)
    #expect(policy.jitter == 0.15)
}

// MARK: - RetryPolicy Custom Initialization Tests

@Test func retryPolicy_customInitialization() {
    let policy = RetryPolicy(
        maxAttempts: 4,
        initialDelay: .milliseconds(500),
        maxDelay: .seconds(15),
        backoffMultiplier: 1.5,
        jitter: 0.2
    )

    #expect(policy.maxAttempts == 4)
    #expect(policy.initialDelay == .milliseconds(500))
    #expect(policy.maxDelay == .seconds(15))
    #expect(policy.backoffMultiplier == 1.5)
    #expect(policy.jitter == 0.2)
}

// MARK: - RetryPolicy Delay Calculation Tests

@Test func retryPolicy_delay_zeroForFirstAttempt() {
    let policy = RetryPolicy.default

    let delay = policy.delay(for: 0)

    #expect(delay == .zero)
}

@Test func retryPolicy_delay_exponentialBackoff() {
    // Use zero jitter to get deterministic results
    let policy = RetryPolicy(
        maxAttempts: 5,
        initialDelay: .seconds(1),
        maxDelay: .seconds(60),
        backoffMultiplier: 2.0,
        jitter: 0.0
    )

    // attempt 1: 1 * 2^1 = 2s
    let delay1 = policy.delay(for: 1)
    #expect(delay1 == .seconds(2))

    // attempt 2: 1 * 2^2 = 4s
    let delay2 = policy.delay(for: 2)
    #expect(delay2 == .seconds(4))

    // attempt 3: 1 * 2^3 = 8s
    let delay3 = policy.delay(for: 3)
    #expect(delay3 == .seconds(8))
}

@Test func retryPolicy_delay_respectsMaxDelay() {
    let policy = RetryPolicy(
        maxAttempts: 10,
        initialDelay: .seconds(1),
        maxDelay: .seconds(5),
        backoffMultiplier: 2.0,
        jitter: 0.0
    )

    // attempt 5: 1 * 2^5 = 32s, but capped at 5s
    let delay = policy.delay(for: 5)
    #expect(delay == .seconds(5))
}

@Test func retryPolicy_delay_appliesJitter() {
    let policy = RetryPolicy(
        maxAttempts: 3,
        initialDelay: .seconds(1),
        maxDelay: .seconds(30),
        backoffMultiplier: 2.0,
        jitter: 0.5  // +/- 50%
    )

    // Run multiple times and check jitter produces variance
    var delays: Set<Duration> = []
    for _ in 0..<20 {
        delays.insert(policy.delay(for: 1))
    }

    // With 50% jitter on 2s base delay, values should be between 1s and 3s
    // We expect some variation (not all identical)
    // Note: There's a tiny chance all 20 could be identical, but extremely unlikely
    #expect(delays.count > 1, "Jitter should produce varying delays")
}

@Test func retryPolicy_delay_jitterBounds() {
    let policy = RetryPolicy(
        maxAttempts: 3,
        initialDelay: .seconds(1),
        maxDelay: .seconds(30),
        backoffMultiplier: 2.0,
        jitter: 0.5  // +/- 50%
    )

    // Base delay for attempt 1 is 2s
    // With 50% jitter: min = 1s, max = 3s
    for _ in 0..<50 {
        let delay = policy.delay(for: 1)
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        #expect(seconds >= 1.0, "Delay should be >= 1s (base 2s - 50%)")
        #expect(seconds <= 3.0, "Delay should be <= 3s (base 2s + 50%)")
    }
}

// MARK: - RetryPolicy Conformance Tests

@Test func retryPolicy_conformsToSendable() {
    let policy = RetryPolicy.default

    // Test that we can use it in a sendable context
    let task = Task {
        return policy.maxAttempts
    }
    _ = task
}

@Test func retryPolicy_conformsToHashable() {
    let policy1 = RetryPolicy(
        maxAttempts: 3,
        initialDelay: .seconds(1),
        maxDelay: .seconds(30),
        backoffMultiplier: 2.0,
        jitter: 0.1
    )

    let policy2 = RetryPolicy(
        maxAttempts: 3,
        initialDelay: .seconds(1),
        maxDelay: .seconds(30),
        backoffMultiplier: 2.0,
        jitter: 0.1
    )

    let policy3 = RetryPolicy(
        maxAttempts: 5,  // Different
        initialDelay: .seconds(1),
        maxDelay: .seconds(30),
        backoffMultiplier: 2.0,
        jitter: 0.1
    )

    #expect(policy1 == policy2)
    #expect(policy1 != policy3)
    #expect(policy1.hashValue == policy2.hashValue)
}
