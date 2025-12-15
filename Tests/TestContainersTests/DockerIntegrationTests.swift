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
