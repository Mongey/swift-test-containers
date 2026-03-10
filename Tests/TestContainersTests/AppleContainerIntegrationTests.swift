import Foundation
import Testing
@testable import TestContainers

// MARK: - Apple Container Integration Tests
// Gated by TESTCONTAINERS_RUN_APPLE_CONTAINER_TESTS=1

private func appleContainerOptedIn() -> Bool {
    ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_APPLE_CONTAINER_TESTS"] == "1"
}

@Test func appleContainer_isAvailable() async throws {
    guard appleContainerOptedIn() else { return }
    let runtime = AppleContainerClient()
    let available = await runtime.isAvailable()
    #expect(available)
}

@Test func appleContainer_canPullImage() async throws {
    guard appleContainerOptedIn() else { return }
    let runtime = AppleContainerClient()
    try await runtime.pullImage("alpine:3.20")
}

@Test func appleContainer_canRunAndRemoveContainer() async throws {
    guard appleContainerOptedIn() else { return }
    let runtime = AppleContainerClient()

    let request = ContainerRequest(image: "alpine:3.20")
        .withCommand(["sleep", "30"])
    let id = try await runtime.runContainer(request)
    #expect(!id.isEmpty)

    // Clean up
    try await runtime.stopContainer(id: id, timeout: .seconds(2))
    try await runtime.removeContainer(id: id)
}

@Test func appleContainer_canExecInContainer() async throws {
    guard appleContainerOptedIn() else { return }
    let runtime = AppleContainerClient()

    let request = ContainerRequest(image: "alpine:3.20")
        .withCommand(["sleep", "30"])
    let id = try await runtime.runContainer(request)

    defer { Task { try? await runtime.stopContainer(id: id, timeout: .seconds(2)); try? await runtime.removeContainer(id: id) } }

    let exitCode = try await runtime.exec(id: id, command: ["echo", "hello"])
    #expect(exitCode == 0)
}

@Test func appleContainer_canGetLogs() async throws {
    guard appleContainerOptedIn() else { return }
    let runtime = AppleContainerClient()

    let request = ContainerRequest(image: "alpine:3.20")
        .withCommand(["sh", "-c", "echo hello-from-apple && sleep 30"])
    let id = try await runtime.runContainer(request)

    defer { Task { try? await runtime.stopContainer(id: id, timeout: .seconds(2)); try? await runtime.removeContainer(id: id) } }

    // Wait a moment for the echo to execute
    try await Task.sleep(for: .seconds(2))

    let logs = try await runtime.logs(id: id)
    #expect(logs.contains("hello-from-apple"))
}

@Test func appleContainer_canInspectContainer() async throws {
    guard appleContainerOptedIn() else { return }
    let runtime = AppleContainerClient()

    let request = ContainerRequest(image: "alpine:3.20")
        .withCommand(["sleep", "30"])
        .withLabel("test-key", "test-value")
        .withEnvironment(["MY_VAR": "my_value"])
    let id = try await runtime.runContainer(request)

    defer { Task { try? await runtime.stopContainer(id: id, timeout: .seconds(2)); try? await runtime.removeContainer(id: id) } }

    let inspection = try await runtime.inspect(id: id)
    #expect(inspection.id == id)
    #expect(inspection.state.status == .running)
    #expect(inspection.state.running == true)
    #expect(inspection.config.labels["test-key"] == "test-value")
    #expect(inspection.config.env.contains("MY_VAR=my_value"))
}

@Test func appleContainer_canResolvePort() async throws {
    guard appleContainerOptedIn() else { return }
    let runtime = AppleContainerClient()

    let request = ContainerRequest(image: "alpine:3.20")
        .withCommand(["sleep", "30"])
        .withExposedPort(80, hostPort: 18234)
    let id = try await runtime.runContainer(request)

    defer { Task { try? await runtime.stopContainer(id: id, timeout: .seconds(2)); try? await runtime.removeContainer(id: id) } }

    let hostPort = try await runtime.port(id: id, containerPort: 80)
    #expect(hostPort == 18234)
}

@Test func appleContainer_canListContainersWithLabels() async throws {
    guard appleContainerOptedIn() else { return }
    let runtime = AppleContainerClient()

    let uniqueLabel = "apple-test-\(UUID().uuidString.prefix(8))"
    let request = ContainerRequest(image: "alpine:3.20")
        .withCommand(["sleep", "30"])
        .withLabel("test-run", uniqueLabel)
    let id = try await runtime.runContainer(request)

    defer { Task { try? await runtime.stopContainer(id: id, timeout: .seconds(2)); try? await runtime.removeContainer(id: id) } }

    let containers = try await runtime.listContainers(labels: ["test-run": uniqueLabel])
    #expect(containers.count == 1)
    #expect(containers.first?.id == id || containers.first?.id.hasPrefix(id.prefix(12)) == true)
}

@Test func appleContainer_canRunNginxAndServeHTTP() async throws {
    guard appleContainerOptedIn() else { return }
    let runtime = AppleContainerClient()

    let request = ContainerRequest(image: "nginx:alpine")
        .withExposedPort(80, hostPort: 18235)
        .waitingFor(.http(HTTPWaitConfig(port: 80)))

    try await withContainer(request, runtime: runtime) { container in
        let port = try await container.hostPort(80)
        #expect(port == 18235)

        let url = URL(string: "http://localhost:\(port)/")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 200)

        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("nginx") || body.contains("Welcome"))
    }
}

@Test func appleContainer_withContainerLifecycle() async throws {
    guard appleContainerOptedIn() else { return }
    let runtime = AppleContainerClient()

    let request = ContainerRequest(image: "alpine:3.20")
        .withCommand(["sh", "-c", "echo ready && sleep 30"])
        .waitingFor(.logContains("ready", timeout: .seconds(10)))

    try await withContainer(request, runtime: runtime) { container in
        let logs = try await container.logs()
        #expect(logs.contains("ready"))
    }
}
