import Foundation
import Testing
@testable import TestContainers

// MARK: - VaultContainerRequest Unit Tests

@Test func vaultContainerRequest_defaultValues() {
    let request = VaultContainerRequest()

    #expect(request.image == "hashicorp/vault:latest")
    #expect(request.vaultPort == 8200)
    #expect(request.host == "127.0.0.1")
    #expect(!request.rootToken.isEmpty)
    #expect(request.initCommands.isEmpty)
    #expect(request.environment.isEmpty)
    #expect(request.waitStrategy == nil)
}

@Test func vaultContainerRequest_customImage() {
    let request = VaultContainerRequest(image: "hashicorp/vault:1.17")

    #expect(request.image == "hashicorp/vault:1.17")
}

@Test func vaultContainerRequest_withRootToken() {
    let request = VaultContainerRequest()
        .withRootToken("my-custom-token")

    #expect(request.rootToken == "my-custom-token")
}

@Test func vaultContainerRequest_withVaultPort() {
    let request = VaultContainerRequest()
        .withVaultPort(9200)

    #expect(request.vaultPort == 9200)
}

@Test func vaultContainerRequest_withHost() {
    let request = VaultContainerRequest()
        .withHost("0.0.0.0")

    #expect(request.host == "0.0.0.0")
}

@Test func vaultContainerRequest_withEnvironment() {
    let request = VaultContainerRequest()
        .withEnvironment(["VAULT_LOG_LEVEL": "debug"])

    #expect(request.environment["VAULT_LOG_LEVEL"] == "debug")
}

@Test func vaultContainerRequest_withInitCommand() {
    let request = VaultContainerRequest()
        .withInitCommand("secrets enable transit")

    #expect(request.initCommands.count == 1)
    #expect(request.initCommands[0] == "secrets enable transit")
}

@Test func vaultContainerRequest_withMultipleInitCommands() {
    let request = VaultContainerRequest()
        .withInitCommand("secrets enable transit")
        .withInitCommand("write -f transit/keys/my-key")

    #expect(request.initCommands.count == 2)
    #expect(request.initCommands[0] == "secrets enable transit")
    #expect(request.initCommands[1] == "write -f transit/keys/my-key")
}

@Test func vaultContainerRequest_withInitCommands() {
    let request = VaultContainerRequest()
        .withInitCommands([
            "secrets enable transit",
            "write -f transit/keys/my-key"
        ])

    #expect(request.initCommands.count == 2)
}

@Test func vaultContainerRequest_withSecret() {
    let request = VaultContainerRequest()
        .withSecret("secret/data/myapp", ["key1": "value1", "key2": "value2"])

    #expect(request.initCommands.count == 1)
    #expect(request.initCommands[0].contains("kv put"))
    #expect(request.initCommands[0].contains("secret/data/myapp"))
}

@Test func vaultContainerRequest_withMultipleSecrets() {
    let request = VaultContainerRequest()
        .withSecret("secret/data/app1", ["key1": "value1"])
        .withSecret("secret/data/app2", ["key2": "value2"])

    #expect(request.initCommands.count == 2)
}

@Test func vaultContainerRequest_withWaitStrategy() {
    let request = VaultContainerRequest()
        .withWaitStrategy(.logContains("Development mode", timeout: .seconds(30)))

    if case let .logContains(text, timeout, _) = request.waitStrategy {
        #expect(text == "Development mode")
        #expect(timeout == .seconds(30))
    } else {
        Issue.record("Expected logContains wait strategy")
    }
}

@Test func vaultContainerRequest_methodChaining() {
    let request = VaultContainerRequest(image: "hashicorp/vault:1.17")
        .withRootToken("root")
        .withVaultPort(8200)
        .withHost("127.0.0.1")
        .withEnvironment(["VAULT_LOG_LEVEL": "debug"])
        .withInitCommand("secrets enable transit")
        .withSecret("secret/data/myapp", ["key": "value"])

    #expect(request.image == "hashicorp/vault:1.17")
    #expect(request.rootToken == "root")
    #expect(request.vaultPort == 8200)
    #expect(request.host == "127.0.0.1")
    #expect(request.environment["VAULT_LOG_LEVEL"] == "debug")
    #expect(request.initCommands.count == 2)
}

@Test func vaultContainerRequest_isHashable() {
    let request1 = VaultContainerRequest()
        .withRootToken("token1")
        .withVaultPort(8200)
    let request2 = VaultContainerRequest()
        .withRootToken("token1")
        .withVaultPort(8200)
    let request3 = VaultContainerRequest()
        .withRootToken("token2")
        .withVaultPort(8200)

    #expect(request1 == request2)
    #expect(request1 != request3)
}

// MARK: - toContainerRequest Tests

@Test func vaultContainerRequest_toContainerRequest_setsDevMode() {
    let request = VaultContainerRequest()
        .withRootToken("test-token")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.environment["VAULT_DEV_ROOT_TOKEN_ID"] == "test-token")
    #expect(containerRequest.environment["VAULT_DEV_LISTEN_ADDRESS"] == "0.0.0.0:8200")
}

@Test func vaultContainerRequest_toContainerRequest_setsImage() {
    let request = VaultContainerRequest(image: "hashicorp/vault:1.17")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.image == "hashicorp/vault:1.17")
}

@Test func vaultContainerRequest_toContainerRequest_setsPort() {
    let request = VaultContainerRequest()
        .withVaultPort(8200)

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.ports.contains { $0.containerPort == 8200 })
}

@Test func vaultContainerRequest_toContainerRequest_setsHost() {
    let request = VaultContainerRequest()
        .withHost("localhost")

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.host == "localhost")
}

@Test func vaultContainerRequest_toContainerRequest_mergesEnvironment() {
    let request = VaultContainerRequest()
        .withRootToken("token")
        .withEnvironment(["VAULT_LOG_LEVEL": "debug"])

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.environment["VAULT_DEV_ROOT_TOKEN_ID"] == "token")
    #expect(containerRequest.environment["VAULT_LOG_LEVEL"] == "debug")
}

@Test func vaultContainerRequest_toContainerRequest_defaultWaitStrategy() {
    let request = VaultContainerRequest()

    let containerRequest = request.toContainerRequest()

    if case let .http(config) = containerRequest.waitStrategy {
        #expect(config.port == 8200)
        #expect(config.path == "/v1/sys/health")
    } else {
        Issue.record("Expected HTTP wait strategy, got \(containerRequest.waitStrategy)")
    }
}

@Test func vaultContainerRequest_toContainerRequest_customWaitStrategy() {
    let request = VaultContainerRequest()
        .withWaitStrategy(.logContains("ready"))

    let containerRequest = request.toContainerRequest()

    if case let .logContains(text, _, _) = containerRequest.waitStrategy {
        #expect(text == "ready")
    } else {
        Issue.record("Expected logContains wait strategy")
    }
}

@Test func vaultContainerRequest_toContainerRequest_customPort() {
    let request = VaultContainerRequest()
        .withVaultPort(9200)

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.environment["VAULT_DEV_LISTEN_ADDRESS"] == "0.0.0.0:9200")
    #expect(containerRequest.ports.contains { $0.containerPort == 9200 })
}

// MARK: - Integration Tests

@Test func vaultContainer_startsSuccessfully() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withVaultContainer(VaultContainerRequest()) { vault in
        let address = try await vault.httpHostAddress()
        let token = vault.rootToken()

        #expect(address.hasPrefix("http://"))
        #expect(!token.isEmpty)
    }
}

@Test func vaultContainer_customToken() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = VaultContainerRequest()
        .withRootToken("my-test-token")

    try await withVaultContainer(request) { vault in
        #expect(vault.rootToken() == "my-test-token")
    }
}

@Test func vaultContainer_hostPort() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withVaultContainer(VaultContainerRequest()) { vault in
        let port = try await vault.hostPort()
        #expect(port > 0)
    }
}

@Test func vaultContainer_httpHostAddress() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withVaultContainer(VaultContainerRequest()) { vault in
        let address = try await vault.httpHostAddress()
        #expect(address.hasPrefix("http://"))
        #expect(address.contains(":"))
    }
}

@Test func vaultContainer_logs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withVaultContainer(VaultContainerRequest()) { vault in
        let logs = try await vault.logs()
        #expect(logs.contains("Vault") || logs.contains("vault"))
    }
}

@Test func vaultContainer_withInitCommands() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = VaultContainerRequest()
        .withRootToken("root")
        .withInitCommand("secrets enable transit")

    try await withVaultContainer(request) { vault in
        let address = try await vault.httpHostAddress()
        #expect(!address.isEmpty)
    }
}

@Test func vaultContainer_withSecret() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = VaultContainerRequest()
        .withRootToken("root")
        .withSecret("secret/myapp", ["api-key": "test123"])

    try await withVaultContainer(request) { vault in
        let address = try await vault.httpHostAddress()
        let token = vault.rootToken()

        #expect(!address.isEmpty)
        #expect(token == "root")
    }
}

@Test func vaultContainer_customImage() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = VaultContainerRequest(image: "hashicorp/vault:1.17")
        .withRootToken("root")

    try await withVaultContainer(request) { vault in
        let logs = try await vault.logs()
        #expect(logs.contains("Vault") || logs.contains("vault"))
    }
}

@Test func vaultContainer_id() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withVaultContainer(VaultContainerRequest()) { vault in
        let id = await vault.id
        #expect(!id.isEmpty)
    }
}

@Test func vaultContainer_host() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = VaultContainerRequest()
        .withHost("127.0.0.1")

    try await withVaultContainer(request) { vault in
        let host = vault.host()
        #expect(host == "127.0.0.1")
    }
}
