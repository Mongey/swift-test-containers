import Foundation
import Testing
@testable import TestContainers

// MARK: - TestContainersSession Tests

@Test func session_generatesUniqueId() {
    let session1 = TestContainersSession()
    let session2 = TestContainersSession()

    #expect(!session1.id.isEmpty)
    #expect(!session2.id.isEmpty)
    #expect(session1.id != session2.id)
}

@Test func session_capturesProcessId() {
    let session = TestContainersSession()

    #expect(session.processId == ProcessInfo.processInfo.processIdentifier)
}

@Test func session_capturesStartTime() {
    let before = Date()
    let session = TestContainersSession()
    let after = Date()

    #expect(session.startTime >= before)
    #expect(session.startTime <= after)
}

@Test func session_generatesSessionLabels() {
    let session = TestContainersSession()
    let labels = session.sessionLabels

    #expect(labels["testcontainers.swift.session.id"] == session.id)
    #expect(labels["testcontainers.swift.session.pid"] == String(session.processId))
    #expect(labels["testcontainers.swift.session.started"] != nil)

    // Verify timestamp is a valid integer
    let timestampString = labels["testcontainers.swift.session.started"]!
    #expect(Int(timestampString) != nil)
}

@Test func session_conformsToSendable() {
    let session = TestContainersSession()

    // Verify we can pass it across concurrency boundaries
    Task {
        let _ = session.id
    }
}

@Test func currentTestSession_existsAndIsValid() {
    #expect(!currentTestSession.id.isEmpty)
    #expect(currentTestSession.processId > 0)
}

// MARK: - TestContainersCleanupConfig Tests

@Test func cleanupConfig_defaultValues() {
    let config = TestContainersCleanupConfig()

    #expect(config.automaticCleanupEnabled == false)
    #expect(config.ageThresholdSeconds == 600)  // 10 minutes
    #expect(config.sessionLabelsEnabled == true)
    #expect(config.customLabelFilters.isEmpty)
    #expect(config.dryRun == false)
    #expect(config.verbose == false)
}

@Test func cleanupConfig_withAutomaticCleanup() {
    let config = TestContainersCleanupConfig()
        .withAutomaticCleanup(true)

    #expect(config.automaticCleanupEnabled == true)
}

@Test func cleanupConfig_withAgeThreshold() {
    let config = TestContainersCleanupConfig()
        .withAgeThreshold(300)

    #expect(config.ageThresholdSeconds == 300)
}

@Test func cleanupConfig_withSessionLabels() {
    let config = TestContainersCleanupConfig()
        .withSessionLabels(false)

    #expect(config.sessionLabelsEnabled == false)
}

@Test func cleanupConfig_withCustomLabelFilter() {
    let config = TestContainersCleanupConfig()
        .withCustomLabelFilter("test.key", "test.value")
        .withCustomLabelFilter("another.key", "another.value")

    #expect(config.customLabelFilters.count == 2)
    #expect(config.customLabelFilters["test.key"] == "test.value")
    #expect(config.customLabelFilters["another.key"] == "another.value")
}

@Test func cleanupConfig_withDryRun() {
    let config = TestContainersCleanupConfig()
        .withDryRun(true)

    #expect(config.dryRun == true)
}

@Test func cleanupConfig_withVerbose() {
    let config = TestContainersCleanupConfig()
        .withVerbose(true)

    #expect(config.verbose == true)
}

@Test func cleanupConfig_chainingMultipleOptions() {
    let config = TestContainersCleanupConfig()
        .withAutomaticCleanup(true)
        .withAgeThreshold(120)
        .withDryRun(true)
        .withVerbose(true)
        .withCustomLabelFilter("env", "test")

    #expect(config.automaticCleanupEnabled == true)
    #expect(config.ageThresholdSeconds == 120)
    #expect(config.dryRun == true)
    #expect(config.verbose == true)
    #expect(config.customLabelFilters["env"] == "test")
}

@Test func cleanupConfig_immutability() {
    let original = TestContainersCleanupConfig()
    let modified = original.withAutomaticCleanup(true)

    #expect(original.automaticCleanupEnabled == false)
    #expect(modified.automaticCleanupEnabled == true)
}

@Test func cleanupConfig_conformsToSendable() {
    let config = TestContainersCleanupConfig()

    Task {
        let _ = config.ageThresholdSeconds
    }
}

// MARK: - CleanupResult Tests

@Test func cleanupResult_defaultValues() {
    let result = CleanupResult(
        containersFound: 5,
        containersRemoved: 3,
        containersFailed: 2,
        containers: [],
        errors: []
    )

    #expect(result.containersFound == 5)
    #expect(result.containersRemoved == 3)
    #expect(result.containersFailed == 2)
    #expect(result.containers.isEmpty)
    #expect(result.errors.isEmpty)
}

@Test func cleanupResult_containerInfo() {
    let info = CleanupResult.CleanupContainerInfo(
        id: "abc123",
        name: "test-container",
        image: "alpine:3",
        createdAt: Date(),
        age: 120.5,
        labels: ["key": "value"],
        removed: true,
        error: nil
    )

    #expect(info.id == "abc123")
    #expect(info.name == "test-container")
    #expect(info.image == "alpine:3")
    #expect(info.age == 120.5)
    #expect(info.labels["key"] == "value")
    #expect(info.removed == true)
    #expect(info.error == nil)
}

@Test func cleanupResult_containerInfoWithError() {
    let info = CleanupResult.CleanupContainerInfo(
        id: "def456",
        name: nil,
        image: "redis:7",
        createdAt: Date(),
        age: 60.0,
        labels: [:],
        removed: false,
        error: "Container in use"
    )

    #expect(info.removed == false)
    #expect(info.error == "Container in use")
}

// MARK: - CleanupError Tests

@Test func cleanupError_dockerUnavailable_description() {
    let error = CleanupError.dockerUnavailable

    #expect(error.description.contains("Docker"))
    #expect(error.description.contains("unavailable"))
}

@Test func cleanupError_containerRemovalFailed_description() {
    let error = CleanupError.containerRemovalFailed(id: "abc123", reason: "Container is running")

    #expect(error.description.contains("abc123"))
    #expect(error.description.contains("Container is running"))
}

@Test func cleanupError_inspectionFailed_description() {
    let error = CleanupError.inspectionFailed(id: "xyz789", reason: "Not found")

    #expect(error.description.contains("xyz789"))
    #expect(error.description.contains("Not found"))
}

// MARK: - ContainerRequest.withSessionLabels Tests

@Test func containerRequest_withSessionLabels_addsLabels() {
    let request = ContainerRequest(image: "alpine:3")
        .withSessionLabels()

    #expect(request.labels["testcontainers.swift.session.id"] != nil)
    #expect(request.labels["testcontainers.swift.session.pid"] != nil)
    #expect(request.labels["testcontainers.swift.session.started"] != nil)
}

@Test func containerRequest_withSessionLabels_preservesExistingLabels() {
    let request = ContainerRequest(image: "alpine:3")
        .withLabel("custom", "value")
        .withSessionLabels()

    #expect(request.labels["custom"] == "value")
    #expect(request.labels["testcontainers.swift"] == "true")  // default label
    #expect(request.labels["testcontainers.swift.session.id"] != nil)
}

@Test func containerRequest_withSessionLabels_returnsNewInstance() {
    let original = ContainerRequest(image: "alpine:3")
    let modified = original.withSessionLabels()

    #expect(original.labels["testcontainers.swift.session.id"] == nil)
    #expect(modified.labels["testcontainers.swift.session.id"] != nil)
}

@Test func containerRequest_withSessionLabels_usesCurrentSession() {
    let request = ContainerRequest(image: "alpine:3")
        .withSessionLabels()

    #expect(request.labels["testcontainers.swift.session.id"] == currentTestSession.id)
    #expect(request.labels["testcontainers.swift.session.pid"] == String(currentTestSession.processId))
}
