import Foundation
import Testing
@testable import TestContainers

// MARK: - RabbitMQContainer Unit Tests

@Test func rabbitmqContainer_defaultValues() {
    let rabbitmq = RabbitMQContainer()

    #expect(rabbitmq.image == "rabbitmq:3.13-management-alpine")
    #expect(rabbitmq.adminUsername == "guest")
    #expect(rabbitmq.adminPassword == "guest")
    #expect(rabbitmq.virtualHost == "/")
    #expect(rabbitmq.enableSSL == false)
    #expect(rabbitmq.host == "127.0.0.1")
}

@Test func rabbitmqContainer_customImage() {
    let rabbitmq = RabbitMQContainer(image: "rabbitmq:3.11-management")

    #expect(rabbitmq.image == "rabbitmq:3.11-management")
}

@Test func rabbitmqContainer_withAdminUsername() {
    let rabbitmq = RabbitMQContainer()
        .withAdminUsername("admin")

    #expect(rabbitmq.adminUsername == "admin")
}

@Test func rabbitmqContainer_withAdminPassword() {
    let rabbitmq = RabbitMQContainer()
        .withAdminPassword("secret123")

    #expect(rabbitmq.adminPassword == "secret123")
}

@Test func rabbitmqContainer_withVirtualHost() {
    let rabbitmq = RabbitMQContainer()
        .withVirtualHost("/test-vhost")

    #expect(rabbitmq.virtualHost == "/test-vhost")
}

@Test func rabbitmqContainer_withSSL() {
    let rabbitmq = RabbitMQContainer()
        .withSSL()

    #expect(rabbitmq.enableSSL == true)
}

@Test func rabbitmqContainer_withHost() {
    let rabbitmq = RabbitMQContainer()
        .withHost("localhost")

    #expect(rabbitmq.host == "localhost")
}

@Test func rabbitmqContainer_methodChaining() {
    let rabbitmq = RabbitMQContainer(image: "rabbitmq:3.12-management")
        .withAdminUsername("admin")
        .withAdminPassword("password")
        .withVirtualHost("/prod")
        .withHost("localhost")

    #expect(rabbitmq.image == "rabbitmq:3.12-management")
    #expect(rabbitmq.adminUsername == "admin")
    #expect(rabbitmq.adminPassword == "password")
    #expect(rabbitmq.virtualHost == "/prod")
    #expect(rabbitmq.host == "localhost")
}

@Test func rabbitmqContainer_builderReturnsNewInstance() {
    let original = RabbitMQContainer()
    let modified = original.withAdminUsername("admin")

    #expect(original.adminUsername == "guest")
    #expect(modified.adminUsername == "admin")
}

@Test func rabbitmqContainer_isHashable() {
    let rabbitmq1 = RabbitMQContainer()
        .withAdminUsername("admin")
    let rabbitmq2 = RabbitMQContainer()
        .withAdminUsername("admin")
    let rabbitmq3 = RabbitMQContainer()
        .withAdminUsername("other")

    #expect(rabbitmq1 == rabbitmq2)
    #expect(rabbitmq1 != rabbitmq3)
}

// MARK: - toContainerRequest Tests

@Test func rabbitmqContainer_toContainerRequest_setsImage() {
    let rabbitmq = RabbitMQContainer(image: "rabbitmq:3.11-management")

    let request = rabbitmq.toContainerRequest()

    #expect(request.image == "rabbitmq:3.11-management")
}

@Test func rabbitmqContainer_toContainerRequest_setsAmqpPort() {
    let rabbitmq = RabbitMQContainer()

    let request = rabbitmq.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 5672 })
}

@Test func rabbitmqContainer_toContainerRequest_setsManagementPort() {
    let rabbitmq = RabbitMQContainer()

    let request = rabbitmq.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 15672 })
}

@Test func rabbitmqContainer_toContainerRequest_setsHost() {
    let rabbitmq = RabbitMQContainer()
        .withHost("localhost")

    let request = rabbitmq.toContainerRequest()

    #expect(request.host == "localhost")
}

@Test func rabbitmqContainer_toContainerRequest_setsDefaultCredentials() {
    let rabbitmq = RabbitMQContainer()

    let request = rabbitmq.toContainerRequest()

    #expect(request.environment["RABBITMQ_DEFAULT_USER"] == "guest")
    #expect(request.environment["RABBITMQ_DEFAULT_PASS"] == "guest")
}

@Test func rabbitmqContainer_toContainerRequest_setsCustomCredentials() {
    let rabbitmq = RabbitMQContainer()
        .withAdminUsername("admin")
        .withAdminPassword("secret")

    let request = rabbitmq.toContainerRequest()

    #expect(request.environment["RABBITMQ_DEFAULT_USER"] == "admin")
    #expect(request.environment["RABBITMQ_DEFAULT_PASS"] == "secret")
}

@Test func rabbitmqContainer_toContainerRequest_defaultWaitStrategy() {
    let rabbitmq = RabbitMQContainer()

    let request = rabbitmq.toContainerRequest()

    if case let .tcpPort(port, timeout, _) = request.waitStrategy {
        #expect(port == 5672)
        #expect(timeout == .seconds(60))
    } else {
        Issue.record("Expected .tcpPort wait strategy, got \(request.waitStrategy)")
    }
}

@Test func rabbitmqContainer_toContainerRequest_customWaitStrategy() {
    let rabbitmq = RabbitMQContainer()
        .waitingFor(.logContains("Server startup complete", timeout: .seconds(90)))

    let request = rabbitmq.toContainerRequest()

    if case let .logContains(text, timeout, _) = request.waitStrategy {
        #expect(text == "Server startup complete")
        #expect(timeout == .seconds(90))
    } else {
        Issue.record("Expected .logContains wait strategy")
    }
}

@Test func rabbitmqContainer_toContainerRequest_withSSLExposesAmqpsPort() {
    let rabbitmq = RabbitMQContainer()
        .withSSL()

    let request = rabbitmq.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 5671 })
}

// MARK: - Connection String Tests

@Test func rabbitmqContainer_buildAmqpURL_defaultVirtualHost() {
    let url = RabbitMQContainer.buildAmqpURL(
        host: "localhost",
        port: 5672,
        username: "guest",
        password: "guest",
        virtualHost: "/"
    )

    #expect(url == "amqp://guest:guest@localhost:5672/")
}

@Test func rabbitmqContainer_buildAmqpURL_customVirtualHost() {
    let url = RabbitMQContainer.buildAmqpURL(
        host: "localhost",
        port: 5672,
        username: "guest",
        password: "guest",
        virtualHost: "/test-vhost"
    )

    #expect(url == "amqp://guest:guest@localhost:5672/test-vhost")
}

@Test func rabbitmqContainer_buildAmqpURL_customCredentials() {
    let url = RabbitMQContainer.buildAmqpURL(
        host: "localhost",
        port: 12345,
        username: "admin",
        password: "secret",
        virtualHost: "/"
    )

    #expect(url == "amqp://admin:secret@localhost:12345/")
}

@Test func rabbitmqContainer_buildAmqpURL_urlEncodesCredentials() {
    let url = RabbitMQContainer.buildAmqpURL(
        host: "localhost",
        port: 5672,
        username: "user@domain",
        password: "p@ss:word/test",
        virtualHost: "/"
    )

    #expect(url.contains("user%40domain"))
    #expect(url.contains("p%40ss%3Aword%2Ftest"))
}

@Test func rabbitmqContainer_buildManagementURL() {
    let url = RabbitMQContainer.buildManagementURL(
        host: "localhost",
        port: 15672
    )

    #expect(url == "http://localhost:15672")
}

@Test func rabbitmqContainer_buildAmqpsURL() {
    let url = RabbitMQContainer.buildAmqpsURL(
        host: "localhost",
        port: 5671,
        username: "guest",
        password: "guest",
        virtualHost: "/"
    )

    #expect(url == "amqps://guest:guest@localhost:5671/")
}

// MARK: - Integration Tests

@Test func rabbitmqContainer_startsSuccessfully() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let rabbitmq = RabbitMQContainer()

    try await withRabbitMQContainer(rabbitmq) { container in
        let amqpURL = try await container.amqpURL()
        #expect(amqpURL.hasPrefix("amqp://guest:guest@"))
        #expect(amqpURL.hasSuffix("/"))

        let amqpPort = try await container.amqpPort()
        #expect(amqpPort > 0)

        let mgmtPort = try await container.managementPort()
        #expect(mgmtPort > 0)
    }
}

@Test func rabbitmqContainer_customCredentialsIntegration() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let rabbitmq = RabbitMQContainer()
        .withAdminUsername("admin")
        .withAdminPassword("password123")

    try await withRabbitMQContainer(rabbitmq) { container in
        let amqpURL = try await container.amqpURL()
        #expect(amqpURL.contains("admin:password123"))
    }
}

@Test func rabbitmqContainer_managementUIIntegration() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let rabbitmq = RabbitMQContainer()

    try await withRabbitMQContainer(rabbitmq) { container in
        let mgmtURL = try await container.managementURL()
        #expect(mgmtURL.hasPrefix("http://"))
        #expect(mgmtURL.contains(":"))
    }
}

@Test func rabbitmqContainer_virtualHostIntegration() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let rabbitmq = RabbitMQContainer()
        .withVirtualHost("/test")

    try await withRabbitMQContainer(rabbitmq) { container in
        let amqpURL = try await container.amqpURL()
        #expect(amqpURL.hasSuffix("/test"))
    }
}

@Test func rabbitmqContainer_logsIntegration() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let rabbitmq = RabbitMQContainer()

    try await withRabbitMQContainer(rabbitmq) { container in
        let logs = try await container.logs()
        #expect(!logs.isEmpty)
    }
}

@Test func rabbitmqContainer_underlyingContainerIntegration() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let rabbitmq = RabbitMQContainer()

    try await withRabbitMQContainer(rabbitmq) { container in
        let underlying = container.underlyingContainer
        let id = await underlying.id
        #expect(!id.isEmpty)
    }
}
