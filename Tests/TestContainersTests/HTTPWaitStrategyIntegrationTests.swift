import Foundation
import Testing
@testable import TestContainers

// MARK: - HTTP Wait Strategy Integration Tests
//
// These tests require Docker to be running and are opt-in via environment variable.
// Run with: TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test

@Test func httpWaitStrategy_nginx_basicHealthCheck() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "nginx:alpine")
        .withExposedPort(80)
        .waitingFor(.http(HTTPWaitConfig(port: 80)))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 80)
        #expect(!endpoint.isEmpty)
    }
}

@Test func httpWaitStrategy_nginx_customPath() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // nginx returns 200 for / by default
    let request = ContainerRequest(image: "nginx:alpine")
        .withExposedPort(80)
        .waitingFor(.http(
            HTTPWaitConfig(port: 80)
                .withPath("/")
                .withStatusCode(200)
        ))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 80)
        #expect(!endpoint.isEmpty)
    }
}

@Test func httpWaitStrategy_nginx_bodyContains() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "nginx:alpine")
        .withExposedPort(80)
        .waitingFor(.http(
            HTTPWaitConfig(port: 80)
                .withBodyContains("nginx")
        ))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 80)
        #expect(!endpoint.isEmpty)
    }
}

@Test func httpWaitStrategy_nginx_statusCodeRange() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "nginx:alpine")
        .withExposedPort(80)
        .waitingFor(.http(
            HTTPWaitConfig(port: 80)
                .withStatusCodeRange(200...299)
        ))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 80)
        #expect(!endpoint.isEmpty)
    }
}

@Test func httpWaitStrategy_httpbin_customEndpoint() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "kennethreitz/httpbin")
        .withExposedPort(80)
        .waitingFor(.http(
            HTTPWaitConfig(port: 80)
                .withPath("/status/200")
                .withStatusCode(200)
                .withTimeout(.seconds(90))
        ))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 80)
        #expect(!endpoint.isEmpty)
    }
}

@Test func httpWaitStrategy_httpbin_bodyRegex() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "kennethreitz/httpbin")
        .withExposedPort(80)
        .waitingFor(.http(
            HTTPWaitConfig(port: 80)
                .withPath("/get")
                .withBodyMatcher(.regex("\"url\"\\s*:"))
                .withTimeout(.seconds(90))
        ))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 80)
        #expect(!endpoint.isEmpty)
    }
}

@Test func httpWaitStrategy_httpbin_headMethod() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // httpbin supports HEAD requests
    let request = ContainerRequest(image: "kennethreitz/httpbin")
        .withExposedPort(80)
        .waitingFor(.http(
            HTTPWaitConfig(port: 80)
                .withPath("/get")
                .withMethod(.head)
                .withStatusCodeRange(200...299)
                .withTimeout(.seconds(90))
        ))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 80)
        #expect(!endpoint.isEmpty)
    }
}

@Test func httpWaitStrategy_httpbin_customHeader() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "kennethreitz/httpbin")
        .withExposedPort(80)
        .waitingFor(.http(
            HTTPWaitConfig(port: 80)
                .withPath("/headers")
                .withHeader("X-Custom-Test", "TestValue")
                .withBodyContains("TestValue")
                .withTimeout(.seconds(90))
        ))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 80)
        #expect(!endpoint.isEmpty)
    }
}

@Test func httpWaitStrategy_wrongStatusCode_timesOut() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // nginx returns 200 for /, but we expect 404 - should timeout
    let request = ContainerRequest(image: "nginx:alpine")
        .withExposedPort(80)
        .waitingFor(.http(
            HTTPWaitConfig(port: 80)
                .withPath("/")
                .withStatusCode(404)
                .withTimeout(.seconds(3))
                .withPollInterval(.milliseconds(500))
        ))

    do {
        _ = try await withContainer(request) { _ in
            Issue.record("Expected timeout error but container started successfully")
        }
    } catch let error as TestContainersError {
        // Expected timeout error
        if case .timeout(let message) = error {
            #expect(message.contains("HTTP endpoint"))
        } else {
            Issue.record("Expected timeout error, got: \(error)")
        }
    }
}

@Test func httpWaitStrategy_wrongBody_timesOut() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // nginx default page doesn't contain this text
    let request = ContainerRequest(image: "nginx:alpine")
        .withExposedPort(80)
        .waitingFor(.http(
            HTTPWaitConfig(port: 80)
                .withBodyContains("this-text-does-not-exist-in-nginx-page")
                .withTimeout(.seconds(3))
                .withPollInterval(.milliseconds(500))
        ))

    do {
        _ = try await withContainer(request) { _ in
            Issue.record("Expected timeout error but container started successfully")
        }
    } catch let error as TestContainersError {
        // Expected timeout error
        if case .timeout(let message) = error {
            #expect(message.contains("HTTP endpoint"))
        } else {
            Issue.record("Expected timeout error, got: \(error)")
        }
    }
}

@Test func httpWaitStrategy_customPollInterval() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "nginx:alpine")
        .withExposedPort(80)
        .waitingFor(.http(
            HTTPWaitConfig(port: 80)
                .withPollInterval(.milliseconds(100))
                .withTimeout(.seconds(60))
        ))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 80)
        #expect(!endpoint.isEmpty)
    }
}

@Test func httpWaitStrategy_chainedWithTCP_httpOnlyUsed() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Test that HTTP strategy is used (last one wins)
    let request = ContainerRequest(image: "nginx:alpine")
        .withExposedPort(80)
        .waitingFor(.tcpPort(80))  // This gets overwritten
        .waitingFor(.http(HTTPWaitConfig(port: 80)))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 80)
        #expect(!endpoint.isEmpty)
    }
}
