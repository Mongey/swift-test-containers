import Foundation
import Testing
@testable import TestContainers

// MARK: - Volume Mount Integration Tests

@Test func canMountNamedVolume_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let volumeName = "test-volume-\(UUID().uuidString.prefix(8))"
    let docker = DockerClient()

    // Create volume
    _ = try await docker.runDocker(["volume", "create", volumeName])

    defer {
        // Cleanup volume
        Task {
            try? await docker.runDocker(["volume", "rm", volumeName])
        }
    }

    // Write data to volume in one container
    let writeRequest = ContainerRequest(image: "alpine:3")
        .withVolume(volumeName, mountedAt: "/data")
        .withCommand(["sh", "-c", "echo 'test content from volume' > /data/test.txt && cat /data/test.txt"])

    try await withContainer(writeRequest) { container in
        let logs = try await container.logs()
        #expect(logs.contains("test content from volume"))
    }

    // Read data from volume in a new container to verify persistence
    let readRequest = ContainerRequest(image: "alpine:3")
        .withVolume(volumeName, mountedAt: "/data")
        .withCommand(["cat", "/data/test.txt"])

    try await withContainer(readRequest) { container in
        let logs = try await container.logs()
        #expect(logs.contains("test content from volume"))
    }
}

@Test func canMountReadOnlyVolume_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let volumeName = "test-readonly-\(UUID().uuidString.prefix(8))"
    let docker = DockerClient()

    // Create volume and pre-populate with data
    _ = try await docker.runDocker(["volume", "create", volumeName])

    defer {
        Task {
            try? await docker.runDocker(["volume", "rm", volumeName])
        }
    }

    // Pre-populate the volume with data
    let setupRequest = ContainerRequest(image: "alpine:3")
        .withVolume(volumeName, mountedAt: "/data")
        .withCommand(["sh", "-c", "echo 'read-only content' > /data/readonly.txt"])

    try await withContainer(setupRequest) { _ in }

    // Attempt to write to read-only volume should fail
    let readOnlyRequest = ContainerRequest(image: "alpine:3")
        .withVolume(volumeName, mountedAt: "/data", readOnly: true)
        .withCommand(["sh", "-c", "echo 'should fail' > /data/newfile.txt 2>&1 || echo 'Write failed as expected'"])

    try await withContainer(readOnlyRequest) { container in
        let logs = try await container.logs()
        // Should see either "Read-only" error or our "Write failed" message
        let writeBlocked = logs.contains("Read-only") || logs.contains("read-only") || logs.contains("Write failed")
        #expect(writeBlocked, "Expected write to read-only volume to be blocked")
    }

    // Verify we can still read from the read-only volume
    let verifyReadRequest = ContainerRequest(image: "alpine:3")
        .withVolume(volumeName, mountedAt: "/data", readOnly: true)
        .withCommand(["cat", "/data/readonly.txt"])

    try await withContainer(verifyReadRequest) { container in
        let logs = try await container.logs()
        #expect(logs.contains("read-only content"))
    }
}

@Test func canMountMultipleVolumes_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let dataVolume = "test-data-\(UUID().uuidString.prefix(8))"
    let logsVolume = "test-logs-\(UUID().uuidString.prefix(8))"
    let cacheVolume = "test-cache-\(UUID().uuidString.prefix(8))"
    let docker = DockerClient()

    // Create all volumes
    _ = try await docker.runDocker(["volume", "create", dataVolume])
    _ = try await docker.runDocker(["volume", "create", logsVolume])
    _ = try await docker.runDocker(["volume", "create", cacheVolume])

    defer {
        Task {
            try? await docker.runDocker(["volume", "rm", dataVolume])
            try? await docker.runDocker(["volume", "rm", logsVolume])
            try? await docker.runDocker(["volume", "rm", cacheVolume])
        }
    }

    // Mount all three volumes and write data to each
    let request = ContainerRequest(image: "alpine:3")
        .withVolume(dataVolume, mountedAt: "/app/data")
        .withVolume(logsVolume, mountedAt: "/app/logs")
        .withVolume(cacheVolume, mountedAt: "/app/cache")
        .withCommand(["sh", "-c", """
            echo 'data content' > /app/data/file.txt && \
            echo 'logs content' > /app/logs/file.txt && \
            echo 'cache content' > /app/cache/file.txt && \
            cat /app/data/file.txt /app/logs/file.txt /app/cache/file.txt
            """])

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("data content"))
        #expect(logs.contains("logs content"))
        #expect(logs.contains("cache content"))
    }
}

@Test func volumeDataPersistsAcrossContainerRestarts_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let volumeName = "test-persist-\(UUID().uuidString.prefix(8))"
    let docker = DockerClient()

    _ = try await docker.runDocker(["volume", "create", volumeName])

    defer {
        Task {
            try? await docker.runDocker(["volume", "rm", volumeName])
        }
    }

    // First container writes a unique value
    let uniqueValue = UUID().uuidString
    let writeRequest = ContainerRequest(image: "alpine:3")
        .withVolume(volumeName, mountedAt: "/persistent")
        .withCommand(["sh", "-c", "echo '\(uniqueValue)' > /persistent/unique.txt"])

    try await withContainer(writeRequest) { _ in }

    // Second container (completely new) reads the value
    let readRequest = ContainerRequest(image: "alpine:3")
        .withVolume(volumeName, mountedAt: "/persistent")
        .withCommand(["cat", "/persistent/unique.txt"])

    try await withContainer(readRequest) { container in
        let logs = try await container.logs()
        #expect(logs.contains(uniqueValue))
    }
}
