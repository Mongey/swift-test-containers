import Foundation
import Testing
@testable import TestContainers

// MARK: - NATSContainer Unit Tests

@Test func natsContainer_defaultValues() {
    let nats = NATSContainer()

    #expect(nats.image == "nats:2.12-alpine")
    #expect(nats.jetStreamEnabled == true)
    #expect(nats.jetStreamStorageDir == nil)
    #expect(nats.username == nil)
    #expect(nats.password == nil)
    #expect(nats.token == nil)
    #expect(nats.clusterName == nil)
    #expect(nats.nodeName == nil)
    #expect(nats.routes.isEmpty)
    #expect(nats.customArgs.isEmpty)
    #expect(nats.host == "127.0.0.1")
    #expect(nats.waitStrategy == nil)
}

@Test func natsContainer_customImage() {
    let nats = NATSContainer(image: "nats:2.10-alpine")

    #expect(nats.image == "nats:2.10-alpine")
}

@Test func natsContainer_withJetStreamDisabled() {
    let nats = NATSContainer()
        .withJetStream(false)

    #expect(nats.jetStreamEnabled == false)
}

@Test func natsContainer_withJetStreamStorageDir() {
    let nats = NATSContainer()
        .withJetStreamStorageDir("/data/jetstream")

    #expect(nats.jetStreamStorageDir == "/data/jetstream")
}

@Test func natsContainer_withUsername() {
    let nats = NATSContainer()
        .withUsername("testuser")

    #expect(nats.username == "testuser")
}

@Test func natsContainer_withPassword() {
    let nats = NATSContainer()
        .withPassword("testpass")

    #expect(nats.password == "testpass")
}

@Test func natsContainer_withCredentials() {
    let nats = NATSContainer()
        .withCredentials(username: "admin", password: "secret")

    #expect(nats.username == "admin")
    #expect(nats.password == "secret")
}

@Test func natsContainer_withToken() {
    let nats = NATSContainer()
        .withToken("my-secret-token")

    #expect(nats.token == "my-secret-token")
}

@Test func natsContainer_withCluster() {
    let nats = NATSContainer()
        .withCluster(name: "my-cluster", nodeName: "node-1")

    #expect(nats.clusterName == "my-cluster")
    #expect(nats.nodeName == "node-1")
}

@Test func natsContainer_withClusterNameOnly() {
    let nats = NATSContainer()
        .withCluster(name: "my-cluster")

    #expect(nats.clusterName == "my-cluster")
    #expect(nats.nodeName == nil)
}

@Test func natsContainer_withRoute() {
    let nats = NATSContainer()
        .withRoute("nats://node1:6222")

    #expect(nats.routes == ["nats://node1:6222"])
}

@Test func natsContainer_withMultipleRoutes() {
    let nats = NATSContainer()
        .withRoute("nats://node1:6222")
        .withRoute("nats://node2:6222")

    #expect(nats.routes.count == 2)
    #expect(nats.routes[0] == "nats://node1:6222")
    #expect(nats.routes[1] == "nats://node2:6222")
}

@Test func natsContainer_withRoutes() {
    let nats = NATSContainer()
        .withRoutes(["nats://node1:6222", "nats://node2:6222"])

    #expect(nats.routes.count == 2)
}

@Test func natsContainer_withArgument() {
    let nats = NATSContainer()
        .withArgument("-DV")

    #expect(nats.customArgs == ["-DV"])
}

@Test func natsContainer_withArguments() {
    let nats = NATSContainer()
        .withArgument("-DV")
        .withArguments(["--max_payload", "1048576"])

    #expect(nats.customArgs.count == 3)
    #expect(nats.customArgs[0] == "-DV")
    #expect(nats.customArgs[1] == "--max_payload")
    #expect(nats.customArgs[2] == "1048576")
}

@Test func natsContainer_withHost() {
    let nats = NATSContainer()
        .withHost("localhost")

    #expect(nats.host == "localhost")
}

@Test func natsContainer_customWaitStrategy() {
    let nats = NATSContainer()
        .waitingFor(.logContains("Server is ready", timeout: .seconds(30)))

    if case let .logContains(text, timeout, _) = nats.waitStrategy {
        #expect(text == "Server is ready")
        #expect(timeout == .seconds(30))
    } else {
        Issue.record("Expected .logContains wait strategy")
    }
}

@Test func natsContainer_builderChaining() {
    let nats = NATSContainer(image: "nats:latest")
        .withJetStream(true)
        .withCredentials(username: "admin", password: "admin123")
        .withCluster(name: "test-cluster", nodeName: "node1")
        .withHost("localhost")

    #expect(nats.image == "nats:latest")
    #expect(nats.jetStreamEnabled == true)
    #expect(nats.username == "admin")
    #expect(nats.password == "admin123")
    #expect(nats.clusterName == "test-cluster")
    #expect(nats.nodeName == "node1")
    #expect(nats.host == "localhost")
}

@Test func natsContainer_builderReturnsNewInstance() {
    let original = NATSContainer()
    let modified = original.withUsername("admin")

    #expect(original.username == nil)
    #expect(modified.username == "admin")
}

@Test func natsContainer_isHashable() {
    let nats1 = NATSContainer()
        .withCredentials(username: "user", password: "pass")
    let nats2 = NATSContainer()
        .withCredentials(username: "user", password: "pass")
    let nats3 = NATSContainer()
        .withCredentials(username: "other", password: "pass")

    #expect(nats1 == nats2)
    #expect(nats1 != nats3)
}

// MARK: - toContainerRequest Tests

@Test func natsContainer_toContainerRequest_setsImage() {
    let nats = NATSContainer(image: "nats:2.10-alpine")

    let request = nats.toContainerRequest()

    #expect(request.image == "nats:2.10-alpine")
}

@Test func natsContainer_toContainerRequest_setsClientPort() {
    let nats = NATSContainer()

    let request = nats.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 4222 })
}

@Test func natsContainer_toContainerRequest_setsMonitoringPort() {
    let nats = NATSContainer()

    let request = nats.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 8222 })
}

@Test func natsContainer_toContainerRequest_setsRoutingPort() {
    let nats = NATSContainer()

    let request = nats.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 6222 })
}

@Test func natsContainer_toContainerRequest_setsHost() {
    let nats = NATSContainer()
        .withHost("localhost")

    let request = nats.toContainerRequest()

    #expect(request.host == "localhost")
}

@Test func natsContainer_toContainerRequest_defaultWaitStrategy() {
    let nats = NATSContainer()

    let request = nats.toContainerRequest()

    if case let .tcpPort(port, timeout, _) = request.waitStrategy {
        #expect(port == 4222)
        #expect(timeout == .seconds(60))
    } else {
        Issue.record("Expected .tcpPort wait strategy, got \(request.waitStrategy)")
    }
}

@Test func natsContainer_toContainerRequest_customWaitStrategy() {
    let nats = NATSContainer()
        .waitingFor(.logContains("Server is ready", timeout: .seconds(90)))

    let request = nats.toContainerRequest()

    if case let .logContains(text, timeout, _) = request.waitStrategy {
        #expect(text == "Server is ready")
        #expect(timeout == .seconds(90))
    } else {
        Issue.record("Expected .logContains wait strategy")
    }
}

@Test func natsContainer_toContainerRequest_jetStreamEnabled() {
    let nats = NATSContainer()
        .withJetStream(true)

    let request = nats.toContainerRequest()

    #expect(request.command.contains("-js") == true)
}

@Test func natsContainer_toContainerRequest_jetStreamDisabled() {
    let nats = NATSContainer()
        .withJetStream(false)

    let request = nats.toContainerRequest()

    #expect(request.command.contains("-js") != true)
}

@Test func natsContainer_toContainerRequest_jetStreamStorageDir() {
    let nats = NATSContainer()
        .withJetStreamStorageDir("/data/js")

    let request = nats.toContainerRequest()

    #expect(request.command.contains("--store_dir") == true)
    #expect(request.command.contains("/data/js") == true)
}

@Test func natsContainer_toContainerRequest_usernamePassword() {
    let nats = NATSContainer()
        .withCredentials(username: "admin", password: "secret")

    let request = nats.toContainerRequest()

    #expect(request.command.contains("--user") == true)
    #expect(request.command.contains("admin") == true)
    #expect(request.command.contains("--pass") == true)
    #expect(request.command.contains("secret") == true)
}

@Test func natsContainer_toContainerRequest_token() {
    let nats = NATSContainer()
        .withToken("my-token")

    let request = nats.toContainerRequest()

    #expect(request.command.contains("--auth") == true)
    #expect(request.command.contains("my-token") == true)
}

@Test func natsContainer_toContainerRequest_clusterConfig() {
    let nats = NATSContainer()
        .withCluster(name: "my-cluster", nodeName: "node1")
        .withRoute("nats://node2:6222")

    let request = nats.toContainerRequest()

    #expect(request.command.contains("--cluster_name") == true)
    #expect(request.command.contains("my-cluster") == true)
    #expect(request.command.contains("--name") == true)
    #expect(request.command.contains("node1") == true)
    #expect(request.command.contains("--routes") == true)
    #expect(request.command.contains("nats://node2:6222") == true)
}

@Test func natsContainer_toContainerRequest_customArgs() {
    let nats = NATSContainer()
        .withArguments(["--max_payload", "1048576"])

    let request = nats.toContainerRequest()

    #expect(request.command.contains("--max_payload") == true)
    #expect(request.command.contains("1048576") == true)
}

// MARK: - Connection String Tests

@Test func natsContainer_buildConnectionString_noAuth() {
    let url = NATSContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 4222
    )

    #expect(url == "nats://127.0.0.1:4222")
}

@Test func natsContainer_buildConnectionString_withCredentials() {
    let url = NATSContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 4222,
        username: "user",
        password: "pass"
    )

    #expect(url == "nats://user:pass@127.0.0.1:4222")
}

@Test func natsContainer_buildConnectionString_withToken() {
    let url = NATSContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 4222,
        token: "my-token"
    )

    #expect(url == "nats://my-token@127.0.0.1:4222")
}

@Test func natsContainer_buildConnectionString_credentialsTakePrecedence() {
    let url = NATSContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 4222,
        username: "user",
        password: "pass",
        token: "my-token"
    )

    #expect(url == "nats://user:pass@127.0.0.1:4222")
}

@Test func natsContainer_buildMonitoringURL() {
    let url = NATSContainer.buildMonitoringURL(
        host: "127.0.0.1",
        port: 8222
    )

    #expect(url == "http://127.0.0.1:8222")
}

// MARK: - Integration Tests

@Test func natsContainer_startsSuccessfully() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nats = NATSContainer()

    try await withNATSContainer(nats) { container in
        let url = try await container.connectionString()
        #expect(url.hasPrefix("nats://"))

        let clientPort = try await container.clientPort()
        #expect(clientPort > 0)

        let monitoringPort = try await container.monitoringPort()
        #expect(monitoringPort > 0)

        let routingPort = try await container.routingPort()
        #expect(routingPort > 0)
    }
}

@Test func natsContainer_connectionStringWithAuth() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nats = NATSContainer()
        .withCredentials(username: "testuser", password: "testpass")

    try await withNATSContainer(nats) { container in
        let url = try await container.connectionString()
        #expect(url.contains("testuser:testpass@"))
    }
}

@Test func natsContainer_jetStreamEnabledInLogs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nats = NATSContainer()
        .withJetStream(true)

    try await withNATSContainer(nats) { container in
        let logs = try await container.logs()
        #expect(logs.contains("JetStream"))
    }
}

@Test func natsContainer_jetStreamDisabledInLogs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nats = NATSContainer()
        .withJetStream(false)

    try await withNATSContainer(nats) { container in
        let logs = try await container.logs()
        #expect(!logs.contains("JetStream"))
    }
}

@Test func natsContainer_allPortsUnique() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nats = NATSContainer()

    try await withNATSContainer(nats) { container in
        let clientPort = try await container.clientPort()
        let monitoringPort = try await container.monitoringPort()
        let routingPort = try await container.routingPort()

        #expect(clientPort != monitoringPort)
        #expect(clientPort != routingPort)
        #expect(monitoringPort != routingPort)
    }
}

@Test func natsContainer_logsAccessible() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nats = NATSContainer()

    try await withNATSContainer(nats) { container in
        let logs = try await container.logs()
        #expect(!logs.isEmpty)
    }
}

@Test func natsContainer_underlyingContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nats = NATSContainer()

    try await withNATSContainer(nats) { container in
        let underlying = container.underlyingContainer
        let id = underlying.id
        #expect(!id.isEmpty)
    }
}
