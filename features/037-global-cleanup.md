# Feature 037: Global Cleanup for Leaked Containers

## Summary

Implement a global cleanup mechanism for orphaned test containers from crashed test runs, aborted processes, or unhandled exceptions. This feature will identify and remove leaked containers using label-based identification, with support for age-based filtering, manual sweep commands, and optional Ryuk-style sidecar container reaping.

**Problem:** When test processes crash, are force-killed, or experience unhandled exceptions before reaching the cleanup code in `withContainer`, Docker containers are left running indefinitely, consuming system resources and potentially causing port conflicts in subsequent test runs.

**Solution:** Provide multiple cleanup strategies that can identify and remove orphaned containers based on labels and age, either manually on-demand, automatically on process startup, or via a sidecar reaper container.

## Current State

### Current Cleanup Mechanism

The library uses a scoped lifecycle pattern with automatic cleanup implemented in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`:

```swift
public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable("`docker` CLI not found or Docker engine not running.")
    }

    let id = try await docker.runContainer(request)
    let container = Container(id: id, request: request, docker: docker)

    let cleanup: () -> Void = { _ = Task { try? await container.terminate() } }

    return try await withTaskCancellationHandler {
        do {
            try await container.waitUntilReady()
            let result = try await operation(container)
            try await container.terminate()  // Normal cleanup
            return result
        } catch {
            try? await container.terminate()  // Error cleanup
            throw error
        }
    } onCancel: {
        cleanup()  // Cancellation cleanup
    }
}
```

**How it works:**
1. Container is started via `docker.runContainer(request)`
2. On successful completion: `container.terminate()` is called
3. On thrown error: `try? await container.terminate()` is called in catch block
4. On task cancellation: cleanup handler calls `terminate()` in background task

**Cleanup implementation** in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`:

```swift
public func terminate() async throws {
    try await docker.removeContainer(id: id)
}
```

Which calls `DockerClient.removeContainer()` at `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`:

```swift
func removeContainer(id: String) async throws {
    _ = try await runDocker(["rm", "-f", id])
}
```

### Current Label System

Every container created by the library is automatically tagged with a label in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`:

```swift
public init(image: String) {
    self.image = image
    self.name = nil
    self.command = []
    self.environment = [:]
    self.labels = ["testcontainers.swift": "true"]  // Default label
    self.ports = []
    self.waitStrategy = .none
    self.host = "127.0.0.1"
}
```

Labels are passed to Docker during container creation in `DockerClient.runContainer()`:

```swift
for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
    args += ["--label", "\(key)=\(value)"]
}
```

**Current label capabilities:**
- Default label: `testcontainers.swift=true` applied to all containers
- Users can add custom labels via `.withLabel(key, value)`
- Labels are passed to `docker run --label` correctly

### Scenarios Where Cleanup Fails

1. **Process crash or SIGKILL**: Swift process terminates before cleanup code runs
2. **Force quit in IDE**: Development environments force-terminate test runs
3. **System shutdown**: Machine powers off during test execution
4. **OOM kill**: Operating system kills process due to memory pressure
5. **Debugger detachment**: Debugging session ends abruptly
6. **Network issues during cleanup**: Docker daemon unreachable when cleanup attempts to run
7. **Unhandled exceptions outside withContainer**: Containers started but scope never completed

## Requirements

### Core Functionality

1. **Label-Based Container Identification**
   - Use existing `testcontainers.swift=true` label to identify library-managed containers
   - Support additional labels for session identification (PID, UUID, timestamp)
   - Support filtering by custom label patterns
   - Optionally include/exclude specific images or container names

2. **Age-Based Cleanup**
   - Calculate container age from creation timestamp
   - Filter containers older than a threshold (default: 10 minutes)
   - Prevent cleanup of recently created containers (guard against cleaning active containers)
   - Support different age thresholds for different scenarios

3. **Manual Cleanup Command**
   - CLI-style function/method to perform on-demand cleanup
   - Dry-run mode to preview what would be cleaned up
   - Verbose output showing containers found and removed
   - Summary statistics (found, removed, errors)

4. **Automatic Cleanup on Startup**
   - Optional: Clean up orphaned containers when test suite initializes
   - Configuration to enable/disable automatic cleanup
   - Configurable age threshold for automatic cleanup
   - Log cleanup actions for observability

5. **Ryuk-Style Sidecar Reaper (Optional)**
   - Long-running lightweight container that monitors and cleans up
   - Connect test process to reaper via TCP heartbeat
   - Reaper removes containers when heartbeat stops
   - Reaper container labels itself as a reaper for identification
   - Reuse existing reaper if already running
   - Clean up reaper itself when no longer needed

6. **Session Labeling**
   - Add unique session identifier to each container
   - Session labels include: process PID, session UUID, start timestamp
   - Enable cleanup of only current session's containers
   - Support cleaning containers from specific past sessions

### Safety Requirements

1. **Prevent False Positives**
   - Never remove containers from other users/processes if not orphaned
   - Require minimum age before removal (prevent race conditions)
   - Verify container is stopped or stuck before removal
   - Double-check labels before removal

2. **Error Handling**
   - Gracefully handle Docker daemon unavailability
   - Log errors for individual container removal failures
   - Continue cleanup process even if some containers fail to remove
   - Report summary of successes and failures

3. **Performance**
   - Cleanup should complete in reasonable time (<5 seconds for typical cases)
   - Minimize Docker API calls
   - Use batch operations where possible
   - Support parallel removal of containers

### Configuration Requirements

1. **Global Configuration Object**
   - Centralized cleanup configuration
   - Enable/disable automatic cleanup
   - Set age thresholds
   - Configure Ryuk behavior
   - Set logging/verbosity levels

2. **Environment Variable Support**
   - `TESTCONTAINERS_CLEANUP_ENABLED`: Enable automatic cleanup (default: false)
   - `TESTCONTAINERS_CLEANUP_AGE_THRESHOLD`: Age in seconds before cleanup (default: 600)
   - `TESTCONTAINERS_RYUK_DISABLED`: Disable Ryuk reaper (default: false)
   - `TESTCONTAINERS_RYUK_CONTAINER_IMAGE`: Custom reaper image
   - `TESTCONTAINERS_CLEANUP_DRY_RUN`: Preview cleanup without removing

3. **Programmatic Configuration**
   - API to configure cleanup behavior in code
   - Override environment variables
   - Configure per-test or per-suite

## API Design

### Proposed Swift API

```swift
// MARK: - Global Configuration

/// Global cleanup configuration for test containers
public struct TestContainersCleanupConfig: Sendable {
    /// Enable automatic cleanup on test suite initialization
    public var automaticCleanupEnabled: Bool

    /// Minimum age (in seconds) before a container is eligible for cleanup
    public var ageThresholdSeconds: TimeInterval

    /// Enable Ryuk-style sidecar reaper for process-lifetime container tracking
    public var ryukEnabled: Bool

    /// Docker image to use for Ryuk reaper container
    public var ryukImage: String

    /// Ryuk heartbeat interval (seconds)
    public var ryukHeartbeatInterval: TimeInterval

    /// Include session labels (PID, UUID) on all containers
    public var sessionLabelsEnabled: Bool

    /// Custom label filters for cleanup (in addition to testcontainers.swift=true)
    public var customLabelFilters: [String: String]

    /// Dry run mode - preview cleanup without removing containers
    public var dryRun: Bool

    /// Verbose logging for cleanup operations
    public var verbose: Bool

    public init(
        automaticCleanupEnabled: Bool = false,
        ageThresholdSeconds: TimeInterval = 600,
        ryukEnabled: Bool = false,
        ryukImage: String = "testcontainers/ryuk:0.6.0",
        ryukHeartbeatInterval: TimeInterval = 10,
        sessionLabelsEnabled: Bool = true,
        customLabelFilters: [String: String] = [:],
        dryRun: Bool = false,
        verbose: Bool = false
    )

    /// Load configuration from environment variables
    public static func fromEnvironment() -> Self

    /// Builder methods
    public func withAutomaticCleanup(_ enabled: Bool) -> Self
    public func withAgeThreshold(_ seconds: TimeInterval) -> Self
    public func withRyuk(enabled: Bool, image: String? = nil) -> Self
    public func withSessionLabels(_ enabled: Bool) -> Self
    public func withCustomLabelFilter(_ key: String, _ value: String) -> Self
    public func withDryRun(_ enabled: Bool) -> Self
    public func withVerbose(_ enabled: Bool) -> Self
}

// MARK: - Cleanup Result

/// Result of cleanup operation with statistics
public struct CleanupResult: Sendable {
    /// Total containers found matching criteria
    public let containersFound: Int

    /// Containers successfully removed
    public let containersRemoved: Int

    /// Containers that failed to remove
    public let containersFailed: Int

    /// Details of containers processed
    public let containers: [CleanupContainerInfo]

    /// Errors encountered during cleanup
    public let errors: [CleanupError]

    public struct CleanupContainerInfo: Sendable {
        public let id: String
        public let name: String?
        public let image: String
        public let createdAt: Date
        public let age: TimeInterval
        public let labels: [String: String]
        public let removed: Bool
        public let error: String?
    }
}

// MARK: - Cleanup Manager

/// Manages cleanup of orphaned test containers
public actor TestContainersCleanup {
    private let docker: DockerClient
    private let config: TestContainersCleanupConfig

    public init(config: TestContainersCleanupConfig = .init(), docker: DockerClient = DockerClient())

    /// Perform cleanup of orphaned containers
    /// - Returns: Result with statistics and details
    public func cleanup() async throws -> CleanupResult

    /// Perform cleanup with custom age threshold
    public func cleanup(olderThan ageSeconds: TimeInterval) async throws -> CleanupResult

    /// Perform cleanup filtering by specific session ID
    public func cleanup(sessionId: String) async throws -> CleanupResult

    /// List containers that would be cleaned up (dry run)
    public func listOrphanedContainers() async throws -> [CleanupResult.CleanupContainerInfo]

    /// Remove a specific container by ID
    public func removeContainer(_ id: String) async throws
}

// MARK: - Global Convenience Functions

/// Perform cleanup with default configuration
public func cleanupOrphanedContainers(
    config: TestContainersCleanupConfig = .init()
) async throws -> CleanupResult

/// Perform cleanup with age threshold
public func cleanupOrphanedContainers(
    olderThan ageSeconds: TimeInterval,
    config: TestContainersCleanupConfig = .init()
) async throws -> CleanupResult

// MARK: - Ryuk Reaper (Optional)

/// Ryuk-style sidecar reaper for automatic cleanup
public actor RyukReaper {
    private let docker: DockerClient
    private let config: TestContainersCleanupConfig
    private var reaperContainer: Container?
    private var heartbeatTask: Task<Void, Never>?

    public init(config: TestContainersCleanupConfig, docker: DockerClient = DockerClient())

    /// Start the reaper container and begin heartbeat
    public func start() async throws

    /// Stop the reaper container and cleanup
    public func stop() async throws

    /// Check if reaper is running
    public func isRunning() async -> Bool

    /// Connect to existing reaper or start a new one
    public func connect() async throws
}

// MARK: - Session Management

/// Manages session-specific container labels
public struct TestContainersSession: Sendable {
    public let id: String
    public let startTime: Date
    public let processId: Int32

    public init()

    /// Get labels to apply to all containers in this session
    public var sessionLabels: [String: String] {
        [
            "testcontainers.swift.session.id": id,
            "testcontainers.swift.session.pid": String(processId),
            "testcontainers.swift.session.started": String(Int(startTime.timeIntervalSince1970))
        ]
    }
}

// Global current session
public let currentTestSession: TestContainersSession

// MARK: - ContainerRequest Extension

extension ContainerRequest {
    /// Apply current session labels to this request
    public func withSessionLabels() -> Self {
        var copy = self
        for (key, value) in currentTestSession.sessionLabels {
            copy.labels[key] = value
        }
        return copy
    }
}

// MARK: - Error Types

public enum CleanupError: Error, CustomStringConvertible, Sendable {
    case dockerUnavailable
    case containerRemovalFailed(id: String, reason: String)
    case ryukStartupFailed(reason: String)
    case ryukConnectionFailed(reason: String)
    case inspectionFailed(id: String, reason: String)

    public var description: String {
        switch self {
        case .dockerUnavailable:
            return "Docker daemon unavailable for cleanup"
        case let .containerRemovalFailed(id, reason):
            return "Failed to remove container \(id): \(reason)"
        case let .ryukStartupFailed(reason):
            return "Failed to start Ryuk reaper: \(reason)"
        case let .ryukConnectionFailed(reason):
            return "Failed to connect to Ryuk reaper: \(reason)"
        case let .inspectionFailed(id, reason):
            return "Failed to inspect container \(id): \(reason)"
        }
    }
}
```

### Usage Examples

#### Example 1: Manual Cleanup

```swift
import Testing
import TestContainers

// Before running tests, clean up orphaned containers
@Test func cleanupBeforeTests() async throws {
    let result = try await cleanupOrphanedContainers(
        olderThan: 600,  // 10 minutes
        config: TestContainersCleanupConfig()
            .withVerbose(true)
    )

    print("Cleanup completed:")
    print("  Found: \(result.containersFound)")
    print("  Removed: \(result.containersRemoved)")
    print("  Failed: \(result.containersFailed)")
}
```

#### Example 2: Dry Run to Preview Cleanup

```swift
// Check what would be cleaned up without removing
@Test func previewCleanup() async throws {
    let cleanup = TestContainersCleanup(
        config: TestContainersCleanupConfig()
            .withDryRun(true)
            .withVerbose(true)
    )

    let containers = try await cleanup.listOrphanedContainers()

    for container in containers {
        print("Would remove: \(container.id) - \(container.image) (age: \(container.age)s)")
    }
}
```

#### Example 3: Automatic Cleanup with Environment Variables

```bash
# Set environment variables
export TESTCONTAINERS_CLEANUP_ENABLED=1
export TESTCONTAINERS_CLEANUP_AGE_THRESHOLD=300  # 5 minutes
```

```swift
// Cleanup runs automatically when first container is started
@Test func myTest() async throws {
    // Automatic cleanup happens transparently here
    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379))

    try await withContainer(request) { container in
        // Test code...
    }
}
```

#### Example 4: Session-Based Cleanup

```swift
// Add session labels to containers for easier cleanup
@Test func testWithSessionLabels() async throws {
    let request = ContainerRequest(image: "postgres:15")
        .withExposedPort(5432)
        .withSessionLabels()  // Add session-specific labels

    try await withContainer(request) { container in
        // Test code...
    }
}

// Later, clean up only this session's containers
@Test func cleanupCurrentSession() async throws {
    let cleanup = TestContainersCleanup()
    let result = try await cleanup.cleanup(sessionId: currentTestSession.id)
    print("Cleaned up \(result.containersRemoved) containers from this session")
}
```

#### Example 5: Ryuk-Style Reaper

```swift
// Start reaper at test suite initialization
let reaper = RyukReaper(
    config: TestContainersCleanupConfig()
        .withRyuk(enabled: true)
)

try await reaper.start()

// Run tests normally - reaper monitors process
@Test func myTest() async throws {
    let request = ContainerRequest(image: "mysql:8")
        .withExposedPort(3306)

    try await withContainer(request) { container in
        // If process crashes, reaper will clean up
    }
}

// Stop reaper at test suite teardown
try await reaper.stop()
```

#### Example 6: Custom Label Filters

```swift
// Clean up only containers with specific custom labels
let config = TestContainersCleanupConfig()
    .withCustomLabelFilter("test.suite", "integration")
    .withCustomLabelFilter("test.environment", "ci")

let cleanup = TestContainersCleanup(config: config)
let result = try await cleanup.cleanup()
```

## Implementation Steps

### 1. Create TestContainersSession Module

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersSession.swift`

- Define `TestContainersSession` struct
- Generate unique session ID (UUID)
- Capture process ID via `ProcessInfo.processInfo.processIdentifier`
- Capture session start time
- Provide `sessionLabels` computed property
- Create global `currentTestSession` instance

**Implementation notes:**
- Session ID should be generated once per process
- Use `UUID().uuidString` for session ID
- Store as `let` global initialized on first access
- Ensure thread-safety with appropriate access patterns

### 2. Extend ContainerRequest with Session Labels

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

- Add `withSessionLabels()` builder method
- Merge session labels into existing labels dictionary
- Update default label initialization to optionally include session labels

**Implementation notes:**
- Keep backward compatibility (session labels opt-in by default)
- Session labels should merge with existing labels
- Follow existing builder pattern

### 3. Create CleanupConfig Module

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersCleanupConfig.swift`

- Define `TestContainersCleanupConfig` struct
- Implement all builder methods
- Implement `fromEnvironment()` static method to read env vars
- Add validation for configuration values

**Implementation notes:**
- Use `ProcessInfo.processInfo.environment` to read env vars
- Parse numeric values safely with defaults on parse failure
- Boolean env vars: "1", "true", "yes" = true, others = false
- Follow existing code style with `Sendable` conformance

### 4. Extend DockerClient with Cleanup Operations

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Add methods:
- `func listContainers(labels: [String: String]) async throws -> [ContainerListItem]`
- `func inspectContainer(id: String) async throws -> ContainerInspection` (simplified version)
- `func removeContainers(ids: [String]) async throws -> [String: Error?]`

**Implementation details:**

```swift
struct ContainerListItem: Sendable, Codable {
    let id: String
    let names: [String]
    let image: String
    let created: Int  // Unix timestamp
    let labels: [String: String]
    let state: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case names = "Names"
        case image = "Image"
        case created = "Created"
        case labels = "Labels"
        case state = "State"
    }
}

func listContainers(labels: [String: String] = [:]) async throws -> [ContainerListItem] {
    var args = ["ps", "-a", "--format", "{{json .}}"]

    for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
        args += ["--filter", "label=\(key)=\(value)"]
    }

    let output = try await runDocker(args)
    let lines = output.stdout.split(separator: "\n")

    return try lines.compactMap { line in
        guard !line.isEmpty else { return nil }
        return try JSONDecoder().decode(ContainerListItem.self, from: Data(line.utf8))
    }
}

func removeContainers(ids: [String], force: Bool = true) async throws -> [String: Error?] {
    var results: [String: Error?] = [:]

    // Remove containers in parallel
    await withTaskGroup(of: (String, Error?).self) { group in
        for id in ids {
            group.addTask {
                do {
                    var args = ["rm"]
                    if force { args.append("-f") }
                    args.append(id)
                    _ = try await self.runDocker(args)
                    return (id, nil)
                } catch {
                    return (id, error)
                }
            }
        }

        for await (id, error) in group {
            results[id] = error
        }
    }

    return results
}
```

**Key considerations:**
- Use `docker ps -a --format "{{json .}}"` for structured output
- Apply label filters via `--filter label=key=value`
- Parse JSON output line by line (one JSON object per container)
- Handle parallel removal for performance
- Return error map so caller can report partial failures

### 5. Create TestContainersCleanup Actor

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersCleanup.swift`

- Implement `TestContainersCleanup` actor
- Implement core `cleanup()` method
- Implement age calculation and filtering
- Implement dry-run mode
- Implement verbose logging
- Generate `CleanupResult` with statistics

**Implementation outline:**

```swift
public actor TestContainersCleanup {
    private let docker: DockerClient
    private let config: TestContainersCleanupConfig

    public init(config: TestContainersCleanupConfig = .init(), docker: DockerClient = DockerClient()) {
        self.docker = docker
        self.config = config
    }

    public func cleanup() async throws -> CleanupResult {
        return try await cleanup(olderThan: config.ageThresholdSeconds)
    }

    public func cleanup(olderThan ageSeconds: TimeInterval) async throws -> CleanupResult {
        // Check Docker availability
        guard await docker.isAvailable() else {
            throw CleanupError.dockerUnavailable
        }

        // Build label filters
        var labelFilters = ["testcontainers.swift": "true"]
        labelFilters.merge(config.customLabelFilters) { _, new in new }

        // List containers matching labels
        let containers = try await docker.listContainers(labels: labelFilters)

        let now = Date()
        var containerInfos: [CleanupResult.CleanupContainerInfo] = []
        var containersToRemove: [String] = []
        var errors: [CleanupError] = []

        // Filter by age
        for container in containers {
            let createdDate = Date(timeIntervalSince1970: TimeInterval(container.created))
            let age = now.timeIntervalSince(createdDate)

            let info = CleanupResult.CleanupContainerInfo(
                id: container.id,
                name: container.names.first,
                image: container.image,
                createdAt: createdDate,
                age: age,
                labels: container.labels,
                removed: false,
                error: nil
            )

            if age >= ageSeconds {
                containersToRemove.append(container.id)
                containerInfos.append(info)

                if config.verbose {
                    print("[TestContainers] Cleanup candidate: \(container.id) (age: \(Int(age))s)")
                }
            }
        }

        // Dry run mode - don't actually remove
        if config.dryRun {
            if config.verbose {
                print("[TestContainers] Dry run - would remove \(containersToRemove.count) containers")
            }
            return CleanupResult(
                containersFound: containerInfos.count,
                containersRemoved: 0,
                containersFailed: 0,
                containers: containerInfos,
                errors: []
            )
        }

        // Remove containers
        let removalResults = try await docker.removeContainers(ids: containersToRemove)

        // Update container infos with results
        var removedCount = 0
        var failedCount = 0

        for (index, id) in containersToRemove.enumerated() {
            if let error = removalResults[id] {
                containerInfos[index] = CleanupResult.CleanupContainerInfo(
                    id: containerInfos[index].id,
                    name: containerInfos[index].name,
                    image: containerInfos[index].image,
                    createdAt: containerInfos[index].createdAt,
                    age: containerInfos[index].age,
                    labels: containerInfos[index].labels,
                    removed: false,
                    error: error.localizedDescription
                )
                failedCount += 1
                errors.append(.containerRemovalFailed(id: id, reason: error.localizedDescription))

                if config.verbose {
                    print("[TestContainers] Failed to remove \(id): \(error)")
                }
            } else {
                containerInfos[index] = CleanupResult.CleanupContainerInfo(
                    id: containerInfos[index].id,
                    name: containerInfos[index].name,
                    image: containerInfos[index].image,
                    createdAt: containerInfos[index].createdAt,
                    age: containerInfos[index].age,
                    labels: containerInfos[index].labels,
                    removed: true,
                    error: nil
                )
                removedCount += 1

                if config.verbose {
                    print("[TestContainers] Removed \(id)")
                }
            }
        }

        return CleanupResult(
            containersFound: containerInfos.count,
            containersRemoved: removedCount,
            containersFailed: failedCount,
            containers: containerInfos,
            errors: errors
        )
    }

    public func cleanup(sessionId: String) async throws -> CleanupResult {
        let config = self.config.withCustomLabelFilter("testcontainers.swift.session.id", sessionId)
        let cleanup = TestContainersCleanup(config: config, docker: docker)
        return try await cleanup.cleanup()
    }

    public func listOrphanedContainers() async throws -> [CleanupResult.CleanupContainerInfo] {
        let config = self.config.withDryRun(true)
        let cleanup = TestContainersCleanup(config: config, docker: docker)
        let result = try await cleanup.cleanup()
        return result.containers
    }

    public func removeContainer(_ id: String) async throws {
        let results = try await docker.removeContainers(ids: [id])
        if let error = results[id] {
            throw CleanupError.containerRemovalFailed(id: id, reason: error.localizedDescription)
        }
    }
}
```

**Key considerations:**
- Use actor to ensure thread-safe access
- Calculate age from Unix timestamp (Docker's `Created` field)
- Support verbose logging with `print()` statements
- Collect errors but continue processing
- Generate detailed result with statistics

### 6. Add Global Convenience Functions

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersCleanup.swift`

Add public convenience functions:

```swift
public func cleanupOrphanedContainers(
    config: TestContainersCleanupConfig = .init()
) async throws -> CleanupResult {
    let cleanup = TestContainersCleanup(config: config)
    return try await cleanup.cleanup()
}

public func cleanupOrphanedContainers(
    olderThan ageSeconds: TimeInterval,
    config: TestContainersCleanupConfig = .init()
) async throws -> CleanupResult {
    let cleanup = TestContainersCleanup(config: config)
    return try await cleanup.cleanup(olderThan: ageSeconds)
}
```

### 7. Implement Automatic Cleanup Hook (Optional)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`

Modify `withContainer` to perform automatic cleanup on first invocation:

```swift
private actor CleanupCoordinator {
    private var hasPerformedStartupCleanup = false

    func performStartupCleanupIfNeeded() async throws {
        guard !hasPerformedStartupCleanup else { return }
        hasPerformedStartupCleanup = true

        let config = TestContainersCleanupConfig.fromEnvironment()
        guard config.automaticCleanupEnabled else { return }

        let cleanup = TestContainersCleanup(config: config)
        let result = try await cleanup.cleanup()

        if config.verbose {
            print("[TestContainers] Startup cleanup: removed \(result.containersRemoved) orphaned containers")
        }
    }
}

private let cleanupCoordinator = CleanupCoordinator()

public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    // Perform startup cleanup on first invocation
    try await cleanupCoordinator.performStartupCleanupIfNeeded()

    // ... rest of existing implementation
}
```

### 8. Implement Ryuk Reaper (Optional Advanced Feature)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/RyukReaper.swift`

- Start Ryuk container with special labels
- Connect to Ryuk via TCP socket
- Send heartbeat at regular intervals
- Implement connection failure handling
- Clean up reaper container on stop

**Implementation notes:**
- Use `testcontainers/ryuk:0.6.0` image (or custom)
- Ryuk listens on port 8080 for connections
- Send heartbeat: "label=testcontainers.swift.session.id=<session_id>\n"
- Reuse existing reaper if found via labels
- This is an advanced feature, implement last

**Ryuk protocol:**
1. Start ryuk container: `docker run -d -v /var/run/docker.sock:/var/run/docker.sock -p 8080 testcontainers/ryuk:0.6.0`
2. Connect to exposed port
3. Send filters: `label=testcontainers.swift.session.id=<id>`
4. Send heartbeat: ACK message every 10 seconds
5. Ryuk removes containers when connection drops

### 9. Add Error Types

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

Add cleanup-related errors:

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    // ... existing cases
    case cleanupFailed(String)
    case ryukUnavailable(String)
}
```

Or create separate error type as shown in API design.

### 10. Update Documentation

**Files to update:**
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/README.md` - Add cleanup section
- Add inline documentation to all public APIs
- Create usage examples in doc comments

## Testing Plan

### Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/TestContainersCleanupTests.swift`

1. **Configuration Tests**
   - Test default config values
   - Test builder pattern methods
   - Test `fromEnvironment()` with various env var values
   - Test config validation

2. **Session Tests**
   - Test session ID generation (unique)
   - Test session labels format
   - Test process ID capture
   - Test timestamp generation

3. **ContainerRequest Session Label Tests**
   - Test `withSessionLabels()` adds correct labels
   - Test session labels merge with existing labels
   - Test session labels don't override custom labels

4. **Age Calculation Tests**
   - Test age calculation from Unix timestamp
   - Test age threshold filtering
   - Test containers below threshold are excluded

5. **Result Generation Tests**
   - Test `CleanupResult` statistics calculation
   - Test error collection
   - Test partial failure handling

### Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/CleanupIntegrationTests.swift`

All tests opt-in via `TESTCONTAINERS_RUN_DOCKER_TESTS=1`:

```swift
@Test func canListOrphanedContainers() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create a test container that won't be cleaned up
    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "300"])
        .withSessionLabels()

    let docker = DockerClient()
    let id = try await docker.runContainer(request)

    // List orphaned containers (should not include recently created)
    let cleanup = TestContainersCleanup(
        config: TestContainersCleanupConfig()
            .withAgeThreshold(60)  // 1 minute
    )

    let containers = try await cleanup.listOrphanedContainers()

    // Our container should not be in the list (too recent)
    #expect(!containers.contains(where: { $0.id == id }))

    // Clean up test container
    try await docker.removeContainer(id: id)
}

@Test func canCleanupOldContainers() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create a test container with old age (simulate by waiting)
    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "1"])
        .withLabel("test.cleanup", "true")

    let docker = DockerClient()
    let id = try await docker.runContainer(request)

    // Wait for container to age
    try await Task.sleep(for: .seconds(2))

    // Cleanup with very short age threshold
    let cleanup = TestContainersCleanup(
        config: TestContainersCleanupConfig()
            .withAgeThreshold(1)
            .withCustomLabelFilter("test.cleanup", "true")
    )

    let result = try await cleanup.cleanup()

    #expect(result.containersFound >= 1)
    #expect(result.containersRemoved >= 1)
    #expect(result.containers.contains(where: { $0.id == id }))
}

@Test func dryRunDoesNotRemoveContainers() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "1"])
        .withLabel("test.dryrun", "true")

    let docker = DockerClient()
    let id = try await docker.runContainer(request)

    try await Task.sleep(for: .seconds(2))

    // Dry run cleanup
    let cleanup = TestContainersCleanup(
        config: TestContainersCleanupConfig()
            .withAgeThreshold(1)
            .withCustomLabelFilter("test.dryrun", "true")
            .withDryRun(true)
    )

    let result = try await cleanup.cleanup()

    #expect(result.containersFound >= 1)
    #expect(result.containersRemoved == 0)  // Dry run doesn't remove

    // Verify container still exists
    let containers = try await docker.listContainers(labels: ["test.dryrun": "true"])
    #expect(containers.contains(where: { $0.id == id }))

    // Clean up
    try await docker.removeContainer(id: id)
}

@Test func cleanupHandlesPartialFailures() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let cleanup = TestContainersCleanup()

    // Try to remove non-existent container
    await #expect(throws: CleanupError.self) {
        try await cleanup.removeContainer("nonexistent")
    }
}

@Test func sessionLabelsAreApplied() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "300"])
        .withSessionLabels()

    let docker = DockerClient()
    let id = try await docker.runContainer(request)

    // Verify session labels were applied (requires inspect functionality)
    // For now, just verify container was created
    #expect(!id.isEmpty)

    // Clean up
    try await docker.removeContainer(id: id)
}

@Test func canCleanupSpecificSession() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create containers with custom session ID
    let customSessionId = UUID().uuidString

    let request = ContainerRequest(image: "alpine:latest")
        .withCommand(["sleep", "1"])
        .withLabel("testcontainers.swift.session.id", customSessionId)

    let docker = DockerClient()
    let id = try await docker.runContainer(request)

    try await Task.sleep(for: .seconds(2))

    // Cleanup only this session
    let cleanup = TestContainersCleanup(
        config: TestContainersCleanupConfig()
            .withAgeThreshold(1)
    )

    let result = try await cleanup.cleanup(sessionId: customSessionId)

    #expect(result.containersRemoved >= 1)
}

@Test func automaticCleanupViaEnvironment() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Set environment variable (would need to be set before process starts in reality)
    // This test just verifies the config parsing

    let config = TestContainersCleanupConfig.fromEnvironment()

    // Test that config reads environment correctly
    if ProcessInfo.processInfo.environment["TESTCONTAINERS_CLEANUP_ENABLED"] == "1" {
        #expect(config.automaticCleanupEnabled)
    }
}
```

### Manual Testing Scenarios

1. **Crash Scenario**
   - Start a test that creates a container
   - Force-kill the test process (SIGKILL)
   - Verify container is still running
   - Run cleanup manually
   - Verify container is removed

2. **Age Threshold**
   - Create containers with different ages
   - Run cleanup with specific age threshold
   - Verify only old containers are removed

3. **Label Filtering**
   - Create containers with various labels
   - Run cleanup with custom label filters
   - Verify only matching containers are removed

4. **Dry Run**
   - Create orphaned containers
   - Run cleanup in dry-run mode
   - Verify containers are not removed
   - Verify dry-run output is correct

5. **Automatic Cleanup**
   - Set `TESTCONTAINERS_CLEANUP_ENABLED=1`
   - Leave orphaned containers from previous run
   - Run a new test
   - Verify orphaned containers are cleaned up automatically

6. **Parallel Cleanup**
   - Create many orphaned containers (10+)
   - Run cleanup
   - Verify all are removed efficiently
   - Check performance (should complete quickly)

## Acceptance Criteria

### Must Have

- [ ] `TestContainersSession` struct with unique ID, PID, and timestamp
- [ ] Global `currentTestSession` instance
- [ ] `ContainerRequest.withSessionLabels()` method
- [ ] `TestContainersCleanupConfig` struct with builder pattern
- [ ] `TestContainersCleanupConfig.fromEnvironment()` method
- [ ] Environment variable support for configuration
- [ ] `DockerClient.listContainers(labels:)` method
- [ ] `DockerClient.removeContainers(ids:)` method with parallel removal
- [ ] `TestContainersCleanup` actor
- [ ] `cleanup()` method with age threshold
- [ ] `cleanup(olderThan:)` method
- [ ] `cleanup(sessionId:)` method
- [ ] `listOrphanedContainers()` method for dry-run
- [ ] `CleanupResult` struct with statistics
- [ ] Global convenience functions `cleanupOrphanedContainers(...)`
- [ ] Age-based filtering (default 10 minutes)
- [ ] Dry-run mode
- [ ] Verbose logging mode
- [ ] Error collection (partial failure support)
- [ ] Unit tests with >80% coverage
- [ ] Integration tests with real Docker containers
- [ ] Documentation in code (doc comments)
- [ ] README updated with cleanup examples

### Should Have

- [ ] Automatic cleanup on startup (opt-in via env var)
- [ ] Session-specific cleanup
- [ ] Custom label filter support
- [ ] Parallel container removal for performance
- [ ] Detailed error reporting
- [ ] Container info in cleanup result (ID, image, age, labels)

### Nice to Have

- [ ] Ryuk-style sidecar reaper
- [ ] Reaper heartbeat mechanism
- [ ] Reaper connection reuse
- [ ] Cleanup statistics logging
- [ ] Cleanup performance metrics
- [ ] Support for cleaning up by image name
- [ ] Support for cleaning up by container name pattern
- [ ] Interactive cleanup mode (prompt before removing)

### Definition of Done

- All "Must Have" criteria completed
- All "Should Have" criteria completed or explicitly deferred
- All tests passing
- Unit tests cover configuration, session management, and age calculation
- Integration tests verify actual Docker cleanup operations
- Code review completed
- Documentation reviewed
- Manually tested crash scenario (forced process termination)
- Manually tested age threshold filtering
- Manually tested dry-run mode
- No regressions in existing functionality
- Follows existing code style and patterns
- All public APIs have comprehensive documentation comments
- README includes cleanup section with examples
- Environment variable documentation complete

## References

### Related Files

- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift` - Current cleanup implementation
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift` - Container termination
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift` - Docker operations
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` - Label system
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift` - Error types

### Similar Implementations

**Testcontainers Java:**
- `ResourceReaper` class for automatic cleanup
- Ryuk container for process-bound cleanup
- Session-based resource tracking
- JVM shutdown hook integration

**Testcontainers Go:**
- `Reaper` struct with label-based cleanup
- Session ID in labels
- Ryuk container support
- `testcontainers.SessionID()` helper

**Testcontainers Node:**
- `TestContainers` class with cleanup methods
- Ryuk container for process monitoring
- Label-based filtering
- Process exit hooks

### Docker CLI Reference

- `docker ps -a --filter "label=key=value"` - List containers by label
- `docker ps -a --format "{{json .}}"` - JSON output format
- `docker rm -f <id>` - Force remove container
- `docker inspect <id>` - Get detailed container info

### Ryuk Documentation

- [testcontainers/moby-ryuk](https://github.com/testcontainers/moby-ryuk) - Official Ryuk implementation
- Ryuk protocol: TCP connection with label filters and heartbeat
- Ryuk image: `testcontainers/ryuk:0.6.0`

## Future Enhancements

1. **Network and Volume Cleanup**
   - Clean up orphaned networks created by test containers
   - Clean up orphaned volumes
   - Detect and remove unused networks/volumes

2. **Container Health Monitoring**
   - Identify containers in unhealthy state
   - Remove stuck containers (starting, restarting, etc.)
   - Alert on containers consuming excessive resources

3. **Cleanup Scheduling**
   - Background cleanup daemon
   - Scheduled cleanup runs
   - Configurable cleanup intervals

4. **Cleanup Policies**
   - Policy-based cleanup (always keep last N containers)
   - Image-specific cleanup rules
   - Resource-based cleanup (remove when disk full)

5. **Observability**
   - Cleanup metrics export
   - Integration with logging systems
   - Cleanup dashboard/reporting

6. **Multi-User Safety**
   - User-specific labels
   - Prevent cleanup of other users' containers
   - Shared cleanup coordination

## Implementation Priority

1. **Phase 1: Core Cleanup (Must Have)**
   - Session management
   - Label system
   - Basic cleanup with age threshold
   - Manual cleanup commands
   - Configuration system

2. **Phase 2: Enhanced Cleanup (Should Have)**
   - Automatic startup cleanup
   - Session-specific cleanup
   - Parallel removal
   - Improved error handling

3. **Phase 3: Advanced Features (Nice to Have)**
   - Ryuk reaper implementation
   - Advanced filtering
   - Performance optimization

## Notes

- This feature addresses issue #91 in FEATURES.md: "Global cleanup for leaked containers (Ryuk/Reaper-style or label-based sweeper)"
- The label-based approach is more portable than Ryuk (works without additional containers)
- Ryuk provides the most robust cleanup but adds complexity
- Start with label-based cleanup, add Ryuk later if needed
- Consider making automatic cleanup opt-in to avoid surprises
- Age threshold prevents accidentally removing active containers from parallel test runs
- Session labels enable safe cleanup of only current session's containers
