import Foundation
import Testing
@testable import TestContainers

// MARK: - ContainerState Tests

@Test func containerState_initiallyCreated_forCreatePath() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    let state = await container.currentState
    #expect(state == .created)
    let running = await container.isRunning
    #expect(running == false)
}

@Test func containerState_initiallyRunning_forRunPath() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker)

    let state = await container.currentState
    #expect(state == .running)
    let running = await container.isRunning
    #expect(running == true)
}

// MARK: - start() Tests

@Test func containerStart_fromCreated_transitionsToRunning() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.start()

    let state = await container.currentState
    #expect(state == .running)
    let running = await container.isRunning
    #expect(running == true)
}

@Test func containerStart_fromStopped_transitionsToRunning() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.start()
    try await container.stop()
    try await container.start()

    let state = await container.currentState
    #expect(state == .running)
}

@Test func containerStart_fromRunning_isIdempotent() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.start()
    try await container.start() // Should not throw

    let state = await container.currentState
    #expect(state == .running)
}

@Test func containerStart_fromTerminated_throws() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.start()
    try await container.terminate()

    await #expect(throws: TestContainersError.self) {
        try await container.start()
    }
}

// MARK: - stop() Tests

@Test func containerStop_fromRunning_transitionsToStopped() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.start()
    try await container.stop()

    let state = await container.currentState
    #expect(state == .stopped)
    let running = await container.isRunning
    #expect(running == false)
}

@Test func containerStop_fromStopped_isIdempotent() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.start()
    try await container.stop()
    try await container.stop() // Should not throw

    let state = await container.currentState
    #expect(state == .stopped)
}

@Test func containerStop_fromCreated_transitionsToStopped() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.stop()

    let state = await container.currentState
    #expect(state == .stopped)
}

@Test func containerStop_fromTerminated_throws() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.start()
    try await container.terminate()

    await #expect(throws: TestContainersError.self) {
        try await container.stop()
    }
}

// MARK: - restart() Tests

@Test func containerRestart_fromRunning_transitionsToRunning() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.start()
    try await container.restart()

    let state = await container.currentState
    #expect(state == .running)
}

@Test func containerRestart_fromTerminated_throws() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.start()
    try await container.terminate()

    await #expect(throws: TestContainersError.self) {
        try await container.restart()
    }
}

// MARK: - terminate() Tests

@Test func containerTerminate_fromRunning_transitionsToTerminated() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.start()
    try await container.terminate()

    let state = await container.currentState
    #expect(state == .terminated)
}

@Test func containerTerminate_fromCreated_transitionsToTerminated() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.terminate()

    let state = await container.currentState
    #expect(state == .terminated)
}

@Test func containerTerminate_fromStopped_transitionsToTerminated() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.start()
    try await container.stop()
    try await container.terminate()

    let state = await container.currentState
    #expect(state == .terminated)
}

@Test func containerTerminate_fromTerminated_isIdempotent() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .created)

    try await container.start()
    try await container.terminate()
    try await container.terminate() // Should not throw

    let state = await container.currentState
    #expect(state == .terminated)
}

// MARK: - waitUntilReady() is public

@Test func containerWaitUntilReady_isCallablePublicly() async throws {
    let (docker, _) = try makeMockDocker()
    let request = ContainerRequest(image: "alpine:3")
    let container = Container(id: "fake-id", request: request, runtime: docker, state: .running)

    // Should compile and not throw with .none wait strategy
    try await container.waitUntilReady()
}

// MARK: - Helpers

private func makeMockDocker() throws -> (DockerClient, URL) {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = tempDir.appendingPathComponent("docker-mock.sh")
    let script = """
    #!/bin/sh
    printf '%s\\n' "$@" >> "\(argsFileURL.path)"
    printf '---\\n' >> "\(argsFileURL.path)"
    echo "fake-container-id"
    """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let docker = DockerClient(dockerPath: scriptURL.path)
    return (docker, tempDir)
}
