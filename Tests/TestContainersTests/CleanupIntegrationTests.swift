import Foundation
import Testing
@testable import TestContainers

// MARK: - Cleanup Integration Tests

/// Integration tests for the cleanup functionality.
/// These tests require Docker to be running and are gated by TESTCONTAINERS_RUN_DOCKER_TESTS=1.

private func dockerTestsEnabled() -> Bool {
    ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
}

@Test func listContainers_withRealDocker_returnsContainers() async throws {
    guard dockerTestsEnabled() else { return }

    let docker = DockerClient()

    // Create a test container with a unique label
    let testLabel = "test.cleanup.list.\(UUID().uuidString)"
    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "300"])
        .withLabel(testLabel, "true")

    let id = try await docker.runContainer(request)

    defer {
        Task {
            try? await docker.removeContainer(id: id)
        }
    }

    // List containers with our test label
    let containers = try await docker.listContainers(labels: [testLabel: "true"])

    // Should find our container
    #expect(containers.count >= 1)
    #expect(containers.contains { $0.id.hasPrefix(id.prefix(12)) || id.hasPrefix($0.id) })

    // Clean up
    try await docker.removeContainer(id: id)
}

@Test func cleanup_recentContainers_areNotRemoved() async throws {
    guard dockerTestsEnabled() else { return }

    let docker = DockerClient()

    // Create a test container with a unique label
    let testLabel = "test.cleanup.recent.\(UUID().uuidString)"
    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "300"])
        .withLabel(testLabel, "true")

    let id = try await docker.runContainer(request)

    defer {
        Task {
            try? await docker.removeContainer(id: id)
        }
    }

    // Run cleanup with a high age threshold (container is too new)
    let cleanup = TestContainersCleanup(
        config: TestContainersCleanupConfig()
            .withAgeThreshold(600)  // 10 minutes
            .withCustomLabelFilter(testLabel, "true"),
        runtime: docker
    )

    let result = try await cleanup.cleanup()

    // Should not find our container (too recent)
    #expect(result.containersFound == 0)
    #expect(result.containersRemoved == 0)

    // Verify container still exists
    let containers = try await docker.listContainers(labels: [testLabel: "true"])
    #expect(containers.count == 1)

    // Clean up manually
    try await docker.removeContainer(id: id)
}

@Test func cleanup_oldContainers_areRemoved() async throws {
    guard dockerTestsEnabled() else { return }

    let docker = DockerClient()

    // Create a test container with a unique label
    let testLabel = "test.cleanup.old.\(UUID().uuidString)"
    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "1"])
        .withLabel(testLabel, "true")

    _ = try await docker.runContainer(request)

    // Wait for container to "age" (2 seconds should be enough)
    try await Task.sleep(for: .seconds(2))

    // Run cleanup with a low age threshold
    let cleanup = TestContainersCleanup(
        config: TestContainersCleanupConfig()
            .withAgeThreshold(1)  // 1 second
            .withCustomLabelFilter(testLabel, "true"),
        runtime: docker
    )

    let result = try await cleanup.cleanup()

    // Should find and remove our container
    #expect(result.containersFound >= 1)
    #expect(result.containersRemoved >= 1)

    // Verify container was removed
    let containers = try await docker.listContainers(labels: [testLabel: "true"])
    #expect(containers.isEmpty)
}

@Test func cleanup_dryRun_doesNotRemoveContainers() async throws {
    guard dockerTestsEnabled() else { return }

    let docker = DockerClient()

    // Create a test container with a unique label
    let testLabel = "test.cleanup.dryrun.\(UUID().uuidString)"
    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "1"])
        .withLabel(testLabel, "true")

    let id = try await docker.runContainer(request)

    defer {
        Task {
            try? await docker.removeContainer(id: id)
        }
    }

    // Wait briefly
    try await Task.sleep(for: .seconds(2))

    // Run cleanup in dry-run mode
    let cleanup = TestContainersCleanup(
        config: TestContainersCleanupConfig()
            .withAgeThreshold(1)
            .withCustomLabelFilter(testLabel, "true")
            .withDryRun(true),
        runtime: docker
    )

    let result = try await cleanup.cleanup()

    // Should find but not remove
    #expect(result.containersFound >= 1)
    #expect(result.containersRemoved == 0)

    // Verify container still exists
    let containers = try await docker.listContainers(labels: [testLabel: "true"])
    #expect(containers.count == 1)

    // Clean up manually
    try await docker.removeContainer(id: id)
}

@Test func cleanup_withSessionLabels_canFilterBySession() async throws {
    guard dockerTestsEnabled() else { return }

    let docker = DockerClient()

    // Create containers with different session IDs
    let sessionId1 = UUID().uuidString
    let sessionId2 = UUID().uuidString
    let testLabel = "test.cleanup.session.\(UUID().uuidString)"

    let request1 = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "1"])
        .withLabel(testLabel, "true")
        .withLabel("testcontainers.swift.session.id", sessionId1)

    let request2 = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "1"])
        .withLabel(testLabel, "true")
        .withLabel("testcontainers.swift.session.id", sessionId2)

    let id1 = try await docker.runContainer(request1)
    let id2 = try await docker.runContainer(request2)

    defer {
        Task {
            try? await docker.removeContainer(id: id1)
            try? await docker.removeContainer(id: id2)
        }
    }

    // Wait briefly
    try await Task.sleep(for: .seconds(2))

    // Clean up only session 1
    let cleanup = TestContainersCleanup(
        config: TestContainersCleanupConfig()
            .withAgeThreshold(1)
            .withCustomLabelFilter(testLabel, "true"),
        runtime: docker
    )

    let result = try await cleanup.cleanup(sessionId: sessionId1)

    // Should remove only session 1 container
    #expect(result.containersRemoved >= 1)

    // Verify session 2 container still exists
    let containers = try await docker.listContainers(labels: [
        testLabel: "true",
        "testcontainers.swift.session.id": sessionId2
    ])
    #expect(containers.count == 1)

    // Clean up remaining
    try await docker.removeContainer(id: id2)
}

@Test func listOrphanedContainers_returnsEligibleContainers() async throws {
    guard dockerTestsEnabled() else { return }

    let docker = DockerClient()

    // Create a test container with a unique label
    let testLabel = "test.cleanup.orphaned.\(UUID().uuidString)"
    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "1"])
        .withLabel(testLabel, "true")

    let id = try await docker.runContainer(request)

    defer {
        Task {
            try? await docker.removeContainer(id: id)
        }
    }

    // Wait briefly
    try await Task.sleep(for: .seconds(2))

    // List orphaned containers
    let cleanup = TestContainersCleanup(
        config: TestContainersCleanupConfig()
            .withAgeThreshold(1)
            .withCustomLabelFilter(testLabel, "true"),
        runtime: docker
    )

    let orphaned = try await cleanup.listOrphanedContainers()

    // Should find our container
    #expect(orphaned.count >= 1)
    #expect(orphaned.contains { $0.id.hasPrefix(id.prefix(12)) || id.hasPrefix($0.id) })

    // Verify container was NOT removed (dry run)
    let containers = try await docker.listContainers(labels: [testLabel: "true"])
    #expect(containers.count == 1)

    // Clean up manually
    try await docker.removeContainer(id: id)
}

@Test func cleanup_parallelRemoval_removesMultipleContainers() async throws {
    guard dockerTestsEnabled() else { return }

    let docker = DockerClient()

    // Create multiple test containers
    let testLabel = "test.cleanup.parallel.\(UUID().uuidString)"

    let request1 = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "1"])
        .withLabel(testLabel, "true")
    let request2 = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "1"])
        .withLabel(testLabel, "true")
    let request3 = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "1"])
        .withLabel(testLabel, "true")

    _ = try await docker.runContainer(request1)
    _ = try await docker.runContainer(request2)
    _ = try await docker.runContainer(request3)

    // Wait briefly
    try await Task.sleep(for: .seconds(2))

    // Clean up all
    let cleanup = TestContainersCleanup(
        config: TestContainersCleanupConfig()
            .withAgeThreshold(1)
            .withCustomLabelFilter(testLabel, "true"),
        runtime: docker
    )

    let result = try await cleanup.cleanup()

    // Should remove all containers
    #expect(result.containersFound == 3)
    #expect(result.containersRemoved == 3)
    #expect(result.containersFailed == 0)

    // Verify all containers were removed
    let containers = try await docker.listContainers(labels: [testLabel: "true"])
    #expect(containers.isEmpty)
}

@Test func removeContainer_removesSpecificContainer() async throws {
    guard dockerTestsEnabled() else { return }

    let docker = DockerClient()

    // Create a test container
    let testLabel = "test.cleanup.remove.\(UUID().uuidString)"
    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "300"])
        .withLabel(testLabel, "true")

    let id = try await docker.runContainer(request)

    // Remove using cleanup actor
    let cleanup = TestContainersCleanup(runtime: docker)
    try await cleanup.removeContainer(id)

    // Verify container was removed
    let containers = try await docker.listContainers(labels: [testLabel: "true"])
    #expect(containers.isEmpty)
}

@Test func containerRequest_withSessionLabels_appliesCurrentSessionLabels() async throws {
    guard dockerTestsEnabled() else { return }

    let docker = DockerClient()

    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "300"])
        .withSessionLabels()

    let id = try await docker.runContainer(request)

    defer {
        Task {
            try? await docker.removeContainer(id: id)
        }
    }

    // List containers with current session ID
    let containers = try await docker.listContainers(labels: [
        "testcontainers.swift.session.id": currentTestSession.id
    ])

    // Should find our container
    #expect(containers.count >= 1)
    #expect(containers.contains { $0.id.hasPrefix(id.prefix(12)) || id.hasPrefix($0.id) })

    // Clean up
    try await docker.removeContainer(id: id)
}

@Test func cleanup_withVerbose_logsOutput() async throws {
    guard dockerTestsEnabled() else { return }

    let docker = DockerClient()

    // Create a test container
    let testLabel = "test.cleanup.verbose.\(UUID().uuidString)"
    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "1"])
        .withLabel(testLabel, "true")

    _ = try await docker.runContainer(request)

    // Wait briefly
    try await Task.sleep(for: .seconds(2))

    // Run cleanup with verbose mode
    let cleanup = TestContainersCleanup(
        config: TestContainersCleanupConfig()
            .withAgeThreshold(1)
            .withCustomLabelFilter(testLabel, "true")
            .withVerbose(true),
        runtime: docker
    )

    // Cleanup should complete (verbose output goes to stdout)
    let result = try await cleanup.cleanup()

    #expect(result.containersRemoved >= 1)
}
