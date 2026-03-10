import Foundation

public actor Container {
    public nonisolated let id: String
    public nonisolated let request: ContainerRequest

    private let runtime: any ContainerRuntime
    private let logger: TCLogger
    private var state: ContainerState
    private var logConsumers: [any LogConsumer] = []
    private var logFollowTask: Task<Void, Never>?

    /// Container lifecycle states.
    public enum ContainerState: Sendable, Equatable, CustomStringConvertible {
        case created
        case starting
        case running
        case stopping
        case stopped
        case terminated

        public var description: String {
            switch self {
            case .created: return "created"
            case .starting: return "starting"
            case .running: return "running"
            case .stopping: return "stopping"
            case .stopped: return "stopped"
            case .terminated: return "terminated"
            }
        }
    }

    init(id: String, request: ContainerRequest, runtime: any ContainerRuntime, state: ContainerState = .running, logger: TCLogger = .null) {
        self.id = id
        self.request = request
        self.runtime = runtime
        self.state = state
        self.logger = logger
    }

    /// The current lifecycle state of the container.
    public var currentState: ContainerState {
        state
    }

    /// Whether the container is currently running.
    public var isRunning: Bool {
        state == .running
    }

    /// Start the container.
    ///
    /// Starts a stopped or newly created container and waits for readiness
    /// according to the configured wait strategy.
    ///
    /// - Idempotent: calling on an already running container is a no-op.
    /// - Throws `TestContainersError.invalidStateTransition` if called on a terminated container.
    public func start() async throws {
        switch state {
        case .created, .stopped:
            logger.info("Starting container", metadata: ["containerId": String(id.prefix(12)), "image": request.image])
            state = .starting
            do {
                try await runtime.startContainer(id: id)
                try await waitUntilReady()
                state = .running
                logger.notice("Container is running", metadata: ["containerId": String(id.prefix(12))])
            } catch {
                // Rollback state on failure
                state = .stopped
                logger.error("Container start failed", metadata: ["containerId": String(id.prefix(12)), "error": "\(error)"])
                throw error
            }

        case .running:
            return

        case .starting:
            throw TestContainersError.invalidStateTransition(
                from: state.description,
                to: "running",
                reason: "Container is already starting"
            )

        case .stopping:
            throw TestContainersError.invalidStateTransition(
                from: state.description,
                to: "running",
                reason: "Cannot start while stopping"
            )

        case .terminated:
            throw TestContainersError.invalidStateTransition(
                from: state.description,
                to: "running",
                reason: "Cannot start terminated container"
            )
        }
    }

    /// Stop the container gracefully.
    ///
    /// - Parameter timeout: Time to wait for graceful stop before force kill. Default: 10 seconds.
    /// - Idempotent: calling on an already stopped container is a no-op.
    /// - Throws `TestContainersError.invalidStateTransition` if called on a terminated container.
    public func stop(timeout: Duration = .seconds(10)) async throws {
        switch state {
        case .running, .starting:
            state = .stopping
            do {
                try await runtime.stopContainer(id: id, timeout: timeout)
                state = .stopped
            } catch {
                state = .stopped
                throw error
            }

        case .stopped:
            return

        case .created:
            state = .stopped

        case .stopping:
            throw TestContainersError.invalidStateTransition(
                from: state.description,
                to: "stopped",
                reason: "Container is already stopping"
            )

        case .terminated:
            throw TestContainersError.invalidStateTransition(
                from: state.description,
                to: "stopped",
                reason: "Cannot stop terminated container"
            )
        }
    }

    /// Restart the container.
    ///
    /// Stops and starts the container, re-running the wait strategy.
    ///
    /// - Parameter timeout: Time to wait for graceful stop. Default: 10 seconds.
    /// - Throws `TestContainersError.invalidStateTransition` if called on a terminated container.
    public func restart(timeout: Duration = .seconds(10)) async throws {
        guard state != .terminated else {
            throw TestContainersError.invalidStateTransition(
                from: state.description,
                to: "running",
                reason: "Cannot restart terminated container"
            )
        }

        try await stop(timeout: timeout)
        try await start()
    }

    public func hostPort(_ containerPort: Int) async throws -> Int {
        try await runtime.port(id: id, containerPort: containerPort)
    }

    public func host() -> String {
        request.host
    }

    public func endpoint(for containerPort: Int) async throws -> String {
        let port = try await hostPort(containerPort)
        return "\(request.host):\(port)"
    }

    public func logs() async throws -> String {
        try await runtime.logs(id: id)
    }

    /// Stream container logs in real-time.
    ///
    /// Returns an AsyncThrowingStream that yields log entries as they are produced
    /// by the container. Use this for monitoring container output in real-time
    /// rather than fetching all logs at once.
    ///
    /// - Parameter options: Options for filtering and formatting the log stream.
    ///   Defaults to following logs with both stdout and stderr.
    /// - Returns: AsyncThrowingStream of LogEntry values
    ///
    /// Example:
    /// ```swift
    /// // Basic streaming
    /// for try await entry in container.streamLogs() {
    ///     print("[\(entry.stream)] \(entry.message)")
    /// }
    ///
    /// // Tail last 100 lines without following
    /// let options = LogStreamOptions(follow: false, tail: 100)
    /// for try await entry in container.streamLogs(options: options) {
    ///     print(entry.message)
    /// }
    ///
    /// // With timestamps
    /// let options = LogStreamOptions(timestamps: true)
    /// for try await entry in container.streamLogs(options: options) {
    ///     if let ts = entry.timestamp {
    ///         print("\(ts): \(entry.message)")
    ///     }
    /// }
    /// ```
    public nonisolated func streamLogs(options: LogStreamOptions = .default) -> AsyncThrowingStream<LogEntry, Error> {
        runtime.streamLogs(id: id, options: options)
    }

    /// Inspect the container to retrieve detailed runtime information.
    ///
    /// Returns comprehensive inspection data including container state,
    /// configuration, and network settings.
    ///
    /// - Returns: `ContainerInspection` with state, config, and networking details
    /// - Throws: `TestContainersError.commandFailed` if docker inspect fails
    ///
    /// Example:
    /// ```swift
    /// let inspection = try await container.inspect()
    /// print("Status: \(inspection.state.status)")
    /// print("IP: \(inspection.networkSettings.ipAddress)")
    /// ```
    public func inspect() async throws -> ContainerInspection {
        try await runtime.inspect(id: id)
    }

    // MARK: - Log Consumers

    /// Add a log consumer to receive container log output.
    public func addLogConsumer(_ consumer: any LogConsumer) {
        logConsumers.append(consumer)
    }

    /// Start streaming container logs to registered consumers.
    /// Does nothing if no consumers are registered.
    func startLogStreaming() {
        guard !logConsumers.isEmpty else { return }

        let consumers = logConsumers
        let stream = streamLogs()

        logFollowTask = Task {
            do {
                for try await entry in stream {
                    if Task.isCancelled { break }
                    let logStream: LogStream = entry.stream == .stderr ? .stderr : .stdout
                    for consumer in consumers {
                        await consumer.accept(stream: logStream, line: entry.message)
                    }
                }
            } catch {
                // Container stopped or stream ended - expected behavior
            }
        }
    }

    /// Stop streaming container logs.
    func stopLogStreaming() {
        logFollowTask?.cancel()
        logFollowTask = nil
    }

    public func terminate() async throws {
        guard state != .terminated else {
            return
        }

        logger.debug("Terminating container", metadata: ["containerId": String(id.prefix(12))])
        stopLogStreaming()

        // Stop gracefully if running
        if state == .running || state == .starting {
            try? await runtime.stopContainer(id: id, timeout: .seconds(5))
        }

        try await runtime.removeContainer(id: id)
        state = .terminated
        logger.info("Container terminated", metadata: ["containerId": String(id.prefix(12))])
    }

    // MARK: - Exec

    /// Execute a command in the running container.
    ///
    /// - Parameters:
    ///   - command: The command and arguments to execute
    ///   - options: Execution options (user, working directory, environment)
    /// - Returns: Command output including exit code, stdout, and stderr
    /// - Throws: `TestContainersError.commandFailed` if exec setup fails
    ///
    /// Example:
    /// ```swift
    /// let result = try await container.exec(["ls", "-la", "/app"])
    /// print("Exit code: \(result.exitCode)")
    /// print("Output:\n\(result.stdout)")
    /// ```
    public func exec(
        _ command: [String],
        options: ExecOptions = ExecOptions()
    ) async throws -> ExecResult {
        try await runtime.exec(id: id, command: command, options: options)
    }

    /// Execute a command in the running container with a custom user.
    ///
    /// Convenience method for running commands as a specific user.
    ///
    /// - Parameters:
    ///   - command: The command and arguments to execute
    ///   - user: User specification (username, UID, or UID:GID)
    /// - Returns: Command output including exit code, stdout, and stderr
    public func exec(
        _ command: [String],
        user: String
    ) async throws -> ExecResult {
        try await exec(command, options: ExecOptions().withUser(user))
    }

    /// Execute a command and return only stdout.
    ///
    /// Convenience method that throws if exit code is non-zero.
    ///
    /// - Parameters:
    ///   - command: The command and arguments to execute
    ///   - options: Execution options
    /// - Returns: Standard output as a string
    /// - Throws: `TestContainersError.execCommandFailed` if exit code != 0
    public func execOutput(
        _ command: [String],
        options: ExecOptions = ExecOptions()
    ) async throws -> String {
        let result = try await exec(command, options: options)
        if result.failed {
            throw TestContainersError.execCommandFailed(
                command: command,
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr,
                containerID: id
            )
        }
        return result.stdout
    }

    // MARK: - Copy Operations

    /// Copy a file from the host filesystem into the container.
    ///
    /// Uses `docker cp` to copy a file from the host to the container.
    ///
    /// - Parameters:
    ///   - hostPath: Absolute path to file on host
    ///   - containerPath: Destination path in container (absolute or relative to workdir)
    /// - Throws: `TestContainersError.invalidInput` if source doesn't exist,
    ///           `TestContainersError.commandFailed` if docker cp fails
    ///
    /// Example:
    /// ```swift
    /// try await container.copyFileToContainer(from: "/tmp/config.json", to: "/app/config.json")
    /// ```
    public func copyFileToContainer(from hostPath: String, to containerPath: String) async throws {
        try await runtime.copyToContainer(id: id, sourcePath: hostPath, destinationPath: containerPath)
    }

    /// Copy a directory from the host filesystem into the container.
    ///
    /// Uses `docker cp` to copy a directory tree recursively.
    ///
    /// - Parameters:
    ///   - hostPath: Absolute path to directory on host
    ///   - containerPath: Destination path in container
    /// - Note: Follows docker cp semantics - trailing slash matters for merge behavior
    /// - Throws: `TestContainersError.invalidInput` if source doesn't exist,
    ///           `TestContainersError.commandFailed` if docker cp fails
    ///
    /// Example:
    /// ```swift
    /// try await container.copyDirectoryToContainer(from: "/tmp/fixtures", to: "/app/data")
    /// ```
    public func copyDirectoryToContainer(from hostPath: String, to containerPath: String) async throws {
        try await runtime.copyToContainer(id: id, sourcePath: hostPath, destinationPath: containerPath)
    }

    /// Copy data directly into a file in the container.
    ///
    /// Creates a temporary file with the data, copies it to the container, and cleans up.
    ///
    /// - Parameters:
    ///   - data: Data to write to the container
    ///   - containerPath: Destination file path in container
    /// - Throws: `TestContainersError.commandFailed` if docker cp fails
    ///
    /// Example:
    /// ```swift
    /// let imageData = try Data(contentsOf: imageURL)
    /// try await container.copyDataToContainer(imageData, to: "/app/image.png")
    /// ```
    public func copyDataToContainer(_ data: Data, to containerPath: String) async throws {
        try await runtime.copyDataToContainer(id: id, data: data, destinationPath: containerPath)
    }

    /// Copy string content into a file in the container.
    ///
    /// Encodes the string as UTF-8 and copies it to the container.
    ///
    /// - Parameters:
    ///   - content: String content to write (will be UTF-8 encoded)
    ///   - containerPath: Destination file path in container
    /// - Throws: `TestContainersError.invalidInput` if string cannot be encoded as UTF-8,
    ///           `TestContainersError.commandFailed` if docker cp fails
    ///
    /// Example:
    /// ```swift
    /// let config = """
    /// server.port=8080
    /// server.host=0.0.0.0
    /// """
    /// try await container.copyToContainer(config, to: "/app/config.properties")
    /// ```
    public func copyToContainer(_ content: String, to containerPath: String) async throws {
        guard let data = content.data(using: .utf8) else {
            throw TestContainersError.invalidInput("Failed to encode string as UTF-8")
        }
        try await copyDataToContainer(data, to: containerPath)
    }

    // MARK: - Copy From Container Operations

    /// Copy a file from the container to the host filesystem.
    ///
    /// Uses `docker cp` to copy a file from the container to the host.
    ///
    /// - Parameters:
    ///   - containerPath: Absolute path to file inside the container
    ///   - hostPath: Destination path on the host (file will be created/overwritten)
    ///   - preservePermissions: Whether to preserve uid/gid (uses -a flag). Default: true
    /// - Returns: URL to the copied file on the host
    /// - Throws: `TestContainersError.commandFailed` if docker cp fails
    ///
    /// Example:
    /// ```swift
    /// let logFile = try await container.copyFileFromContainer(
    ///     "/var/log/app.log",
    ///     to: "/tmp/app-log.txt"
    /// )
    /// let contents = try String(contentsOf: logFile)
    /// ```
    public func copyFileFromContainer(
        _ containerPath: String,
        to hostPath: String,
        preservePermissions: Bool = true
    ) async throws -> URL {
        try await runtime.copyFromContainer(
            id: id,
            containerPath: containerPath,
            hostPath: hostPath,
            archive: preservePermissions
        )
        return URL(fileURLWithPath: hostPath)
    }

    /// Copy a directory from the container to the host filesystem.
    ///
    /// Uses `docker cp` to copy a directory tree recursively.
    ///
    /// - Parameters:
    ///   - containerPath: Absolute path to the directory inside the container
    ///   - hostPath: Destination directory on the host (created if it doesn't exist)
    ///   - preservePermissions: Whether to preserve uid/gid (uses -a flag). Default: true
    /// - Returns: URL to the copied directory on the host
    /// - Throws: `TestContainersError.commandFailed` if docker cp fails
    ///
    /// Example:
    /// ```swift
    /// let artifactsDir = try await container.copyDirectoryFromContainer(
    ///     "/app/artifacts",
    ///     to: "/tmp/test-artifacts"
    /// )
    /// ```
    public func copyDirectoryFromContainer(
        _ containerPath: String,
        to hostPath: String,
        preservePermissions: Bool = true
    ) async throws -> URL {
        // Ensure destination directory exists
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: hostPath) {
            try fileManager.createDirectory(
                atPath: hostPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        try await runtime.copyFromContainer(
            id: id,
            containerPath: containerPath,
            hostPath: hostPath,
            archive: preservePermissions
        )
        return URL(fileURLWithPath: hostPath)
    }

    /// Copy a file from the container directly into memory as Data.
    ///
    /// Copies the file to a temporary location and reads it into memory.
    /// The temporary file is cleaned up automatically.
    ///
    /// - Parameter containerPath: Absolute path to the file inside the container
    /// - Returns: File contents as Data
    /// - Throws: `TestContainersError.commandFailed` if the copy operation fails
    ///
    /// Example:
    /// ```swift
    /// let configData = try await container.copyFileToData("/etc/app/config.json")
    /// let config = try JSONDecoder().decode(AppConfig.self, from: configData)
    /// ```
    public func copyFileToData(_ containerPath: String) async throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("testcontainers-\(UUID().uuidString)")

        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        try await runtime.copyFromContainer(
            id: id,
            containerPath: containerPath,
            hostPath: tempFile.path,
            archive: false
        )

        return try Data(contentsOf: tempFile)
    }

    // MARK: - Container-to-Container Communication

    /// Returns the container's internal IP address within its primary Docker network.
    ///
    /// This IP is used for container-to-container communication, not host-to-container.
    ///
    /// - Returns: The container's internal IP address (e.g., "172.17.0.2")
    /// - Throws: `TestContainersError` if unable to inspect the container or no networks found
    public func internalIP() async throws -> String {
        let inspection = try await runtime.inspect(id: id)
        guard let firstNetwork = inspection.networkSettings.networks.values.first else {
            throw TestContainersError.unexpectedDockerOutput(
                "No networks found for container \(id)"
            )
        }
        return firstNetwork.ipAddress
    }

    /// Returns the container's internal IP address for a specific Docker network.
    ///
    /// - Parameter networkName: The name of the Docker network
    /// - Returns: The container's IP address within the specified network
    /// - Throws: `TestContainersError.networkNotFound` if the network is not found
    public func internalIP(forNetwork networkName: String) async throws -> String {
        let inspection = try await runtime.inspect(id: id)
        guard let network = inspection.networkSettings.networks[networkName] else {
            throw TestContainersError.networkNotFound(networkName, id: id)
        }
        return network.ipAddress
    }

    /// Returns the container's hostname for DNS-based communication within Docker networks.
    ///
    /// - Returns: The container's fixed name (if set via `.withFixedName()`) or short container ID (first 12 chars)
    public func internalHostname() -> String {
        if let name = request.name, !request.autoGenerateName {
            return name
        }
        return String(id.prefix(12))
    }

    /// Returns an internal endpoint (IP:port) for container-to-container communication.
    ///
    /// Uses the container's internal IP and internal port, not host-mapped values.
    ///
    /// - Parameter containerPort: The port exposed within the container
    /// - Returns: An endpoint string in the format "ip:port" (e.g., "172.17.0.2:5432")
    public func internalEndpoint(for containerPort: Int) async throws -> String {
        let ip = try await internalIP()
        return "\(ip):\(containerPort)"
    }

    /// Returns an internal endpoint using the container's hostname instead of IP.
    ///
    /// Useful when DNS resolution is available (custom networks, not default bridge).
    ///
    /// - Parameter containerPort: The port exposed within the container
    /// - Returns: An endpoint string in the format "hostname:port"
    public func internalHostnameEndpoint(for containerPort: Int) async throws -> String {
        let hostname = internalHostname()
        return "\(hostname):\(containerPort)"
    }

    public func waitUntilReady() async throws {
        try await waitForStrategy(request.waitStrategy)
    }

    /// Waits for a specific strategy against an already-running container.
    ///
    /// This is primarily used by dependency wait graphs where a dependent
    /// container may require a custom readiness condition on its dependency.
    func wait(for strategy: WaitStrategy) async throws {
        try await waitForStrategy(strategy)
    }

    // MARK: - Wait Strategy Execution

    /// Collects diagnostic information from the container for timeout errors.
    /// Never throws - returns best-effort diagnostics.
    private func collectDiagnostics(description: String) async -> TimeoutDiagnostics {
        let config = request.diagnostics
        var recentLogs: String?
        var containerState: ContainerStateDiagnostics?

        if config.captureLogsOnFailure && config.logTailLines > 0 {
            recentLogs = try? await runtime.logsTail(id: id, lines: config.logTailLines)
        }

        if config.captureStateOnFailure {
            if let inspection = try? await runtime.inspect(id: id) {
                containerState = ContainerStateDiagnostics(
                    status: inspection.state.status.rawValue,
                    running: inspection.state.running,
                    exitCode: inspection.state.exitCode,
                    oomKilled: inspection.state.oomKilled
                )
            }
        }

        return TimeoutDiagnostics(
            description: description,
            containerId: id,
            image: request.image,
            containerState: containerState,
            recentLogs: recentLogs,
            logLineCount: config.logTailLines
        )
    }

    private func waitForStrategy(_ strategy: WaitStrategy) async throws {
        let diagnosticsEnabled = request.diagnostics.captureLogsOnFailure || request.diagnostics.captureStateOnFailure

        switch strategy {
        case .none:
            return
        case let .logContains(needle, timeout, pollInterval):
            let desc = "container logs to contain '\(needle)'"
            if diagnosticsEnabled {
                try await Waiter.waitWithDiagnostics(
                    timeout: timeout,
                    pollInterval: pollInterval,
                    description: desc,
                    onTimeout: { [self] in await collectDiagnostics(description: desc) }
                ) { [runtime, id] in
                    let text = try await runtime.logs(id: id)
                    return text.contains(needle)
                }
            } else {
                try await Waiter.wait(timeout: timeout, pollInterval: pollInterval, description: desc) { [runtime, id] in
                    let text = try await runtime.logs(id: id)
                    return text.contains(needle)
                }
            }
        case let .logMatches(pattern, timeout, pollInterval):
            // Validate regex pattern early
            do {
                _ = try Regex(pattern)
            } catch {
                throw TestContainersError.invalidRegexPattern(pattern, underlyingError: error.localizedDescription)
            }

            let desc = "container logs to match regex '\(pattern)'"
            if diagnosticsEnabled {
                try await Waiter.waitWithDiagnostics(
                    timeout: timeout,
                    pollInterval: pollInterval,
                    description: desc,
                    onTimeout: { [self] in await collectDiagnostics(description: desc) }
                ) { [runtime, id, pattern] in
                    let text = try await runtime.logs(id: id)
                    let regex = try! Regex(pattern)
                    return text.contains(regex)
                }
            } else {
                try await Waiter.wait(timeout: timeout, pollInterval: pollInterval, description: desc) { [runtime, id, pattern] in
                    let text = try await runtime.logs(id: id)
                    let regex = try! Regex(pattern)
                    return text.contains(regex)
                }
            }
        case let .tcpPort(containerPort, timeout, pollInterval):
            let hostPort = try await runtime.port(id: id, containerPort: containerPort)
            let host = request.host
            let desc = "TCP port \(host):\(hostPort) to accept connections"
            if diagnosticsEnabled {
                try await Waiter.waitWithDiagnostics(
                    timeout: timeout,
                    pollInterval: pollInterval,
                    description: desc,
                    onTimeout: { [self] in await collectDiagnostics(description: desc) }
                ) {
                    TCPProbe.canConnect(host: host, port: hostPort, timeout: .milliseconds(200))
                }
            } else {
                try await Waiter.wait(timeout: timeout, pollInterval: pollInterval, description: desc) {
                    TCPProbe.canConnect(host: host, port: hostPort, timeout: .milliseconds(200))
                }
            }
        case let .http(config):
            let hostPort = try await runtime.port(id: id, containerPort: config.port)
            let host = request.host
            let scheme = config.useTLS ? "https" : "http"
            let url = "\(scheme)://\(host):\(hostPort)\(config.path)"
            let desc = "HTTP endpoint \(url) to return expected response"
            if diagnosticsEnabled {
                try await Waiter.waitWithDiagnostics(
                    timeout: config.timeout,
                    pollInterval: config.pollInterval,
                    description: desc,
                    onTimeout: { [self] in await collectDiagnostics(description: desc) }
                ) {
                    await HTTPProbe.check(
                        url: url,
                        method: config.method,
                        headers: config.headers,
                        statusCodeMatcher: config.statusCodeMatcher,
                        bodyMatcher: config.bodyMatcher,
                        allowInsecureTLS: config.allowInsecureTLS,
                        requestTimeout: config.requestTimeout
                    )
                }
            } else {
                try await Waiter.wait(
                    timeout: config.timeout,
                    pollInterval: config.pollInterval,
                    description: desc
                ) {
                    await HTTPProbe.check(
                        url: url,
                        method: config.method,
                        headers: config.headers,
                        statusCodeMatcher: config.statusCodeMatcher,
                        bodyMatcher: config.bodyMatcher,
                        allowInsecureTLS: config.allowInsecureTLS,
                        requestTimeout: config.requestTimeout
                    )
                }
            }
        case let .exec(command, timeout, pollInterval):
            let desc = "command '\(command.joined(separator: " "))' to exit with code 0"
            if diagnosticsEnabled {
                try await Waiter.waitWithDiagnostics(
                    timeout: timeout,
                    pollInterval: pollInterval,
                    description: desc,
                    onTimeout: { [self] in await collectDiagnostics(description: desc) }
                ) { [runtime, id] in
                    let exitCode = try await runtime.exec(id: id, command: command)
                    return exitCode == 0
                }
            } else {
                try await Waiter.wait(timeout: timeout, pollInterval: pollInterval, description: desc) { [runtime, id] in
                    let exitCode = try await runtime.exec(id: id, command: command)
                    return exitCode == 0
                }
            }
        case let .healthCheck(timeout, pollInterval):
            // First check if container has health check configured
            let initialStatus = try await runtime.healthStatus(id: id)
            guard initialStatus.hasHealthCheck else {
                throw TestContainersError.healthCheckNotConfigured(
                    "Container \(id) does not have a HEALTHCHECK configured. " +
                    "Ensure the image has a HEALTHCHECK instruction or specify one via --health-cmd."
                )
            }

            let desc = "container health status to be 'healthy'"
            if diagnosticsEnabled {
                try await Waiter.waitWithDiagnostics(
                    timeout: timeout,
                    pollInterval: pollInterval,
                    description: desc,
                    onTimeout: { [self] in await collectDiagnostics(description: desc) }
                ) { [runtime, id] in
                    let status = try await runtime.healthStatus(id: id)
                    return status.status == .healthy
                }
            } else {
                try await Waiter.wait(timeout: timeout, pollInterval: pollInterval, description: desc) { [runtime, id] in
                    let status = try await runtime.healthStatus(id: id)
                    return status.status == .healthy
                }
            }
        case let .all(strategies, compositeTimeout):
            try await waitForAll(strategies, compositeTimeout: compositeTimeout)
        case let .any(strategies, compositeTimeout):
            try await waitForAny(strategies, compositeTimeout: compositeTimeout)
        }
    }

    /// Waits for all strategies to succeed in parallel.
    /// Fails fast if any strategy fails.
    private func waitForAll(_ strategies: [WaitStrategy], compositeTimeout: Duration?) async throws {
        // Empty array succeeds immediately (vacuous truth)
        guard !strategies.isEmpty else { return }

        // Single strategy optimization
        if strategies.count == 1 {
            try await waitForStrategy(strategies[0])
            return
        }

        // Execute all strategies in parallel
        let operation: @Sendable () async throws -> Void = { [self] in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for strategy in strategies {
                    group.addTask {
                        try await self.waitForStrategy(strategy)
                    }
                }
                // Wait for all to complete - fails fast on first error
                try await group.waitForAll()
            }
        }

        // Apply composite timeout if specified
        if let timeout = compositeTimeout {
            try await Waiter.withTimeout(timeout, description: "all wait strategies to complete", operation: operation)
        } else {
            try await operation()
        }
    }

    /// Waits for any strategy to succeed in parallel.
    /// First success wins, all must fail for the composite to fail.
    private func waitForAny(_ strategies: [WaitStrategy], compositeTimeout: Duration?) async throws {
        // Empty array fails immediately
        guard !strategies.isEmpty else {
            throw TestContainersError.emptyAnyWaitStrategy
        }

        // Single strategy optimization
        if strategies.count == 1 {
            try await waitForStrategy(strategies[0])
            return
        }

        // Determine timeout: use composite timeout or max of individual timeouts
        let effectiveTimeout = compositeTimeout ?? strategies.map { $0.maxTimeout() }.max() ?? .seconds(60)

        try await Waiter.withTimeout(effectiveTimeout, description: "any wait strategy to complete") { [self] in
            // Use actor to collect errors safely
            let errorCollector = ErrorCollector()

            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, strategy) in strategies.enumerated() {
                    group.addTask {
                        do {
                            try await self.waitForStrategy(strategy)
                        } catch {
                            await errorCollector.add(index: index, error: error)
                            throw error
                        }
                    }
                }

                // Wait for first success
                var successCount = 0
                var errorCount = 0
                let totalCount = strategies.count

                while let result = await group.nextResult() {
                    switch result {
                    case .success:
                        successCount += 1
                        // First success - cancel remaining tasks and return
                        group.cancelAll()
                        return
                    case .failure:
                        errorCount += 1
                        // All failed - throw combined error
                        if errorCount == totalCount {
                            let errors = await errorCollector.getErrors()
                            throw TestContainersError.allWaitStrategiesFailed(errors)
                        }
                        // Continue waiting for other strategies
                    }
                }
            }
        }
    }
}

/// Actor for safely collecting errors from concurrent tasks
private actor ErrorCollector {
    private var errors: [(Int, Error)] = []

    func add(index: Int, error: Error) {
        errors.append((index, error))
    }

    func getErrors() -> [String] {
        errors.sorted { $0.0 < $1.0 }.map { "\($0.1)" }
    }
}
