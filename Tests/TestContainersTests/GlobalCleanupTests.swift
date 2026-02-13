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

// MARK: - ContainerListItem Tests

@Test func containerListItem_decodesFromJSON() throws {
    let json = """
    {"ID":"abc123def456","Names":"/my-container","Image":"alpine:3","Created":1702000000,"Labels":"testcontainers.swift=true","State":"running"}
    """
    let data = Data(json.utf8)
    let item = try JSONDecoder().decode(ContainerListItem.self, from: data)

    #expect(item.id == "abc123def456")
    #expect(item.names == "/my-container")
    #expect(item.image == "alpine:3")
    #expect(item.created == 1702000000)
    #expect(item.state == "running")
}

@Test func containerListItem_decodesMultipleNames() throws {
    let json = """
    {"ID":"abc123","Names":"/name1,/name2","Image":"redis:7","Created":1702000000,"Labels":"","State":"exited"}
    """
    let data = Data(json.utf8)
    let item = try JSONDecoder().decode(ContainerListItem.self, from: data)

    #expect(item.names == "/name1,/name2")
}

@Test func containerListItem_decodesEmptyLabels() throws {
    let json = """
    {"ID":"abc123","Names":"","Image":"nginx","Created":1702000000,"Labels":"","State":"created"}
    """
    let data = Data(json.utf8)
    let item = try JSONDecoder().decode(ContainerListItem.self, from: data)

    #expect(item.labels == "")
}

@Test func containerListItem_decodesMultipleLabels() throws {
    let json = """
    {"ID":"abc123","Names":"/test","Image":"postgres:15","Created":1702000000,"Labels":"key1=value1,key2=value2","State":"running"}
    """
    let data = Data(json.utf8)
    let item = try JSONDecoder().decode(ContainerListItem.self, from: data)

    #expect(item.labels.contains("key1=value1"))
    #expect(item.labels.contains("key2=value2"))
}

@Test func containerListItem_conformsToSendable() {
    let json = """
    {"ID":"abc123","Names":"","Image":"alpine","Created":1702000000,"Labels":"","State":"running"}
    """
    let data = Data(json.utf8)
    let item = try? JSONDecoder().decode(ContainerListItem.self, from: data)

    Task {
        let _ = item?.id
    }
}

// MARK: - DockerClient.listContainersArgs Tests

@Test func listContainersArgs_noFilters() {
    let args = DockerClient.listContainersArgs(labels: [:])

    #expect(args == ["ps", "-a", "--no-trunc", "--format", "{{json .}}"])
}

@Test func listContainersArgs_singleLabelFilter() {
    let args = DockerClient.listContainersArgs(labels: ["testcontainers.swift": "true"])

    #expect(args.contains("--filter"))
    #expect(args.contains("label=testcontainers.swift=true"))
}

@Test func listContainersArgs_multipleLabelFilters() {
    let args = DockerClient.listContainersArgs(labels: [
        "testcontainers.swift": "true",
        "env": "test"
    ])

    #expect(args.contains("--filter"))
    // Both filters should be present
    let filterIndices = args.enumerated().filter { $0.element == "--filter" }.map { $0.offset }
    #expect(filterIndices.count == 2)

    // Check both label filters exist
    #expect(args.contains("label=env=test"))
    #expect(args.contains("label=testcontainers.swift=true"))
}

@Test func listContainersArgs_sortedForDeterministicOutput() {
    // Call multiple times with same labels, should produce same order
    let labels = ["z": "last", "a": "first", "m": "middle"]
    let args1 = DockerClient.listContainersArgs(labels: labels)
    let args2 = DockerClient.listContainersArgs(labels: labels)

    #expect(args1 == args2)

    // Verify alphabetical order
    let labelArgs = args1.filter { $0.starts(with: "label=") }
    #expect(labelArgs[0] == "label=a=first")
    #expect(labelArgs[1] == "label=m=middle")
    #expect(labelArgs[2] == "label=z=last")
}

// MARK: - DockerClient.parseContainerList Tests

@Test func parseContainerList_emptyOutput() throws {
    let output = ""
    let items = try DockerClient.parseContainerList(output)

    #expect(items.isEmpty)
}

@Test func parseContainerList_singleContainer() throws {
    let output = """
    {"ID":"abc123","Names":"/test-container","Image":"alpine:3","Created":1702000000,"Labels":"testcontainers.swift=true","State":"running"}
    """
    let items = try DockerClient.parseContainerList(output)

    #expect(items.count == 1)
    #expect(items[0].id == "abc123")
    #expect(items[0].names == "/test-container")
    #expect(items[0].image == "alpine:3")
}

@Test func parseContainerList_multipleContainers() throws {
    let output = """
    {"ID":"abc123","Names":"/container1","Image":"alpine:3","Created":1702000000,"Labels":"","State":"running"}
    {"ID":"def456","Names":"/container2","Image":"redis:7","Created":1702000100,"Labels":"","State":"exited"}
    {"ID":"ghi789","Names":"/container3","Image":"nginx:latest","Created":1702000200,"Labels":"","State":"created"}
    """
    let items = try DockerClient.parseContainerList(output)

    #expect(items.count == 3)
    #expect(items[0].id == "abc123")
    #expect(items[1].id == "def456")
    #expect(items[2].id == "ghi789")
}

@Test func parseContainerList_skipsEmptyLines() throws {
    let output = """
    {"ID":"abc123","Names":"/test","Image":"alpine","Created":1702000000,"Labels":"","State":"running"}

    {"ID":"def456","Names":"/test2","Image":"redis","Created":1702000100,"Labels":"","State":"exited"}

    """
    let items = try DockerClient.parseContainerList(output)

    #expect(items.count == 2)
}

@Test func parseContainerList_handlesWhitespace() throws {
    let output = """
      {"ID":"abc123","Names":"/test","Image":"alpine","Created":1702000000,"Labels":"","State":"running"}
    """
    let items = try DockerClient.parseContainerList(output)

    #expect(items.count == 1)
    #expect(items[0].id == "abc123")
}

// MARK: - ContainerListItem.parsedLabels Tests

@Test func parsedLabels_emptyString() {
    let item = ContainerListItem(
        id: "abc123",
        names: "/test",
        image: "alpine",
        created: 1702000000,
        labels: "",
        state: "running"
    )

    #expect(item.parsedLabels.isEmpty)
}

@Test func parsedLabels_singleLabel() {
    let item = ContainerListItem(
        id: "abc123",
        names: "/test",
        image: "alpine",
        created: 1702000000,
        labels: "key=value",
        state: "running"
    )

    #expect(item.parsedLabels["key"] == "value")
}

@Test func parsedLabels_multipleLabels() {
    let item = ContainerListItem(
        id: "abc123",
        names: "/test",
        image: "alpine",
        created: 1702000000,
        labels: "key1=value1,key2=value2,testcontainers.swift=true",
        state: "running"
    )

    #expect(item.parsedLabels.count == 3)
    #expect(item.parsedLabels["key1"] == "value1")
    #expect(item.parsedLabels["key2"] == "value2")
    #expect(item.parsedLabels["testcontainers.swift"] == "true")
}

@Test func parsedLabels_handlesEqualsInValue() {
    let item = ContainerListItem(
        id: "abc123",
        names: "/test",
        image: "alpine",
        created: 1702000000,
        labels: "url=http://example.com?foo=bar",
        state: "running"
    )

    #expect(item.parsedLabels["url"] == "http://example.com?foo=bar")
}

// MARK: - ContainerListItem.firstName Tests

@Test func firstName_emptyNames() {
    let item = ContainerListItem(
        id: "abc123",
        names: "",
        image: "alpine",
        created: 1702000000,
        labels: "",
        state: "running"
    )

    #expect(item.firstName == nil)
}

@Test func firstName_singleName() {
    let item = ContainerListItem(
        id: "abc123",
        names: "/my-container",
        image: "alpine",
        created: 1702000000,
        labels: "",
        state: "running"
    )

    #expect(item.firstName == "my-container")
}

@Test func firstName_multipleNames() {
    let item = ContainerListItem(
        id: "abc123",
        names: "/name1,/name2,/name3",
        image: "alpine",
        created: 1702000000,
        labels: "",
        state: "running"
    )

    #expect(item.firstName == "name1")
}

@Test func firstName_stripsLeadingSlash() {
    let item = ContainerListItem(
        id: "abc123",
        names: "/test-container",
        image: "alpine",
        created: 1702000000,
        labels: "",
        state: "running"
    )

    #expect(item.firstName == "test-container")
}

// MARK: - TestContainersCleanup Actor Tests

@Test func testContainersCleanup_initializesWithDefaultConfig() async {
    let cleanup = TestContainersCleanup()

    // Verify default configuration is applied
    let config = await cleanup.configuration
    #expect(config.ageThresholdSeconds == 600)
    #expect(config.automaticCleanupEnabled == false)
    #expect(config.dryRun == false)
}

@Test func testContainersCleanup_initializesWithCustomConfig() async {
    let customConfig = TestContainersCleanupConfig()
        .withAgeThreshold(300)
        .withDryRun(true)
        .withVerbose(true)

    let cleanup = TestContainersCleanup(config: customConfig)

    let config = await cleanup.configuration
    #expect(config.ageThresholdSeconds == 300)
    #expect(config.dryRun == true)
    #expect(config.verbose == true)
}

@Test func testContainersCleanup_conformsToSendable() async {
    let cleanup = TestContainersCleanup()

    // Verify we can pass it across concurrency boundaries
    Task {
        let _ = await cleanup.configuration
    }
}

// MARK: - Age Calculation Tests

@Test func containerListItem_ageCalculation() {
    let now = Date()
    let fiveMinutesAgo = now.addingTimeInterval(-300)
    let timestamp = Int(fiveMinutesAgo.timeIntervalSince1970)

    let item = ContainerListItem(
        id: "abc123",
        names: "/test",
        image: "alpine",
        created: timestamp,
        labels: "",
        state: "running"
    )

    let age = now.timeIntervalSince(item.createdDate)

    // Age should be approximately 300 seconds (allowing for small timing differences)
    #expect(age >= 299)
    #expect(age <= 301)
}

@Test func containerListItem_createdDate() {
    let timestamp = 1702000000  // Fixed timestamp
    let item = ContainerListItem(
        id: "abc123",
        names: "/test",
        image: "alpine",
        created: timestamp,
        labels: "",
        state: "running"
    )

    let expected = Date(timeIntervalSince1970: TimeInterval(timestamp))
    #expect(item.createdDate == expected)
}

// MARK: - Cleanup Build Label Filters Tests

@Test func cleanupConfig_buildLabelFilters_includesBaseLabel() {
    let config = TestContainersCleanupConfig()
    let filters = config.buildLabelFilters()

    #expect(filters["testcontainers.swift"] == "true")
}

@Test func cleanupConfig_buildLabelFilters_includesCustomFilters() {
    let config = TestContainersCleanupConfig()
        .withCustomLabelFilter("env", "test")
        .withCustomLabelFilter("project", "myapp")

    let filters = config.buildLabelFilters()

    #expect(filters["testcontainers.swift"] == "true")
    #expect(filters["env"] == "test")
    #expect(filters["project"] == "myapp")
}

@Test func cleanupConfig_buildLabelFilters_customOverridesBase() {
    let config = TestContainersCleanupConfig()
        .withCustomLabelFilter("testcontainers.swift", "false")

    let filters = config.buildLabelFilters()

    // Custom filter overrides base
    #expect(filters["testcontainers.swift"] == "false")
}

// MARK: - Convenience Function Tests

@Test func cleanupOrphanedContainers_functionExists() async throws {
    // This test verifies the convenience function signature
    // Actual cleanup requires Docker, so we just verify it compiles
    let config = TestContainersCleanupConfig()
        .withDryRun(true)

    // The function should exist and be callable
    // (Will fail if Docker is not available, but that's expected)
    do {
        _ = try await cleanupOrphanedContainers(config: config)
    } catch is CleanupError {
        // Expected to fail with a CleanupError if Docker is not running
    } catch {
        // Also OK if it throws other errors
    }
}

@Test func cleanupOrphanedContainers_withAgeThreshold_functionExists() async throws {
    let config = TestContainersCleanupConfig()
        .withDryRun(true)

    do {
        _ = try await cleanupOrphanedContainers(olderThan: 60, config: config)
    } catch {
        // Expected to fail without Docker
    }
}
