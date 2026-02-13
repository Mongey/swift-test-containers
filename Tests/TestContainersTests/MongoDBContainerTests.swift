import Foundation
import Testing
@testable import TestContainers

// MARK: - MongoDBContainer Unit Tests

@Test func mongoDBContainer_defaultValues() {
    let mongo = MongoDBContainer()

    #expect(mongo.image == "mongo:7")
    #expect(mongo.port == 27017)
    #expect(mongo.username == nil)
    #expect(mongo.password == nil)
    #expect(mongo.database == nil)
    #expect(mongo.replicaSet == nil)
    #expect(mongo.host == "127.0.0.1")
}

@Test func mongoDBContainer_customImage() {
    let mongo = MongoDBContainer(image: "mongo:6")

    #expect(mongo.image == "mongo:6")
}

@Test func mongoDBContainer_withUsername() {
    let mongo = MongoDBContainer()
        .withUsername("admin")

    #expect(mongo.username == "admin")
}

@Test func mongoDBContainer_withPassword() {
    let mongo = MongoDBContainer()
        .withPassword("secret123")

    #expect(mongo.password == "secret123")
}

@Test func mongoDBContainer_withDatabase() {
    let mongo = MongoDBContainer()
        .withDatabase("testdb")

    #expect(mongo.database == "testdb")
}

@Test func mongoDBContainer_withReplicaSet() {
    let mongo = MongoDBContainer()
        .withReplicaSet()

    #expect(mongo.replicaSet != nil)
    #expect(mongo.replicaSet?.name == "rs")
}

@Test func mongoDBContainer_withReplicaSet_customName() {
    let mongo = MongoDBContainer()
        .withReplicaSet(name: "myrs")

    #expect(mongo.replicaSet?.name == "myrs")
}

@Test func mongoDBContainer_withHost() {
    let mongo = MongoDBContainer()
        .withHost("localhost")

    #expect(mongo.host == "localhost")
}

@Test func mongoDBContainer_methodChaining() {
    let mongo = MongoDBContainer(image: "mongo:6")
        .withUsername("admin")
        .withPassword("pass")
        .withDatabase("mydb")
        .withReplicaSet(name: "testrs")
        .withHost("localhost")

    #expect(mongo.image == "mongo:6")
    #expect(mongo.username == "admin")
    #expect(mongo.password == "pass")
    #expect(mongo.database == "mydb")
    #expect(mongo.replicaSet?.name == "testrs")
    #expect(mongo.host == "localhost")
}

@Test func mongoDBContainer_builderReturnsNewInstance() {
    let original = MongoDBContainer()
    let modified = original.withUsername("admin")

    #expect(original.username == nil)
    #expect(modified.username == "admin")
}

@Test func mongoDBContainer_isHashable() {
    let mongo1 = MongoDBContainer()
        .withUsername("admin")
        .withPassword("pass")
    let mongo2 = MongoDBContainer()
        .withUsername("admin")
        .withPassword("pass")
    let mongo3 = MongoDBContainer()
        .withUsername("other")

    #expect(mongo1 == mongo2)
    #expect(mongo1 != mongo3)
}

// MARK: - toContainerRequest Tests

@Test func mongoDBContainer_toContainerRequest_setsImage() {
    let mongo = MongoDBContainer(image: "mongo:6")

    let request = mongo.toContainerRequest()

    #expect(request.image == "mongo:6")
}

@Test func mongoDBContainer_toContainerRequest_setsPort() {
    let mongo = MongoDBContainer()

    let request = mongo.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 27017 })
}

@Test func mongoDBContainer_toContainerRequest_setsHost() {
    let mongo = MongoDBContainer()
        .withHost("localhost")

    let request = mongo.toContainerRequest()

    #expect(request.host == "localhost")
}

@Test func mongoDBContainer_toContainerRequest_defaultWaitStrategy() {
    let mongo = MongoDBContainer()

    let request = mongo.toContainerRequest()

    if case let .logContains(text, _, _) = request.waitStrategy {
        #expect(text == "Waiting for connections")
    } else {
        Issue.record("Expected .logContains wait strategy, got \(request.waitStrategy)")
    }
}

@Test func mongoDBContainer_toContainerRequest_withAuth() {
    let mongo = MongoDBContainer()
        .withUsername("admin")
        .withPassword("secret")

    let request = mongo.toContainerRequest()

    #expect(request.environment["MONGO_INITDB_ROOT_USERNAME"] == "admin")
    #expect(request.environment["MONGO_INITDB_ROOT_PASSWORD"] == "secret")
}

@Test func mongoDBContainer_toContainerRequest_noAuthByDefault() {
    let mongo = MongoDBContainer()

    let request = mongo.toContainerRequest()

    #expect(request.environment["MONGO_INITDB_ROOT_USERNAME"] == nil)
    #expect(request.environment["MONGO_INITDB_ROOT_PASSWORD"] == nil)
}

@Test func mongoDBContainer_toContainerRequest_onlyUsernameDoesNotSetEnv() {
    let mongo = MongoDBContainer()
        .withUsername("admin")

    let request = mongo.toContainerRequest()

    // Both must be set for auth to be configured
    #expect(request.environment["MONGO_INITDB_ROOT_USERNAME"] == nil)
    #expect(request.environment["MONGO_INITDB_ROOT_PASSWORD"] == nil)
}

@Test func mongoDBContainer_toContainerRequest_replicaSet() {
    let mongo = MongoDBContainer()
        .withReplicaSet(name: "testrs")

    let request = mongo.toContainerRequest()

    #expect(request.command.contains("--replSet"))
    #expect(request.command.contains("testrs"))
}

@Test func mongoDBContainer_toContainerRequest_replicaSetDefaultName() {
    let mongo = MongoDBContainer()
        .withReplicaSet()

    let request = mongo.toContainerRequest()

    #expect(request.command.contains("--replSet"))
    #expect(request.command.contains("rs"))
}

@Test func mongoDBContainer_toContainerRequest_noCommandByDefault() {
    let mongo = MongoDBContainer()

    let request = mongo.toContainerRequest()

    #expect(request.command.isEmpty)
}

@Test func mongoDBContainer_toContainerRequest_initDatabase() {
    let mongo = MongoDBContainer()
        .withDatabase("testdb")

    let request = mongo.toContainerRequest()

    #expect(request.environment["MONGO_INITDB_DATABASE"] == "testdb")
}

// MARK: - Connection String Tests

@Test func mongoDBContainer_connectionString_basic() {
    let connStr = MongoDBContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 27017
    )

    #expect(connStr == "mongodb://127.0.0.1:27017/?directConnection=true")
}

@Test func mongoDBContainer_connectionString_withAuth() {
    let connStr = MongoDBContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 27017,
        username: "admin",
        password: "secret"
    )

    #expect(connStr == "mongodb://admin:secret@127.0.0.1:27017/?directConnection=true")
}

@Test func mongoDBContainer_connectionString_withDatabase() {
    let connStr = MongoDBContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 27017,
        database: "mydb"
    )

    #expect(connStr == "mongodb://127.0.0.1:27017/mydb?directConnection=true")
}

@Test func mongoDBContainer_connectionString_withReplicaSet() {
    let connStr = MongoDBContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 27017,
        replicaSet: "rs"
    )

    #expect(connStr == "mongodb://127.0.0.1:27017/?directConnection=true&replicaSet=rs")
}

@Test func mongoDBContainer_connectionString_full() {
    let connStr = MongoDBContainer.buildConnectionString(
        host: "localhost",
        port: 55432,
        username: "admin",
        password: "pass",
        database: "testdb",
        replicaSet: "myrs"
    )

    #expect(connStr == "mongodb://admin:pass@localhost:55432/testdb?directConnection=true&replicaSet=myrs")
}

@Test func mongoDBContainer_connectionString_urlEncodesCredentials() {
    let connStr = MongoDBContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 27017,
        username: "user@domain",
        password: "p@ss:word/test"
    )

    #expect(connStr.contains("user%40domain"))
    #expect(connStr.contains("p%40ss%3Aword%2Ftest"))
    #expect(!connStr.contains("user@domain:"))
}

@Test func mongoDBContainer_connectionString_databaseWithAuth() {
    let connStr = MongoDBContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 27017,
        username: "admin",
        password: "secret",
        database: "mydb"
    )

    #expect(connStr == "mongodb://admin:secret@127.0.0.1:27017/mydb?directConnection=true")
}

// MARK: - ReplicaSetConfig Tests

@Test func mongoDBReplicaSetConfig_defaultName() {
    let config = MongoDBContainer.ReplicaSetConfig()

    #expect(config.name == "rs")
}

@Test func mongoDBReplicaSetConfig_customName() {
    let config = MongoDBContainer.ReplicaSetConfig(name: "custom")

    #expect(config.name == "custom")
}

@Test func mongoDBReplicaSetConfig_isHashable() {
    let config1 = MongoDBContainer.ReplicaSetConfig(name: "rs")
    let config2 = MongoDBContainer.ReplicaSetConfig(name: "rs")
    let config3 = MongoDBContainer.ReplicaSetConfig(name: "other")

    #expect(config1 == config2)
    #expect(config1 != config3)
}

// MARK: - Integration Tests

@Test func mongoDBContainer_startsSuccessfully() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let mongo = MongoDBContainer()

    try await withMongoDBContainer(mongo) { container in
        let connStr = try await container.connectionString()
        #expect(connStr.hasPrefix("mongodb://"))
        #expect(connStr.contains("127.0.0.1"))
        #expect(connStr.contains("directConnection=true"))
        #expect(!connStr.contains("@")) // No auth
    }
}

@Test func mongoDBContainer_withAuthIntegration() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let mongo = MongoDBContainer()
        .withUsername("testuser")
        .withPassword("testpass")

    try await withMongoDBContainer(mongo) { container in
        let connStr = try await container.connectionString()
        #expect(connStr.contains("testuser:testpass@"))

        let port = try await container.port()
        #expect(port > 0)
    }
}

@Test func mongoDBContainer_portMapping() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let mongo = MongoDBContainer()

    try await withMongoDBContainer(mongo) { container in
        let port = try await container.port()
        #expect(port > 0)

        let host = container.host()
        #expect(host == "127.0.0.1")
    }
}

@Test func mongoDBContainer_logs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let mongo = MongoDBContainer()

    try await withMongoDBContainer(mongo) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Waiting for connections"))
    }
}

@Test func mongoDBContainer_underlyingContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let mongo = MongoDBContainer()

    try await withMongoDBContainer(mongo) { container in
        let underlying = container.underlyingContainer
        let id = await underlying.id
        #expect(!id.isEmpty)
    }
}

@Test func mongoDBContainer_execPing() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let mongo = MongoDBContainer()

    try await withMongoDBContainer(mongo) { container in
        let result = try await container.exec(["mongosh", "--quiet", "--eval", "db.adminCommand('ping')"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("ok"))
    }
}

@Test func mongoDBContainer_replicaSetIntegration() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let mongo = MongoDBContainer()
        .withReplicaSet(name: "testrs")

    try await withMongoDBContainer(mongo) { container in
        let connStr = try await container.connectionString()
        #expect(connStr.contains("replicaSet=testrs"))

        // Verify replica set is initialized by checking status
        let result = try await container.exec(["mongosh", "--quiet", "--eval", "rs.status().ok"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("1"))
    }
}

@Test func mongoDBContainer_withDatabaseIntegration() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let mongo = MongoDBContainer()
        .withDatabase("testdb")

    try await withMongoDBContainer(mongo) { container in
        let connStr = try await container.connectionString()
        #expect(connStr.contains("/testdb"))
    }
}
