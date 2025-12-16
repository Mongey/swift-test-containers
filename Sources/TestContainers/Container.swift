import Foundation

public actor Container {
    public let id: String
    public let request: ContainerRequest

    private let docker: DockerClient

    init(id: String, request: ContainerRequest, docker: DockerClient) {
        self.id = id
        self.request = request
        self.docker = docker
    }

    public func hostPort(_ containerPort: Int) async throws -> Int {
        try await docker.port(id: id, containerPort: containerPort)
    }

    public func host() -> String {
        request.host
    }

    public func endpoint(for containerPort: Int) async throws -> String {
        let port = try await hostPort(containerPort)
        return "\(request.host):\(port)"
    }

    public func logs() async throws -> String {
        try await docker.logs(id: id)
    }

    public func terminate() async throws {
        try await docker.removeContainer(id: id)
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
        try await docker.exec(id: id, command: command, options: options)
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
        try await docker.copyToContainer(id: id, sourcePath: hostPath, destinationPath: containerPath)
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
        try await docker.copyToContainer(id: id, sourcePath: hostPath, destinationPath: containerPath)
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
        try await docker.copyDataToContainer(id: id, data: data, destinationPath: containerPath)
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
        try await docker.copyFromContainer(
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

        try await docker.copyFromContainer(
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

        try await docker.copyFromContainer(
            id: id,
            containerPath: containerPath,
            hostPath: tempFile.path,
            archive: false
        )

        return try Data(contentsOf: tempFile)
    }

    func waitUntilReady() async throws {
        try await waitForStrategy(request.waitStrategy)
    }

    // MARK: - Wait Strategy Execution

    private func waitForStrategy(_ strategy: WaitStrategy) async throws {
        switch strategy {
        case .none:
            return
        case let .logContains(needle, timeout, pollInterval):
            try await Waiter.wait(timeout: timeout, pollInterval: pollInterval, description: "container logs to contain '\(needle)'") { [docker, id] in
                let text = try await docker.logs(id: id)
                return text.contains(needle)
            }
        case let .logMatches(pattern, timeout, pollInterval):
            // Validate regex pattern early
            do {
                _ = try Regex(pattern)
            } catch {
                throw TestContainersError.invalidRegexPattern(pattern, underlyingError: error.localizedDescription)
            }

            try await Waiter.wait(
                timeout: timeout,
                pollInterval: pollInterval,
                description: "container logs to match regex '\(pattern)'"
            ) { [docker, id, pattern] in
                let text = try await docker.logs(id: id)
                // Regex is compiled each iteration but pattern validation happened above
                let regex = try! Regex(pattern)
                return text.contains(regex)
            }
        case let .tcpPort(containerPort, timeout, pollInterval):
            let hostPort = try await docker.port(id: id, containerPort: containerPort)
            let host = request.host
            try await Waiter.wait(timeout: timeout, pollInterval: pollInterval, description: "TCP port \(host):\(hostPort) to accept connections") {
                TCPProbe.canConnect(host: host, port: hostPort, timeout: .milliseconds(200))
            }
        case let .http(config):
            let hostPort = try await docker.port(id: id, containerPort: config.port)
            let host = request.host
            let scheme = config.useTLS ? "https" : "http"
            let url = "\(scheme)://\(host):\(hostPort)\(config.path)"
            try await Waiter.wait(
                timeout: config.timeout,
                pollInterval: config.pollInterval,
                description: "HTTP endpoint \(url) to return expected response"
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
        case let .exec(command, timeout, pollInterval):
            try await Waiter.wait(
                timeout: timeout,
                pollInterval: pollInterval,
                description: "command '\(command.joined(separator: " "))' to exit with code 0"
            ) { [docker, id] in
                let exitCode = try await docker.exec(id: id, command: command)
                return exitCode == 0
            }
        case let .healthCheck(timeout, pollInterval):
            // First check if container has health check configured
            let initialStatus = try await docker.healthStatus(id: id)
            guard initialStatus.hasHealthCheck else {
                throw TestContainersError.healthCheckNotConfigured(
                    "Container \(id) does not have a HEALTHCHECK configured. " +
                    "Ensure the image has a HEALTHCHECK instruction or specify one via --health-cmd."
                )
            }

            try await Waiter.wait(
                timeout: timeout,
                pollInterval: pollInterval,
                description: "container health status to be 'healthy'"
            ) { [docker, id] in
                let status = try await docker.healthStatus(id: id)
                return status.status == .healthy
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

