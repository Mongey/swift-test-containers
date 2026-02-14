import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TestContainers

// MARK: - OpenSearchContainer Unit Tests

@Test func opensearchContainer_defaultValues() {
    let container = OpenSearchContainer()

    #expect(container.image == "opensearchproject/opensearch:2.11.1")
    #expect(container.port == 9200)
    #expect(container.host == "127.0.0.1")
    #expect(container.username == "admin")
    #expect(container.password == "admin")
    #expect(container.securityEnabled)
    #expect(container.environment["discovery.type"] == "single-node")
    #expect(container.environment["OPENSEARCH_JAVA_OPTS"] == "-Xms512m -Xmx512m")
    #expect(container.environment["DISABLE_INSTALL_DEMO_CONFIG"] == "true")
    #expect(container.waitStrategy == nil)
}

@Test func opensearchContainer_withUsername() {
    let container = OpenSearchContainer()
        .withUsername("my-admin")

    #expect(container.username == "my-admin")
}

@Test func opensearchContainer_withPassword() {
    let container = OpenSearchContainer()
        .withPassword("secret")

    #expect(container.password == "secret")
}

@Test func opensearchContainer_withSecurityDisabled() {
    let container = OpenSearchContainer()
        .withSecurityDisabled()

    #expect(!container.securityEnabled)
}

@Test func opensearchContainer_withPort() {
    let container = OpenSearchContainer()
        .withPort(19200)

    #expect(container.port == 19200)
}

@Test func opensearchContainer_withHost() {
    let container = OpenSearchContainer()
        .withHost("localhost")

    #expect(container.host == "localhost")
}

@Test func opensearchContainer_withJvmHeap() {
    let container = OpenSearchContainer()
        .withJvmHeap(min: "384m", max: "512m")

    #expect(container.environment["OPENSEARCH_JAVA_OPTS"] == "-Xms384m -Xmx512m")
}

@Test func opensearchContainer_withConfiguration_mergesValues() {
    let container = OpenSearchContainer()
        .withConfiguration([
            "cluster.name": "search-test",
            "action.auto_create_index": "false",
        ])

    #expect(container.environment["cluster.name"] == "search-test")
    #expect(container.environment["action.auto_create_index"] == "false")
    #expect(container.environment["discovery.type"] == "single-node")
}

@Test func opensearchContainer_methodChaining() {
    let container = OpenSearchContainer(image: "opensearchproject/opensearch:2.12.0")
        .withUsername("ops-admin")
        .withPassword("ops-pass")
        .withJvmHeap(min: "512m", max: "1g")
        .withConfiguration(["cluster.name": "my-search"])
        .withPort(19200)
        .withHost("localhost")

    #expect(container.image == "opensearchproject/opensearch:2.12.0")
    #expect(container.username == "ops-admin")
    #expect(container.password == "ops-pass")
    #expect(container.environment["OPENSEARCH_JAVA_OPTS"] == "-Xms512m -Xmx1g")
    #expect(container.environment["cluster.name"] == "my-search")
    #expect(container.port == 19200)
    #expect(container.host == "localhost")
}

@Test func opensearchContainer_builderReturnsNewInstance() {
    let original = OpenSearchContainer()
    let modified = original.withPassword("newpass")

    #expect(original.password == "admin")
    #expect(modified.password == "newpass")
}

@Test func opensearchContainer_toContainerRequest_defaultsUseHttpHealthWaitAndAuth() {
    let request = OpenSearchContainer().toContainerRequest()

    #expect(request.image == "opensearchproject/opensearch:2.11.1")
    #expect(request.ports.contains { $0.containerPort == 9200 })
    #expect(request.environment["DISABLE_SECURITY_PLUGIN"] == nil)

    if case let .http(config) = request.waitStrategy {
        #expect(config.port == 9200)
        #expect(config.path == "/_cluster/health")
        #expect(!config.useTLS)

        let expectedAuth = "Basic \(Data("admin:admin".utf8).base64EncodedString())"
        #expect(config.headers["Authorization"] == expectedAuth)
    } else {
        Issue.record("Expected HTTP wait strategy, got \(String(describing: request.waitStrategy))")
    }
}

@Test func opensearchContainer_toContainerRequest_securityDisabledUsesNoAuth() {
    let request = OpenSearchContainer()
        .withSecurityDisabled()
        .toContainerRequest()

    #expect(request.environment["DISABLE_SECURITY_PLUGIN"] == "true")

    if case let .http(config) = request.waitStrategy {
        #expect(config.headers["Authorization"] == nil)
    } else {
        Issue.record("Expected HTTP wait strategy")
    }
}

@Test func opensearchContainer_toContainerRequest_setsInitialAdminPasswordFor212Plus() {
    let request = OpenSearchContainer(image: "opensearchproject/opensearch:2.12.0")
        .toContainerRequest()

    #expect(request.environment["OPENSEARCH_INITIAL_ADMIN_PASSWORD"] == "admin")
}

@Test func opensearchContainer_toContainerRequest_customPasswordSetsInitialAdminPassword() {
    let request = OpenSearchContainer(image: "opensearchproject/opensearch:2.11.1")
        .withPassword("custom-admin-pass")
        .toContainerRequest()

    #expect(request.environment["OPENSEARCH_INITIAL_ADMIN_PASSWORD"] == "custom-admin-pass")
}

@Test func opensearchContainer_toContainerRequest_customWaitStrategyOverridesDefault() {
    let request = OpenSearchContainer()
        .waitingFor(.tcpPort(9200, timeout: .seconds(45)))
        .toContainerRequest()

    if case let .tcpPort(port, timeout, _) = request.waitStrategy {
        #expect(port == 9200)
        #expect(timeout == .seconds(45))
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

@Test func opensearchSettings_supportsOptionalCredentials() {
    let secured = OpenSearchSettings(
        address: "http://127.0.0.1:9200",
        username: "admin",
        password: "secret"
    )
    let insecure = OpenSearchSettings(
        address: "http://127.0.0.1:9200",
        username: nil,
        password: nil
    )

    #expect(secured.username == "admin")
    #expect(secured.password == "secret")
    #expect(insecure.username == nil)
    #expect(insecure.password == nil)
}

// MARK: - OpenSearch Integration Tests

@Test func opensearchContainer_startsWithSecurityDisabled() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let container = OpenSearchContainer()
        .withSecurityDisabled()
        .withJvmHeap(min: "256m", max: "256m")

    try await withOpenSearchContainer(container) { running in
        let address = try await running.httpAddress()
        #expect(address.hasPrefix("http://"))

        let settings = try await running.settings()
        #expect(settings.address == address)
        #expect(settings.username == nil)
        #expect(settings.password == nil)

        let healthURL = URL(string: "\(address)/_cluster/health")!
        let (_, response) = try await URLSession.shared.data(from: healthURL)
        let httpResponse = response as? HTTPURLResponse
        #expect(httpResponse?.statusCode == 200)
    }
}

@Test func opensearchContainer_defaultSettingsContainCredentials() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let container = OpenSearchContainer()
        .withJvmHeap(min: "256m", max: "256m")

    try await withOpenSearchContainer(container) { running in
        let settings = try await running.settings()

        #expect(settings.address.hasPrefix("http://"))
        #expect(settings.username == "admin")
        #expect(settings.password == "admin")
    }
}
