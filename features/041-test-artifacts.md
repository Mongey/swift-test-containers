# Feature: Per-Test Artifacts (Logs on Failure, Container Metadata)

## Status: ✅ IMPLEMENTED

Implemented in commits:
- `4b2d8a5` - Add artifact collection types and ArtifactCollector actor
- `cce2403` - Add artifact configuration to ContainerRequest
- `b9f906d` - Integrate artifact collection into withContainer lifecycle
- `35c3c1d` - Add Docker integration tests for artifact collection

## Summary

Artifact collection for swift-test-containers that automatically captures container logs and metadata when tests fail. This feature provides essential debugging information by saving artifacts to disk, making it easier to diagnose test failures in CI/CD environments and local development.

Key capabilities:
- Automatically save container logs when tests fail or containers are terminated prematurely
- Capture container metadata (configuration, environment)
- Configurable output directory for artifacts
- Configurable collection triggers (onFailure, always, onTimeout)
- Retention policies for artifact cleanup
- Integration with swift-testing framework via `testName` parameter

## Implementation Summary

### Files Added/Modified
- `Sources/TestContainers/ArtifactConfig.swift` - Configuration struct with builder pattern
- `Sources/TestContainers/ContainerArtifact.swift` - Artifact and collection result types
- `Sources/TestContainers/ArtifactCollector.swift` - Actor for collecting and persisting artifacts
- `Sources/TestContainers/ContainerRequest.swift` - Added `artifactConfig` property and builder methods
- `Sources/TestContainers/WithContainer.swift` - Added `testName` parameter and artifact integration
- `Tests/TestContainersTests/ArtifactCollectorTests.swift` - 48 unit tests
- `Tests/TestContainersTests/DockerIntegrationTests.swift` - 4 integration tests

### Quick Start

```swift
// Default: artifacts collected on failure only
let request = ContainerRequest(image: "redis:7")
    .withExposedPort(6379)
    .waitingFor(.tcpPort(6379))

try await withContainer(request, testName: "MyTests.testRedis") { container in
    // Test code here - if it fails, artifacts saved to .testcontainers-artifacts/
}

// Custom configuration
let config = ArtifactConfig()
    .withOutputDirectory("/tmp/test-artifacts")
    .withTrigger(.always)  // Collect even on success
    .withRetentionPolicy(.keepLast(5))

let request = ContainerRequest(image: "postgres:15")
    .withArtifacts(config)

// Disable artifacts
let request = ContainerRequest(image: "nginx:latest")
    .withoutArtifacts()
```

## Previous State

### Artifact Handling Before Implementation

Previously, swift-test-containers had **no artifact collection mechanism**:

1. **Container logs** are available via `Container.logs()` but must be manually called by test code
2. **No automatic capture** on test failure
3. **No persistence** - logs are lost when containers are terminated
4. **No metadata capture** - container configuration and state are not preserved
5. **Manual debugging** - developers must reproduce failures to inspect logs

### Relevant Code Locations

**Container lifecycle** (`/Sources/TestContainers/WithContainer.swift:3-30`):
```swift
public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    // ... docker availability check ...
    let id = try await docker.runContainer(request)
    let container = Container(id: id, request: request, docker: docker)

    let cleanup: () -> Void = { _ = Task { try? await container.terminate() } }

    return try await withTaskCancellationHandler {
        do {
            try await container.waitUntilReady()
            let result = try await operation(container)
            try await container.terminate()  // Success path - no artifacts
            return result
        } catch {
            try? await container.terminate()  // Failure path - logs lost!
            throw error
        }
    } onCancel: {
        cleanup()
    }
}
```

**Current log retrieval** (`/Sources/TestContainers/Container.swift:28-30`):
```swift
public func logs() async throws -> String {
    try await docker.logs(id: id)
}
```

**Docker client logs implementation** (`/Sources/TestContainers/DockerClient.swift:60-63`):
```swift
func logs(id: String) async throws -> String {
    let output = try await runDocker(["logs", id])
    return output.stdout
}
```

## Requirements

### Functional Requirements

1. **Automatic Log Capture on Failure**
   - Capture container logs when test throws an error
   - Capture logs when container fails to start (wait strategy timeout)
   - Capture logs on task cancellation
   - Include both stdout and stderr from container

2. **Container Metadata Capture**
   - Container ID
   - Image name and tag
   - Container configuration (environment variables, labels, ports)
   - Container state at failure time (running, exited, exit code)
   - Container inspect JSON (full metadata)
   - Timestamps (container start time, failure time)

3. **Artifact Storage**
   - Save artifacts to configurable directory
   - Default location: `.testcontainers-artifacts/<test-name>/<container-id>/`
   - Organize by test suite and test case
   - Include timestamp in directory name for multiple runs
   - Clean up old artifacts (configurable retention policy)

4. **File Formats**
   - `logs.txt` - Container stdout/stderr logs
   - `metadata.json` - Structured container metadata
   - `request.json` - Original ContainerRequest configuration
   - `error.txt` - Error message that caused failure (if available)

5. **Configuration Options**
   - Enable/disable artifact collection (default: enabled)
   - Configure output directory
   - Configure which artifacts to collect (logs, metadata, both)
   - Configure retention policy (keep last N runs, keep for X days, keep all)
   - Configure collection trigger (on failure only, always, on specific errors)

6. **XCTest/swift-testing Integration**
   - Extract test name from execution context
   - Integrate with test lifecycle hooks
   - Work with both XCTest and swift-testing frameworks
   - Provide manual artifact collection API for advanced use cases

### Non-Functional Requirements

1. **Performance**
   - Artifact collection should not significantly slow down test execution
   - Async/concurrent artifact writing (don't block test cleanup)
   - Minimal overhead when disabled

2. **Reliability**
   - Artifact collection failures should not cause test failures
   - Gracefully handle file system errors
   - Handle concurrent test execution (unique artifact directories)

3. **Usability**
   - Minimal configuration required (works by default)
   - Clear documentation of artifact locations
   - Helpful log messages when artifacts are saved
   - Easy to locate artifacts for specific test failures

4. **Compatibility**
   - Work with existing Container and ContainerRequest APIs
   - No breaking changes to public API
   - Support both macOS and Linux
   - Compatible with CI/CD environments (GitHub Actions, GitLab CI, etc.)

## API Design

### Core Types

```swift
// New file: /Sources/TestContainers/ArtifactCollector.swift

/// Configuration for test artifact collection
public struct ArtifactConfig: Sendable {
    /// Enable or disable artifact collection
    public var enabled: Bool

    /// Base directory for artifacts (default: ./.testcontainers-artifacts)
    public var outputDirectory: String

    /// What to collect
    public var collectLogs: Bool
    public var collectMetadata: Bool
    public var collectRequest: Bool

    /// When to collect artifacts
    public enum CollectionTrigger: Sendable {
        case onFailure      // Only on test failure (default)
        case always         // Always collect
        case onTimeout      // Only on wait strategy timeout
        case custom((Error?) -> Bool)  // Custom predicate
    }
    public var trigger: CollectionTrigger

    /// Retention policy
    public enum RetentionPolicy: Sendable {
        case keepAll
        case keepLast(Int)
        case keepForDays(Int)
    }
    public var retentionPolicy: RetentionPolicy

    public init(
        enabled: Bool = true,
        outputDirectory: String = ".testcontainers-artifacts",
        collectLogs: Bool = true,
        collectMetadata: Bool = true,
        collectRequest: Bool = true,
        trigger: CollectionTrigger = .onFailure,
        retentionPolicy: RetentionPolicy = .keepLast(10)
    ) {
        self.enabled = enabled
        self.outputDirectory = outputDirectory
        self.collectLogs = collectLogs
        self.collectMetadata = collectMetadata
        self.collectRequest = collectRequest
        self.trigger = trigger
        self.retentionPolicy = retentionPolicy
    }

    /// Default configuration
    public static let `default` = ArtifactConfig()

    /// Disabled artifact collection
    public static let disabled = ArtifactConfig(enabled: false)
}

/// Container metadata captured at failure time
public struct ContainerArtifact: Sendable, Codable {
    public let containerId: String
    public let imageName: String
    public let containerName: String?
    public let captureTime: Date
    public let containerState: String
    public let exitCode: Int?
    public let environment: [String: String]
    public let labels: [String: String]
    public let ports: [String]
    public let inspectJSON: String?
}

/// Result of artifact collection
public struct ArtifactCollection: Sendable {
    public let artifactDirectory: String
    public let logsFile: String?
    public let metadataFile: String?
    public let requestFile: String?
    public let errorFile: String?

    public var isEmpty: Bool {
        logsFile == nil && metadataFile == nil && requestFile == nil && errorFile == nil
    }
}

/// Actor responsible for collecting and persisting artifacts
public actor ArtifactCollector {
    private let config: ArtifactConfig
    private let fileManager: FileManager

    public init(config: ArtifactConfig = .default) {
        self.config = config
        self.fileManager = FileManager.default
    }

    /// Collect artifacts for a container
    public func collect(
        container: Container,
        testName: String?,
        error: Error?
    ) async -> ArtifactCollection? {
        guard config.enabled else { return nil }
        guard shouldCollect(error: error) else { return nil }

        let artifactDir = makeArtifactDirectory(
            testName: testName ?? "unknown-test",
            containerId: container.id
        )

        var collection = ArtifactCollection(
            artifactDirectory: artifactDir,
            logsFile: nil,
            metadataFile: nil,
            requestFile: nil,
            errorFile: nil
        )

        // Collect logs
        if config.collectLogs {
            collection.logsFile = await collectLogs(container: container, outputDir: artifactDir)
        }

        // Collect metadata
        if config.collectMetadata {
            collection.metadataFile = await collectMetadata(container: container, outputDir: artifactDir)
        }

        // Collect request
        if config.collectRequest {
            collection.requestFile = await collectRequest(container: container, outputDir: artifactDir)
        }

        // Collect error info
        if let error = error {
            collection.errorFile = await collectError(error: error, outputDir: artifactDir)
        }

        applyRetentionPolicy()

        return collection.isEmpty ? nil : collection
    }

    private func shouldCollect(error: Error?) -> Bool {
        switch config.trigger {
        case .onFailure:
            return error != nil
        case .always:
            return true
        case .onTimeout:
            if case TestContainersError.timeout = error {
                return true
            }
            return false
        case .custom(let predicate):
            return predicate(error)
        }
    }

    // ... implementation details ...
}
```

### Updated ContainerRequest

```swift
// Add to existing /Sources/TestContainers/ContainerRequest.swift

public struct ContainerRequest: Sendable, Hashable {
    // ... existing properties ...

    /// Artifact collection configuration
    public var artifactConfig: ArtifactConfig

    public init(image: String) {
        // ... existing initialization ...
        self.artifactConfig = .default
    }

    /// Configure artifact collection
    public func withArtifacts(_ config: ArtifactConfig) -> Self {
        var copy = self
        copy.artifactConfig = config
        return copy
    }

    /// Disable artifact collection for this container
    public func withoutArtifacts() -> Self {
        withArtifacts(.disabled)
    }
}
```

### Updated withContainer

```swift
// Update existing /Sources/TestContainers/WithContainer.swift

public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    testName: String? = nil,  // Optional test name override
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable("`docker` CLI not found or Docker engine not running.")
    }

    let id = try await docker.runContainer(request)
    let container = Container(id: id, request: request, docker: docker)
    let collector = ArtifactCollector(config: request.artifactConfig)

    // Auto-detect test name if not provided
    let detectedTestName = testName ?? detectCurrentTestName()

    let cleanup: (Error?) -> Void = { error in
        Task {
            // Collect artifacts before termination
            let artifacts = await collector.collect(
                container: container,
                testName: detectedTestName,
                error: error
            )

            if let artifacts = artifacts, !artifacts.isEmpty {
                print("[TestContainers] Artifacts saved to: \(artifacts.artifactDirectory)")
            }

            try? await container.terminate()
        }
    }

    return try await withTaskCancellationHandler {
        do {
            try await container.waitUntilReady()
            let result = try await operation(container)

            // Success path - check if we should collect anyway
            if request.artifactConfig.trigger == .always {
                _ = await collector.collect(
                    container: container,
                    testName: detectedTestName,
                    error: nil
                )
            }

            try await container.terminate()
            return result
        } catch {
            cleanup(error)
            throw error
        }
    } onCancel: {
        cleanup(nil)  // Cancellation is a special case
    }
}

/// Attempt to detect the current test name from execution context
private func detectCurrentTestName() -> String? {
    // Use stack trace analysis to find test method
    // Format: TestClassName.testMethodName
    let stackSymbols = Thread.callStackSymbols
    for symbol in stackSymbols {
        // Look for test method patterns
        // XCTest: "-[TestClass testMethod]"
        // swift-testing: "TestClass.testMethod()"
        if let testName = parseTestName(from: symbol) {
            return testName
        }
    }
    return nil
}

private func parseTestName(from symbol: String) -> String? {
    // Implementation to parse test names from stack traces
    // This will handle both XCTest and swift-testing patterns
    // Returns format: "TestClassName.testMethodName"

    // XCTest pattern: -[TestClassName testMethodName]
    if let range = symbol.range(of: #"-\[(\w+)\s+(\w+)\]"#, options: .regularExpression) {
        // Extract and format
    }

    // swift-testing pattern: TestClassName.testMethodName()
    if let range = symbol.range(of: #"(\w+Tests)\.(\w+)\("#, options: .regularExpression) {
        // Extract and format
    }

    return nil
}
```

### Manual Artifact Collection API

```swift
// Add to existing /Sources/TestContainers/Container.swift

public actor Container {
    // ... existing properties ...

    /// Manually save artifacts for this container
    public func saveArtifacts(
        testName: String? = nil,
        config: ArtifactConfig? = nil
    ) async -> ArtifactCollection? {
        let collector = ArtifactCollector(config: config ?? request.artifactConfig)
        return await collector.collect(
            container: self,
            testName: testName,
            error: nil
        )
    }
}
```

### Docker Client Additions

```swift
// Add to existing /Sources/TestContainers/DockerClient.swift

public actor DockerClient {
    // ... existing methods ...

    /// Get detailed container information via docker inspect
    func inspect(id: String) async throws -> String {
        let output = try await runDocker(["inspect", id])
        return output.stdout
    }

    /// Get container state information
    func containerState(id: String) async throws -> ContainerState {
        let inspectJSON = try await inspect(id: id)
        // Parse JSON and extract state
        return try parseContainerState(from: inspectJSON)
    }
}

/// Container state information
public struct ContainerState: Sendable, Codable {
    public let status: String  // created, running, paused, restarting, removing, exited, dead
    public let running: Bool
    public let exitCode: Int?
    public let startedAt: String?
    public let finishedAt: String?
}
```

## Implementation Steps

### Phase 1: Core Infrastructure (High Priority)

1. **Create ArtifactCollector Actor**
   - File: `/Sources/TestContainers/ArtifactCollector.swift`
   - Implement `ArtifactConfig` struct with all configuration options
   - Implement `ContainerArtifact` and `ArtifactCollection` types
   - Implement basic `ArtifactCollector` actor with directory creation
   - Dependencies: Foundation (FileManager, JSONEncoder)

2. **Add Docker Inspect Support**
   - Update `/Sources/TestContainers/DockerClient.swift`
   - Add `inspect(id:)` method using `docker inspect`
   - Add `containerState(id:)` helper method
   - Add JSON parsing for container state
   - Unit test: Mock docker inspect output parsing

3. **Implement Log Collection**
   - Add `collectLogs(container:outputDir:)` to ArtifactCollector
   - Call `container.logs()` and write to `logs.txt`
   - Handle errors gracefully (log but don't throw)
   - Unit test: Verify log file creation and content

4. **Implement Metadata Collection**
   - Add `collectMetadata(container:outputDir:)` to ArtifactCollector
   - Call `docker.inspect(id:)` and save full JSON
   - Parse key fields into `ContainerArtifact` struct
   - Save structured metadata to `metadata.json`
   - Unit test: Verify metadata file creation and JSON structure

5. **Implement Request Collection**
   - Add `collectRequest(container:outputDir:)` to ArtifactCollector
   - Serialize `ContainerRequest` to JSON
   - Save to `request.json`
   - Unit test: Verify request file creation and content

6. **Implement Error Collection**
   - Add `collectError(error:outputDir:)` to ArtifactCollector
   - Format error description and stack trace
   - Save to `error.txt`
   - Include TestContainersError details if applicable
   - Unit test: Verify error file creation and formatting

### Phase 2: Integration with Container Lifecycle (High Priority)

7. **Update ContainerRequest**
   - Add `artifactConfig: ArtifactConfig` property
   - Add `withArtifacts(_:)` builder method
   - Add `withoutArtifacts()` convenience method
   - Update `Hashable` conformance to include artifactConfig
   - Unit test: Verify builder pattern works correctly

8. **Update withContainer Function**
   - Modify `/Sources/TestContainers/WithContainer.swift`
   - Create ArtifactCollector instance with request config
   - Call `collector.collect()` on error path
   - Call `collector.collect()` on cancellation path
   - Call `collector.collect()` on success if trigger is `.always`
   - Print artifact location to stdout when collected
   - Unit test: Mock collector to verify it's called at right times

9. **Implement Test Name Detection**
   - Add `detectCurrentTestName()` helper function
   - Parse stack traces for XCTest patterns: `-[ClassName testMethod]`
   - Parse stack traces for swift-testing patterns: `ClassName.testMethod()`
   - Return formatted name: `ClassName.testMethod`
   - Fall back to "unknown-test" if detection fails
   - Unit test: Test with sample stack traces

10. **Add testName Parameter to withContainer**
    - Add optional `testName: String?` parameter
    - Default to auto-detection if nil
    - Pass to collector.collect()
    - Unit test: Verify manual name override works

### Phase 3: File System Management (Medium Priority)

11. **Implement Directory Structure**
    - Create base artifact directory (default: `.testcontainers-artifacts`)
    - Create test-specific subdirectories: `<testName>/`
    - Create container-specific subdirectories: `<containerId>/`
    - Add timestamp to avoid collisions: `<containerId>_<timestamp>/`
    - Handle filesystem errors gracefully
    - Unit test: Verify directory structure creation

12. **Implement Retention Policy**
    - Add `applyRetentionPolicy()` method to ArtifactCollector
    - Implement `.keepAll` (no cleanup)
    - Implement `.keepLast(n)` (remove oldest artifact directories)
    - Implement `.keepForDays(n)` (remove directories older than N days)
    - Sort directories by timestamp for cleanup
    - Handle filesystem errors gracefully
    - Unit test: Verify retention policies work correctly

13. **Add Concurrent Test Safety**
    - Use UUIDs or timestamps to make directory names unique
    - Handle race conditions in directory creation
    - Test with parallel test execution
    - Unit test: Simulate concurrent artifact collection

### Phase 4: Enhanced Container API (Medium Priority)

14. **Add Manual Artifact Collection API**
    - Add `saveArtifacts(testName:config:)` to Container
    - Allow manual triggering of artifact collection
    - Return `ArtifactCollection` result
    - Unit test: Verify manual collection works

15. **Add Artifact Query API**
    - Add static method to list artifact directories
    - Add method to read artifacts for specific test
    - Useful for CI/CD integration
    - Unit test: Verify artifact listing works

### Phase 5: Documentation and Examples (Medium Priority)

16. **Add Code Documentation**
    - Document all public types and methods
    - Add usage examples in doc comments
    - Document default behaviors
    - Document filesystem layout

17. **Create Usage Examples**
    - Add example test with artifact collection
    - Add example with custom configuration
    - Add example with manual collection
    - Add example showing artifact location
    - Update README.md with artifacts section

18. **Update FEATURES.md**
    - Move "Per-test artifacts" from Tier 3 to Implemented
    - Document the feature status

### Phase 6: Testing (High Priority - Parallel with Implementation)

19. **Unit Tests for ArtifactCollector**
    - Test configuration defaults
    - Test collection trigger logic
    - Test file writing operations
    - Test error handling (filesystem errors)
    - Test retention policy application
    - Mock filesystem operations where needed

20. **Unit Tests for Docker Inspect**
    - Test inspect command execution
    - Test JSON parsing
    - Test error handling
    - Mock docker CLI responses

21. **Integration Tests**
    - Test artifact collection on container failure
    - Test artifact collection on wait timeout
    - Test artifact collection on success (with .always trigger)
    - Test artifact collection on cancellation
    - Verify file contents are correct
    - Test with both XCTest and swift-testing
    - Requires: `TESTCONTAINERS_RUN_DOCKER_TESTS=1`

22. **Test Name Detection Tests**
    - Test XCTest name detection
    - Test swift-testing name detection
    - Test fallback behavior
    - Mock stack traces for testing

## Testing Plan

### Unit Tests

**File: `/Tests/TestContainersTests/ArtifactCollectorTests.swift`**

```swift
import Testing
import Foundation
@testable import TestContainers

@Test func artifactConfigDefaults() {
    let config = ArtifactConfig.default
    #expect(config.enabled == true)
    #expect(config.outputDirectory == ".testcontainers-artifacts")
    #expect(config.collectLogs == true)
    #expect(config.collectMetadata == true)
}

@Test func artifactConfigDisabled() {
    let config = ArtifactConfig.disabled
    #expect(config.enabled == false)
}

@Test func shouldCollectOnFailure() async {
    let collector = ArtifactCollector(config: .default)
    let error = TestContainersError.timeout("test timeout")
    // Test that shouldCollect returns true for errors
}

@Test func shouldNotCollectOnSuccessWithOnFailureTrigger() async {
    let config = ArtifactConfig(trigger: .onFailure)
    let collector = ArtifactCollector(config: config)
    // Test that shouldCollect returns false when error is nil
}

@Test func shouldCollectOnSuccessWithAlwaysTrigger() async {
    let config = ArtifactConfig(trigger: .always)
    let collector = ArtifactCollector(config: config)
    // Test that shouldCollect returns true even when error is nil
}

@Test func shouldCollectOnlyTimeoutErrors() async {
    let config = ArtifactConfig(trigger: .onTimeout)
    let collector = ArtifactCollector(config: config)

    let timeoutError = TestContainersError.timeout("test")
    // Test returns true for timeout errors

    let otherError = TestContainersError.dockerNotAvailable("test")
    // Test returns false for other errors
}

@Test func retentionPolicyKeepLast() async throws {
    // Create temp directory with 5 artifact directories
    // Apply keepLast(3) policy
    // Verify only 3 newest remain
}

@Test func retentionPolicyKeepForDays() async throws {
    // Create temp directory with old and new artifacts
    // Apply keepForDays(7) policy
    // Verify old artifacts removed, new ones kept
}

@Test func directoryStructureCreation() async throws {
    // Test that artifact directory structure is created correctly
    // Format: base/testName/containerId_timestamp/
}

@Test func containerRequestWithArtifacts() {
    let request = ContainerRequest(image: "redis:7")
        .withArtifacts(.default)
    #expect(request.artifactConfig.enabled == true)
}

@Test func containerRequestWithoutArtifacts() {
    let request = ContainerRequest(image: "redis:7")
        .withoutArtifacts()
    #expect(request.artifactConfig.enabled == false)
}
```

**File: `/Tests/TestContainersTests/DockerInspectTests.swift`**

```swift
import Testing
@testable import TestContainers

@Test func parseContainerStateFromJSON() throws {
    let sampleJSON = """
    [{
        "State": {
            "Status": "running",
            "Running": true,
            "ExitCode": 0,
            "StartedAt": "2025-01-15T10:00:00Z"
        }
    }]
    """
    // Test JSON parsing logic
}

@Test func parseExitedContainerState() throws {
    let sampleJSON = """
    [{
        "State": {
            "Status": "exited",
            "Running": false,
            "ExitCode": 1,
            "FinishedAt": "2025-01-15T10:05:00Z"
        }
    }]
    """
    // Test parsing exited container
}
```

**File: `/Tests/TestContainersTests/TestNameDetectionTests.swift`**

```swift
import Testing
@testable import TestContainers

@Test func detectXCTestName() {
    let stackSymbol = "2   TestContainersTests   0x0001 -[DockerIntegrationTests testRedisContainer] + 123"
    let name = parseTestName(from: stackSymbol)
    #expect(name == "DockerIntegrationTests.testRedisContainer")
}

@Test func detectSwiftTestingName() {
    let stackSymbol = "3   TestContainersTests   0x0002 DockerIntegrationTests.canStartContainer_whenOptedIn() + 456"
    let name = parseTestName(from: stackSymbol)
    #expect(name == "DockerIntegrationTests.canStartContainer_whenOptedIn")
}

@Test func fallbackForUnknownPattern() {
    let stackSymbol = "4   Foundation   0x0003 unknown + 789"
    let name = parseTestName(from: stackSymbol)
    #expect(name == nil)
}
```

### Integration Tests

**File: `/Tests/TestContainersTests/ArtifactIntegrationTests.swift`**

```swift
import Testing
import Foundation
@testable import TestContainers

@Test func collectsArtifactsOnFailure() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-artifacts-\(UUID().uuidString)")

    let config = ArtifactConfig(
        outputDirectory: tempDir.path,
        trigger: .onFailure
    )

    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.logContains("impossible-string", timeout: .seconds(2)))
        .withArtifacts(config)

    do {
        try await withContainer(request) { container in
            // This should timeout waiting for impossible log string
        }
        Issue.record("Expected timeout error")
    } catch {
        // Verify artifacts were created
        let artifactDirs = try FileManager.default
            .contentsOfDirectory(atPath: tempDir.path)
        #expect(!artifactDirs.isEmpty)

        // Verify logs.txt exists and has content
        // Verify metadata.json exists and is valid JSON
        // Verify request.json exists
        // Verify error.txt exists
    }

    // Cleanup
    try? FileManager.default.removeItem(at: tempDir)
}

@Test func doesNotCollectArtifactsOnSuccess() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-artifacts-\(UUID().uuidString)")

    let config = ArtifactConfig(
        outputDirectory: tempDir.path,
        trigger: .onFailure
    )

    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379))
        .withArtifacts(config)

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }

    // Verify NO artifacts were created
    let artifactExists = FileManager.default.fileExists(atPath: tempDir.path)
    #expect(!artifactExists)
}

@Test func collectsArtifactsAlways() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-artifacts-\(UUID().uuidString)")

    let config = ArtifactConfig(
        outputDirectory: tempDir.path,
        trigger: .always
    )

    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379))
        .withArtifacts(config)

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }

    // Verify artifacts WERE created even on success
    let artifactDirs = try FileManager.default
        .contentsOfDirectory(atPath: tempDir.path)
    #expect(!artifactDirs.isEmpty)

    // Cleanup
    try? FileManager.default.removeItem(at: tempDir)
}

@Test func manualArtifactCollection() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-artifacts-\(UUID().uuidString)")

    let config = ArtifactConfig(
        enabled: false,  // Disable automatic collection
        outputDirectory: tempDir.path
    )

    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379))
        .withArtifacts(config)

    try await withContainer(request) { container in
        // Manually trigger artifact collection
        let artifacts = await container.saveArtifacts(
            testName: "manualTest",
            config: ArtifactConfig(outputDirectory: tempDir.path)
        )

        #expect(artifacts != nil)
        #expect(artifacts?.logsFile != nil)
        #expect(artifacts?.metadataFile != nil)
    }

    // Cleanup
    try? FileManager.default.removeItem(at: tempDir)
}

@Test func artifactFilesContainExpectedContent() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-artifacts-\(UUID().uuidString)")

    let config = ArtifactConfig(
        outputDirectory: tempDir.path,
        trigger: .always
    )

    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379))
        .withArtifacts(config)

    try await withContainer(request) { container in
        // Generate some logs
        _ = try await container.logs()
    }

    // Find artifact directory
    let artifactDirs = try FileManager.default
        .contentsOfDirectory(atPath: tempDir.path)
    guard let firstDir = artifactDirs.first else {
        Issue.record("No artifact directory created")
        return
    }

    let artifactPath = tempDir.appendingPathComponent(firstDir)

    // Verify logs.txt
    let logsPath = artifactPath.appendingPathComponent("logs.txt")
    let logsExist = FileManager.default.fileExists(atPath: logsPath.path)
    #expect(logsExist)
    let logs = try String(contentsOf: logsPath)
    #expect(logs.contains("Redis"))  // Should contain Redis startup messages

    // Verify metadata.json
    let metadataPath = artifactPath.appendingPathComponent("metadata.json")
    let metadataExist = FileManager.default.fileExists(atPath: metadataPath.path)
    #expect(metadataExist)
    let metadataData = try Data(contentsOf: metadataPath)
    let metadata = try JSONDecoder().decode(ContainerArtifact.self, from: metadataData)
    #expect(metadata.imageName == "redis:7")

    // Verify request.json
    let requestPath = artifactPath.appendingPathComponent("request.json")
    let requestExist = FileManager.default.fileExists(atPath: requestPath.path)
    #expect(requestExist)

    // Cleanup
    try? FileManager.default.removeItem(at: tempDir)
}
```

### CI/CD Integration Testing

Test artifact collection in GitHub Actions:

```yaml
# .github/workflows/test.yml
- name: Run tests with artifacts
  env:
    TESTCONTAINERS_RUN_DOCKER_TESTS: 1
  run: swift test

- name: Upload test artifacts
  if: failure()
  uses: actions/upload-artifact@v3
  with:
    name: testcontainers-artifacts
    path: .testcontainers-artifacts/
    retention-days: 7
```

## Acceptance Criteria

### Must Have

- [ ] Artifacts are automatically collected when tests fail
- [ ] Artifacts include container logs (stdout/stderr)
- [ ] Artifacts include container metadata (inspect JSON)
- [ ] Artifacts include original ContainerRequest configuration
- [ ] Artifacts include error message that caused failure
- [ ] Artifacts are saved to configurable directory with sensible default
- [ ] Directory structure organizes artifacts by test name and container ID
- [ ] Artifact collection can be disabled via configuration
- [ ] Artifact collection failures do not cause test failures
- [ ] Public API is documented with examples
- [ ] Unit tests cover core functionality (>80% coverage)
- [ ] Integration tests verify end-to-end behavior with real Docker containers

### Should Have

- [ ] Test name is automatically detected from execution context (XCTest and swift-testing)
- [ ] Retention policy automatically cleans up old artifacts
- [ ] Manual artifact collection API for advanced use cases
- [ ] Informative log messages when artifacts are saved
- [ ] Artifacts work correctly with concurrent test execution
- [ ] Performance overhead is minimal (<5% impact on test execution time)
- [ ] Works on both macOS and Linux
- [ ] CI/CD integration examples provided

### Nice to Have

- [ ] Artifact query API to list and read artifacts
- [ ] Compression of artifact directories (zip/tar.gz)
- [ ] Custom artifact collectors (user-defined artifact types)
- [ ] Artifact upload to S3/cloud storage
- [ ] HTML report generation from artifacts
- [ ] Artifact comparison between test runs
- [ ] Integration with test reporting frameworks

## Dependencies

### Internal Dependencies
- Existing `Container` actor (log retrieval, lifecycle)
- Existing `DockerClient` actor (needs new `inspect` method)
- Existing `ContainerRequest` struct (needs artifact config property)
- Existing `withContainer` function (needs artifact collection hooks)
- Existing `TestContainersError` enum (for error type detection)

### External Dependencies
- Foundation (FileManager, JSONEncoder/Decoder, Date)
- Swift Concurrency (async/await, actors)
- XCTest or swift-testing (for test name detection)

### New Files Required
- `/Sources/TestContainers/ArtifactCollector.swift` (core implementation)
- `/Tests/TestContainersTests/ArtifactCollectorTests.swift` (unit tests)
- `/Tests/TestContainersTests/ArtifactIntegrationTests.swift` (integration tests)
- `/Tests/TestContainersTests/TestNameDetectionTests.swift` (test name tests)
- `/Tests/TestContainersTests/DockerInspectTests.swift` (inspect tests)

## Migration Path

### For Existing Users

No breaking changes. Artifact collection is:
- Enabled by default but only triggers on failure
- Can be disabled per-container: `.withoutArtifacts()`
- Can be configured globally via environment variable (future enhancement)

### Backward Compatibility

All changes are additive:
- New properties use sensible defaults
- Existing API unchanged
- New optional parameters default to auto-detection

## Performance Considerations

### Overhead Analysis

**When disabled**: Zero overhead (early return in collect method)

**When enabled (on failure only)**:
- Artifact collection happens after test failure (not in hot path)
- Async/concurrent execution (doesn't block test cleanup)
- Estimated overhead: <100ms per failed test

**When enabled (always)**:
- Overhead on every test
- Should be opt-in for CI/CD environments only
- Estimated overhead: <200ms per test

### Optimization Strategies

1. **Lazy artifact directory creation** - Only create directories if artifacts collected
2. **Parallel file writing** - Write logs, metadata, and request files concurrently
3. **Stream logs directly to file** - Avoid loading full log string in memory
4. **Background retention policy** - Run cleanup in background task
5. **Configurable artifact types** - Allow disabling metadata or request if not needed

## Security Considerations

1. **Sensitive Data in Logs**
   - Container logs may contain secrets/credentials
   - Document best practices (don't log secrets)
   - Consider adding redaction feature (future)

2. **File System Permissions**
   - Artifacts saved with default file permissions
   - Document secure artifact directory setup for CI/CD

3. **Disk Space Management**
   - Retention policies prevent unbounded growth
   - Document recommended retention settings
   - Consider adding disk space limits (future)

## Documentation Requirements

1. **README.md Updates**
   - Add "Debugging with Artifacts" section
   - Show basic usage example
   - Document artifact directory structure
   - Document configuration options

2. **API Documentation**
   - Document all public types with doc comments
   - Include usage examples in doc comments
   - Document default behaviors
   - Document filesystem layout

3. **Troubleshooting Guide**
   - How to locate artifacts for failed tests
   - How to configure artifact collection
   - How to integrate with CI/CD
   - Common issues and solutions

## Future Enhancements

### Short Term (Next 3-6 months)
- Environment variable configuration (TESTCONTAINERS_ARTIFACTS_DIR)
- Compression of artifact directories
- HTML report generation

### Medium Term (6-12 months)
- Artifact upload to cloud storage (S3, Azure Blob)
- Custom artifact collectors (user-defined artifacts)
- Integration with test reporting frameworks
- Artifact comparison between runs

### Long Term (12+ months)
- Distributed artifact collection (multi-node CI/CD)
- Real-time artifact streaming during test execution
- AI-powered failure analysis from artifacts
- Artifact-based test replay

## References

### External Projects

- **testcontainers-go**: [Container Logs on Failure](https://github.com/testcontainers/testcontainers-go/blob/main/docs/features/follow_logs.md)
- **testcontainers-java**: [Container Logs](https://java.testcontainers.org/features/container_logs/)
- **pytest**: [Test artifacts and fixtures](https://docs.pytest.org/en/stable/how-to/fixtures.html)

### Related Features

- Feature 011: Stream Logs (complement to artifact collection)
- Feature 010: Container Inspect (dependency for metadata)
- Feature 007: Container Exec (potential artifact source)

## Open Questions

1. **Test name detection reliability**: How reliable is stack trace parsing across different Swift versions and test frameworks?
   - Mitigation: Provide manual override via `testName` parameter

2. **Artifact size limits**: Should we enforce maximum artifact size or log line limits?
   - Recommendation: Document best practices, add limits as optional feature later

3. **Concurrent test isolation**: How to ensure artifact directories don't collide in parallel test execution?
   - Solution: Use container ID + timestamp + random suffix for uniqueness

4. **CI/CD integration**: Should we provide built-in upload to cloud storage?
   - Recommendation: Start with filesystem, add cloud upload as separate feature

## Success Metrics

### Adoption Metrics
- % of users who keep artifacts enabled (default)
- % of users who customize artifact configuration
- % of tests that produce artifacts

### Quality Metrics
- Reduction in "cannot reproduce test failure" issues
- Time saved debugging test failures
- User satisfaction with artifact content

### Performance Metrics
- Average artifact collection time
- Average artifact disk usage
- Impact on overall test execution time

---

## Appendix A: Example Usage

### Basic Usage (Default Behavior)

```swift
import Testing
import TestContainers

@Test func databaseTest() async throws {
    let request = ContainerRequest(image: "postgres:15")
        .withExposedPort(5432)
        .waitingFor(.tcpPort(5432))
        // Artifacts enabled by default, collected on failure only

    try await withContainer(request) { container in
        // If test fails here, artifacts automatically saved to:
        // .testcontainers-artifacts/DatabaseTests.databaseTest/<container-id>/
        let port = try await container.hostPort(5432)
        #expect(port > 0)
    }
}
```

### Custom Configuration

```swift
@Test func customArtifactConfig() async throws {
    let artifactConfig = ArtifactConfig(
        outputDirectory: "/tmp/my-test-artifacts",
        collectLogs: true,
        collectMetadata: true,
        trigger: .always,  // Collect even on success
        retentionPolicy: .keepLast(5)
    )

    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379))
        .withArtifacts(artifactConfig)

    try await withContainer(request) { container in
        // Artifacts saved even if test passes
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }
}
```

### Disable Artifacts

```swift
@Test func noArtifacts() async throws {
    let request = ContainerRequest(image: "nginx:latest")
        .withExposedPort(80)
        .withoutArtifacts()  // Disable artifact collection

    try await withContainer(request) { container in
        // No artifacts collected even on failure
        let port = try await container.hostPort(80)
        #expect(port > 0)
    }
}
```

### Manual Artifact Collection

```swift
@Test func manualCollection() async throws {
    let request = ContainerRequest(image: "mysql:8")
        .withExposedPort(3306)
        .withoutArtifacts()  // Disable automatic collection

    try await withContainer(request) { container in
        // ... test operations ...

        // Manually collect artifacts at specific point
        if someCondition {
            let artifacts = await container.saveArtifacts(
                testName: "mysql-debug-snapshot"
            )
            if let artifacts = artifacts {
                print("Snapshot saved to: \(artifacts.artifactDirectory)")
            }
        }
    }
}
```

### CI/CD Integration

```swift
// In your test setup, configure artifacts for CI
#if CI_ENVIRONMENT
let defaultConfig = ArtifactConfig(
    outputDirectory: ProcessInfo.processInfo.environment["ARTIFACT_DIR"] ?? ".testcontainers-artifacts",
    trigger: .onFailure,
    retentionPolicy: .keepAll  // CI handles cleanup
)
#else
let defaultConfig = ArtifactConfig.default
#endif
```

## Appendix B: Artifact Directory Structure

```
.testcontainers-artifacts/
├── DatabaseTests.databaseTest/
│   ├── abc123_20250115_100530/
│   │   ├── logs.txt                    # Container stdout/stderr
│   │   ├── metadata.json               # Structured container info
│   │   ├── request.json                # Original ContainerRequest
│   │   └── error.txt                   # Error that caused failure
│   └── def456_20250115_100645/
│       ├── logs.txt
│       ├── metadata.json
│       └── request.json
├── RedisTests.connectionTest/
│   └── ghi789_20250115_101000/
│       ├── logs.txt
│       ├── metadata.json
│       └── request.json
└── .retention                          # Metadata for retention policy
```

## Appendix C: Example Artifact Files

### logs.txt
```
1:C 15 Jan 2025 10:05:30.123 # oO0OoO0OoO0Oo Redis is starting oO0OoO0OoO0Oo
1:C 15 Jan 2025 10:05:30.123 # Redis version=7.0.0, bits=64, commit=00000000
1:C 15 Jan 2025 10:05:30.124 # Configuration loaded
1:M 15 Jan 2025 10:05:30.125 * Running mode=standalone, port=6379
1:M 15 Jan 2025 10:05:30.126 * Server initialized
1:M 15 Jan 2025 10:05:30.127 * Ready to accept connections
```

### metadata.json
```json
{
  "containerId": "abc123def456",
  "imageName": "redis:7",
  "containerName": "testcontainer-redis-1",
  "captureTime": "2025-01-15T10:05:35Z",
  "containerState": "running",
  "exitCode": null,
  "environment": {
    "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "REDIS_VERSION": "7.0.0"
  },
  "labels": {
    "testcontainers.swift": "true"
  },
  "ports": [
    "6379/tcp -> 0.0.0.0:54321"
  ],
  "inspectJSON": "{ ... full docker inspect output ... }"
}
```

### request.json
```json
{
  "image": "redis:7",
  "name": null,
  "command": [],
  "environment": {},
  "labels": {
    "testcontainers.swift": "true"
  },
  "ports": [
    {
      "containerPort": 6379,
      "hostPort": null
    }
  ],
  "waitStrategy": {
    "type": "tcpPort",
    "port": 6379,
    "timeout": 60.0,
    "pollInterval": 0.2
  },
  "host": "127.0.0.1"
}
```

### error.txt
```
Timed out: TCP port 127.0.0.1:54321 to accept connections

Error: TestContainersError.timeout
Test: DatabaseTests.databaseTest
Container: abc123def456
Image: redis:7
Captured: 2025-01-15 10:05:35 UTC

Stack trace:
  at Container.waitUntilReady()
  at withContainer(_:docker:operation:)
  at DatabaseTests.databaseTest()
```
