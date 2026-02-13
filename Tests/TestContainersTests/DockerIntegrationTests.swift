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

@Test func canRunContainerAsSpecificUser_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withUser(uid: 1000, gid: 1000)
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let uidResult = try await container.exec(["id", "-u"])
        let gidResult = try await container.exec(["id", "-g"])

        #expect(uidResult.exitCode == 0)
        #expect(gidResult.exitCode == 0)
        #expect(uidResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1000")
        #expect(gidResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1000")
    }
}

// MARK: - Extra Hosts Integration Tests

@Test func extraHosts_areWrittenToEtcHosts_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withExtraHost(hostname: "db.local", ip: "192.0.2.10")
        .withExtraHost(hostname: "cache.local", ip: "192.0.2.11")
        .withCommand(["cat", "/etc/hosts"])

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("192.0.2.10"))
        #expect(logs.contains("db.local"))
        #expect(logs.contains("192.0.2.11"))
        #expect(logs.contains("cache.local"))
    }
}

// MARK: - Resource Limits Integration Tests

@Test func resourceLimits_canStartContainerWithMemoryLimit_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7")
        .withMemoryLimit("256m")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }
}

@Test func resourceLimits_canStartContainerWithCpuAndMemory_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withMemoryLimit("128m")
        .withCpuLimit("0.5")
        .withCpuShares(512)
        .withCommand(["sh", "-c", "echo ready && sleep 1"])
        .waitingFor(.logContains("ready", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("ready"))
    }
}

// MARK: - Platform Selection Integration Tests

@Test func platformSelection_canStartContainer_withAMD64Platform() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withPlatform("linux/amd64")
        .withCommand(["sh", "-c", "uname -m && sleep 1"])
        .waitingFor(.logContains("x86_64", timeout: .seconds(30)))

    do {
        try await withContainer(request) { container in
            let logs = try await container.logs()
            #expect(logs.contains("x86_64"))
        }
    } catch let error as TestContainersError {
        if isUnsupportedPlatformError(error) {
            return
        }
        throw error
    }
}

@Test func platformSelection_canStartContainer_withARM64Platform() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withPlatform("linux/arm64")
        .withCommand(["sh", "-c", "uname -m && sleep 1"])
        .waitingFor(.logContains("aarch64", timeout: .seconds(30)))

    do {
        try await withContainer(request) { container in
            let logs = try await container.logs()
            #expect(logs.contains("aarch64"))
        }
    } catch let error as TestContainersError {
        if isUnsupportedPlatformError(error) {
            return
        }
        throw error
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

// MARK: - Tmpfs Mount Integration Tests

@Test func tmpfs_canMountSingleTmpfs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withTmpfs("/tmpdata", sizeLimit: "50m", mode: "1777")
        .withCommand(["sh", "-c", "mount | grep tmpdata && df -h /tmpdata && touch /tmpdata/test.txt && ls -la /tmpdata && echo SUCCESS"])
        .waitingFor(.logContains("SUCCESS", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()

        // Verify tmpfs is mounted
        #expect(logs.contains("tmpfs on /tmpdata"))

        // Verify file creation works
        #expect(logs.contains("test.txt"))

        // Verify success marker
        #expect(logs.contains("SUCCESS"))
    }
}

@Test func tmpfs_canMountMultipleTmpfs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withTmpfs("/tmp1", sizeLimit: "10m")
        .withTmpfs("/tmp2", sizeLimit: "20m")
        .withCommand(["sh", "-c", "mount | grep 'tmpfs on /tmp' && echo SUCCESS"])
        .waitingFor(.logContains("SUCCESS", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()

        // Both mounts should be present
        #expect(logs.contains("tmpfs on /tmp1"))
        #expect(logs.contains("tmpfs on /tmp2"))
        #expect(logs.contains("SUCCESS"))
    }
}

@Test func tmpfs_mountWithModeOnly() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withTmpfs("/scratch", mode: "0755")
        .withCommand(["sh", "-c", "mount | grep scratch && stat -c '%a' /scratch && echo SUCCESS"])
        .waitingFor(.logContains("SUCCESS", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()

        // Verify tmpfs is mounted
        #expect(logs.contains("tmpfs on /scratch"))
        #expect(logs.contains("SUCCESS"))
    }
}

@Test func tmpfs_mountWithNoOptions() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withTmpfs("/simple")
        .withCommand(["sh", "-c", "mount | grep simple && touch /simple/file.txt && cat /simple/file.txt && echo SUCCESS"])
        .waitingFor(.logContains("SUCCESS", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()

        // Verify tmpfs is mounted and usable
        #expect(logs.contains("tmpfs on /simple"))
        #expect(logs.contains("SUCCESS"))
    }
}

// MARK: - Working Directory Integration Tests

@Test func workingDirectory_setsContainerWorkingDirectory() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withWorkingDirectory("/tmp")
        .withCommand(["sh", "-c", "pwd && echo SUCCESS"])
        .waitingFor(.logContains("SUCCESS", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()

        // Verify working directory is set
        #expect(logs.contains("/tmp"))
        #expect(logs.contains("SUCCESS"))
    }
}

@Test func workingDirectory_createsNonExistentDirectory() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withWorkingDirectory("/app/data")
        .withCommand(["sh", "-c", "pwd && echo SUCCESS"])
        .waitingFor(.logContains("SUCCESS", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()

        // Docker creates the directory if it doesn't exist
        #expect(logs.contains("/app/data"))
        #expect(logs.contains("SUCCESS"))
    }
}

@Test func workingDirectory_worksWithCommand() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withWorkingDirectory("/home")
        .withCommand(["sh", "-c", "touch testfile.txt && ls && echo SUCCESS"])
        .waitingFor(.logContains("SUCCESS", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()

        // File should be created in the working directory
        #expect(logs.contains("testfile.txt"))
        #expect(logs.contains("SUCCESS"))
    }
}

// MARK: - Image Pull Policy Integration Tests

@Test func imagePullPolicy_always_pullsAndStartsContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.always)
        .withCommand(["sh", "-c", "echo 'pull-always-test' && sleep 2"])
        .waitingFor(.logContains("pull-always-test", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("pull-always-test"))
    }
}

@Test func imagePullPolicy_ifNotPresent_startsContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.ifNotPresent)
        .withCommand(["sh", "-c", "echo 'pull-ifnotpresent-test' && sleep 2"])
        .waitingFor(.logContains("pull-ifnotpresent-test", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("pull-ifnotpresent-test"))
    }
}

@Test func imagePullPolicy_never_startsContainerWhenImageExists() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // alpine:3 should already be present from other tests
    // First ensure it's pulled using the always policy
    let pullRequest = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.always)
        .withCommand(["true"])
    try? await withContainer(pullRequest) { _ in }

    let request = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.never)
        .withCommand(["sh", "-c", "echo 'pull-never-test' && sleep 2"])
        .waitingFor(.logContains("pull-never-test", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("pull-never-test"))
    }
}

@Test func imagePullPolicy_never_failsWhenImageMissing() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nonExistentImage = "alpine:this-tag-definitely-does-not-exist-\(UUID().uuidString)"

    let request = ContainerRequest(image: nonExistentImage)
        .withImagePullPolicy(.never)
        .withCommand(["echo", "test"])

    do {
        try await withContainer(request) { _ in
            Issue.record("Should have thrown imageNotFoundLocally error")
        }
    } catch let error as TestContainersError {
        if case let .imageNotFoundLocally(image, _) = error {
            #expect(image == nonExistentImage)
        } else {
            Issue.record("Expected imageNotFoundLocally error, got: \(error)")
        }
    }
}

@Test func imagePullPolicy_default_behavesLikeIfNotPresent() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // No pull policy specified - should use default .ifNotPresent
    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "echo 'default-pull-test' && sleep 2"])
        .waitingFor(.logContains("default-pull-test", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("default-pull-test"))
    }
}

// MARK: - Explicit Start/Stop Lifecycle Integration Tests

@Test func manualLifecycle_createStartStopTerminate() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let container = try await createContainer(
        ContainerRequest(image: "redis:7")
            .withExposedPort(6379)
            .waitingFor(.tcpPort(6379, timeout: .seconds(30)))
    )

    #expect(await container.currentState == .created)
    #expect(await container.isRunning == false)

    try await container.start()
    #expect(await container.currentState == .running)
    #expect(await container.isRunning == true)

    let port = try await container.hostPort(6379)
    #expect(port > 0)

    try await container.stop()
    #expect(await container.currentState == .stopped)
    #expect(await container.isRunning == false)

    try await container.terminate()
    #expect(await container.currentState == .terminated)
}

@Test func manualLifecycle_restart() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let container = try await createContainer(
        ContainerRequest(image: "redis:7")
            .withExposedPort(6379)
            .waitingFor(.tcpPort(6379, timeout: .seconds(30)))
    )

    try await container.start()
    #expect(await container.isRunning == true)

    try await container.restart()
    #expect(await container.currentState == .running)

    let port = try await container.hostPort(6379)
    #expect(port > 0)

    try await container.terminate()
}

@Test func manualLifecycle_idempotentOperations() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let container = try await createContainer(
        ContainerRequest(image: "redis:7")
            .withExposedPort(6379)
            .waitingFor(.tcpPort(6379, timeout: .seconds(30)))
    )

    try await container.start()
    try await container.start() // Should not throw
    #expect(await container.isRunning == true)

    try await container.stop()
    try await container.stop() // Should not throw
    #expect(await container.isRunning == false)

    try await container.terminate()
    try await container.terminate() // Should not throw
}

@Test func manualLifecycle_invalidStateTransitions() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let container = try await createContainer(
        ContainerRequest(image: "redis:7")
            .withExposedPort(6379)
            .waitingFor(.tcpPort(6379, timeout: .seconds(30)))
    )

    try await container.start()
    try await container.terminate()

    await #expect(throws: TestContainersError.self) {
        try await container.start()
    }

    await #expect(throws: TestContainersError.self) {
        try await container.stop()
    }

    await #expect(throws: TestContainersError.self) {
        try await container.restart()
    }
}

@Test func withContainerStillWorks_afterLifecycleFeature() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
        #expect(await container.isRunning == true)
    }
}

// MARK: - Network Alias Integration Tests

@Test func networkAlias_containerCanResolveOtherByAlias() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withNetwork(NetworkRequest()) { network in
        let networkName = await network.name

        let server = ContainerRequest(image: "nginx:alpine")
            .withNetwork(networkName, aliases: ["webserver"])
            .withExposedPort(80)
            .waitingFor(.tcpPort(80, timeout: .seconds(30)))

        let client = ContainerRequest(image: "alpine:3")
            .withNetwork(networkName)
            .withCommand(["sleep", "300"])

        try await withContainer(server) { _ in
            try await withContainer(client) { clientContainer in
                // Client can resolve "webserver" via DNS and ping it
                let result = try await clientContainer.exec(["ping", "-c", "1", "-W", "5", "webserver"])
                #expect(result.exitCode == 0)
            }
        }
    }
}

@Test func networkAlias_multipleAliasesAllResolvable() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withNetwork(NetworkRequest()) { network in
        let networkName = await network.name

        let server = ContainerRequest(image: "nginx:alpine")
            .withNetwork(networkName, aliases: ["web", "www", "nginx-svc"])
            .withExposedPort(80)
            .waitingFor(.tcpPort(80, timeout: .seconds(30)))

        let client = ContainerRequest(image: "alpine:3")
            .withNetwork(networkName)
            .withCommand(["sleep", "300"])

        try await withContainer(server) { _ in
            try await withContainer(client) { clientContainer in
                for alias in ["web", "www", "nginx-svc"] {
                    let result = try await clientContainer.exec(["ping", "-c", "1", "-W", "5", alias])
                    #expect(result.exitCode == 0, "Failed to resolve alias: \(alias)")
                }
            }
        }
    }
}

@Test func networkAlias_containerCommunicationOverTCP() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withNetwork(NetworkRequest()) { network in
        let networkName = await network.name

        // Start nginx as the server with alias "http-server"
        let server = ContainerRequest(image: "nginx:alpine")
            .withNetwork(networkName, aliases: ["http-server"])
            .withExposedPort(80)
            .waitingFor(.tcpPort(80, timeout: .seconds(30)))

        // Alpine client that will fetch from the server by alias
        let client = ContainerRequest(image: "alpine:3")
            .withNetwork(networkName)
            .withCommand(["sleep", "300"])

        try await withContainer(server) { _ in
            try await withContainer(client) { clientContainer in
                // wget the nginx default page via the alias
                let result = try await clientContainer.exec([
                    "wget", "-q", "-O", "-", "http://http-server:80/"
                ])
                #expect(result.exitCode == 0)
                #expect(result.stdout.contains("nginx"))
            }
        }
    }
}

private func isUnsupportedPlatformError(_ error: TestContainersError) -> Bool {
    guard case let .commandFailed(_, _, _, stderr) = error else {
        return false
    }

    let message = stderr.lowercased()
    return message.contains("no matching manifest for")
        || message.contains("requested image's platform")
        || (message.contains("platform") && message.contains("not supported"))
}
