import Foundation
import Testing
@testable import TestContainers

// MARK: - MySQLContainerRequest Unit Tests

@Test func mysqlContainerRequest_defaultValues() {
    let request = MySQLContainerRequest()

    #expect(request.image == "mysql:8.0")
    #expect(request.database == "test")
    #expect(request.rootPassword == "test")
    #expect(request.username == "test")
    #expect(request.password == "test")
    #expect(request.port == 3306)
    #expect(request.host == "127.0.0.1")
    #expect(request.environment.isEmpty)
    #expect(request.waitStrategy == nil)
}

@Test func mysqlContainerRequest_customImage() {
    let request = MySQLContainerRequest(image: "mysql:5.7")

    #expect(request.image == "mysql:5.7")
}

@Test func mysqlContainerRequest_withDatabase() {
    let request = MySQLContainerRequest()
        .withDatabase("myapp")

    #expect(request.database == "myapp")
}

@Test func mysqlContainerRequest_withRootPassword() {
    let request = MySQLContainerRequest()
        .withRootPassword("secret")

    #expect(request.rootPassword == "secret")
}

@Test func mysqlContainerRequest_withUsername() {
    let request = MySQLContainerRequest()
        .withUsername("myuser", password: "mypass")

    #expect(request.username == "myuser")
    #expect(request.password == "mypass")
}

@Test func mysqlContainerRequest_withRootOnly() {
    let request = MySQLContainerRequest()
        .withRootOnly()

    #expect(request.username == nil)
    #expect(request.password == nil)
}

@Test func mysqlContainerRequest_withPort() {
    let request = MySQLContainerRequest()
        .withPort(3307)

    #expect(request.port == 3307)
}

@Test func mysqlContainerRequest_withHost() {
    let request = MySQLContainerRequest()
        .withHost("0.0.0.0")

    #expect(request.host == "0.0.0.0")
}

@Test func mysqlContainerRequest_withEnvironment() {
    let request = MySQLContainerRequest()
        .withEnvironment(["MYSQL_INITDB_SKIP_TZINFO": "1"])

    #expect(request.environment["MYSQL_INITDB_SKIP_TZINFO"] == "1")
}

@Test func mysqlContainerRequest_withWaitStrategy() {
    let request = MySQLContainerRequest()
        .withWaitStrategy(.tcpPort(3306, timeout: .seconds(30)))

    if case let .tcpPort(port, timeout, _) = request.waitStrategy {
        #expect(port == 3306)
        #expect(timeout == .seconds(30))
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

@Test func mysqlContainerRequest_waitingFor_alias() {
    let request = MySQLContainerRequest()
        .waitingFor(.tcpPort(3306, timeout: .seconds(45)))

    if case let .tcpPort(port, timeout, _) = request.waitStrategy {
        #expect(port == 3306)
        #expect(timeout == .seconds(45))
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

@Test func mysqlContainerRequest_methodChaining() {
    let request = MySQLContainerRequest(image: "mysql:5.7")
        .withDatabase("myapp")
        .withRootPassword("rootpass")
        .withUsername("appuser", password: "apppass")
        .withPort(3306)
        .withHost("127.0.0.1")
        .withEnvironment(["MYSQL_INITDB_SKIP_TZINFO": "1"])

    #expect(request.image == "mysql:5.7")
    #expect(request.database == "myapp")
    #expect(request.rootPassword == "rootpass")
    #expect(request.username == "appuser")
    #expect(request.password == "apppass")
    #expect(request.port == 3306)
    #expect(request.host == "127.0.0.1")
    #expect(request.environment["MYSQL_INITDB_SKIP_TZINFO"] == "1")
}

@Test func mysqlContainerRequest_isHashable() {
    let request1 = MySQLContainerRequest()
        .withDatabase("test1")
        .withRootPassword("pass1")
    let request2 = MySQLContainerRequest()
        .withDatabase("test1")
        .withRootPassword("pass1")
    let request3 = MySQLContainerRequest()
        .withDatabase("test2")
        .withRootPassword("pass2")

    #expect(request1 == request2)
    #expect(request1 != request3)
}

// MARK: - toContainerRequest Tests

@Test func mysqlContainerRequest_toContainerRequest_setsImage() {
    let request = MySQLContainerRequest(image: "mysql:5.7")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.image == "mysql:5.7")
}

@Test func mysqlContainerRequest_toContainerRequest_setsEnvironment() {
    let request = MySQLContainerRequest()
        .withDatabase("mydb")
        .withRootPassword("rootpass")
        .withUsername("user", password: "userpass")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.environment["MYSQL_DATABASE"] == "mydb")
    #expect(containerRequest.environment["MYSQL_ROOT_PASSWORD"] == "rootpass")
    #expect(containerRequest.environment["MYSQL_USER"] == "user")
    #expect(containerRequest.environment["MYSQL_PASSWORD"] == "userpass")
}

@Test func mysqlContainerRequest_toContainerRequest_rootOnly() {
    let request = MySQLContainerRequest()
        .withRootOnly()
        .withRootPassword("rootpass")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.environment["MYSQL_ROOT_PASSWORD"] == "rootpass")
    #expect(containerRequest.environment["MYSQL_USER"] == nil)
    #expect(containerRequest.environment["MYSQL_PASSWORD"] == nil)
}

@Test func mysqlContainerRequest_toContainerRequest_setsPort() {
    let request = MySQLContainerRequest()
        .withPort(3306)

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.ports.contains { $0.containerPort == 3306 })
}

@Test func mysqlContainerRequest_toContainerRequest_customContainerAndHostPort() {
    let request = MySQLContainerRequest()
        .withContainerPort(3307)
        .withHostPort(13307)

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.ports.contains {
        $0.containerPort == 3307 && $0.hostPort == 13307
    })
}

@Test func mysqlContainerRequest_toContainerRequest_withInitScripts() {
    let request = MySQLContainerRequest()
        .withInitScript("/tmp/01-schema.sql")
        .withInitScripts(["/tmp/02-data.sql", "/tmp/03-extra.sh"])

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.bindMounts.contains {
        $0.hostPath == "/tmp/01-schema.sql" &&
            $0.containerPath == "/docker-entrypoint-initdb.d/01-schema.sql" &&
            $0.readOnly
    })
    #expect(containerRequest.bindMounts.contains {
        $0.hostPath == "/tmp/02-data.sql" &&
            $0.containerPath == "/docker-entrypoint-initdb.d/02-data.sql" &&
            $0.readOnly
    })
    #expect(containerRequest.bindMounts.contains {
        $0.hostPath == "/tmp/03-extra.sh" &&
            $0.containerPath == "/docker-entrypoint-initdb.d/03-extra.sh" &&
            $0.readOnly
    })
}

@Test func mysqlContainerRequest_toContainerRequest_withConfigFile() {
    let request = MySQLContainerRequest()
        .withConfigFile("/tmp/custom.cnf")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.bindMounts.contains {
        $0.hostPath == "/tmp/custom.cnf" &&
            $0.containerPath == "/etc/mysql/conf.d/custom.cnf" &&
            $0.readOnly
    })
}

@Test func mysqlContainerRequest_asContainerRequest_alias() {
    let request = MySQLContainerRequest()
        .withDatabase("mydb")
        .withContainerPort(3307)
        .withHostPort(13307)

    #expect(request.asContainerRequest() == request.toContainerRequest())
}

@Test func mysqlContainerRequest_toContainerRequest_setsHost() {
    let request = MySQLContainerRequest()
        .withHost("localhost")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.host == "localhost")
}

@Test func mysqlContainerRequest_toContainerRequest_mergesEnvironment() {
    let request = MySQLContainerRequest()
        .withDatabase("mydb")
        .withEnvironment(["MYSQL_INITDB_SKIP_TZINFO": "1"])

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.environment["MYSQL_DATABASE"] == "mydb")
    #expect(containerRequest.environment["MYSQL_INITDB_SKIP_TZINFO"] == "1")
}

@Test func mysqlContainerRequest_toContainerRequest_defaultWaitStrategy() {
    let request = MySQLContainerRequest()

    let containerRequest = request.toContainerRequest()

    if case let .logContains(text, timeout, _) = containerRequest.waitStrategy {
        #expect(text == "ready for connections")
        #expect(timeout == .seconds(60))
    } else {
        Issue.record("Expected logContains wait strategy, got \(containerRequest.waitStrategy)")
    }
}

@Test func mysqlContainerRequest_toContainerRequest_customWaitStrategy() {
    let request = MySQLContainerRequest()
        .withWaitStrategy(.tcpPort(3306))

    let containerRequest = request.toContainerRequest()

    if case let .tcpPort(port, _, _) = containerRequest.waitStrategy {
        #expect(port == 3306)
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

@Test func mysqlContainerRequest_toContainerRequest_storesMetadataInLabels() {
    let request = MySQLContainerRequest()
        .withDatabase("mydb")
        .withUsername("user", password: "pass")
        .withRootPassword("rootpass")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.labels["testcontainers.mysql.database"] == "mydb")
    #expect(containerRequest.labels["testcontainers.mysql.username"] == "user")
    #expect(containerRequest.labels["testcontainers.mysql.password"] == "pass")
    #expect(containerRequest.labels["testcontainers.mysql.rootPassword"] == "rootpass")
}

@Test func mysqlContainerRequest_toContainerRequest_rootOnly_noUsernameLabel() {
    let request = MySQLContainerRequest()
        .withRootOnly()

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.labels["testcontainers.mysql.username"] == nil)
    #expect(containerRequest.labels["testcontainers.mysql.password"] == nil)
}

// MARK: - MariaDBContainerRequest Unit Tests

@Test func mariadbContainerRequest_defaultValues() {
    let request = MariaDBContainerRequest()

    #expect(request.image == "mariadb:11.0")
    #expect(request.database == "test")
    #expect(request.rootPassword == "test")
    #expect(request.username == "test")
    #expect(request.password == "test")
    #expect(request.port == 3306)
    #expect(request.host == "127.0.0.1")
    #expect(request.environment.isEmpty)
    #expect(request.waitStrategy == nil)
}

@Test func mariadbContainerRequest_customImage() {
    let request = MariaDBContainerRequest(image: "mariadb:10.6")

    #expect(request.image == "mariadb:10.6")
}

@Test func mariadbContainerRequest_withDatabase() {
    let request = MariaDBContainerRequest()
        .withDatabase("myapp")

    #expect(request.database == "myapp")
}

@Test func mariadbContainerRequest_withRootPassword() {
    let request = MariaDBContainerRequest()
        .withRootPassword("secret")

    #expect(request.rootPassword == "secret")
}

@Test func mariadbContainerRequest_withUsername() {
    let request = MariaDBContainerRequest()
        .withUsername("myuser", password: "mypass")

    #expect(request.username == "myuser")
    #expect(request.password == "mypass")
}

@Test func mariadbContainerRequest_withRootOnly() {
    let request = MariaDBContainerRequest()
        .withRootOnly()

    #expect(request.username == nil)
    #expect(request.password == nil)
}

@Test func mariadbContainerRequest_withPort() {
    let request = MariaDBContainerRequest()
        .withPort(3307)

    #expect(request.port == 3307)
}

@Test func mariadbContainerRequest_withHost() {
    let request = MariaDBContainerRequest()
        .withHost("0.0.0.0")

    #expect(request.host == "0.0.0.0")
}

@Test func mariadbContainerRequest_withEnvironment() {
    let request = MariaDBContainerRequest()
        .withEnvironment(["MARIADB_AUTO_UPGRADE": "1"])

    #expect(request.environment["MARIADB_AUTO_UPGRADE"] == "1")
}

@Test func mariadbContainerRequest_withWaitStrategy() {
    let request = MariaDBContainerRequest()
        .withWaitStrategy(.tcpPort(3306, timeout: .seconds(30)))

    if case let .tcpPort(port, timeout, _) = request.waitStrategy {
        #expect(port == 3306)
        #expect(timeout == .seconds(30))
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

@Test func mariadbContainerRequest_waitingFor_alias() {
    let request = MariaDBContainerRequest()
        .waitingFor(.tcpPort(3306, timeout: .seconds(45)))

    if case let .tcpPort(port, timeout, _) = request.waitStrategy {
        #expect(port == 3306)
        #expect(timeout == .seconds(45))
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

@Test func mariadbContainerRequest_methodChaining() {
    let request = MariaDBContainerRequest(image: "mariadb:10.6")
        .withDatabase("myapp")
        .withRootPassword("rootpass")
        .withUsername("appuser", password: "apppass")
        .withPort(3306)
        .withHost("127.0.0.1")
        .withEnvironment(["MARIADB_AUTO_UPGRADE": "1"])

    #expect(request.image == "mariadb:10.6")
    #expect(request.database == "myapp")
    #expect(request.rootPassword == "rootpass")
    #expect(request.username == "appuser")
    #expect(request.password == "apppass")
    #expect(request.port == 3306)
    #expect(request.host == "127.0.0.1")
    #expect(request.environment["MARIADB_AUTO_UPGRADE"] == "1")
}

@Test func mariadbContainerRequest_isHashable() {
    let request1 = MariaDBContainerRequest()
        .withDatabase("test1")
        .withRootPassword("pass1")
    let request2 = MariaDBContainerRequest()
        .withDatabase("test1")
        .withRootPassword("pass1")
    let request3 = MariaDBContainerRequest()
        .withDatabase("test2")
        .withRootPassword("pass2")

    #expect(request1 == request2)
    #expect(request1 != request3)
}

// MARK: - MariaDB toContainerRequest Tests

@Test func mariadbContainerRequest_toContainerRequest_setsImage() {
    let request = MariaDBContainerRequest(image: "mariadb:10.6")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.image == "mariadb:10.6")
}

@Test func mariadbContainerRequest_toContainerRequest_setsEnvironment() {
    let request = MariaDBContainerRequest()
        .withDatabase("mydb")
        .withRootPassword("rootpass")
        .withUsername("user", password: "userpass")

    let containerRequest = request.toContainerRequest()

    // MariaDB uses MYSQL_* env vars for compatibility
    #expect(containerRequest.environment["MYSQL_DATABASE"] == "mydb")
    #expect(containerRequest.environment["MYSQL_ROOT_PASSWORD"] == "rootpass")
    #expect(containerRequest.environment["MYSQL_USER"] == "user")
    #expect(containerRequest.environment["MYSQL_PASSWORD"] == "userpass")
}

@Test func mariadbContainerRequest_toContainerRequest_rootOnly() {
    let request = MariaDBContainerRequest()
        .withRootOnly()
        .withRootPassword("rootpass")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.environment["MYSQL_ROOT_PASSWORD"] == "rootpass")
    #expect(containerRequest.environment["MYSQL_USER"] == nil)
    #expect(containerRequest.environment["MYSQL_PASSWORD"] == nil)
}

@Test func mariadbContainerRequest_toContainerRequest_setsPort() {
    let request = MariaDBContainerRequest()
        .withPort(3306)

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.ports.contains { $0.containerPort == 3306 })
}

@Test func mariadbContainerRequest_toContainerRequest_customContainerAndHostPort() {
    let request = MariaDBContainerRequest()
        .withContainerPort(3307)
        .withHostPort(13307)

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.ports.contains {
        $0.containerPort == 3307 && $0.hostPort == 13307
    })
}

@Test func mariadbContainerRequest_toContainerRequest_withInitScripts() {
    let request = MariaDBContainerRequest()
        .withInitScript("/tmp/01-schema.sql")
        .withInitScripts(["/tmp/02-data.sql", "/tmp/03-extra.sh"])

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.bindMounts.contains {
        $0.hostPath == "/tmp/01-schema.sql" &&
            $0.containerPath == "/docker-entrypoint-initdb.d/01-schema.sql" &&
            $0.readOnly
    })
    #expect(containerRequest.bindMounts.contains {
        $0.hostPath == "/tmp/02-data.sql" &&
            $0.containerPath == "/docker-entrypoint-initdb.d/02-data.sql" &&
            $0.readOnly
    })
    #expect(containerRequest.bindMounts.contains {
        $0.hostPath == "/tmp/03-extra.sh" &&
            $0.containerPath == "/docker-entrypoint-initdb.d/03-extra.sh" &&
            $0.readOnly
    })
}

@Test func mariadbContainerRequest_toContainerRequest_withConfigFile() {
    let request = MariaDBContainerRequest()
        .withConfigFile("/tmp/custom.cnf")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.bindMounts.contains {
        $0.hostPath == "/tmp/custom.cnf" &&
            $0.containerPath == "/etc/mysql/conf.d/custom.cnf" &&
            $0.readOnly
    })
}

@Test func mariadbContainerRequest_asContainerRequest_alias() {
    let request = MariaDBContainerRequest()
        .withDatabase("mydb")
        .withContainerPort(3307)
        .withHostPort(13307)

    #expect(request.asContainerRequest() == request.toContainerRequest())
}

@Test func mariadbContainerRequest_toContainerRequest_setsHost() {
    let request = MariaDBContainerRequest()
        .withHost("localhost")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.host == "localhost")
}

@Test func mariadbContainerRequest_toContainerRequest_mergesEnvironment() {
    let request = MariaDBContainerRequest()
        .withDatabase("mydb")
        .withEnvironment(["MARIADB_AUTO_UPGRADE": "1"])

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.environment["MYSQL_DATABASE"] == "mydb")
    #expect(containerRequest.environment["MARIADB_AUTO_UPGRADE"] == "1")
}

@Test func mariadbContainerRequest_toContainerRequest_defaultWaitStrategy() {
    let request = MariaDBContainerRequest()

    let containerRequest = request.toContainerRequest()

    if case let .logContains(text, timeout, _) = containerRequest.waitStrategy {
        #expect(text == "ready for connections")
        #expect(timeout == .seconds(60))
    } else {
        Issue.record("Expected logContains wait strategy, got \(containerRequest.waitStrategy)")
    }
}

@Test func mariadbContainerRequest_toContainerRequest_customWaitStrategy() {
    let request = MariaDBContainerRequest()
        .withWaitStrategy(.tcpPort(3306))

    let containerRequest = request.toContainerRequest()

    if case let .tcpPort(port, _, _) = containerRequest.waitStrategy {
        #expect(port == 3306)
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

@Test func mariadbContainerRequest_toContainerRequest_storesMetadataInLabels() {
    let request = MariaDBContainerRequest()
        .withDatabase("mydb")
        .withUsername("user", password: "pass")
        .withRootPassword("rootpass")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.labels["testcontainers.mariadb.database"] == "mydb")
    #expect(containerRequest.labels["testcontainers.mariadb.username"] == "user")
    #expect(containerRequest.labels["testcontainers.mariadb.password"] == "pass")
    #expect(containerRequest.labels["testcontainers.mariadb.rootPassword"] == "rootpass")
}

@Test func mariadbContainerRequest_toContainerRequest_rootOnly_noUsernameLabel() {
    let request = MariaDBContainerRequest()
        .withRootOnly()

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.labels["testcontainers.mariadb.username"] == nil)
    #expect(containerRequest.labels["testcontainers.mariadb.password"] == nil)
}

// MARK: - MySQL Integration Tests

@Test func mysqlContainer_startsSuccessfully() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withMySQLContainer(MySQLContainerRequest()) { mysql in
        let port = try await mysql.hostPort()
        #expect(port > 0)

        let connectionString = try await mysql.connectionString()
        #expect(connectionString.hasPrefix("mysql://test:test@"))
        #expect(connectionString.contains("/test"))
    }
}

@Test func mysqlContainer_customDatabaseAndUser() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = MySQLContainerRequest()
        .withDatabase("myapp")
        .withUsername("appuser", password: "apppass")

    try await withMySQLContainer(request) { mysql in
        let connectionString = try await mysql.connectionString()
        #expect(connectionString.contains("appuser:apppass"))
        #expect(connectionString.hasSuffix("/myapp"))
    }
}

@Test func mysqlContainer_rootConnectionString() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = MySQLContainerRequest()
        .withRootPassword("rootsecret")

    try await withMySQLContainer(request) { mysql in
        let rootConnectionString = try await mysql.rootConnectionString()
        #expect(rootConnectionString.hasPrefix("mysql://root:rootsecret@"))
    }
}

@Test func mysqlContainer_connectionStringWithParameters() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withMySQLContainer(MySQLContainerRequest()) { mysql in
        let connectionString = try await mysql.connectionString(
            parameters: ["charset": "utf8mb4", "parseTime": "true"]
        )
        #expect(connectionString.contains("charset=utf8mb4"))
        #expect(connectionString.contains("parseTime=true"))
    }
}

@Test func mysqlContainer_rootOnlyMode() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = MySQLContainerRequest()
        .withRootOnly()
        .withRootPassword("rootonly")

    try await withMySQLContainer(request) { mysql in
        // Non-root connection should fail
        do {
            _ = try await mysql.connectionString()
            Issue.record("Expected error for root-only container")
        } catch {
            // Expected - no non-root user configured
        }

        // Root connection should work
        let rootConnectionString = try await mysql.rootConnectionString()
        #expect(rootConnectionString.hasPrefix("mysql://root:rootonly@"))
    }
}

@Test func mysqlContainer_logs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withMySQLContainer(MySQLContainerRequest()) { mysql in
        let logs = try await mysql.logs()
        #expect(logs.contains("MySQL") || logs.contains("mysql") || logs.contains("ready for connections"))
    }
}

@Test func mysqlContainer_id() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withMySQLContainer(MySQLContainerRequest()) { mysql in
        let id = await mysql.id
        #expect(!id.isEmpty)
    }
}

@Test func mysqlContainer_host() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = MySQLContainerRequest()
        .withHost("127.0.0.1")

    try await withMySQLContainer(request) { mysql in
        #expect(mysql.host() == "127.0.0.1")
    }
}

@Test func mysqlContainer_database() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = MySQLContainerRequest()
        .withDatabase("customdb")

    try await withMySQLContainer(request) { mysql in
        #expect(mysql.database() == "customdb")
    }
}

@Test func mysqlContainer_username() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = MySQLContainerRequest()
        .withUsername("customuser", password: "custompass")

    try await withMySQLContainer(request) { mysql in
        #expect(mysql.username() == "customuser")
    }
}

@Test func mysqlContainer_scopedMethodHelper() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await MySQLContainerRequest().withContainer { mysql in
        let connectionString = try await mysql.connectionString()
        #expect(connectionString.hasPrefix("mysql://"))
    }
}

@Test func mysqlContainer_underlyingContainerConnectionStringHelpers() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withMySQLContainer(MySQLContainerRequest()) { mysql in
        let generic = await mysql.underlyingContainer
        let userURL = try await generic.mysqlConnectionString()
        let rootURL = try await generic.mysqlRootConnectionString()

        #expect(userURL.hasPrefix("mysql://test:test@"))
        #expect(rootURL.hasPrefix("mysql://root:test@"))
    }
}

// MARK: - MariaDB Integration Tests

@Test func mariadbContainer_startsSuccessfully() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withMariaDBContainer(MariaDBContainerRequest()) { mariadb in
        let port = try await mariadb.hostPort()
        #expect(port > 0)

        let connectionString = try await mariadb.connectionString()
        #expect(connectionString.hasPrefix("mysql://test:test@"))
        #expect(connectionString.contains("/test"))
    }
}

@Test func mariadbContainer_customDatabaseAndUser() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = MariaDBContainerRequest()
        .withDatabase("myapp")
        .withUsername("appuser", password: "apppass")

    try await withMariaDBContainer(request) { mariadb in
        let connectionString = try await mariadb.connectionString()
        #expect(connectionString.contains("appuser:apppass"))
        #expect(connectionString.hasSuffix("/myapp"))
    }
}

@Test func mariadbContainer_rootConnectionString() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = MariaDBContainerRequest()
        .withRootPassword("rootsecret")

    try await withMariaDBContainer(request) { mariadb in
        let rootConnectionString = try await mariadb.rootConnectionString()
        #expect(rootConnectionString.hasPrefix("mysql://root:rootsecret@"))
    }
}

@Test func mariadbContainer_connectionStringWithParameters() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withMariaDBContainer(MariaDBContainerRequest()) { mariadb in
        let connectionString = try await mariadb.connectionString(
            parameters: ["charset": "utf8mb4", "parseTime": "true"]
        )
        #expect(connectionString.contains("charset=utf8mb4"))
        #expect(connectionString.contains("parseTime=true"))
    }
}

@Test func mariadbContainer_rootOnlyMode() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = MariaDBContainerRequest()
        .withRootOnly()
        .withRootPassword("rootonly")

    try await withMariaDBContainer(request) { mariadb in
        // Non-root connection should fail
        do {
            _ = try await mariadb.connectionString()
            Issue.record("Expected error for root-only container")
        } catch {
            // Expected - no non-root user configured
        }

        // Root connection should work
        let rootConnectionString = try await mariadb.rootConnectionString()
        #expect(rootConnectionString.hasPrefix("mysql://root:rootonly@"))
    }
}

@Test func mariadbContainer_logs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withMariaDBContainer(MariaDBContainerRequest()) { mariadb in
        let logs = try await mariadb.logs()
        #expect(logs.contains("MariaDB") || logs.contains("mariadb") || logs.contains("ready for connections"))
    }
}

@Test func mariadbContainer_id() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withMariaDBContainer(MariaDBContainerRequest()) { mariadb in
        let id = await mariadb.id
        #expect(!id.isEmpty)
    }
}

@Test func mariadbContainer_host() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = MariaDBContainerRequest()
        .withHost("127.0.0.1")

    try await withMariaDBContainer(request) { mariadb in
        #expect(mariadb.host() == "127.0.0.1")
    }
}

@Test func mariadbContainer_database() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = MariaDBContainerRequest()
        .withDatabase("customdb")

    try await withMariaDBContainer(request) { mariadb in
        #expect(mariadb.database() == "customdb")
    }
}

@Test func mariadbContainer_username() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = MariaDBContainerRequest()
        .withUsername("customuser", password: "custompass")

    try await withMariaDBContainer(request) { mariadb in
        #expect(mariadb.username() == "customuser")
    }
}

@Test func mariadbContainer_scopedMethodHelper() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await MariaDBContainerRequest().withContainer { mariadb in
        let connectionString = try await mariadb.connectionString()
        #expect(connectionString.hasPrefix("mysql://"))
    }
}

@Test func mariadbContainer_underlyingContainerConnectionStringHelpers() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withMariaDBContainer(MariaDBContainerRequest()) { mariadb in
        let generic = await mariadb.underlyingContainer
        let userURL = try await generic.mariadbConnectionString()
        let rootURL = try await generic.mariadbRootConnectionString()

        #expect(userURL.hasPrefix("mysql://test:test@"))
        #expect(rootURL.hasPrefix("mysql://root:test@"))
    }
}
