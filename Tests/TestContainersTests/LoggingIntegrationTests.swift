import Foundation
import Testing
@testable import TestContainers

// MARK: - Mock script helper (local copy for this test file)

private func makeDockerMockScript(in tempDir: URL, argsFileURL: URL) throws -> URL {
    let scriptURL = tempDir.appendingPathComponent("docker-mock.sh")
    let script = """
    #!/bin/sh
    echo "fake-container-id"
    printf '%s\\n' "$@" > "\(argsFileURL.path)"
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
}

// MARK: - DockerClient accepts logger

@Test func dockerClient_acceptsLoggerParameter() {
    let mock = MockLogHandler()
    let logger = TCLogger(handler: mock)
    let _ = DockerClient(dockerPath: "docker", logger: logger)
}

@Test func dockerClient_defaultsToNullLogger() {
    let docker = DockerClient()
    // Should not crash — uses .null logger internally
    _ = docker
}

// MARK: - DockerClient mock-based logging tests

@Test func dockerClient_isAvailable_logsDebugAndResult() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let mock = MockLogHandler()
    let logger = TCLogger(handler: mock)
    let docker = DockerClient(dockerPath: scriptURL.path, logger: logger)

    let available = await docker.isAvailable()
    #expect(available == true)

    let debugEntries = mock.entries.filter { $0.level == .debug }
    #expect(debugEntries.contains(where: { $0.message.contains("Checking Docker availability") }))

    let infoEntries = mock.entries.filter { $0.level == .info }
    #expect(infoEntries.contains(where: { $0.message.contains("Docker is available") }))
}

@Test func dockerClient_runContainer_logsStartAndCompletion() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let mock = MockLogHandler()
    let logger = TCLogger(handler: mock)
    let docker = DockerClient(dockerPath: scriptURL.path, logger: logger)

    let request = ContainerRequest(image: "alpine:3")
    let id = try await docker.runContainer(request)
    #expect(!id.isEmpty)

    let infoEntries = mock.entries.filter { $0.level == .info }
    #expect(infoEntries.contains(where: { $0.message.contains("Starting container") }))

    let noticeEntries = mock.entries.filter { $0.level == .notice }
    #expect(noticeEntries.contains(where: { $0.message.contains("Container started") }))
}

@Test func dockerClient_removeContainer_logsDebug() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let mock = MockLogHandler()
    let logger = TCLogger(handler: mock)
    let docker = DockerClient(dockerPath: scriptURL.path, logger: logger)

    try await docker.removeContainer(id: "abc123")

    let debugEntries = mock.entries.filter { $0.level == .debug }
    #expect(debugEntries.contains(where: { $0.message.contains("Removing container") }))
}

// MARK: - Waiter logging

@Test func waiter_logsStartAndCompletion() async throws {
    let mock = MockLogHandler()
    let logger = TCLogger(handler: mock)

    try await Waiter.wait(
        timeout: .seconds(5),
        pollInterval: .milliseconds(10),
        description: "test condition",
        logger: logger
    ) {
        true
    }

    let debugEntries = mock.entries.filter { $0.level == .debug }
    #expect(debugEntries.contains(where: { $0.message.contains("Starting wait") }))
    #expect(debugEntries.contains(where: { $0.message.contains("Wait condition met") }))
}

@Test func waiter_logsErrorOnTimeout() async {
    let mock = MockLogHandler()
    let logger = TCLogger(handler: mock)

    do {
        try await Waiter.wait(
            timeout: .milliseconds(50),
            pollInterval: .milliseconds(10),
            description: "always fails",
            logger: logger
        ) {
            false
        }
        Issue.record("Expected timeout")
    } catch {
        let errorEntries = mock.entries.filter { $0.level == .error }
        #expect(errorEntries.contains(where: { $0.message.contains("Wait timed out") }))
    }
}

// MARK: - ProcessRunner logging

@Test func processRunner_logsTraceForCommandExecution() async throws {
    let mock = MockLogHandler()
    let logger = TCLogger(handler: mock)
    let runner = ProcessRunner(logger: logger)

    _ = try await runner.run(executable: "/bin/echo", arguments: ["hello"])

    let traceEntries = mock.entries.filter { $0.level == .trace }
    #expect(traceEntries.contains(where: { $0.message.contains("Executing command") }))
    #expect(traceEntries.contains(where: { $0.message.contains("Command completed") }))
}
