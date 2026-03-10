import Foundation

/// Create a container without starting it.
///
/// Returns a `Container` in the `.created` state. Call `start()` to start it,
/// and `terminate()` when done.
///
/// For automatic lifecycle management, prefer `withContainer(_:operation:)`.
///
/// - Important: In the runtime abstraction release, the `docker:` parameter was
///   renamed to `runtime:`.
///
/// - Parameters:
///   - request: The container configuration
///   - runtime: The container runtime to use
/// - Returns: A `Container` in `.created` state
public func createContainer(
    _ request: ContainerRequest,
    runtime: any ContainerRuntime = DockerClient(),
    logger: TCLogger = .null
) async throws -> Container {
    logger.debug("Checking Docker availability")
    if !(await runtime.isAvailable()) {
        logger.error("Docker not available")
        throw TestContainersError.dockerNotAvailable(
            "`docker` CLI not found or Docker engine not running."
        )
    }

    // Build image from Dockerfile if specified
    if let dockerfileConfig = request.imageFromDockerfile {
        let tag = request.image
        _ = try await runtime.buildImage(dockerfileConfig, tag: tag)
    }

    // Handle image pull policy and create container
    let id = try await runtime.createContainer(request)
    return Container(id: id, request: request, runtime: runtime, state: .created, logger: logger)
}

public func withContainer<T>(
    _ request: ContainerRequest,
    runtime: any ContainerRuntime = DockerClient(),
    logger: TCLogger = .null,
    testName: String? = nil,
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    try await withContainer(
        request,
        runtime: runtime,
        reuseConfig: ReuseConfig.fromEnvironment(),
        logger: logger,
        testName: testName,
        operation: operation
    )
}

func withContainer<T>(
    _ request: ContainerRequest,
    runtime: any ContainerRuntime = DockerClient(),
    reuseConfig: ReuseConfig,
    logger: TCLogger = .null,
    testName: String? = nil,
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    logger.debug("Checking Docker availability")
    if !(await runtime.isAvailable()) {
        logger.error("Docker not available")
        throw TestContainersError.dockerNotAvailable("`docker` CLI not found or Docker engine not running.")
    }

    let reuseEnabledForRequest = request.reuse && reuseConfig.enabled && request.imageFromDockerfile == nil

    // Build image from Dockerfile if specified
    let builtImageTag: String?
    if let dockerfileConfig = request.imageFromDockerfile {
        let tag = request.image  // Use the auto-generated tag from request
        _ = try await runtime.buildImage(dockerfileConfig, tag: tag)
        builtImageTag = tag
    } else {
        builtImageTag = nil
    }

    // PreStart hooks - run before container creation
    let preStartContext = LifecycleContext(container: nil, request: request, runtime: runtime)
    do {
        try await executeLifecycleHooks(request.preStartHooks, context: preStartContext, phase: .preStart)
    } catch {
        // PreStart hook failed - clean up built image if any
        await cleanupBuiltImage(tag: builtImageTag, runtime: runtime)
        throw error
    }

    let startup: ContainerStartupResult
    do {
        startup = try await retryableContainerStartup(
            request,
            runtime: runtime,
            reuseEnabled: reuseEnabledForRequest,
            logger: logger
        )
    } catch {
        // PreStart succeeded but container creation failed - clean up built image
        await cleanupBuiltImage(tag: builtImageTag, runtime: runtime)
        throw error
    }

    // PostStart hooks - run after container is ready
    let postStartContext = LifecycleContext(container: startup.container, request: request, runtime: runtime)
    do {
        try await executeLifecycleHooks(request.postStartHooks, context: postStartContext, phase: .postStart)
    } catch {
        // PostStart hook failed - cleanup container and run terminate hooks
        try? await terminateWithHooks(container: startup.container, request: request, runtime: runtime)
        await cleanupBuiltImage(tag: builtImageTag, runtime: runtime)
        throw error
    }

    // Create artifact collector based on request configuration
    let artifactCollector = ArtifactCollector(config: request.artifactConfig)

    return try await withTaskCancellationHandler {
        do {
            let result = try await operation(startup.container)
            // Collect artifacts if trigger is .always (even on success)
            _ = await artifactCollector.collect(
                container: startup.container,
                testName: testName,
                error: nil
            )
            if startup.shouldTerminateOnCompletion {
                try await terminateWithHooks(container: startup.container, request: request, runtime: runtime)
            }
            await cleanupBuiltImage(tag: builtImageTag, runtime: runtime)
            return result
        } catch {
            // Collect artifacts on failure
            _ = await artifactCollector.collect(
                container: startup.container,
                testName: testName,
                error: error
            )
            if startup.shouldTerminateOnCompletion {
                try? await terminateWithHooks(container: startup.container, request: request, runtime: runtime)
            }
            await cleanupBuiltImage(tag: builtImageTag, runtime: runtime)
            throw error
        }
    } onCancel: {
        Task {
            // Collect artifacts on cancellation (treated as failure)
            _ = await artifactCollector.collect(
                container: startup.container,
                testName: testName,
                error: CancellationError()
            )
            if startup.shouldTerminateOnCompletion {
                try? await terminateWithHooks(container: startup.container, request: request, runtime: runtime)
            }
            await cleanupBuiltImage(tag: builtImageTag, runtime: runtime)
        }
    }
}

/// Cleans up a built image if one was created.
private func cleanupBuiltImage(tag: String?, runtime: any ContainerRuntime) async {
    if let tag = tag {
        try? await runtime.removeImage(tag)
    }
}

/// Terminates a container, running lifecycle hooks before and after.
/// Errors in hooks are logged but don't prevent termination.
private func terminateWithHooks(
    container: Container,
    request: ContainerRequest,
    runtime: any ContainerRuntime
) async throws {
    let context = LifecycleContext(container: container, request: request, runtime: runtime)

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

private struct ContainerStartupResult {
    let container: Container
    let shouldTerminateOnCompletion: Bool
}

/// Attempts to start a container with optional retry logic.
///
/// If the request has a retry policy configured, this function will retry
/// container startup (including wait strategy) on failure, using exponential
/// backoff with jitter between attempts.
///
/// - Parameters:
///   - request: The container request configuration
///   - runtime: The container runtime to use
///   - reuseEnabled: Whether container reuse is enabled for this request
/// - Returns: A running, ready container startup result
/// - Throws: `TestContainersError.startupRetriesExhausted` if all attempts fail
private func retryableContainerStartup(
    _ request: ContainerRequest,
    runtime: any ContainerRuntime,
    reuseEnabled: Bool,
    logger: TCLogger = .null
) async throws -> ContainerStartupResult {
    guard let policy = request.retryPolicy else {
        // No retry policy - single attempt
        return try await startContainer(request, runtime: runtime, reuseEnabled: reuseEnabled, logger: logger)
    }

    var lastError: Error?

    for attempt in 0...policy.maxAttempts {
        do {
            // Apply delay before retry (not before first attempt)
            if attempt > 0 {
                let delay = policy.delay(for: attempt)
                try await Task.sleep(for: delay)
            }

            return try await startContainer(request, runtime: runtime, reuseEnabled: reuseEnabled, logger: logger)

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
    runtime: any ContainerRuntime,
    reuseEnabled: Bool,
    logger: TCLogger = .null
) async throws -> ContainerStartupResult {
    guard reuseEnabled else {
        let id = try await runtime.runContainer(request)
        let container = Container(id: id, request: request, runtime: runtime, logger: logger)
        await setupLogConsumers(container: container, request: request)

        do {
            try await container.waitUntilReady()
            return ContainerStartupResult(container: container, shouldTerminateOnCompletion: true)
        } catch {
            // Wait failed - cleanup container before throwing
            try? await container.terminate()
            throw error
        }
    }

    let hash = ReuseFingerprint.hash(for: request)
    let reusableRequest = request.withReuseLabels(hash: hash)

    if let candidate = try await runtime.findReusableContainer(hash: hash) {
        let reusedContainer = Container(id: candidate.id, request: reusableRequest, runtime: runtime, logger: logger)
        await setupLogConsumers(container: reusedContainer, request: reusableRequest)

        do {
            try await reusedContainer.waitUntilReady()
            return ContainerStartupResult(container: reusedContainer, shouldTerminateOnCompletion: false)
        } catch {
            // Reused container failed readiness checks. Remove and recreate.
            try? await reusedContainer.terminate()
        }
    }

    let id = try await runtime.runContainer(reusableRequest)
    let container = Container(id: id, request: reusableRequest, runtime: runtime, logger: logger)
    await setupLogConsumers(container: container, request: reusableRequest)

    do {
        try await container.waitUntilReady()
        return ContainerStartupResult(container: container, shouldTerminateOnCompletion: false)
    } catch {
        try? await container.terminate()
        throw error
    }
}

/// Transfers log consumers from the request to the container and starts streaming.
private func setupLogConsumers(container: Container, request: ContainerRequest) async {
    for entry in request.logConsumers {
        await container.addLogConsumer(entry.consumer)
    }
    await container.startLogStreaming()
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
