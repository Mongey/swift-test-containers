import Foundation

public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable("`docker` CLI not found or Docker engine not running.")
    }

    // Build image from Dockerfile if specified
    let builtImageTag: String?
    if let dockerfileConfig = request.imageFromDockerfile {
        let tag = request.image  // Use the auto-generated tag from request
        _ = try await docker.buildImage(dockerfileConfig, tag: tag)
        builtImageTag = tag
    } else {
        builtImageTag = nil
    }

    // PreStart hooks - run before container creation
    let preStartContext = LifecycleContext(container: nil, request: request, docker: docker)
    do {
        try await executeLifecycleHooks(request.preStartHooks, context: preStartContext, phase: .preStart)
    } catch {
        // PreStart hook failed - clean up built image if any
        await cleanupBuiltImage(tag: builtImageTag, docker: docker)
        throw error
    }

    let container: Container
    do {
        container = try await retryableContainerStartup(request, docker: docker)
    } catch {
        // PreStart succeeded but container creation failed - clean up built image
        await cleanupBuiltImage(tag: builtImageTag, docker: docker)
        throw error
    }

    // PostStart hooks - run after container is ready
    let postStartContext = LifecycleContext(container: container, request: request, docker: docker)
    do {
        try await executeLifecycleHooks(request.postStartHooks, context: postStartContext, phase: .postStart)
    } catch {
        // PostStart hook failed - cleanup container and run terminate hooks
        try? await terminateWithHooks(container: container, request: request, docker: docker)
        await cleanupBuiltImage(tag: builtImageTag, docker: docker)
        throw error
    }

    return try await withTaskCancellationHandler {
        do {
            let result = try await operation(container)
            try await terminateWithHooks(container: container, request: request, docker: docker)
            await cleanupBuiltImage(tag: builtImageTag, docker: docker)
            return result
        } catch {
            try? await terminateWithHooks(container: container, request: request, docker: docker)
            await cleanupBuiltImage(tag: builtImageTag, docker: docker)
            throw error
        }
    } onCancel: {
        Task {
            try? await terminateWithHooks(container: container, request: request, docker: docker)
            await cleanupBuiltImage(tag: builtImageTag, docker: docker)
        }
    }
}

/// Cleans up a built image if one was created.
private func cleanupBuiltImage(tag: String?, docker: DockerClient) async {
    if let tag = tag {
        try? await docker.removeImage(tag)
    }
}

/// Terminates a container, running lifecycle hooks before and after.
/// Errors in hooks are logged but don't prevent termination.
private func terminateWithHooks(
    container: Container,
    request: ContainerRequest,
    docker: DockerClient
) async throws {
    let context = LifecycleContext(container: container, request: request, docker: docker)

    // PreTerminate hooks - errors are logged but don't prevent termination
    do {
        try await executeLifecycleHooks(request.preTerminateHooks, context: context, phase: .preTerminate)
    } catch {
        // Log but continue with termination
    }

    // Actually terminate the container
    try await container.terminate()

    // PostTerminate hooks - errors are logged but don't affect the result
    do {
        try await executeLifecycleHooks(request.postTerminateHooks, context: context, phase: .postTerminate)
    } catch {
        // Log but don't fail
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
