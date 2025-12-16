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
            #"start worker process"#,
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

// MARK: - exec Wait Strategy Integration Tests

@Test func exec_succeeds_whenCommandExitsZero() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Alpine container creates a file after a delay, then sleeps
    let request = ContainerRequest(image: "alpine:3")
        .withCommand([
            "sh", "-c",
            "sleep 2 && touch /tmp/ready && sleep 30"
        ])
        .waitingFor(.exec(
            ["test", "-f", "/tmp/ready"],
            timeout: .seconds(10)
        ))

    try await withContainer(request) { container in
        // If we get here, the wait strategy succeeded
        let containerId = await container.id
        #expect(containerId.isEmpty == false)
    }
}

@Test func exec_succeeds_immediatelyWhenCommandAlwaysSucceeds() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // The 'true' command always exits with 0
    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .waitingFor(.exec(["true"], timeout: .seconds(10)))

    try await withContainer(request) { container in
        let containerId = await container.id
        #expect(containerId.isEmpty == false)
    }
}

@Test func exec_timesOut_whenCommandNeverSucceeds() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .waitingFor(.exec(
            ["test", "-f", "/nonexistent"],
            timeout: .seconds(2),
            pollInterval: .milliseconds(100)
        ))

    do {
        try await withContainer(request) { _ in
            Issue.record("Expected timeout error")
        }
    } catch let error as TestContainersError {
        if case let .timeout(message) = error {
            #expect(message.contains("test -f /nonexistent"))
        } else {
            Issue.record("Expected timeout error, got: \(error)")
        }
    }
}

@Test func exec_withPostgres_pgIsReady() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "postgres:16-alpine")
        .withEnvironment(["POSTGRES_PASSWORD": "test"])
        .withExposedPort(5432)
        .waitingFor(.exec(
            ["pg_isready", "-U", "postgres"],
            timeout: .seconds(60)
        ))

    try await withContainer(request) { container in
        let port = try await container.hostPort(5432)
        #expect(port > 0)
    }
}

@Test func exec_withShellCommand() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Test complex shell command execution
    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .waitingFor(.exec(
            ["sh", "-c", "echo hello && test 1 -eq 1"],
            timeout: .seconds(10)
        ))

    try await withContainer(request) { container in
        let containerId = await container.id
        #expect(containerId.isEmpty == false)
    }
}

// MARK: - healthCheck Wait Strategy Integration Tests

@Test func healthCheck_succeeds_withRuntimeHealthCheck() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Use withHealthCheck to configure a runtime health check
    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "sleep 2 && touch /tmp/healthy && sleep 60"])
        .withHealthCheck(command: ["test", "-f", "/tmp/healthy"], interval: .seconds(1))
        .waitingFor(.healthCheck(timeout: .seconds(30)))

    try await withContainer(request) { container in
        let containerId = await container.id
        #expect(containerId.isEmpty == false)
    }
}

@Test func healthCheck_succeeds_withPostgres() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Configure health check using pg_isready
    let request = ContainerRequest(image: "postgres:16-alpine")
        .withEnvironment(["POSTGRES_PASSWORD": "test"])
        .withExposedPort(5432)
        .withHealthCheck(command: ["pg_isready", "-U", "postgres"], interval: .seconds(1))
        .waitingFor(.healthCheck(timeout: .seconds(120)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(5432)
        #expect(port > 0)

        // Container should be healthy at this point
        let logs = try await container.logs()
        #expect(logs.contains("database system is ready to accept connections"))
    }
}

@Test func healthCheck_failsWithoutHealthCheck() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Alpine has no HEALTHCHECK configured and we don't add one
    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .waitingFor(.healthCheck(timeout: .seconds(5)))

    do {
        try await withContainer(request) { _ in
            Issue.record("Expected healthCheckNotConfigured error")
        }
    } catch let error as TestContainersError {
        if case let .healthCheckNotConfigured(message) = error {
            #expect(message.contains("does not have a HEALTHCHECK configured"))
        } else {
            Issue.record("Expected healthCheckNotConfigured error, got: \(error)")
        }
    }
}

// MARK: - Entrypoint Override Integration Tests

@Test func entrypoint_override_withShellCommand() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint(["/bin/sh", "-c"])
        .withCommand(["echo 'Entrypoint override works' && sleep 1"])
        .waitingFor(.logContains("Entrypoint override works"))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Entrypoint override works"))
    }
}

@Test func entrypoint_disable_allowsDirectCommand() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Disable entrypoint and run echo directly
    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint([])
        .withCommand(["/bin/echo", "Direct command execution"])
        .waitingFor(.logContains("Direct command execution"))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Direct command execution"))
    }
}

@Test func entrypoint_singleExecutable_passesArgsFromCommand() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint("/bin/echo")
        .withCommand(["Hello", "from", "entrypoint"])
        .waitingFor(.logContains("Hello from entrypoint"))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Hello from entrypoint"))
    }
}

@Test func entrypoint_multiPart_prependsArgsToCommand() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Test that multi-part entrypoint works: ["/bin/sh", "-c"] with command
    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint(["/bin/sh", "-c"])
        .withCommand(["echo 'Multi-part entrypoint' && sleep 1"])
        .waitingFor(.logContains("Multi-part entrypoint"))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Multi-part entrypoint"))
    }
}

// MARK: - Artifact Collection Integration Tests

@Test func artifactCollection_onFailure_collectsArtifacts() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let artifactDir = "/tmp/testcontainers-artifact-test-\(UUID().uuidString)"
    let config = ArtifactConfig()
        .withOutputDirectory(artifactDir)
        .withTrigger(.onFailure)

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["/bin/sh", "-c", "echo 'Test artifact output' && sleep 2"])
        .waitingFor(.logContains("Test artifact output"))
        .withArtifacts(config)

    // Intentionally fail the operation
    do {
        try await withContainer(request, testName: "ArtifactTests.testFailure") { _ in
            throw TestContainersError.timeout("Intentional test failure")
        }
        Issue.record("Expected error to be thrown")
    } catch {
        // Error expected
    }

    // Verify artifacts were collected
    let fm = FileManager.default
    let artifactTestDir = "\(artifactDir)/ArtifactTests.testFailure"
    #expect(fm.fileExists(atPath: artifactTestDir))

    // Cleanup
    try? fm.removeItem(atPath: artifactDir)
}

@Test func artifactCollection_always_collectsOnSuccess() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let artifactDir = "/tmp/testcontainers-artifact-test-\(UUID().uuidString)"
    let config = ArtifactConfig()
        .withOutputDirectory(artifactDir)
        .withTrigger(.always)

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["/bin/sh", "-c", "echo 'Always collect test' && sleep 2"])
        .waitingFor(.logContains("Always collect test"))
        .withArtifacts(config)

    try await withContainer(request, testName: "ArtifactTests.testAlways") { _ in
        // Success path
    }

    // Verify artifacts were collected even on success
    let fm = FileManager.default
    let artifactTestDir = "\(artifactDir)/ArtifactTests.testAlways"
    #expect(fm.fileExists(atPath: artifactTestDir))

    // Cleanup
    try? fm.removeItem(atPath: artifactDir)
}

@Test func artifactCollection_disabled_doesNotCollect() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let artifactDir = "/tmp/testcontainers-artifact-test-\(UUID().uuidString)"

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["/bin/sh", "-c", "echo 'No collect test' && sleep 2"])
        .waitingFor(.logContains("No collect test"))
        .withoutArtifacts()

    // Intentionally fail the operation
    do {
        try await withContainer(request, testName: "ArtifactTests.testDisabled") { _ in
            throw TestContainersError.timeout("Intentional test failure")
        }
        Issue.record("Expected error to be thrown")
    } catch {
        // Error expected
    }

    // Verify no artifacts were collected
    let fm = FileManager.default
    let artifactTestDir = "\(artifactDir)/ArtifactTests.testDisabled"
    #expect(!fm.fileExists(atPath: artifactTestDir))
}

@Test func artifactCollection_collectsLogsAndMetadata() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let artifactDir = "/tmp/testcontainers-artifact-test-\(UUID().uuidString)"
    let config = ArtifactConfig()
        .withOutputDirectory(artifactDir)
        .withTrigger(.onFailure)

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["/bin/sh", "-c", "echo 'Logs and metadata test' && sleep 2"])
        .waitingFor(.logContains("Logs and metadata test"))
        .withEnvironment(["TEST_VAR": "test_value"])
        .withArtifacts(config)

    // Intentionally fail the operation
    do {
        try await withContainer(request, testName: "ArtifactTests.testLogsAndMetadata") { _ in
            throw TestContainersError.timeout("Intentional test failure")
        }
    } catch {
        // Error expected
    }

    // Verify artifact files were created
    let fm = FileManager.default
    let artifactTestDir = "\(artifactDir)/ArtifactTests.testLogsAndMetadata"

    // Find the artifact subdirectory (containerId_timestamp)
    if let contents = try? fm.contentsOfDirectory(atPath: artifactTestDir), let subdir = contents.first {
        let artifactSubdir = "\(artifactTestDir)/\(subdir)"

        // Check logs file exists and contains output
        let logsPath = "\(artifactSubdir)/logs.txt"
        if fm.fileExists(atPath: logsPath),
           let logsContent = try? String(contentsOfFile: logsPath, encoding: .utf8) {
            #expect(logsContent.contains("Logs and metadata test"))
        }

        // Check metadata file exists
        let metadataPath = "\(artifactSubdir)/metadata.json"
        #expect(fm.fileExists(atPath: metadataPath))

        // Check request file exists and contains environment
        let requestPath = "\(artifactSubdir)/request.json"
        if fm.fileExists(atPath: requestPath),
           let requestContent = try? String(contentsOfFile: requestPath, encoding: .utf8) {
            #expect(requestContent.contains("TEST_VAR"))
        }

        // Check error file exists
        let errorPath = "\(artifactSubdir)/error.txt"
        #expect(fm.fileExists(atPath: errorPath))
    }

    // Cleanup
    try? fm.removeItem(atPath: artifactDir)
}
