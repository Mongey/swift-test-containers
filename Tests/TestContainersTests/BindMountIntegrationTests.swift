import Foundation
import Testing
@testable import TestContainers

// MARK: - Bind Mount Integration Tests

@Test func bindMount_canReadHostFile() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create temporary directory with test file
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-bind-mount-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    let testFile = tempDir.appendingPathComponent("test.txt")
    let testContent = "Hello from host filesystem!"
    try testContent.write(to: testFile, atomically: true, encoding: .utf8)

    // Mount directory and read file from container
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(
            hostPath: tempDir.path,
            containerPath: "/mnt/host",
            readOnly: true
        )
        .withCommand(["cat", "/mnt/host/test.txt"])

    try await withContainer(request) { container in
        // Give container time to execute cat command
        try await Task.sleep(for: .milliseconds(500))

        let logs = try await container.logs()
        #expect(logs.contains(testContent))
    }
}

@Test func bindMount_canWriteToHostDirectory() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create temporary directory
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-write-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // Mount directory read-write and create file from container
    let outputFile = "output.txt"
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(
            hostPath: tempDir.path,
            containerPath: "/mnt/output",
            readOnly: false
        )
        .withCommand(["sh", "-c", "echo 'Container was here' > /mnt/output/\(outputFile)"])

    try await withContainer(request) { _ in
        try await Task.sleep(for: .milliseconds(500))
    }

    // Verify file was created on host
    let outputPath = tempDir.appendingPathComponent(outputFile)
    #expect(FileManager.default.fileExists(atPath: outputPath.path))

    let content = try String(contentsOf: outputPath, encoding: .utf8)
    #expect(content.contains("Container was here"))
}

@Test func bindMount_readOnlyPreventsWrites() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-readonly-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // Attempt to write to read-only mount (should fail)
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(
            hostPath: tempDir.path,
            containerPath: "/mnt/readonly",
            readOnly: true
        )
        .withCommand(["sh", "-c", "echo 'test' > /mnt/readonly/test.txt || echo 'Write failed as expected'"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .milliseconds(500))

        let logs = try await container.logs()
        #expect(logs.contains("Write failed as expected") || logs.contains("Read-only"))
    }

    // Verify no file was created
    let testPath = tempDir.appendingPathComponent("test.txt")
    #expect(!FileManager.default.fileExists(atPath: testPath.path))
}

@Test func bindMount_multipleBindMounts() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create two temporary directories
    let tempDir1 = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-multi-1-\(UUID().uuidString)")
    let tempDir2 = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-multi-2-\(UUID().uuidString)")

    try FileManager.default.createDirectory(at: tempDir1, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tempDir2, withIntermediateDirectories: true)

    defer {
        try? FileManager.default.removeItem(at: tempDir1)
        try? FileManager.default.removeItem(at: tempDir2)
    }

    // Create files in both directories
    try "Content from dir1".write(to: tempDir1.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
    try "Content from dir2".write(to: tempDir2.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

    // Mount both directories
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(hostPath: tempDir1.path, containerPath: "/mnt/dir1", readOnly: true)
        .withBindMount(hostPath: tempDir2.path, containerPath: "/mnt/dir2", readOnly: true)
        .withCommand(["sh", "-c", "cat /mnt/dir1/file1.txt && echo '---' && cat /mnt/dir2/file2.txt"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .milliseconds(500))

        let logs = try await container.logs()
        #expect(logs.contains("Content from dir1"))
        #expect(logs.contains("Content from dir2"))
    }
}

@Test func bindMount_singleFileMounting() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create a single file
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-file-mount-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    let testFile = tempDir.appendingPathComponent("config.txt")
    let configContent = "config_key=config_value"
    try configContent.write(to: testFile, atomically: true, encoding: .utf8)

    // Mount single file (not directory)
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(
            hostPath: testFile.path,
            containerPath: "/etc/myconfig.txt",
            readOnly: true
        )
        .withCommand(["cat", "/etc/myconfig.txt"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .milliseconds(500))

        let logs = try await container.logs()
        #expect(logs.contains(configContent))
    }
}

@Test func bindMount_withCachedConsistency() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-cached-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    let testFile = tempDir.appendingPathComponent("test.txt")
    try "Cached content".write(to: testFile, atomically: true, encoding: .utf8)

    // Mount with cached consistency (optimized for read-heavy workloads)
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(
            hostPath: tempDir.path,
            containerPath: "/mnt/cached",
            readOnly: true,
            consistency: .cached
        )
        .withCommand(["cat", "/mnt/cached/test.txt"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .milliseconds(500))

        let logs = try await container.logs()
        #expect(logs.contains("Cached content"))
    }
}

@Test func bindMount_withDelegatedConsistency() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-delegated-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // Mount with delegated consistency (optimized for write-heavy workloads)
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(
            hostPath: tempDir.path,
            containerPath: "/mnt/delegated",
            readOnly: false,
            consistency: .delegated
        )
        .withCommand(["sh", "-c", "echo 'Delegated write test' > /mnt/delegated/output.txt"])

    try await withContainer(request) { _ in
        try await Task.sleep(for: .milliseconds(500))
    }

    let outputPath = tempDir.appendingPathComponent("output.txt")
    #expect(FileManager.default.fileExists(atPath: outputPath.path))

    let content = try String(contentsOf: outputPath, encoding: .utf8)
    #expect(content.contains("Delegated write test"))
}
