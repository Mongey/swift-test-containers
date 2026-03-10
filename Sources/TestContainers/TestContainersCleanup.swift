import Foundation

/// Manages cleanup of orphaned test containers.
///
/// The cleanup actor provides methods to identify and remove containers
/// that were left behind from crashed test processes or interrupted runs.
/// It uses label-based filtering to identify containers created by this library.
///
/// Example usage:
/// ```swift
/// let cleanup = TestContainersCleanup(
///     config: TestContainersCleanupConfig()
///         .withAgeThreshold(300)
///         .withVerbose(true)
/// )
///
/// let result = try await cleanup.cleanup()
/// print("Removed \(result.containersRemoved) containers")
/// ```
public actor TestContainersCleanup {
    private let runtime: any ContainerRuntime
    private let config: TestContainersCleanupConfig

    /// The current cleanup configuration.
    public var configuration: TestContainersCleanupConfig {
        config
    }

    /// Create a new cleanup manager with the given configuration.
    ///
    /// - Parameters:
    ///   - config: Configuration for cleanup behavior (defaults to standard config)
    ///   - docker: Docker client to use (defaults to new client)
    public init(
        config: TestContainersCleanupConfig = TestContainersCleanupConfig(),
        runtime: any ContainerRuntime = DockerClient()
    ) {
        self.config = config
        self.runtime = runtime
    }

    /// Perform cleanup of orphaned containers using the configured age threshold.
    ///
    /// - Returns: Result with statistics and details about the cleanup operation
    /// - Throws: `CleanupError.dockerUnavailable` if Docker is not running
    public func cleanup() async throws -> CleanupResult {
        try await cleanup(olderThan: config.ageThresholdSeconds)
    }

    /// Perform cleanup of containers older than the specified age.
    ///
    /// - Parameter ageSeconds: Minimum age in seconds for a container to be eligible
    /// - Returns: Result with statistics and details about the cleanup operation
    /// - Throws: `CleanupError.dockerUnavailable` if Docker is not running
    public func cleanup(olderThan ageSeconds: TimeInterval) async throws -> CleanupResult {
        // Check Docker availability
        guard await runtime.isAvailable() else {
            throw CleanupError.dockerUnavailable
        }

        // Build label filters from configuration
        let labelFilters = config.buildLabelFilters()

        // List containers matching labels
        let containers: [ContainerListItem]
        do {
            containers = try await runtime.listContainers(labels: labelFilters)
        } catch {
            throw CleanupError.dockerUnavailable
        }

        let now = Date()
        var containerInfos: [CleanupResult.CleanupContainerInfo] = []
        var containersToRemove: [String] = []
        var errors: [CleanupError] = []

        // Filter by age and build info list
        for container in containers {
            let age = now.timeIntervalSince(container.createdDate)

            if age >= ageSeconds {
                let info = CleanupResult.CleanupContainerInfo(
                    id: container.id,
                    name: container.firstName,
                    image: container.image,
                    createdAt: container.createdDate,
                    age: age,
                    labels: container.parsedLabels,
                    removed: false,
                    error: nil
                )

                containersToRemove.append(container.id)
                containerInfos.append(info)

                if config.verbose {
                    print("[TestContainers] Cleanup candidate: \(container.id) - \(container.image) (age: \(Int(age))s)")
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

        // Remove containers in parallel
        let removalResults = await runtime.removeContainers(ids: containersToRemove)

        // Update container infos with results
        var removedCount = 0
        var failedCount = 0

        for (index, id) in containersToRemove.enumerated() {
            if let error = removalResults[id], error != nil {
                let errorMessage = error!.localizedDescription
                containerInfos[index] = CleanupResult.CleanupContainerInfo(
                    id: containerInfos[index].id,
                    name: containerInfos[index].name,
                    image: containerInfos[index].image,
                    createdAt: containerInfos[index].createdAt,
                    age: containerInfos[index].age,
                    labels: containerInfos[index].labels,
                    removed: false,
                    error: errorMessage
                )
                failedCount += 1
                errors.append(.containerRemovalFailed(id: id, reason: errorMessage))

                if config.verbose {
                    print("[TestContainers] Failed to remove \(id): \(errorMessage)")
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

        if config.verbose {
            print("[TestContainers] Cleanup complete: found \(containerInfos.count), removed \(removedCount), failed \(failedCount)")
        }

        return CleanupResult(
            containersFound: containerInfos.count,
            containersRemoved: removedCount,
            containersFailed: failedCount,
            containers: containerInfos,
            errors: errors
        )
    }

    /// Perform cleanup filtering by a specific session ID.
    ///
    /// This removes only containers from a specific test session, identified
    /// by their `testcontainers.swift.session.id` label.
    ///
    /// - Parameter sessionId: The session ID to filter by
    /// - Returns: Result with statistics and details about the cleanup operation
    /// - Throws: `CleanupError.dockerUnavailable` if Docker is not running
    public func cleanup(sessionId: String) async throws -> CleanupResult {
        let sessionConfig = config.withCustomLabelFilter("testcontainers.swift.session.id", sessionId)
        let sessionCleanup = TestContainersCleanup(config: sessionConfig, runtime: runtime)
        return try await sessionCleanup.cleanup()
    }

    /// List containers that would be cleaned up without removing them.
    ///
    /// This is equivalent to running cleanup in dry-run mode and returning
    /// only the container list.
    ///
    /// - Returns: Array of containers eligible for cleanup
    /// - Throws: `CleanupError.dockerUnavailable` if Docker is not running
    public func listOrphanedContainers() async throws -> [CleanupResult.CleanupContainerInfo] {
        let dryRunConfig = config.withDryRun(true)
        let dryRunCleanup = TestContainersCleanup(config: dryRunConfig, runtime: runtime)
        let result = try await dryRunCleanup.cleanup()
        return result.containers
    }

    /// Remove a specific container by ID.
    ///
    /// - Parameter id: The container ID to remove
    /// - Throws: `CleanupError.containerRemovalFailed` if removal fails
    public func removeContainer(_ id: String) async throws {
        let results = await runtime.removeContainers(ids: [id])
        if let error = results[id], error != nil {
            throw CleanupError.containerRemovalFailed(id: id, reason: error!.localizedDescription)
        }
    }
}

// MARK: - Global Convenience Functions

/// Perform cleanup of orphaned test containers.
///
/// This is a convenience function that creates a temporary `TestContainersCleanup`
/// instance and performs cleanup with the given configuration.
///
/// - Parameter config: Configuration for cleanup behavior
/// - Returns: Result with statistics and details about the cleanup operation
/// - Throws: `CleanupError.dockerUnavailable` if Docker is not running
public func cleanupOrphanedContainers(
    config: TestContainersCleanupConfig = TestContainersCleanupConfig()
) async throws -> CleanupResult {
    let cleanup = TestContainersCleanup(config: config)
    return try await cleanup.cleanup()
}

/// Perform cleanup of containers older than the specified age.
///
/// This is a convenience function that creates a temporary `TestContainersCleanup`
/// instance and performs cleanup with the given age threshold.
///
/// - Parameters:
///   - ageSeconds: Minimum age in seconds for a container to be eligible
///   - config: Configuration for cleanup behavior
/// - Returns: Result with statistics and details about the cleanup operation
/// - Throws: `CleanupError.dockerUnavailable` if Docker is not running
public func cleanupOrphanedContainers(
    olderThan ageSeconds: TimeInterval,
    config: TestContainersCleanupConfig = TestContainersCleanupConfig()
) async throws -> CleanupResult {
    let cleanup = TestContainersCleanup(config: config)
    return try await cleanup.cleanup(olderThan: ageSeconds)
}
