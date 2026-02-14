import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TestContainers

// MARK: - ElasticsearchContainer Unit Tests

@Test func elasticsearchContainer_defaultValues() {
    let container = ElasticsearchContainer()

    #expect(container.image == "elasticsearch:8.11.0")
    #expect(container.port == 9200)
    #expect(container.host == "127.0.0.1")
    #expect(container.username == "elastic")
    #expect(container.password == "changeme")
    #expect(container.securityEnabled)
    #expect(container.environment["discovery.type"] == "single-node")
    #expect(container.environment["ES_JAVA_OPTS"] == "-Xms512m -Xmx512m")
    #expect(container.waitStrategy == nil)
}

@Test func elasticsearchContainer_es7DefaultsDisableSecurity() {
    let container = ElasticsearchContainer(image: "elasticsearch:7.17.15")

    #expect(!container.securityEnabled)
}

@Test func elasticsearchContainer_withPassword_enablesSecurityAndUpdatesPassword() {
    let container = ElasticsearchContainer(image: "elasticsearch:7.17.15")
        .withPassword("secret")

    #expect(container.securityEnabled)
    #expect(container.password == "secret")
}

@Test func elasticsearchContainer_withSecurityDisabled() {
    let container = ElasticsearchContainer()
        .withSecurityDisabled()

    #expect(!container.securityEnabled)
}

@Test func elasticsearchContainer_withPort() {
    let container = ElasticsearchContainer()
        .withPort(19200)

    #expect(container.port == 19200)
}

@Test func elasticsearchContainer_withHost() {
    let container = ElasticsearchContainer()
        .withHost("localhost")

    #expect(container.host == "localhost")
}

@Test func elasticsearchContainer_withJvmHeap() {
    let container = ElasticsearchContainer()
        .withJvmHeap(min: "256m", max: "768m")

    #expect(container.environment["ES_JAVA_OPTS"] == "-Xms256m -Xmx768m")
}

@Test func elasticsearchContainer_withConfiguration_mergesValues() {
    let container = ElasticsearchContainer()
        .withConfiguration([
            "cluster.name": "test-cluster",
            "action.auto_create_index": "false",
        ])

    #expect(container.environment["cluster.name"] == "test-cluster")
    #expect(container.environment["action.auto_create_index"] == "false")
    #expect(container.environment["discovery.type"] == "single-node")
}

@Test func elasticsearchContainer_methodChaining() {
    let container = ElasticsearchContainer(image: "elasticsearch:8.12.0")
        .withPassword("elastic-pass")
        .withJvmHeap(min: "512m", max: "1g")
        .withConfiguration(["cluster.name": "my-cluster"])
        .withPort(19200)
        .withHost("localhost")

    #expect(container.image == "elasticsearch:8.12.0")
    #expect(container.password == "elastic-pass")
    #expect(container.environment["ES_JAVA_OPTS"] == "-Xms512m -Xmx1g")
    #expect(container.environment["cluster.name"] == "my-cluster")
    #expect(container.port == 19200)
    #expect(container.host == "localhost")
}

@Test func elasticsearchContainer_builderReturnsNewInstance() {
    let original = ElasticsearchContainer()
    let modified = original.withPassword("newpass")

    #expect(original.password == "changeme")
    #expect(modified.password == "newpass")
}

@Test func elasticsearchContainer_toContainerRequest_configuresSecurityAndWaitForEs8() {
    let request = ElasticsearchContainer().toContainerRequest()

    #expect(request.image == "elasticsearch:8.11.0")
    #expect(request.environment["xpack.security.enabled"] == "true")
    #expect(request.environment["ELASTIC_PASSWORD"] == "changeme")
    #expect(request.ports.contains { $0.containerPort == 9200 })

    if case let .http(config) = request.waitStrategy {
        #expect(config.port == 9200)
        #expect(config.path == "/_cluster/health")
        #expect(config.useTLS)
        #expect(config.allowInsecureTLS)

        let expectedAuth = "Basic \(Data("elastic:changeme".utf8).base64EncodedString())"
        #expect(config.headers["Authorization"] == expectedAuth)

        if case let .regex(pattern)? = config.bodyMatcher {
            #expect(pattern.contains("yellow"))
            #expect(pattern.contains("green"))
        } else {
            Issue.record("Expected regex body matcher")
        }
    } else {
        Issue.record("Expected HTTP wait strategy, got \(String(describing: request.waitStrategy))")
    }
}

@Test func elasticsearchContainer_toContainerRequest_configuresHttpWhenSecurityDisabled() {
    let request = ElasticsearchContainer()
        .withSecurityDisabled()
        .toContainerRequest()

    #expect(request.environment["xpack.security.enabled"] == "false")
    #expect(request.environment["ELASTIC_PASSWORD"] == nil)

    if case let .http(config) = request.waitStrategy {
        #expect(!config.useTLS)
        #expect(config.headers["Authorization"] == nil)
    } else {
        Issue.record("Expected HTTP wait strategy")
    }
}

@Test func elasticsearchContainer_toContainerRequest_customWaitStrategyOverridesDefault() {
    let request = ElasticsearchContainer()
        .waitingFor(.tcpPort(9200, timeout: .seconds(90)))
        .toContainerRequest()

    if case let .tcpPort(port, timeout, _) = request.waitStrategy {
        #expect(port == 9200)
        #expect(timeout == .seconds(90))
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

@Test func elasticsearchSettings_supportsOptionalCredentialsAndCACert() {
    let caCert = Data([0x01, 0x02, 0x03])
    let secured = ElasticsearchSettings(
        address: "https://127.0.0.1:9200",
        username: "elastic",
        password: "secret",
        caCert: caCert
    )
    let insecure = ElasticsearchSettings(
        address: "http://127.0.0.1:9200",
        username: nil,
        password: nil,
        caCert: nil
    )

    #expect(secured.address.hasPrefix("https://"))
    #expect(secured.username == "elastic")
    #expect(secured.password == "secret")
    #expect(secured.caCert == caCert)

    #expect(insecure.username == nil)
    #expect(insecure.password == nil)
    #expect(insecure.caCert == nil)
}

// MARK: - Elasticsearch Integration Tests

@Test func elasticsearchContainer_startsWithSecurityDisabled() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let container = ElasticsearchContainer()
        .withSecurityDisabled()
        .withJvmHeap(min: "256m", max: "256m")

    try await withElasticsearchContainer(container) { running in
        let address = try await running.httpAddress()
        #expect(address.hasPrefix("http://"))

        let settings = try await running.settings()
        #expect(settings.address == address)
        #expect(settings.username == nil)
        #expect(settings.password == nil)
        #expect(settings.caCert == nil)

        let healthURL = URL(string: "\(address)/_cluster/health")!
        let (_, response) = try await URLSession.shared.data(from: healthURL)
        let httpResponse = response as? HTTPURLResponse
        #expect(httpResponse?.statusCode == 200)
    }
}

@Test func elasticsearchContainer_defaultSecurityReturnsHttpsSettings() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let container = ElasticsearchContainer()
        .withJvmHeap(min: "256m", max: "256m")

    try await withElasticsearchContainer(container) { running in
        let settings = try await running.settings()

        #expect(settings.address.hasPrefix("https://"))
        #expect(settings.username == "elastic")
        #expect(settings.password == "changeme")
    }
}
