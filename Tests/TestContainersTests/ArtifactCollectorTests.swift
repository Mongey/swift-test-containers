import Foundation
import Testing
@testable import TestContainers

// MARK: - ArtifactConfig Tests

@Test func artifactConfig_defaultValues() {
    let config = ArtifactConfig()

    #expect(config.enabled == true)
    #expect(config.outputDirectory == ".testcontainers-artifacts")
    #expect(config.collectLogs == true)
    #expect(config.collectMetadata == true)
    #expect(config.collectRequest == true)
}

@Test func artifactConfig_default_staticProperty() {
    let config = ArtifactConfig.default

    #expect(config.enabled == true)
    #expect(config.outputDirectory == ".testcontainers-artifacts")
}

@Test func artifactConfig_disabled_staticProperty() {
    let config = ArtifactConfig.disabled

    #expect(config.enabled == false)
}

@Test func artifactConfig_withEnabled() {
    let config = ArtifactConfig()
        .withEnabled(false)

    #expect(config.enabled == false)
}

@Test func artifactConfig_withOutputDirectory() {
    let config = ArtifactConfig()
        .withOutputDirectory("/tmp/my-artifacts")

    #expect(config.outputDirectory == "/tmp/my-artifacts")
}

@Test func artifactConfig_withCollectLogs() {
    let config = ArtifactConfig()
        .withCollectLogs(false)

    #expect(config.collectLogs == false)
}

@Test func artifactConfig_withCollectMetadata() {
    let config = ArtifactConfig()
        .withCollectMetadata(false)

    #expect(config.collectMetadata == false)
}

@Test func artifactConfig_withCollectRequest() {
    let config = ArtifactConfig()
        .withCollectRequest(false)

    #expect(config.collectRequest == false)
}

@Test func artifactConfig_withTrigger_onFailure() {
    let config = ArtifactConfig()
        .withTrigger(.onFailure)

    if case .onFailure = config.trigger {
        // Expected
    } else {
        Issue.record("Expected onFailure trigger")
    }
}

@Test func artifactConfig_withTrigger_always() {
    let config = ArtifactConfig()
        .withTrigger(.always)

    if case .always = config.trigger {
        // Expected
    } else {
        Issue.record("Expected always trigger")
    }
}

@Test func artifactConfig_withTrigger_onTimeout() {
    let config = ArtifactConfig()
        .withTrigger(.onTimeout)

    if case .onTimeout = config.trigger {
        // Expected
    } else {
        Issue.record("Expected onTimeout trigger")
    }
}

@Test func artifactConfig_withRetentionPolicy_keepAll() {
    let config = ArtifactConfig()
        .withRetentionPolicy(.keepAll)

    if case .keepAll = config.retentionPolicy {
        // Expected
    } else {
        Issue.record("Expected keepAll retention policy")
    }
}

@Test func artifactConfig_withRetentionPolicy_keepLast() {
    let config = ArtifactConfig()
        .withRetentionPolicy(.keepLast(5))

    if case let .keepLast(count) = config.retentionPolicy {
        #expect(count == 5)
    } else {
        Issue.record("Expected keepLast retention policy")
    }
}

@Test func artifactConfig_withRetentionPolicy_keepForDays() {
    let config = ArtifactConfig()
        .withRetentionPolicy(.keepForDays(7))

    if case let .keepForDays(days) = config.retentionPolicy {
        #expect(days == 7)
    } else {
        Issue.record("Expected keepForDays retention policy")
    }
}

@Test func artifactConfig_chainedBuilders() {
    let config = ArtifactConfig()
        .withEnabled(true)
        .withOutputDirectory("/custom/path")
        .withCollectLogs(true)
        .withCollectMetadata(false)
        .withTrigger(.always)
        .withRetentionPolicy(.keepLast(10))

    #expect(config.enabled == true)
    #expect(config.outputDirectory == "/custom/path")
    #expect(config.collectLogs == true)
    #expect(config.collectMetadata == false)

    if case .always = config.trigger {
        // Expected
    } else {
        Issue.record("Expected always trigger")
    }

    if case let .keepLast(count) = config.retentionPolicy {
        #expect(count == 10)
    } else {
        Issue.record("Expected keepLast retention policy")
    }
}

@Test func artifactConfig_immutability() {
    let original = ArtifactConfig()
    let modified = original.withEnabled(false)

    #expect(original.enabled == true)
    #expect(modified.enabled == false)
}

@Test func artifactConfig_conformsToSendable() {
    let config = ArtifactConfig()

    Task {
        let _ = config.enabled
    }
}

// MARK: - CollectionTrigger Tests

@Test func collectionTrigger_onFailure_defaultValue() {
    let config = ArtifactConfig()

    if case .onFailure = config.trigger {
        // Expected default
    } else {
        Issue.record("Expected onFailure as default trigger")
    }
}

// MARK: - RetentionPolicy Tests

@Test func retentionPolicy_keepLast_defaultValue() {
    let config = ArtifactConfig()

    if case let .keepLast(count) = config.retentionPolicy {
        #expect(count == 10)  // Default is keepLast(10)
    } else {
        Issue.record("Expected keepLast(10) as default retention policy")
    }
}

// MARK: - ContainerArtifact Tests

@Test func containerArtifact_initializesWithAllFields() {
    let artifact = ContainerArtifact(
        containerId: "abc123",
        imageName: "redis:7",
        containerName: "my-redis",
        captureTime: Date(),
        containerState: "running",
        exitCode: nil,
        environment: ["REDIS_VERSION": "7.0"],
        labels: ["testcontainers.swift": "true"],
        ports: ["6379/tcp -> 0.0.0.0:54321"],
        inspectJSON: "{}"
    )

    #expect(artifact.containerId == "abc123")
    #expect(artifact.imageName == "redis:7")
    #expect(artifact.containerName == "my-redis")
    #expect(artifact.containerState == "running")
    #expect(artifact.exitCode == nil)
    #expect(artifact.environment["REDIS_VERSION"] == "7.0")
    #expect(artifact.labels["testcontainers.swift"] == "true")
    #expect(artifact.ports.first == "6379/tcp -> 0.0.0.0:54321")
}

@Test func containerArtifact_encodesToJSON() throws {
    let artifact = ContainerArtifact(
        containerId: "abc123",
        imageName: "redis:7",
        containerName: nil,
        captureTime: Date(timeIntervalSince1970: 1700000000),
        containerState: "exited",
        exitCode: 0,
        environment: [:],
        labels: [:],
        ports: [],
        inspectJSON: nil
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(artifact)
    let json = String(data: data, encoding: .utf8)

    #expect(json != nil)
    #expect(json!.contains("abc123"))
    #expect(json!.contains("redis:7"))
}

@Test func containerArtifact_decodesFromJSON() throws {
    let json = """
    {
        "containerId": "def456",
        "imageName": "postgres:15",
        "containerName": "test-postgres",
        "captureTime": 1700000000,
        "containerState": "running",
        "exitCode": null,
        "environment": {"POSTGRES_DB": "test"},
        "labels": {},
        "ports": ["5432/tcp -> 0.0.0.0:54322"],
        "inspectJSON": null
    }
    """

    let decoder = JSONDecoder()
    let data = Data(json.utf8)
    let artifact = try decoder.decode(ContainerArtifact.self, from: data)

    #expect(artifact.containerId == "def456")
    #expect(artifact.imageName == "postgres:15")
    #expect(artifact.containerName == "test-postgres")
    #expect(artifact.environment["POSTGRES_DB"] == "test")
}

@Test func containerArtifact_conformsToSendable() {
    let artifact = ContainerArtifact(
        containerId: "abc123",
        imageName: "redis:7",
        containerName: nil,
        captureTime: Date(),
        containerState: "running",
        exitCode: nil,
        environment: [:],
        labels: [:],
        ports: [],
        inspectJSON: nil
    )

    Task {
        let _ = artifact.containerId
    }
}

// MARK: - ArtifactCollection Tests

@Test func artifactCollection_initializesWithAllFields() {
    let collection = ArtifactCollection(
        artifactDirectory: "/tmp/artifacts/test",
        logsFile: "/tmp/artifacts/test/logs.txt",
        metadataFile: "/tmp/artifacts/test/metadata.json",
        requestFile: "/tmp/artifacts/test/request.json",
        errorFile: "/tmp/artifacts/test/error.txt"
    )

    #expect(collection.artifactDirectory == "/tmp/artifacts/test")
    #expect(collection.logsFile == "/tmp/artifacts/test/logs.txt")
    #expect(collection.metadataFile == "/tmp/artifacts/test/metadata.json")
    #expect(collection.requestFile == "/tmp/artifacts/test/request.json")
    #expect(collection.errorFile == "/tmp/artifacts/test/error.txt")
}

@Test func artifactCollection_isEmpty_whenAllFilesNil() {
    let collection = ArtifactCollection(
        artifactDirectory: "/tmp/artifacts/test",
        logsFile: nil,
        metadataFile: nil,
        requestFile: nil,
        errorFile: nil
    )

    #expect(collection.isEmpty == true)
}

@Test func artifactCollection_isEmpty_whenHasLogs() {
    let collection = ArtifactCollection(
        artifactDirectory: "/tmp/artifacts/test",
        logsFile: "/tmp/artifacts/test/logs.txt",
        metadataFile: nil,
        requestFile: nil,
        errorFile: nil
    )

    #expect(collection.isEmpty == false)
}

@Test func artifactCollection_isEmpty_whenHasMetadata() {
    let collection = ArtifactCollection(
        artifactDirectory: "/tmp/artifacts/test",
        logsFile: nil,
        metadataFile: "/tmp/artifacts/test/metadata.json",
        requestFile: nil,
        errorFile: nil
    )

    #expect(collection.isEmpty == false)
}

@Test func artifactCollection_conformsToSendable() {
    let collection = ArtifactCollection(
        artifactDirectory: "/tmp/test",
        logsFile: nil,
        metadataFile: nil,
        requestFile: nil,
        errorFile: nil
    )

    Task {
        let _ = collection.artifactDirectory
    }
}

// MARK: - ArtifactCollector Tests

@Test func artifactCollector_initializesWithDefaultConfig() async {
    let collector = ArtifactCollector()
    let config = await collector.configuration

    #expect(config.enabled == true)
}

@Test func artifactCollector_initializesWithCustomConfig() async {
    let customConfig = ArtifactConfig()
        .withEnabled(false)

    let collector = ArtifactCollector(config: customConfig)
    let config = await collector.configuration

    #expect(config.enabled == false)
}

@Test func artifactCollector_shouldCollect_onFailure_withError() async {
    let config = ArtifactConfig()
        .withTrigger(.onFailure)

    let collector = ArtifactCollector(config: config)
    let error = TestContainersError.timeout("test timeout")

    let shouldCollect = await collector.shouldCollect(error: error)
    #expect(shouldCollect == true)
}

@Test func artifactCollector_shouldCollect_onFailure_withoutError() async {
    let config = ArtifactConfig()
        .withTrigger(.onFailure)

    let collector = ArtifactCollector(config: config)

    let shouldCollect = await collector.shouldCollect(error: nil)
    #expect(shouldCollect == false)
}

@Test func artifactCollector_shouldCollect_always_withError() async {
    let config = ArtifactConfig()
        .withTrigger(.always)

    let collector = ArtifactCollector(config: config)
    let error = TestContainersError.timeout("test timeout")

    let shouldCollect = await collector.shouldCollect(error: error)
    #expect(shouldCollect == true)
}

@Test func artifactCollector_shouldCollect_always_withoutError() async {
    let config = ArtifactConfig()
        .withTrigger(.always)

    let collector = ArtifactCollector(config: config)

    let shouldCollect = await collector.shouldCollect(error: nil)
    #expect(shouldCollect == true)
}

@Test func artifactCollector_shouldCollect_onTimeout_withTimeoutError() async {
    let config = ArtifactConfig()
        .withTrigger(.onTimeout)

    let collector = ArtifactCollector(config: config)
    let error = TestContainersError.timeout("test timeout")

    let shouldCollect = await collector.shouldCollect(error: error)
    #expect(shouldCollect == true)
}

@Test func artifactCollector_shouldCollect_onTimeout_withOtherError() async {
    let config = ArtifactConfig()
        .withTrigger(.onTimeout)

    let collector = ArtifactCollector(config: config)
    let error = TestContainersError.dockerNotAvailable("not available")

    let shouldCollect = await collector.shouldCollect(error: error)
    #expect(shouldCollect == false)
}

@Test func artifactCollector_shouldCollect_disabled() async {
    let config = ArtifactConfig()
        .withEnabled(false)

    let collector = ArtifactCollector(config: config)
    let error = TestContainersError.timeout("test timeout")

    let shouldCollect = await collector.shouldCollect(error: error)
    #expect(shouldCollect == false)
}

@Test func artifactCollector_makeArtifactDirectory_createsCorrectPath() async {
    let config = ArtifactConfig()
        .withOutputDirectory("/tmp/artifacts")

    let collector = ArtifactCollector(config: config)
    let path = await collector.makeArtifactDirectory(testName: "MyTests.testExample", containerId: "abc123")

    #expect(path.hasPrefix("/tmp/artifacts/MyTests.testExample/abc123_"))
}

@Test func artifactCollector_makeArtifactDirectory_sanitizesTestName() async {
    let config = ArtifactConfig()
        .withOutputDirectory("/tmp/artifacts")

    let collector = ArtifactCollector(config: config)

    // Test names with special characters should be sanitized
    let path = await collector.makeArtifactDirectory(testName: "My/Test:Name", containerId: "abc123")

    #expect(!path.contains(":"))
}

@Test func artifactCollector_conformsToSendable() async {
    let collector = ArtifactCollector()

    Task {
        let _ = await collector.configuration
    }
}

// MARK: - ContainerRequest.withArtifacts Tests

@Test func containerRequest_withArtifacts_default() {
    let request = ContainerRequest(image: "redis:7")
        .withArtifacts(.default)

    #expect(request.artifactConfig.enabled == true)
    #expect(request.artifactConfig.outputDirectory == ".testcontainers-artifacts")
}

@Test func containerRequest_withArtifacts_custom() {
    let config = ArtifactConfig()
        .withOutputDirectory("/custom/path")
        .withTrigger(.always)

    let request = ContainerRequest(image: "redis:7")
        .withArtifacts(config)

    #expect(request.artifactConfig.outputDirectory == "/custom/path")
    if case .always = request.artifactConfig.trigger {
        // Expected
    } else {
        Issue.record("Expected always trigger")
    }
}

@Test func containerRequest_withoutArtifacts() {
    let request = ContainerRequest(image: "redis:7")
        .withoutArtifacts()

    #expect(request.artifactConfig.enabled == false)
}

@Test func containerRequest_artifactConfig_defaultValue() {
    let request = ContainerRequest(image: "redis:7")

    // Default should be enabled with onFailure trigger
    #expect(request.artifactConfig.enabled == true)
    if case .onFailure = request.artifactConfig.trigger {
        // Expected
    } else {
        Issue.record("Expected onFailure as default trigger")
    }
}

@Test func containerRequest_withArtifacts_preservesOtherConfig() {
    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .withEnvironment(["KEY": "value"])
        .withArtifacts(.disabled)

    #expect(request.image == "redis:7")
    #expect(request.ports.count == 1)
    #expect(request.environment["KEY"] == "value")
    #expect(request.artifactConfig.enabled == false)
}

@Test func containerRequest_withArtifacts_returnsNewInstance() {
    let original = ContainerRequest(image: "redis:7")
    let modified = original.withArtifacts(.disabled)

    #expect(original.artifactConfig.enabled == true)
    #expect(modified.artifactConfig.enabled == false)
}

@Test func containerRequest_artifactConfig_isHashable() {
    let request1 = ContainerRequest(image: "redis:7")
        .withArtifacts(.default)
    let request2 = ContainerRequest(image: "redis:7")
        .withArtifacts(.default)

    // Hashable conformance should work
    #expect(request1.hashValue == request2.hashValue)
}

// MARK: - withContainer Signature Tests

@Test func withContainer_acceptsTestNameParameter() async throws {
    // This test verifies the function signature accepts testName
    // We can't actually run it without Docker, but we verify it compiles
    func verifySignature() async throws {
        let request = ContainerRequest(image: "alpine:3")
        // The following line should compile with the new signature
        _ = try await withContainer(request, testName: "MyTests.testExample") { _ in
            "result"
        }
    }
    // This test verifies the function exists with the right signature
    // Just checking it compiles is the test
}
