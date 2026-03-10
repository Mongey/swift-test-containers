import Foundation
import Testing
@testable import TestContainers

// MARK: - MemcachedContainer Unit Tests

@Test func memcachedContainer_defaultValues() {
    let memcached = MemcachedContainer()

    #expect(memcached.image == "memcached:1.6")
    #expect(memcached.port == 11211)
    #expect(memcached.memoryMB == nil)
    #expect(memcached.maxConnections == nil)
    #expect(memcached.threads == nil)
    #expect(memcached.verbose == false)
    #expect(memcached.host == "127.0.0.1")
}

@Test func memcachedContainer_customImage() {
    let memcached = MemcachedContainer(image: "memcached:1.6-alpine")

    #expect(memcached.image == "memcached:1.6-alpine")
}

@Test func memcachedContainer_withPort() {
    let memcached = MemcachedContainer()
        .withPort(12345)

    #expect(memcached.port == 12345)
}

@Test func memcachedContainer_withMemory() {
    let memcached = MemcachedContainer()
        .withMemory(megabytes: 128)

    #expect(memcached.memoryMB == 128)
}

@Test func memcachedContainer_withMaxConnections() {
    let memcached = MemcachedContainer()
        .withMaxConnections(2048)

    #expect(memcached.maxConnections == 2048)
}

@Test func memcachedContainer_withThreads() {
    let memcached = MemcachedContainer()
        .withThreads(8)

    #expect(memcached.threads == 8)
}

@Test func memcachedContainer_withVerbose() {
    let memcached = MemcachedContainer()
        .withVerbose()

    #expect(memcached.verbose == true)
}

@Test func memcachedContainer_withHost() {
    let memcached = MemcachedContainer()
        .withHost("localhost")

    #expect(memcached.host == "localhost")
}

@Test func memcachedContainer_methodChaining() {
    let memcached = MemcachedContainer(image: "memcached:1.6-alpine")
        .withPort(12000)
        .withMemory(megabytes: 256)
        .withMaxConnections(4096)
        .withThreads(4)
        .withVerbose()
        .withHost("localhost")

    #expect(memcached.image == "memcached:1.6-alpine")
    #expect(memcached.port == 12000)
    #expect(memcached.memoryMB == 256)
    #expect(memcached.maxConnections == 4096)
    #expect(memcached.threads == 4)
    #expect(memcached.verbose == true)
    #expect(memcached.host == "localhost")
}

@Test func memcachedContainer_builderReturnsNewInstance() {
    let original = MemcachedContainer()
    let modified = original.withMemory(megabytes: 128)

    #expect(original.memoryMB == nil)
    #expect(modified.memoryMB == 128)
}

@Test func memcachedContainer_isHashable() {
    let mc1 = MemcachedContainer()
        .withMemory(megabytes: 64)
    let mc2 = MemcachedContainer()
        .withMemory(megabytes: 64)
    let mc3 = MemcachedContainer()
        .withMemory(megabytes: 128)

    #expect(mc1 == mc2)
    #expect(mc1 != mc3)
}

// MARK: - toContainerRequest Tests

@Test func memcachedContainer_toContainerRequest_setsImage() {
    let memcached = MemcachedContainer(image: "memcached:1.6-alpine")

    let request = memcached.toContainerRequest()

    #expect(request.image == "memcached:1.6-alpine")
}

@Test func memcachedContainer_toContainerRequest_setsPort() {
    let memcached = MemcachedContainer()

    let request = memcached.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 11211 })
}

@Test func memcachedContainer_toContainerRequest_setsHost() {
    let memcached = MemcachedContainer()
        .withHost("localhost")

    let request = memcached.toContainerRequest()

    #expect(request.host == "localhost")
}

@Test func memcachedContainer_toContainerRequest_defaultWaitStrategy() {
    let memcached = MemcachedContainer()

    let request = memcached.toContainerRequest()

    if case let .tcpPort(port, _, _) = request.waitStrategy {
        #expect(port == 11211)
    } else {
        Issue.record("Expected .tcpPort wait strategy, got \(request.waitStrategy)")
    }
}

@Test func memcachedContainer_toContainerRequest_customWaitStrategy() {
    let memcached = MemcachedContainer()
        .waitingFor(.logContains("server listening", timeout: .seconds(30)))

    let request = memcached.toContainerRequest()

    if case let .logContains(text, _, _) = request.waitStrategy {
        #expect(text == "server listening")
    } else {
        Issue.record("Expected logContains wait strategy")
    }
}

@Test func memcachedContainer_toContainerRequest_noCommandByDefault() {
    let memcached = MemcachedContainer()

    let request = memcached.toContainerRequest()

    #expect(request.command.isEmpty)
}

@Test func memcachedContainer_toContainerRequest_withMemory() {
    let memcached = MemcachedContainer()
        .withMemory(megabytes: 128)

    let request = memcached.toContainerRequest()

    #expect(request.command.contains("-m"))
    #expect(request.command.contains("128"))
}

@Test func memcachedContainer_toContainerRequest_withMaxConnections() {
    let memcached = MemcachedContainer()
        .withMaxConnections(2048)

    let request = memcached.toContainerRequest()

    #expect(request.command.contains("-c"))
    #expect(request.command.contains("2048"))
}

@Test func memcachedContainer_toContainerRequest_withThreads() {
    let memcached = MemcachedContainer()
        .withThreads(8)

    let request = memcached.toContainerRequest()

    #expect(request.command.contains("-t"))
    #expect(request.command.contains("8"))
}

@Test func memcachedContainer_toContainerRequest_withVerbose() {
    let memcached = MemcachedContainer()
        .withVerbose()

    let request = memcached.toContainerRequest()

    #expect(request.command.contains("-v"))
}

@Test func memcachedContainer_toContainerRequest_allOptions() {
    let memcached = MemcachedContainer()
        .withMemory(megabytes: 256)
        .withMaxConnections(4096)
        .withThreads(4)
        .withVerbose()

    let request = memcached.toContainerRequest()

    #expect(request.command.contains("-m"))
    #expect(request.command.contains("256"))
    #expect(request.command.contains("-c"))
    #expect(request.command.contains("4096"))
    #expect(request.command.contains("-t"))
    #expect(request.command.contains("4"))
    #expect(request.command.contains("-v"))
}

@Test func memcachedContainer_toContainerRequest_customPort() {
    let memcached = MemcachedContainer()
        .withPort(12345)

    let request = memcached.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 12345 })
}

// MARK: - Connection String Tests

@Test func memcachedContainer_connectionString_basic() {
    let connStr = MemcachedContainer.buildConnectionString(
        host: "localhost",
        port: 11211
    )

    #expect(connStr == "localhost:11211")
}

@Test func memcachedContainer_connectionString_customPort() {
    let connStr = MemcachedContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 32768
    )

    #expect(connStr == "127.0.0.1:32768")
}

// MARK: - Static Constants Tests

@Test func memcachedContainer_defaultPort() {
    #expect(MemcachedContainer.defaultPort == 11211)
}

@Test func memcachedContainer_defaultImage() {
    #expect(MemcachedContainer.defaultImage == "memcached:1.6")
}

// MARK: - Integration Tests

@Test func memcachedContainer_startsSuccessfully() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let memcached = MemcachedContainer()

    try await withMemcachedContainer(memcached) { container in
        let connStr = try await container.connectionString()
        #expect(connStr.contains("127.0.0.1"))
        #expect(connStr.contains(":"))
    }
}

@Test func memcachedContainer_portMapping() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let memcached = MemcachedContainer()

    try await withMemcachedContainer(memcached) { container in
        let port = try await container.port()
        #expect(port > 0)

        let host = container.host()
        #expect(host == "127.0.0.1")
    }
}

@Test func memcachedContainer_withMemoryIntegration() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let memcached = MemcachedContainer()
        .withMemory(megabytes: 128)

    try await withMemcachedContainer(memcached) { container in
        let connStr = try await container.connectionString()
        #expect(!connStr.isEmpty)
    }
}

@Test func memcachedContainer_underlyingContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let memcached = MemcachedContainer()

    try await withMemcachedContainer(memcached) { container in
        let underlying = container.underlyingContainer
        let id = await underlying.id
        #expect(!id.isEmpty)
    }
}

@Test func memcachedContainer_execStats() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let memcached = MemcachedContainer()

    try await withMemcachedContainer(memcached) { container in
        // Use exec to send stats command via bash
        let result = try await container.exec(["bash", "-c", "echo stats | nc localhost 11211"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("STAT"))
    }
}
