import Foundation
import Testing
@testable import TestContainers

// MARK: - Error Case Tests

@Test func networkNotFound_errorDescription_includesNetworkAndContainerId() {
    let error = TestContainersError.networkNotFound("my-network", id: "abc123def456")
    #expect(error.description.contains("my-network"))
    #expect(error.description.contains("abc123def456"))
}

// MARK: - internalHostname Unit Tests

@Test func internalHostname_returnsName_whenNameIsSet() async throws {
    let request = ContainerRequest(image: "alpine:3")
        .withFixedName("my-db")
    let container = Container(
        id: "abcdef1234567890abcdef1234567890",
        request: request,
        runtime: DockerClient()
    )

    let hostname = await container.internalHostname()
    #expect(hostname == "my-db")
}

@Test func internalHostname_returnsShortId_whenNoNameSet() async throws {
    let request = ContainerRequest(image: "alpine:3")
    // Force autoGenerateName off and name nil so there's no resolved name
    var noNameRequest = request
    noNameRequest.name = nil
    noNameRequest.autoGenerateName = false

    let container = Container(
        id: "abcdef1234567890abcdef1234567890",
        request: noNameRequest,
        runtime: DockerClient()
    )

    let hostname = await container.internalHostname()
    #expect(hostname == "abcdef123456")
    #expect(hostname.count == 12)
}

@Test func internalHostname_returnsShortId_forShortContainerId() async throws {
    var request = ContainerRequest(image: "alpine:3")
    request.name = nil
    request.autoGenerateName = false

    let container = Container(
        id: "abc123",
        request: request,
        runtime: DockerClient()
    )

    let hostname = await container.internalHostname()
    #expect(hostname == "abc123")
}

// MARK: - Integration Tests (require Docker)

@Test func internalIP_returnsValidIP_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let ip = try await container.internalIP()

        // Should be a valid IP address (contains dots)
        #expect(ip.contains("."))
        #expect(!ip.isEmpty)

        // IP should be in a private range (Docker typically uses 172.x.x.x)
        let parts = ip.split(separator: ".")
        #expect(parts.count == 4)
    }
}

@Test func internalIP_forNetwork_returnsIPForSpecificNetwork() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withNetwork(NetworkRequest()) { network in
        let networkName = await network.name

        let request = ContainerRequest(image: "alpine:3")
            .withNetwork(networkName)
            .withCommand(["sleep", "30"])

        try await withContainer(request) { container in
            let ip = try await container.internalIP(forNetwork: networkName)
            #expect(ip.contains("."))
            #expect(!ip.isEmpty)
        }
    }
}

@Test func internalIP_forNetwork_throwsForNonexistentNetwork() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        await #expect(throws: TestContainersError.self) {
            _ = try await container.internalIP(forNetwork: "nonexistent-network-xyz")
        }
    }
}

@Test func internalEndpoint_returnsIPColonPort() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let endpoint = try await container.internalEndpoint(for: 5432)

        // Should be in format "ip:port"
        #expect(endpoint.hasSuffix(":5432"))
        let parts = endpoint.split(separator: ":")
        #expect(parts.count == 2)
        #expect(parts[1] == "5432")
    }
}

@Test func internalHostnameEndpoint_returnsHostnameColonPort() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withFixedName("test-hostname-ep-\(UUID().uuidString.prefix(8))")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let endpoint = try await container.internalHostnameEndpoint(for: 6379)
        #expect(endpoint.hasSuffix(":6379"))
        #expect(endpoint.hasPrefix("test-hostname-ep-"))
    }
}

@Test func twoContainers_haveDifferentInternalIPs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request1 = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])

    let request2 = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])

    try await withContainer(request1) { container1 in
        try await withContainer(request2) { container2 in
            let ip1 = try await container1.internalIP()
            let ip2 = try await container2.internalIP()

            #expect(ip1 != ip2, "Two containers should have different internal IPs")
        }
    }
}
