import Foundation
import Testing
@testable import TestContainers

// MARK: - ContainerRequest Reuse

@Test func containerRequest_reuse_defaultsToFalse() {
    let request = ContainerRequest(image: "alpine:3")

    #expect(request.reuse == false)
}

@Test func containerRequest_withReuse_enablesReuse() {
    let request = ContainerRequest(image: "alpine:3")
        .withReuse()

    #expect(request.reuse == true)
}

@Test func containerRequest_withReuse_canDisableReuse() {
    let request = ContainerRequest(image: "alpine:3")
        .withReuse(true)
        .withReuse(false)

    #expect(request.reuse == false)
}

// MARK: - ReuseConfig

@Test func reuseConfig_fromEnvironment_defaultsToDisabled() {
    let config = ReuseConfig.fromEnvironment(environment: [:], propertiesFilePath: "/path/does/not/exist")

    #expect(config.enabled == false)
}

@Test func reuseConfig_fromEnvironment_envTrue_enablesReuse() {
    let config = ReuseConfig.fromEnvironment(
        environment: ["TESTCONTAINERS_REUSE_ENABLE": "true"],
        propertiesFilePath: "/path/does/not/exist"
    )

    #expect(config.enabled == true)
}

@Test func reuseConfig_fromEnvironment_envOne_enablesReuse() {
    let config = ReuseConfig.fromEnvironment(
        environment: ["TESTCONTAINERS_REUSE_ENABLE": "1"],
        propertiesFilePath: "/path/does/not/exist"
    )

    #expect(config.enabled == true)
}

@Test func reuseConfig_fromEnvironment_invalidEnvFallsBackToProperties() throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let propertiesFile = tempDir.appendingPathComponent(".testcontainers.properties")
    try "testcontainers.reuse.enable=true\n".write(to: propertiesFile, atomically: true, encoding: .utf8)

    let config = ReuseConfig.fromEnvironment(
        environment: ["TESTCONTAINERS_REUSE_ENABLE": "maybe"],
        propertiesFilePath: propertiesFile.path
    )

    #expect(config.enabled == true)
}

@Test func reuseConfig_fromEnvironment_propertiesEnabled_enablesReuse() throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let propertiesFile = tempDir.appendingPathComponent(".testcontainers.properties")
    try "testcontainers.reuse.enable=1\n".write(to: propertiesFile, atomically: true, encoding: .utf8)

    let config = ReuseConfig.fromEnvironment(environment: [:], propertiesFilePath: propertiesFile.path)

    #expect(config.enabled == true)
}

// MARK: - Fingerprinting

@Test func reuseFingerprint_isDeterministic_forEquivalentRequests() {
    let request1 = ContainerRequest(image: "redis:7")
        .withCommand(["redis-server", "--save", ""])
        .withEnvironment(["B": "2", "A": "1"])
        .withLabels(["z": "9", "a": "1"])
        .withExposedPort(6379)
        .withExposedPort(6380, hostPort: 16380)
        .withVolume("data", mountedAt: "/data")
        .withBindMount(hostPath: "/tmp", containerPath: "/tmp-host", readOnly: true)
        .withTmpfs("/cache", sizeLimit: "64m", mode: "1777")
        .withWorkingDirectory("/work")
        .withCapabilityAdd(.netAdmin)
        .withCapabilityDrop(.sysTime)
        .waitingFor(.logContains("Ready to accept connections"))

    let request2 = ContainerRequest(image: "redis:7")
        .withCommand(["redis-server", "--save", ""])
        .withEnvironment(["A": "1", "B": "2"])
        .withLabels(["a": "1", "z": "9"])
        .withExposedPort(6379)
        .withExposedPort(6380, hostPort: 16380)
        .withVolume("data", mountedAt: "/data")
        .withBindMount(hostPath: "/tmp", containerPath: "/tmp-host", readOnly: true)
        .withTmpfs("/cache", sizeLimit: "64m", mode: "1777")
        .withWorkingDirectory("/work")
        .withCapabilityAdd(.netAdmin)
        .withCapabilityDrop(.sysTime)
        .waitingFor(.logContains("Ready to accept connections"))

    let hash1 = ReuseFingerprint.hash(for: request1)
    let hash2 = ReuseFingerprint.hash(for: request2)

    #expect(hash1 == hash2)
}

@Test func reuseFingerprint_changes_whenRelevantConfigChanges() {
    let base = ContainerRequest(image: "redis:7")
        .withCommand(["redis-server"])
        .withEnvironment(["MODE": "A"])

    let changed = base.withEnvironment(["MODE": "B"])

    #expect(ReuseFingerprint.hash(for: base) != ReuseFingerprint.hash(for: changed))
}

@Test func reuseFingerprint_ignoresVolatileLabels() {
    let request1 = ContainerRequest(image: "alpine:3")
        .withLabel("testcontainers.swift.session.id", "session-a")
        .withLabel("testcontainers.swift.session.pid", "100")
        .withLabel("testcontainers.swift.reuse.hash", "hash-a")
        .withLabel("testcontainers.swift.reuse.version", "1")
        .withLabel("custom", "stable")

    let request2 = ContainerRequest(image: "alpine:3")
        .withLabel("testcontainers.swift.session.id", "session-b")
        .withLabel("testcontainers.swift.session.pid", "200")
        .withLabel("testcontainers.swift.reuse.hash", "hash-b")
        .withLabel("testcontainers.swift.reuse.version", "1")
        .withLabel("custom", "stable")

    #expect(ReuseFingerprint.hash(for: request1) == ReuseFingerprint.hash(for: request2))
}

// MARK: - Reuse Container Selection

@Test func selectReusableContainer_choosesNewestRunningContainer() {
    let older = ContainerListItem(
        id: "old-running",
        names: "/old-running",
        image: "redis:7",
        created: 1702000000,
        labels: "testcontainers.swift.reuse=true",
        state: "running"
    )

    let newer = ContainerListItem(
        id: "new-running",
        names: "/new-running",
        image: "redis:7",
        created: 1702000100,
        labels: "testcontainers.swift.reuse=true",
        state: "running"
    )

    let exited = ContainerListItem(
        id: "exited",
        names: "/exited",
        image: "redis:7",
        created: 1702000200,
        labels: "testcontainers.swift.reuse=true",
        state: "exited"
    )

    let selected = DockerClient.selectReusableContainer(from: [older, exited, newer])

    #expect(selected?.id == "new-running")
}

// MARK: - Integration

@Test func reuse_disabled_createsFreshContainerEachRun() async throws {
    guard dockerIntegrationEnabled else { return }

    let marker = "reuse-disabled-fresh"
    try await cleanupReusableContainers(marker: marker)

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "sleep 300"])
        .withLabel("testcontainers.swift.reuse.test", marker)
        .withReuse()

    let first = try await withContainer(request, reuseConfig: .disabled) { container in
        container.id
    }

    let second = try await withContainer(request, reuseConfig: .disabled) { container in
        container.id
    }

    #expect(first != second)

    try await cleanupReusableContainers(marker: marker)
}

@Test func reuse_enabled_reusesContainerIdForSameRequest() async throws {
    guard dockerIntegrationEnabled else { return }

    let marker = "reuse-enabled-same"
    try await cleanupReusableContainers(marker: marker)

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "sleep 300"])
        .withLabel("testcontainers.swift.reuse.test", marker)
        .withReuse()

    do {
        let first = try await withContainer(request, reuseConfig: .enabled) { container in
            container.id
        }

        let second = try await withContainer(request, reuseConfig: .enabled) { container in
            container.id
        }

        #expect(first == second)

        let docker = DockerClient()
        let hash = ReuseFingerprint.hash(for: request)
        let reusable = try await docker.findReusableContainer(hash: hash)
        #expect(reusable?.id == first)
    } catch {
        try await cleanupReusableContainers(marker: marker)
        throw error
    }

    try await cleanupReusableContainers(marker: marker)
}

@Test func reuse_ignoresStoppedContainers() async throws {
    guard dockerIntegrationEnabled else { return }

    let marker = "reuse-ignores-stopped"
    try await cleanupReusableContainers(marker: marker)

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "sleep 1"])
        .withLabel("testcontainers.swift.reuse.test", marker)
        .withReuse()

    do {
        let first = try await withContainer(request, reuseConfig: .enabled) { container in
            container.id
        }

        try await Task.sleep(for: .seconds(2))

        let second = try await withContainer(request, reuseConfig: .enabled) { container in
            container.id
        }

        #expect(first != second)
    } catch {
        try await cleanupReusableContainers(marker: marker)
        throw error
    }

    try await cleanupReusableContainers(marker: marker)
}

private let dockerIntegrationEnabled = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"

private func cleanupReusableContainers(marker: String) async throws {
    let docker = DockerClient()
    guard await docker.isAvailable() else { return }

    let containers = try await docker.listContainers(labels: ["testcontainers.swift.reuse.test": marker])
    for container in containers {
        try? await docker.removeContainer(id: container.id)
    }
}
