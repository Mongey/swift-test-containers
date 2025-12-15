import Foundation
import Testing
import TestContainers

@Test func canStartContainer_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
        let endpoint = try await container.endpoint(for: 6379)
        #expect(endpoint.contains(":"))
    }
}

// MARK: - logMatches Integration Tests

@Test func logMatches_redis_basicRegexPattern() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7-alpine")
        .withExposedPort(6379)
        .waitingFor(.logMatches(
            #"Ready to accept connections"#,
            timeout: .seconds(60)
        ))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Ready to accept connections"))
    }
}

@Test func logMatches_redis_complexRegexPattern() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Match Redis startup with version pattern like "Redis version=7.x.x"
    let request = ContainerRequest(image: "redis:7-alpine")
        .withExposedPort(6379)
        .waitingFor(.logMatches(
            #"Redis version=\d+\.\d+\.\d+"#,
            timeout: .seconds(60)
        ))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Redis version="))
    }
}

@Test func logMatches_nginx_complexPattern() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Match nginx startup notice pattern
    let request = ContainerRequest(image: "nginx:alpine")
        .withExposedPort(80)
        .waitingFor(.logMatches(
            #"start worker process(es)?"#,
            timeout: .seconds(30)
        ))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("worker process"))
    }
}

@Test func logMatches_failsOnInvalidRegex() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7-alpine")
        .withExposedPort(6379)
        .waitingFor(.logMatches(
            #"[invalid(regex"#,  // Invalid regex pattern - unclosed bracket
            timeout: .seconds(10)
        ))

    do {
        try await withContainer(request) { _ in
            Issue.record("Expected error to be thrown for invalid regex")
        }
    } catch let error as TestContainersError {
        if case let .invalidRegexPattern(pattern, _) = error {
            #expect(pattern == "[invalid(regex")
        } else {
            Issue.record("Expected invalidRegexPattern error, got: \(error)")
        }
    }
}

@Test func logMatches_timesOutWhenPatternNeverMatches() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7-alpine")
        .withExposedPort(6379)
        .waitingFor(.logMatches(
            #"this_pattern_will_never_appear_in_redis_logs_xyz123"#,
            timeout: .seconds(3)
        ))

    do {
        try await withContainer(request) { _ in
            Issue.record("Expected timeout error")
        }
    } catch let error as TestContainersError {
        if case let .timeout(message) = error {
            #expect(message.contains("this_pattern_will_never_appear"))
        } else {
            Issue.record("Expected timeout error, got: \(error)")
        }
    }
}
