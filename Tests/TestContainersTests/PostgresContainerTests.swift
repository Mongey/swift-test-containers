import Foundation
import Testing
@testable import TestContainers

// MARK: - PostgresContainer Unit Tests

@Test func postgresContainer_defaultValues() {
    let postgres = PostgresContainer()

    #expect(postgres.image == "postgres:16-alpine")
    #expect(postgres.database == "postgres")
    #expect(postgres.username == "postgres")
    #expect(postgres.password == "postgres")
    #expect(postgres.port == 5432)
}

@Test func postgresContainer_customImage() {
    let postgres = PostgresContainer(image: "postgres:15-alpine")

    #expect(postgres.image == "postgres:15-alpine")
}

@Test func postgresContainer_withDatabase() {
    let postgres = PostgresContainer()
        .withDatabase("myapp")

    #expect(postgres.database == "myapp")
}

@Test func postgresContainer_withUsername() {
    let postgres = PostgresContainer()
        .withUsername("appuser")

    #expect(postgres.username == "appuser")
}

@Test func postgresContainer_withPassword() {
    let postgres = PostgresContainer()
        .withPassword("secret123")

    #expect(postgres.password == "secret123")
}

@Test func postgresContainer_withPort() {
    let postgres = PostgresContainer()
        .withPort(5433)

    #expect(postgres.port == 5433)
}

@Test func postgresContainer_withEnvironment() {
    let postgres = PostgresContainer()
        .withEnvironment(["PGDATA": "/var/lib/postgresql/data/pgdata"])

    #expect(postgres.environment["PGDATA"] == "/var/lib/postgresql/data/pgdata")
}

@Test func postgresContainer_withHost() {
    let postgres = PostgresContainer()
        .withHost("localhost")

    #expect(postgres.host == "localhost")
}

@Test func postgresContainer_methodChaining() {
    let postgres = PostgresContainer(image: "postgres:14-alpine")
        .withDatabase("testdb")
        .withUsername("testuser")
        .withPassword("testpass")
        .withPort(5432)
        .withEnvironment(["POSTGRES_INITDB_ARGS": "--encoding=UTF8"])

    #expect(postgres.image == "postgres:14-alpine")
    #expect(postgres.database == "testdb")
    #expect(postgres.username == "testuser")
    #expect(postgres.password == "testpass")
    #expect(postgres.environment["POSTGRES_INITDB_ARGS"] == "--encoding=UTF8")
}

@Test func postgresContainer_builderReturnsNewInstance() {
    let original = PostgresContainer()
    let modified = original.withDatabase("newdb")

    #expect(original.database == "postgres")
    #expect(modified.database == "newdb")
}

@Test func postgresContainer_isHashable() {
    let postgres1 = PostgresContainer()
        .withDatabase("db1")
    let postgres2 = PostgresContainer()
        .withDatabase("db1")
    let postgres3 = PostgresContainer()
        .withDatabase("db2")

    #expect(postgres1 == postgres2)
    #expect(postgres1 != postgres3)
}

// MARK: - toContainerRequest Tests

@Test func postgresContainer_toContainerRequest_setsImage() {
    let postgres = PostgresContainer(image: "postgres:15-alpine")

    let request = postgres.toContainerRequest()

    #expect(request.image == "postgres:15-alpine")
}

@Test func postgresContainer_toContainerRequest_setsEnvironment() {
    let postgres = PostgresContainer()
        .withDatabase("testdb")
        .withUsername("testuser")
        .withPassword("testpass")

    let request = postgres.toContainerRequest()

    #expect(request.environment["POSTGRES_DB"] == "testdb")
    #expect(request.environment["POSTGRES_USER"] == "testuser")
    #expect(request.environment["POSTGRES_PASSWORD"] == "testpass")
}

@Test func postgresContainer_toContainerRequest_mergesEnvironment() {
    let postgres = PostgresContainer()
        .withEnvironment(["PGDATA": "/custom/path"])

    let request = postgres.toContainerRequest()

    #expect(request.environment["PGDATA"] == "/custom/path")
    #expect(request.environment["POSTGRES_DB"] == "postgres")
}

@Test func postgresContainer_toContainerRequest_setsPort() {
    let postgres = PostgresContainer()

    let request = postgres.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 5432 })
}

@Test func postgresContainer_toContainerRequest_setsHost() {
    let postgres = PostgresContainer()
        .withHost("localhost")

    let request = postgres.toContainerRequest()

    #expect(request.host == "localhost")
}

@Test func postgresContainer_toContainerRequest_defaultWaitStrategy() {
    let postgres = PostgresContainer()

    let request = postgres.toContainerRequest()

    // Default wait strategy should be exec with pg_isready
    if case let .exec(command, _, _) = request.waitStrategy {
        #expect(command.contains("pg_isready"))
    } else {
        Issue.record("Expected .exec wait strategy with pg_isready, got \(request.waitStrategy)")
    }
}

@Test func postgresContainer_toContainerRequest_customWaitStrategy() {
    let postgres = PostgresContainer()
        .waitingFor(.tcpPort(5432, timeout: .seconds(30)))

    let request = postgres.toContainerRequest()

    if case let .tcpPort(port, timeout, _) = request.waitStrategy {
        #expect(port == 5432)
        #expect(timeout == .seconds(30))
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

// MARK: - Connection String Tests

@Test func postgresContainer_connectionString_basicFormat() {
    let connStr = PostgresContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 5432,
        database: "testdb",
        username: "user",
        password: "pass"
    )

    #expect(connStr == "postgresql://user:pass@127.0.0.1:5432/testdb")
}

@Test func postgresContainer_connectionString_withSslMode() {
    let connStr = PostgresContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 5432,
        database: "testdb",
        username: "user",
        password: "pass",
        sslMode: "require"
    )

    #expect(connStr.contains("sslmode=require"))
}

@Test func postgresContainer_connectionString_withOptions() {
    let connStr = PostgresContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 5432,
        database: "testdb",
        username: "user",
        password: "pass",
        options: ["application_name": "myapp", "connect_timeout": "10"]
    )

    #expect(connStr.contains("application_name=myapp"))
    #expect(connStr.contains("connect_timeout=10"))
}

@Test func postgresContainer_connectionString_urlEncodesSpecialChars() {
    let connStr = PostgresContainer.buildConnectionString(
        host: "127.0.0.1",
        port: 5432,
        database: "testdb",
        username: "user@domain",
        password: "p@ss:word/test"
    )

    // Special characters should be URL encoded
    #expect(connStr.contains("user%40domain"))
    #expect(connStr.contains("p%40ss%3Aword%2Ftest"))
}

@Test func postgresContainer_connectionString_withSslModeAndOptions() {
    let connStr = PostgresContainer.buildConnectionString(
        host: "localhost",
        port: 15432,
        database: "mydb",
        username: "admin",
        password: "secret",
        sslMode: "disable",
        options: ["application_name": "test"]
    )

    #expect(connStr.hasPrefix("postgresql://admin:secret@localhost:15432/mydb?"))
    #expect(connStr.contains("sslmode=disable"))
    #expect(connStr.contains("application_name=test"))
}

// MARK: - Integration Tests

@Test func postgresContainer_startsSuccessfully() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let postgres = PostgresContainer()

    try await withPostgresContainer(postgres) { container in
        let connStr = try await container.connectionString()
        #expect(connStr.hasPrefix("postgresql://"))
        #expect(connStr.contains("postgres"))
    }
}

@Test func postgresContainer_customCredentials() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let postgres = PostgresContainer()
        .withDatabase("testdb")
        .withUsername("testuser")
        .withPassword("testpass")

    try await withPostgresContainer(postgres) { container in
        let connStr = try await container.connectionString()
        #expect(connStr.contains("testdb"))
        #expect(connStr.contains("testuser"))
        #expect(connStr.contains("testpass"))

        #expect(container.database() == "testdb")
        #expect(container.username() == "testuser")
        #expect(container.password() == "testpass")
    }
}

@Test func postgresContainer_connectionStringWithSslMode() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let postgres = PostgresContainer()

    try await withPostgresContainer(postgres) { container in
        let connStr = try await container.connectionString(sslMode: "disable")
        #expect(connStr.contains("sslmode=disable"))
    }
}

@Test func postgresContainer_connectionStringWithOptions() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let postgres = PostgresContainer()

    try await withPostgresContainer(postgres) { container in
        let connStr = try await container.connectionString(
            options: ["application_name": "testapp", "connect_timeout": "5"]
        )
        #expect(connStr.contains("application_name=testapp"))
        #expect(connStr.contains("connect_timeout=5"))
    }
}

@Test func postgresContainer_portMapping() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let postgres = PostgresContainer()

    try await withPostgresContainer(postgres) { container in
        let port = try await container.port()
        #expect(port > 0)

        let host = container.host()
        #expect(host == "127.0.0.1")
    }
}

@Test func postgresContainer_logs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let postgres = PostgresContainer()

    try await withPostgresContainer(postgres) { container in
        let logs = try await container.logs()
        #expect(logs.contains("database system is ready to accept connections"))
    }
}

@Test func postgresContainer_underlyingContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let postgres = PostgresContainer()

    try await withPostgresContainer(postgres) { container in
        let underlying = container.underlyingContainer
        let id = await underlying.id
        #expect(!id.isEmpty)
    }
}

@Test func postgresContainer_version15() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let postgres = PostgresContainer(image: "postgres:15-alpine")

    try await withPostgresContainer(postgres) { container in
        let connStr = try await container.connectionString()
        #expect(!connStr.isEmpty)
    }
}

@Test func postgresContainer_execQuery() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let postgres = PostgresContainer()
        .withDatabase("testdb")

    try await withPostgresContainer(postgres) { container in
        // Execute a simple query using psql
        let result = try await container.exec(["psql", "-U", "postgres", "-d", "testdb", "-c", "SELECT 1 as test;"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("1"))
    }
}
