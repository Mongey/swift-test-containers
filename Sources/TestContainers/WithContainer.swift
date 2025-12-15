import Foundation

public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable("`docker` CLI not found or Docker engine not running.")
    }

    let container = try await retryableContainerStartup(request, docker: docker)

    return try await withTaskCancellationHandler {
        do {
            let result = try await operation(container)
            try await container.terminate()
            return result
        } catch {
            try? await container.terminate()
            throw error
        }
    } onCancel: {
        Task { try? await container.terminate() }
    }
}

/// Attempts to start a container with optional retry logic.
///
/// If the request has a retry policy configured, this function will retry
/// container startup (including wait strategy) on failure, using exponential
/// backoff with jitter between attempts.
///
/// - Parameters:
///   - request: The container request configuration
///   - docker: The Docker client to use
/// - Returns: A running, ready container
/// - Throws: `TestContainersError.startupRetriesExhausted` if all attempts fail
private func retryableContainerStartup(
    _ request: ContainerRequest,
    docker: DockerClient
) async throws -> Container {
    guard let policy = request.retryPolicy else {
        // No retry policy - single attempt
        return try await startContainer(request, docker: docker)
    }

    var lastError: Error?

    for attempt in 0...policy.maxAttempts {
        do {
            // Apply delay before retry (not before first attempt)
            if attempt > 0 {
                let delay = policy.delay(for: attempt)
                try await Task.sleep(for: delay)
            }

            return try await startContainer(request, docker: docker)

        } catch {
            lastError = error

            // Don't retry on certain errors - fail fast
            if shouldNotRetry(error) {
                throw error
            }

            // If we have more attempts, continue
            if attempt < policy.maxAttempts {
                continue
            }
        }
    }

    // All retries exhausted
    throw TestContainersError.startupRetriesExhausted(
        attempts: policy.maxAttempts + 1,
        lastError: lastError!
    )
}

/// Starts a container and waits for it to be ready.
/// Cleans up the container on failure.
private func startContainer(
    _ request: ContainerRequest,
    docker: DockerClient
) async throws -> Container {
    let id = try await docker.runContainer(request)
    let container = Container(id: id, request: request, docker: docker)

    do {
        try await container.waitUntilReady()
        return container
    } catch {
        // Wait failed - cleanup container before throwing
        try? await container.terminate()
        throw error
    }
}

/// Determines if an error should not be retried (fail fast).
private func shouldNotRetry(_ error: Error) -> Bool {
    switch error {
    case TestContainersError.dockerNotAvailable:
        return true  // Fail fast - Docker not available
    case is CancellationError:
        return true  // Don't retry on user cancellation
    default:
        return false  // Retry on other errors
    }
}
