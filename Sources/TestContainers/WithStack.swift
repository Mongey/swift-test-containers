import Foundation

/// Run a multi-container stack with scoped lifecycle management.
///
/// - Important: In the runtime abstraction release, the `docker:` parameter was
///   renamed to `runtime:`.
public func withStack<T>(
    _ stack: ContainerStack,
    runtime: any ContainerRuntime = DockerClient(),
    logger: TCLogger = .null,
    operation: @Sendable (RunningStack) async throws -> T
) async throws -> T {
    try stack.validate()

    if !(await runtime.isAvailable()) {
        throw TestContainersError.dockerNotAvailable(
            "`docker` CLI not found or Docker engine not running."
        )
    }

    let startupOrder = try stack.startupOrder()
    let shutdownOrder = Array(startupOrder.reversed())
    let networkInfo = try await prepareStackNetwork(
        stack: stack,
        runtime: runtime,
        hasContainers: !startupOrder.isEmpty
    )

    let volumeInfos = try await prepareStackVolumes(
        stack: stack,
        runtime: runtime
    )

    let cleanupTracker = StackCleanupTracker(
        shutdownOrder: shutdownOrder,
        network: networkInfo,
        volumes: volumeInfos,
        runtime: runtime
    )

    let dependencySignals = Dictionary(
        uniqueKeysWithValues: startupOrder.map { ($0, DependencySignal(name: $0)) }
    )

    let startupTasks = makeStartupTasks(
        stack: stack,
        runtime: runtime,
        startupOrder: startupOrder,
        networkInfo: networkInfo,
        cleanupTracker: cleanupTracker,
        dependencySignals: dependencySignals
    )

    return try await withTaskCancellationHandler {
        do {
            for name in startupOrder {
                guard let task = startupTasks[name] else { continue }
                try await task.value
            }

            let runningStack = RunningStack(
                stackId: networkInfo?.name ?? "tc-stack-\(UUID().uuidString.prefix(8).lowercased())",
                containers: await cleanupTracker.runningContainers(),
                network: networkInfo,
                volumes: volumeInfos,
                shutdownOrder: shutdownOrder,
                runtime: runtime
            )

            let result = try await operation(runningStack)
            try? await runningStack.terminate()
            return result
        } catch {
            for task in startupTasks.values {
                task.cancel()
            }
            await cleanupTracker.terminateAll()
            throw error
        }
    } onCancel: {
        Task {
            for task in startupTasks.values {
                task.cancel()
            }
            await cleanupTracker.terminateAll()
        }
    }
}

private func makeStartupTasks(
    stack: ContainerStack,
    runtime: any ContainerRuntime,
    startupOrder: [String],
    networkInfo: StackNetworkInfo?,
    cleanupTracker: StackCleanupTracker,
    dependencySignals: [String: DependencySignal]
) -> [String: Task<Void, Error>] {
    var tasks: [String: Task<Void, Error>] = [:]

    for name in startupOrder {
        let task = Task {
            guard let signal = dependencySignals[name] else {
                throw TestContainersError.lifecycleError(
                    "Missing startup signal for container '\(name)'"
                )
            }

            do {
                try await waitForDependencies(
                    of: name,
                    stack: stack,
                    dependencySignals: dependencySignals
                )

                guard let baseRequest = stack.containers[name] else {
                    throw TestContainersError.invalidDependency(
                        dependent: name,
                        dependency: "<none>",
                        reason: "Container '\(name)' is not defined in stack"
                    )
                }

                var request = buildStackRequest(
                    baseRequest: baseRequest,
                    containerName: name,
                    stack: stack
                )

                if let networkName = networkInfo?.name {
                    attachStackNetwork(&request, networkName: networkName, alias: name)
                }

                let id = try await runtime.runContainer(request)
                let container = Container(id: id, request: request, runtime: runtime)
                await cleanupTracker.register(container: container, name: name)
                await signal.markStarted(container)

                try await container.waitUntilReady()
                await signal.markReady(container)
            } catch {
                await signal.markFailed(error)
                throw error
            }
        }

        tasks[name] = task
    }

    return tasks
}

private func waitForDependencies(
    of containerName: String,
    stack: ContainerStack,
    dependencySignals: [String: DependencySignal]
) async throws {
    let dependencies = stack.dependencies[containerName, default: []].sorted()

    for dependencyName in dependencies {
        guard let signal = dependencySignals[dependencyName] else {
            throw TestContainersError.invalidDependency(
                dependent: containerName,
                dependency: dependencyName,
                reason: "Dependency signal was not initialized"
            )
        }

        let strategy = stack.dependencyWaitStrategy(for: containerName, dependency: dependencyName)
        try await waitForDependency(
            dependencyName,
            strategy: strategy,
            signal: signal
        )
    }
}

private func waitForDependency(
    _ dependencyName: String,
    strategy: DependencyWaitStrategy,
    signal: DependencySignal
) async throws {
    switch strategy {
    case .started:
        _ = try await signal.waitUntilStarted()

    case .ready:
        _ = try await signal.waitUntilReady()

    case .healthy:
        let container = try await signal.waitUntilStarted()
        try await container.wait(for: .healthCheck())

    case .custom(let waitStrategy):
        let container = try await signal.waitUntilStarted()
        try await container.wait(for: waitStrategy)
    }
}

private func buildStackRequest(
    baseRequest: ContainerRequest,
    containerName: String,
    stack: ContainerStack
) -> ContainerRequest {
    var request = baseRequest

    // Stack-level environment and labels are defaults; container-specific values win.
    var mergedEnvironment = stack.environment
    for (key, value) in baseRequest.environment {
        mergedEnvironment[key] = value
    }
    request.environment = mergedEnvironment

    var mergedLabels = stack.labels
    mergedLabels["testcontainers.swift.stack.container"] = containerName
    for (key, value) in baseRequest.labels {
        mergedLabels[key] = value
    }
    request.labels = mergedLabels

    return request
}

private func attachStackNetwork(
    _ request: inout ContainerRequest,
    networkName: String,
    alias: String
) {
    guard request.networkMode == nil else { return }

    if let index = request.networks.firstIndex(where: { $0.networkName == networkName }) {
        var connection = request.networks[index]
        if !connection.aliases.contains(alias) {
            connection.aliases.append(alias)
        }

        // Ensure stack network remains the primary network for DNS/alias flags on docker run.
        request.networks.remove(at: index)
        request.networks.insert(connection, at: 0)
        return
    }

    request.networks.insert(
        NetworkConnection(networkName: networkName, aliases: [alias]),
        at: 0
    )
}

private func prepareStackVolumes(
    stack: ContainerStack,
    runtime: any ContainerRuntime
) async throws -> [StackVolumeInfo] {
    var volumeInfos: [StackVolumeInfo] = []

    for (name, config) in stack.volumes.sorted(by: { $0.key < $1.key }) {
        _ = try await runtime.createVolume(name: name, config: config)
        volumeInfos.append(StackVolumeInfo(name: name, removeOnTermination: true))
    }

    return volumeInfos
}

private func prepareStackNetwork(
    stack: ContainerStack,
    runtime: any ContainerRuntime,
    hasContainers: Bool
) async throws -> StackNetworkInfo? {
    guard hasContainers, let config = stack.network else {
        return nil
    }

    if config.createIfMissing {
        let networkName: String
        if let providedName = config.name?.trimmingCharacters(in: .whitespacesAndNewlines), !providedName.isEmpty {
            networkName = providedName
        } else {
            networkName = "tc-stack-\(UUID().uuidString.prefix(8).lowercased())"
        }

        let id = try await runtime.createNetwork(
            name: networkName,
            driver: config.driver,
            internal: config.internal
        )

        return StackNetworkInfo(name: networkName, id: id, removeOnTermination: true)
    }

    guard let existingName = config.name?.trimmingCharacters(in: .whitespacesAndNewlines), !existingName.isEmpty else {
        throw TestContainersError.invalidInput(
            "Network name must be provided when createIfMissing is false"
        )
    }

    let exists = try await runtime.networkExists(existingName)
    guard exists else {
        throw TestContainersError.invalidInput(
            "Configured stack network '\(existingName)' does not exist"
        )
    }

    return StackNetworkInfo(name: existingName, id: existingName, removeOnTermination: false)
}

private actor StackCleanupTracker {
    private var containers: [String: Container] = [:]
    private let shutdownOrder: [String]
    private let network: StackNetworkInfo?
    private let volumes: [StackVolumeInfo]
    private let runtime: any ContainerRuntime
    private var didTerminate = false

    init(shutdownOrder: [String], network: StackNetworkInfo?, volumes: [StackVolumeInfo], runtime: any ContainerRuntime) {
        self.shutdownOrder = shutdownOrder
        self.network = network
        self.volumes = volumes
        self.runtime = runtime
    }

    func register(container: Container, name: String) {
        containers[name] = container
    }

    func runningContainers() -> [String: Container] {
        containers
    }

    func terminateAll() async {
        guard !didTerminate else { return }
        didTerminate = true

        for name in shutdownOrder {
            guard let container = containers[name] else { continue }
            try? await container.terminate()
        }

        if let network, network.removeOnTermination {
            try? await runtime.removeNetwork(id: network.id)
        }

        for volume in volumes where volume.removeOnTermination {
            try? await runtime.removeVolume(name: volume.name)
        }
    }
}

private actor DependencySignal {
    private enum State {
        case pending
        case started(Container)
        case ready(Container)
        case failed(String)
    }

    private let name: String
    private var state: State = .pending
    private var startedContinuations: [CheckedContinuation<Container, Error>] = []
    private var readyContinuations: [CheckedContinuation<Container, Error>] = []

    init(name: String) {
        self.name = name
    }

    func markStarted(_ container: Container) {
        switch state {
        case .failed:
            return
        case .ready:
            return
        case .started:
            return
        case .pending:
            state = .started(container)
            let continuations = startedContinuations
            startedContinuations.removeAll(keepingCapacity: false)
            for continuation in continuations {
                continuation.resume(returning: container)
            }
        }
    }

    func markReady(_ container: Container) {
        switch state {
        case .failed:
            return
        case .pending, .started, .ready:
            state = .ready(container)

            let started = startedContinuations
            startedContinuations.removeAll(keepingCapacity: false)
            for continuation in started {
                continuation.resume(returning: container)
            }

            let ready = readyContinuations
            readyContinuations.removeAll(keepingCapacity: false)
            for continuation in ready {
                continuation.resume(returning: container)
            }
        }
    }

    func markFailed(_ error: Error) {
        let message = String(describing: error)
        state = .failed(message)

        let dependencyError = TestContainersError.lifecycleError(
            "Dependency '\(name)' failed during startup: \(message)"
        )

        let started = startedContinuations
        startedContinuations.removeAll(keepingCapacity: false)
        for continuation in started {
            continuation.resume(throwing: dependencyError)
        }

        let ready = readyContinuations
        readyContinuations.removeAll(keepingCapacity: false)
        for continuation in ready {
            continuation.resume(throwing: dependencyError)
        }
    }

    func waitUntilStarted() async throws -> Container {
        switch state {
        case .started(let container), .ready(let container):
            return container
        case .failed(let message):
            throw TestContainersError.lifecycleError(
                "Dependency '\(name)' failed during startup: \(message)"
            )
        case .pending:
            return try await withCheckedThrowingContinuation { continuation in
                startedContinuations.append(continuation)
            }
        }
    }

    func waitUntilReady() async throws -> Container {
        switch state {
        case .ready(let container):
            return container
        case .failed(let message):
            throw TestContainersError.lifecycleError(
                "Dependency '\(name)' failed during startup: \(message)"
            )
        case .pending, .started:
            return try await withCheckedThrowingContinuation { continuation in
                readyContinuations.append(continuation)
            }
        }
    }
}
