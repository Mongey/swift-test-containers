import Foundation
import Testing
@testable import TestContainers

// MARK: - RedisContainer Unit Tests

@Test func redisContainer_defaultValues() {
    let redis = RedisContainer()

    #expect(redis.image == "redis:7")
    #expect(redis.port == 6379)
    #expect(redis.password == nil)
    #expect(redis.database == 0)
    #expect(redis.logLevel == nil)
    #expect(redis.snapshotting == nil)
    #expect(redis.host == "127.0.0.1")
}

@Test func redisContainer_customImage() {
    let redis = RedisContainer(image: "redis:6-alpine")

    #expect(redis.image == "redis:6-alpine")
}

@Test func redisContainer_withPassword() {
    let redis = RedisContainer()
        .withPassword("secret123")

    #expect(redis.password == "secret123")
}

@Test func redisContainer_withPort() {
    let redis = RedisContainer()
        .withPort(7000)

    #expect(redis.port == 7000)
}

@Test func redisContainer_withDatabase() {
    let redis = RedisContainer()
        .withDatabase(2)

    #expect(redis.database == 2)
}

@Test func redisContainer_withLogLevel() {
    let redis = RedisContainer()
        .withLogLevel(.verbose)

    #expect(redis.logLevel == .verbose)
}

@Test func redisContainer_withSnapshotting() {
    let redis = RedisContainer()
        .withSnapshotting(seconds: 10, changes: 1)

    #expect(redis.snapshotting == RedisSnapshotting(seconds: 10, changes: 1))
}

@Test func redisContainer_withHost() {
    let redis = RedisContainer()
        .withHost("localhost")

    #expect(redis.host == "localhost")
}

@Test func redisContainer_methodChaining() {
    let redis = RedisContainer(image: "redis:6-alpine")
        .withPassword("pass")
        .withPort(7000)
        .withDatabase(3)
        .withLogLevel(.debug)
        .withSnapshotting(seconds: 60, changes: 100)
        .withHost("localhost")

    #expect(redis.image == "redis:6-alpine")
    #expect(redis.password == "pass")
    #expect(redis.port == 7000)
    #expect(redis.database == 3)
    #expect(redis.logLevel == .debug)
    #expect(redis.snapshotting == RedisSnapshotting(seconds: 60, changes: 100))
    #expect(redis.host == "localhost")
}

@Test func redisContainer_builderReturnsNewInstance() {
    let original = RedisContainer()
    let modified = original.withPassword("secret")

    #expect(original.password == nil)
    #expect(modified.password == "secret")
}

@Test func redisContainer_isHashable() {
    let redis1 = RedisContainer()
        .withPassword("pass")
    let redis2 = RedisContainer()
        .withPassword("pass")
    let redis3 = RedisContainer()
        .withPassword("other")

    #expect(redis1 == redis2)
    #expect(redis1 != redis3)
}

// MARK: - toContainerRequest Tests

@Test func redisContainer_toContainerRequest_setsImage() {
    let redis = RedisContainer(image: "redis:6-alpine")

    let request = redis.toContainerRequest()

    #expect(request.image == "redis:6-alpine")
}

@Test func redisContainer_toContainerRequest_setsPort() {
    let redis = RedisContainer()

    let request = redis.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 6379 })
}

@Test func redisContainer_toContainerRequest_setsHost() {
    let redis = RedisContainer()
        .withHost("localhost")

    let request = redis.toContainerRequest()

    #expect(request.host == "localhost")
}

@Test func redisContainer_toContainerRequest_defaultWaitStrategy() {
    let redis = RedisContainer()

    let request = redis.toContainerRequest()

    if case let .logContains(text, _, _) = request.waitStrategy {
        #expect(text == "Ready to accept connections")
    } else {
        Issue.record("Expected .logContains wait strategy, got \(request.waitStrategy)")
    }
}

@Test func redisContainer_toContainerRequest_customWaitStrategy() {
    let redis = RedisContainer()
        .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

    let request = redis.toContainerRequest()

    if case let .tcpPort(port, timeout, _) = request.waitStrategy {
        #expect(port == 6379)
        #expect(timeout == .seconds(30))
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

@Test func redisContainer_toContainerRequest_withPassword() {
    let redis = RedisContainer()
        .withPassword("test-password")

    let request = redis.toContainerRequest()

    #expect(request.command.contains("--requirepass"))
    #expect(request.command.contains("test-password"))
}

@Test func redisContainer_toContainerRequest_withLogLevel() {
    let redis = RedisContainer()
        .withLogLevel(.verbose)

    let request = redis.toContainerRequest()

    #expect(request.command.contains("--loglevel"))
    #expect(request.command.contains("verbose"))
}

@Test func redisContainer_toContainerRequest_withSnapshotting() {
    let redis = RedisContainer()
        .withSnapshotting(seconds: 10, changes: 1)

    let request = redis.toContainerRequest()

    #expect(request.command.contains("--save"))
    #expect(request.command.contains("10 1"))
}

@Test func redisContainer_toContainerRequest_disablesPersistenceByDefault() {
    let redis = RedisContainer()

    let request = redis.toContainerRequest()

    #expect(request.command.contains("--save"))
    #expect(request.command.contains(""))
}

@Test func redisContainer_toContainerRequest_commandStartsWithRedisServer() {
    let redis = RedisContainer()

    let request = redis.toContainerRequest()

    #expect(request.command.first == "redis-server")
}

// MARK: - Connection String Tests

@Test func redisContainer_connectionString_basic() {
    let connStr = RedisContainer.buildConnectionString(
        host: "localhost",
        port: 6379
    )

    #expect(connStr == "redis://localhost:6379")
}

@Test func redisContainer_connectionString_withPassword() {
    let connStr = RedisContainer.buildConnectionString(
        host: "localhost",
        port: 6379,
        password: "my-password"
    )

    #expect(connStr == "redis://:my-password@localhost:6379")
}

@Test func redisContainer_connectionString_withDatabase() {
    let connStr = RedisContainer.buildConnectionString(
        host: "localhost",
        port: 6379,
        database: 2
    )

    #expect(connStr == "redis://localhost:6379/2")
}

@Test func redisContainer_connectionString_withPasswordAndDatabase() {
    let connStr = RedisContainer.buildConnectionString(
        host: "localhost",
        port: 6379,
        password: "secret",
        database: 5
    )

    #expect(connStr == "redis://:secret@localhost:6379/5")
}

@Test func redisContainer_connectionString_urlEncodesPassword() {
    let connStr = RedisContainer.buildConnectionString(
        host: "localhost",
        port: 6379,
        password: "p@ss:word/test"
    )

    #expect(connStr.contains("p%40ss%3Aword%2Ftest"))
}

@Test func redisContainer_connectionString_databaseZeroOmitted() {
    let connStr = RedisContainer.buildConnectionString(
        host: "localhost",
        port: 6379,
        database: 0
    )

    #expect(connStr == "redis://localhost:6379")
}

// MARK: - RedisLogLevel Tests

@Test func redisLogLevel_rawValues() {
    #expect(RedisLogLevel.debug.rawValue == "debug")
    #expect(RedisLogLevel.verbose.rawValue == "verbose")
    #expect(RedisLogLevel.notice.rawValue == "notice")
    #expect(RedisLogLevel.warning.rawValue == "warning")
}

// MARK: - Integration Tests

@Test func redisContainer_startsSuccessfully() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let redis = RedisContainer()

    try await withRedisContainer(redis) { container in
        let connStr = try await container.connectionString()
        #expect(connStr.hasPrefix("redis://"))
        #expect(connStr.contains("127.0.0.1"))
    }
}

@Test func redisContainer_withPasswordIntegration() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let redis = RedisContainer()
        .withPassword("test-password")

    try await withRedisContainer(redis) { container in
        let connStr = try await container.connectionString()
        #expect(connStr.contains(":test-password@"))

        // Verify Redis requires auth by using exec
        let result = try await container.exec(["redis-cli", "-a", "test-password", "PING"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("PONG"))
    }
}

@Test func redisContainer_portMapping() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let redis = RedisContainer()

    try await withRedisContainer(redis) { container in
        let port = try await container.port()
        #expect(port > 0)

        let host = container.host()
        #expect(host == "127.0.0.1")
    }
}

@Test func redisContainer_logs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let redis = RedisContainer()

    try await withRedisContainer(redis) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Ready to accept connections"))
    }
}

@Test func redisContainer_underlyingContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let redis = RedisContainer()

    try await withRedisContainer(redis) { container in
        let underlying = container.underlyingContainer
        let id = await underlying.id
        #expect(!id.isEmpty)
    }
}

@Test func redisContainer_version6() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let redis = RedisContainer(image: "redis:6-alpine")

    try await withRedisContainer(redis) { container in
        let connStr = try await container.connectionString()
        #expect(!connStr.isEmpty)
    }
}

@Test func redisContainer_execPing() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let redis = RedisContainer()

    try await withRedisContainer(redis) { container in
        let result = try await container.exec(["redis-cli", "PING"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("PONG"))
    }
}
