import Foundation

/// Represents the health status of a container from Docker's HEALTHCHECK feature.
public struct ContainerHealthStatus: Sendable, Equatable {
    /// Possible health check status values from Docker.
    public enum Status: String, Sendable {
        case starting
        case healthy
        case unhealthy
    }

    /// The current health status. Nil if the container is in an unknown state.
    public let status: Status?
    /// Whether the container has a health check configured.
    public let hasHealthCheck: Bool
}

/// Internal struct for parsing Docker health check JSON response.
private struct HealthCheckResponse: Decodable {
    let Status: String?
}

public struct DockerClient: Sendable {
    private let dockerPath: String
    private let runner: ProcessRunner
    private let logger: TCLogger

    public init(dockerPath: String = "docker", logger: TCLogger = .null) {
        self.dockerPath = dockerPath
        self.logger = logger
        self.runner = ProcessRunner(logger: logger)
    }

    public func isAvailable() async -> Bool {
        logger.debug("Checking Docker availability", metadata: ["dockerPath": dockerPath])
        let start = ContinuousClock.now
        do {
            let result = try await runner.run(executable: dockerPath, arguments: ["version", "--format", "{{.Server.Version}}"])
            let available = result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let duration = ContinuousClock.now - start
            if available {
                logger.info("Docker is available", metadata: [
                    "version": result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    "duration": "\(duration)",
                ])
            } else {
                logger.warning("Docker check failed", metadata: [
                    "exitCode": "\(result.exitCode)",
                    "duration": "\(duration)",
                ])
            }
            return available
        } catch {
            let duration = ContinuousClock.now - start
            logger.error("Docker availability check threw error", metadata: [
                "error": "\(error)",
                "duration": "\(duration)",
            ])
            return false
        }
    }

    func runDocker(_ args: [String], environment: [String: String] = [:], stdinData: Data? = nil) async throws -> CommandOutput {
        let output = try await runner.run(executable: dockerPath, arguments: args, environment: environment, stdinData: stdinData)
        if output.exitCode != 0 {
            throw TestContainersError.commandFailed(command: [dockerPath] + args, exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
        }
        return output
    }

    // MARK: - Registry Authentication

    /// Build the docker login command arguments.
    static func loginArgs(registry: String, username: String) -> [String] {
        ["login", registry, "-u", username, "--password-stdin"]
    }

    /// Authenticate to a Docker registry before pulling/running images.
    ///
    /// - Parameter auth: The authentication configuration
    /// - Parameter environment: Mutable environment dictionary to update (for configFile)
    func authenticateRegistry(_ auth: RegistryAuth, environment: inout [String: String]) async throws {
        switch auth {
        case let .credentials(registry, username, password):
            let args = Self.loginArgs(registry: registry, username: username)
            let passwordData = Data(password.utf8)
            _ = try await runDocker(args, stdinData: passwordData)

        case let .configFile(path):
            environment["DOCKER_CONFIG"] = path

        case .systemDefault:
            break
        }
    }

    /// Check if an image exists in the local Docker image cache.
    ///
    /// - Parameters:
    ///   - image: Image reference (name, name:tag, or digest)
    ///   - platform: Optional platform (e.g., "linux/amd64") for multi-platform images
    /// - Returns: `true` if image exists locally, `false` otherwise
    public func imageExists(_ image: String, platform: String? = nil) async -> Bool {
        do {
            var args = ["image", "inspect"]
            if let platform {
                args += ["--platform", platform]
            }
            args.append(image)
            let output = try await runner.run(executable: dockerPath, arguments: args)
            return output.exitCode == 0
        } catch {
            return false
        }
    }

    /// Pull an image from a registry.
    ///
    /// - Parameters:
    ///   - image: Image reference to pull
    ///   - platform: Optional platform (e.g., "linux/amd64") for multi-platform images
    public func pullImage(_ image: String, platform: String? = nil, environment: [String: String] = [:]) async throws {
        var args = ["pull"]
        if let platform {
            args += ["--platform", platform]
        }
        args.append(image)
        let output = try await runner.run(executable: dockerPath, arguments: args, environment: environment)
        if output.exitCode != 0 {
            throw TestContainersError.imagePullFailed(
                image: image,
                exitCode: output.exitCode,
                stdout: output.stdout,
                stderr: output.stderr
            )
        }
    }

    /// Inspect an image to retrieve comprehensive metadata.
    ///
    /// Queries the local Docker daemon for image information including
    /// architecture, exposed ports, environment variables, labels, and more.
    ///
    /// - Parameters:
    ///   - image: Image reference (name:tag, name@digest, or image ID)
    ///   - platform: Optional platform specifier for multi-platform images (e.g., "linux/amd64")
    /// - Returns: Detailed image metadata
    /// - Throws: `TestContainersError.commandFailed` if Docker command fails
    /// - Throws: `DecodingError` if JSON parsing fails
    public func inspectImage(_ image: String, platform: String? = nil) async throws -> ImageInspection {
        var args = ["image", "inspect"]
        if let platform {
            args += ["--platform", platform]
        }
        args.append(image)

        let output = try await runDocker(args)
        return try ImageInspection.parse(from: output.stdout)
    }

    func runContainer(_ request: ContainerRequest) async throws -> String {
        logger.info("Starting container", metadata: [
            "image": request.image,
            "name": request.name ?? "auto",
        ])
        let start = ContinuousClock.now

        var authEnvironment: [String: String] = [:]

        // Authenticate to registry if credentials are provided
        if let auth = request.registryAuth {
            try await authenticateRegistry(auth, environment: &authEnvironment)
        }

        try await handleImagePullPolicy(request, environment: authEnvironment)

        var args: [String] = ["run", "-d"]
        args += try buildContainerArgs(request)

        let output = try await runDocker(args, environment: authEnvironment)
        let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw TestContainersError.unexpectedDockerOutput(output.stdout) }

        try await connectAdditionalNetworks(request: request, containerId: id)

        let duration = ContinuousClock.now - start
        logger.notice("Container started", metadata: [
            "containerId": String(id.prefix(12)),
            "image": request.image,
            "duration": "\(duration)",
        ])

        return id
    }

    /// Create a container without starting it.
    ///
    /// Uses `docker create` to create the container. Call `Container.start()` to start it later.
    ///
    /// - Parameter request: The container configuration
    /// - Returns: The container ID
    func createContainer(_ request: ContainerRequest) async throws -> String {
        logger.info("Creating container", metadata: [
            "image": request.image,
            "name": request.name ?? "auto",
        ])

        var authEnvironment: [String: String] = [:]

        if let auth = request.registryAuth {
            try await authenticateRegistry(auth, environment: &authEnvironment)
        }

        try await handleImagePullPolicy(request, environment: authEnvironment)

        var args: [String] = ["create"]
        args += try buildContainerArgs(request)

        let output = try await runDocker(args, environment: authEnvironment)
        let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw TestContainersError.unexpectedDockerOutput(output.stdout) }

        try await connectAdditionalNetworks(request: request, containerId: id)

        logger.notice("Container created", metadata: [
            "containerId": String(id.prefix(12)),
            "image": request.image,
        ])

        return id
    }

    /// Start an existing container.
    func startContainer(id: String) async throws {
        logger.debug("Starting container", metadata: ["containerId": String(id.prefix(12))])
        _ = try await runDocker(["start", id])
    }

    /// Stop a running container gracefully.
    func stopContainer(id: String, timeout: Duration) async throws {
        logger.debug("Stopping container", metadata: [
            "containerId": String(id.prefix(12)),
            "timeout": "\(timeout)",
        ])
        let seconds = Int(timeout.components.seconds)
        _ = try await runDocker(["stop", "--time", "\(seconds)", id])
    }

    private func handleImagePullPolicy(_ request: ContainerRequest, environment: [String: String] = [:]) async throws {
        let image = request.resolvedImage
        switch request.imagePullPolicy {
        case .always:
            try await pullImage(image, environment: environment)
        case .ifNotPresent:
            break
        case .never:
            let exists = await imageExists(image)
            if !exists {
                throw TestContainersError.imageNotFoundLocally(
                    image: image,
                    message: "Pull policy is set to 'never'. Either pull the image manually with 'docker pull \(image)' or change the pull policy."
                )
            }
        }
    }

    private func buildContainerArgs(_ request: ContainerRequest) throws -> [String] {
        var args: [String] = []

        if let platform = request.platform {
            guard ContainerRequest.isValidPlatform(platform) else {
                throw TestContainersError.invalidInput(
                    "Invalid platform '\(platform)'. Expected format <os>/<architecture>[/variant], for example linux/amd64 or linux/arm/v7."
                )
            }
            args += ["--platform", platform]
        }

        if let name = request.resolvedName() {
            args += ["--name", name]
        }

        if let user = request.user {
            args += ["--user", user.dockerFlag]
        }

        for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
            args += ["-e", "\(key)=\(value)"]
        }

        for mapping in request.ports {
            args += ["-p", mapping.dockerFlag]
        }

        for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
            args += ["--label", "\(key)=\(value)"]
        }

        for host in request.extraHosts.sorted(by: {
            if $0.hostname == $1.hostname {
                return $0.ip < $1.ip
            }
            return $0.hostname < $1.hostname
        }) {
            guard host.isValid else {
                throw TestContainersError.invalidInput(
                    "Invalid extra host mapping '\(host.dockerFlag)'. Hostname and IP must both be non-empty."
                )
            }
            args += ["--add-host", host.dockerFlag]
        }

        // Add resource limits
        let limits = request.resourceLimits
        if let memory = limits.memory {
            args += ["--memory", memory]
        }
        if let memoryReservation = limits.memoryReservation {
            args += ["--memory-reservation", memoryReservation]
        }
        if let memorySwap = limits.memorySwap {
            args += ["--memory-swap", memorySwap]
        }
        if let cpus = limits.cpus {
            args += ["--cpus", cpus]
        }
        if let cpuShares = limits.cpuShares {
            args += ["--cpu-shares", String(cpuShares)]
        }
        if let cpuPeriod = limits.cpuPeriod {
            args += ["--cpu-period", String(cpuPeriod)]
        }
        if let cpuQuota = limits.cpuQuota {
            args += ["--cpu-quota", String(cpuQuota)]
        }

        if request.privileged {
            args.append("--privileged")
        }

        for capability in request.capabilitiesToAdd.sorted(by: { $0.rawValue < $1.rawValue }) {
            args += ["--cap-add", capability.rawValue]
        }

        for capability in request.capabilitiesToDrop.sorted(by: { $0.rawValue < $1.rawValue }) {
            args += ["--cap-drop", capability.rawValue]
        }

        // Add volume mounts sorted by volume name for deterministic ordering
        for mount in request.volumes.sorted(by: { $0.volumeName < $1.volumeName }) {
            args += ["-v", mount.dockerFlag]
        }

        // Add bind mounts sorted by host path for deterministic ordering
        for mount in request.bindMounts.sorted(by: { $0.hostPath < $1.hostPath }) {
            args += ["-v", mount.dockerFlag]
        }

        // Add tmpfs mounts sorted by container path for deterministic ordering
        for mount in request.tmpfsMounts.sorted(by: { $0.containerPath < $1.containerPath }) {
            args += ["--tmpfs", mount.dockerFlag]
        }

        // Add working directory if specified
        if let workingDirectory = request.workingDirectory {
            args += ["--workdir", workingDirectory]
        }

        // Add health check configuration if specified
        if let healthCheck = request.healthCheck {
            let cmdString = healthCheck.command.joined(separator: " ")
            args += ["--health-cmd", cmdString]

            if let interval = healthCheck.interval {
                args += ["--health-interval", Self.formatDuration(interval)]
            }
            if let timeout = healthCheck.timeout {
                args += ["--health-timeout", Self.formatDuration(timeout)]
            }
            if let startPeriod = healthCheck.startPeriod {
                args += ["--health-start-period", Self.formatDuration(startPeriod)]
            }
            if let retries = healthCheck.retries {
                args += ["--health-retries", String(retries)]
            }
        }

        // Add network configuration
        if let mode = request.networkMode {
            args += ["--network", mode.dockerFlag]
        } else if let firstNetwork = request.networks.first {
            args += ["--network", firstNetwork.networkName]
            for alias in firstNetwork.aliases {
                args += ["--network-alias", alias]
            }
            if let ipv4 = firstNetwork.ipv4Address {
                args += ["--ip", ipv4]
            }
            if let ipv6 = firstNetwork.ipv6Address {
                args += ["--ip6", ipv6]
            }
        }

        // Add entrypoint override if specified
        if let entrypoint = request.entrypoint {
            if entrypoint.isEmpty {
                args += ["--entrypoint", ""]
            } else {
                args += ["--entrypoint", entrypoint[0]]
            }
        }

        args.append(request.resolvedImage)

        // Handle multi-part entrypoint: elements after the first become command prefix
        if let entrypoint = request.entrypoint, entrypoint.count > 1 {
            args += Array(entrypoint[1...])
        }

        args += request.command

        return args
    }

    private func connectAdditionalNetworks(request: ContainerRequest, containerId: String) async throws {
        if request.networkMode == nil {
            for network in request.networks.dropFirst() {
                try await connectToNetwork(
                    containerId: containerId,
                    networkName: network.networkName,
                    aliases: network.aliases,
                    ipv4Address: network.ipv4Address,
                    ipv6Address: network.ipv6Address
                )
            }
        }
    }

    private static func formatDuration(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds >= 1.0 {
            return "\(Int(seconds))s"
        } else {
            return "\(Int(seconds * 1000))ms"
        }
    }

    func removeContainer(id: String) async throws {
        logger.debug("Removing container", metadata: ["containerId": String(id.prefix(12))])
        _ = try await runDocker(["rm", "-f", id])
    }

    /// Fetch the last N lines of container logs.
    func logsTail(id: String, lines: Int) async throws -> String {
        let args = Self.logsTailArgs(id: id, lines: lines)
        let output = try await runDocker(args)
        return output.stdout + output.stderr
    }

    /// Build the docker logs --tail command arguments.
    static func logsTailArgs(id: String, lines: Int) -> [String] {
        ["logs", "--tail", "\(lines)", id]
    }

    func logs(id: String) async throws -> String {
        let output = try await runDocker(["logs", id])
        // Docker logs outputs to both stdout and stderr - combine them
        return output.stdout + output.stderr
    }

    func port(id: String, containerPort: Int) async throws -> Int {
        let output = try await runDocker(["port", id, "\(containerPort)"])
        let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Self.parseDockerPort(text) else {
            throw TestContainersError.unexpectedDockerOutput(text)
        }
        return port
    }

    func exec(id: String, command: [String]) async throws -> Int32 {
        var args = ["exec", id]
        args += command
        let output = try await runner.run(executable: dockerPath, arguments: args)
        return output.exitCode
    }

    /// Execute a command in a container with options.
    ///
    /// - Parameters:
    ///   - id: The container ID
    ///   - command: The command and arguments to execute
    ///   - options: Execution options (user, working directory, environment, etc.)
    /// - Returns: ExecResult containing exit code, stdout, and stderr
    func exec(id: String, command: [String], options: ExecOptions) async throws -> ExecResult {
        var args: [String] = ["exec"]

        if options.detached {
            args.append("-d")
        }

        if options.interactive {
            args.append("-i")
        }

        if options.tty {
            args.append("-t")
        }

        if let user = options.user {
            args += ["-u", user]
        }

        if let workdir = options.workingDirectory {
            args += ["-w", workdir]
        }

        for (key, value) in options.environment.sorted(by: { $0.key < $1.key }) {
            args += ["-e", "\(key)=\(value)"]
        }

        args.append(id)
        args += command

        // Note: Don't use runDocker() because we want to capture non-zero exit codes
        // without throwing - the command may intentionally fail
        let output = try await runner.run(executable: dockerPath, arguments: args)

        return ExecResult(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
    }

    func healthStatus(id: String) async throws -> ContainerHealthStatus {
        let output = try await runDocker([
            "inspect",
            "--format", "{{json .State.Health}}",
            id
        ])
        return try Self.parseHealthStatus(output.stdout)
    }

    static func parseHealthStatus(_ json: String) throws -> ContainerHealthStatus {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle "null" case (no health check configured)
        if trimmed == "null" || trimmed.isEmpty {
            return ContainerHealthStatus(status: nil, hasHealthCheck: false)
        }

        let data = Data(trimmed.utf8)
        let response = try JSONDecoder().decode(HealthCheckResponse.self, from: data)

        guard let statusString = response.Status else {
            return ContainerHealthStatus(status: nil, hasHealthCheck: false)
        }

        let status = ContainerHealthStatus.Status(rawValue: statusString)
        return ContainerHealthStatus(status: status, hasHealthCheck: true)
    }

    private static func parseDockerPort(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            var digits: [UInt8] = []
            for scalar in line.utf8.reversed() {
                if scalar >= 48 && scalar <= 57 {
                    digits.append(scalar)
                    continue
                }
                if scalar == 58 { // ':'
                    break
                }
                digits.removeAll(keepingCapacity: true)
                break
            }

            guard !digits.isEmpty else { continue }
            let portString = String(bytes: digits.reversed(), encoding: .utf8) ?? ""
            if let port = Int(portString) { return port }
        }
        return nil
    }

    // MARK: - Network Operations

    /// Create a Docker network with explicit primitive options.
    ///
    /// This overload is useful for stack orchestration APIs that use lightweight
    /// network config values instead of `NetworkRequest`.
    func createNetwork(name: String, driver: String = "bridge", internal: Bool = false) async throws -> String {
        var args: [String] = ["network", "create", "--driver", driver]
        if `internal` {
            args.append("--internal")
        }
        args.append(name)

        let output = try await runDocker(args)
        let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw TestContainersError.unexpectedDockerOutput(output.stdout)
        }
        return id
    }

    func createNetwork(_ request: NetworkRequest) async throws -> (id: String, name: String) {
        var args: [String] = ["network", "create"]

        args += ["--driver", request.driver.rawValue]

        for (key, value) in request.options.sorted(by: { $0.key < $1.key }) {
            args += ["--opt", "\(key)=\(value)"]
        }

        for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
            args += ["--label", "\(key)=\(value)"]
        }

        if let ipam = request.ipamConfig {
            if let subnet = ipam.subnet {
                args += ["--subnet", subnet]
            }
            if let gateway = ipam.gateway {
                args += ["--gateway", gateway]
            }
            if let ipRange = ipam.ipRange {
                args += ["--ip-range", ipRange]
            }
        }

        if request.enableIPv6 {
            args += ["--ipv6"]
        }

        if request.internal {
            args += ["--internal"]
        }

        if request.attachable {
            args += ["--attachable"]
        }

        let networkName = request.name ?? "tc-network-\(UUID().uuidString.prefix(8).lowercased())"
        args.append(networkName)

        let output = try await runDocker(args)
        let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw TestContainersError.unexpectedDockerOutput(output.stdout)
        }

        return (id: id, name: networkName)
    }

    func removeNetwork(id: String) async throws {
        _ = try await runDocker(["network", "rm", id])
    }

    /// Connect a running container to a network.
    ///
    /// - Parameters:
    ///   - containerId: The container ID
    ///   - networkName: The network to connect to
    ///   - aliases: DNS aliases for service discovery within the network
    ///   - ipv4Address: Optional IPv4 address to assign
    ///   - ipv6Address: Optional IPv6 address to assign
    func connectToNetwork(
        containerId: String,
        networkName: String,
        aliases: [String] = [],
        ipv4Address: String? = nil,
        ipv6Address: String? = nil
    ) async throws {
        var args = ["network", "connect"]

        for alias in aliases {
            args += ["--alias", alias]
        }

        if let ipv4 = ipv4Address {
            args += ["--ip", ipv4]
        }

        if let ipv6 = ipv6Address {
            args += ["--ip6", ipv6]
        }

        args += [networkName, containerId]
        _ = try await runDocker(args)
    }

    func networkExists(_ nameOrID: String) async throws -> Bool {
        do {
            _ = try await runDocker(["network", "inspect", nameOrID])
            return true
        } catch {
            return false
        }
    }

    // MARK: - Volume Operations

    /// Create a Docker volume with the given name and optional configuration.
    ///
    /// - Parameters:
    ///   - name: The volume name
    ///   - config: Optional volume configuration (driver, driver options)
    /// - Returns: The volume name
    func createVolume(name: String, config: VolumeConfig = VolumeConfig()) async throws -> String {
        var args: [String] = ["volume", "create"]

        args += ["--driver", config.driver]

        for (key, value) in config.options.sorted(by: { $0.key < $1.key }) {
            args += ["--opt", "\(key)=\(value)"]
        }

        args.append(name)

        _ = try await runDocker(args)
        return name
    }

    /// Remove a Docker volume by name.
    ///
    /// - Parameter name: The volume name to remove
    func removeVolume(name: String) async throws {
        _ = try await runDocker(["volume", "rm", "-f", name])
    }

    // MARK: - Copy Operations

    /// Copy a file or directory from the host to a container.
    ///
    /// - Parameters:
    ///   - id: The container ID
    ///   - sourcePath: Absolute path to source file or directory on host
    ///   - destinationPath: Destination path in container
    /// - Throws: `TestContainersError.invalidInput` if source doesn't exist,
    ///           `TestContainersError.commandFailed` if docker cp fails
    func copyToContainer(id: String, sourcePath: String, destinationPath: String) async throws {
        // Validate source exists
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourcePath, isDirectory: &isDirectory) else {
            throw TestContainersError.invalidInput("Source path does not exist: \(sourcePath)")
        }

        // docker cp <src> <container>:<dest>
        let target = "\(id):\(destinationPath)"
        _ = try await runDocker(["cp", sourcePath, target])
    }

    /// Copy data directly to a file in a container.
    ///
    /// Creates a temporary file, copies it to the container, and cleans up.
    ///
    /// - Parameters:
    ///   - id: The container ID
    ///   - data: Data to write to the container
    ///   - destinationPath: Destination file path in container
    /// - Throws: `TestContainersError.commandFailed` if docker cp fails
    func copyDataToContainer(id: String, data: Data, destinationPath: String) async throws {
        // Create temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileName = "testcontainers-\(UUID().uuidString)"
        let tempFileURL = tempDir.appendingPathComponent(tempFileName)

        do {
            // Write data to temp file
            try data.write(to: tempFileURL)

            // Copy temp file to container
            try await copyToContainer(id: id, sourcePath: tempFileURL.path, destinationPath: destinationPath)

            // Clean up temp file
            try FileManager.default.removeItem(at: tempFileURL)
        } catch {
            // Ensure cleanup even on failure
            try? FileManager.default.removeItem(at: tempFileURL)
            throw error
        }
    }

    /// Copy a file or directory from a container to the host filesystem.
    ///
    /// - Parameters:
    ///   - id: The container ID
    ///   - containerPath: Absolute path to source file or directory in container
    ///   - hostPath: Destination path on host
    ///   - archive: Whether to preserve uid/gid info (uses -a flag)
    /// - Throws: `TestContainersError.commandFailed` if docker cp fails
    func copyFromContainer(
        id: String,
        containerPath: String,
        hostPath: String,
        archive: Bool = true
    ) async throws {
        var args = ["cp"]
        if archive {
            args.append("-a")
        }
        args.append("\(id):\(containerPath)")
        args.append(hostPath)
        _ = try await runDocker(args)
    }

    // MARK: - Log Streaming

    /// Stream container logs in real-time.
    ///
    /// - Parameters:
    ///   - id: The container ID
    ///   - options: Options for filtering and formatting the log stream
    /// - Returns: AsyncThrowingStream of LogEntry values
    func streamLogs(id: String, options: LogStreamOptions) -> AsyncThrowingStream<LogEntry, Error> {
        var args = ["logs"]
        args.append(contentsOf: options.toDockerArgs())
        args.append(id)

        // Capture values for use in closures
        let capturedArgs = args
        let capturedDockerPath = dockerPath
        let capturedRunner = runner
        let hasTimestamps = options.timestamps

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in capturedRunner.streamLines(executable: capturedDockerPath, arguments: capturedArgs) {
                        if Task.isCancelled {
                            break
                        }
                        let entry = LogEntry.parse(line: line, hasTimestamps: hasTimestamps)
                        continuation.yield(entry)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Inspect Operations

    /// Inspect a container to retrieve detailed runtime information.
    ///
    /// - Parameter id: The container ID
    /// - Returns: Comprehensive inspection data including state, config, and networking
    /// - Throws: `TestContainersError.commandFailed` if docker inspect fails,
    ///           `TestContainersError.unexpectedDockerOutput` if output is invalid
    func inspect(id: String) async throws -> ContainerInspection {
        let output = try await runDocker(["inspect", id])
        return try ContainerInspection.parse(from: output.stdout)
    }

    // MARK: - Image Build Operations

    /// Build an image from a Dockerfile.
    ///
    /// - Parameters:
    ///   - config: Dockerfile build configuration
    ///   - tag: Image tag for the built image
    /// - Returns: The image tag
    /// - Throws: `TestContainersError.imageBuildFailed` if the build fails
    func buildImage(_ config: ImageFromDockerfile, tag: String) async throws -> String {
        let args = Self.buildImageArgs(config: config, tag: tag)
        let output = try await runner.run(executable: dockerPath, arguments: args)

        if output.exitCode != 0 {
            throw TestContainersError.imageBuildFailed(
                dockerfile: config.dockerfilePath,
                context: config.buildContext,
                exitCode: output.exitCode,
                stdout: output.stdout,
                stderr: output.stderr
            )
        }

        return tag
    }

    /// Remove an image by tag.
    ///
    /// - Parameter tag: The image tag to remove
    /// - Throws: `TestContainersError.commandFailed` if removal fails
    func removeImage(_ tag: String) async throws {
        // Use -f to force removal, ignoring errors if image doesn't exist
        _ = try? await runDocker(["rmi", "-f", tag])
    }

    /// Build the docker build command arguments from an ImageFromDockerfile config.
    ///
    /// This is exposed as a static method for testing purposes.
    ///
    /// - Parameters:
    ///   - config: The Dockerfile build configuration
    ///   - tag: The image tag to use
    /// - Returns: Array of command line arguments for docker build
    static func buildImageArgs(config: ImageFromDockerfile, tag: String) -> [String] {
        var args: [String] = ["build"]

        // Add tag
        args += ["-t", tag]

        // Add dockerfile path
        args += ["-f", config.dockerfilePath]

        // Add build arguments (sorted for deterministic output)
        for (key, value) in config.buildArgs.sorted(by: { $0.key < $1.key }) {
            args += ["--build-arg", "\(key)=\(value)"]
        }

        // Add target stage if specified
        if let target = config.targetStage {
            args += ["--target", target]
        }

        // Add cache options
        if config.noCache {
            args.append("--no-cache")
        }

        if config.pullBaseImages {
            args.append("--pull")
        }

        // Add build context (must be last)
        args.append(config.buildContext)

        return args
    }

    // MARK: - Container List Operations

    /// List containers matching the given label filters.
    ///
    /// - Parameter labels: Dictionary of label key-value pairs to filter by
    /// - Returns: Array of container list items
    /// - Throws: `TestContainersError.commandFailed` if docker ps fails
    func listContainers(labels: [String: String] = [:]) async throws -> [ContainerListItem] {
        let args = Self.listContainersArgs(labels: labels)
        let output = try await runDocker(args)
        return try Self.parseContainerList(output.stdout)
    }

    /// Finds the newest running reusable container for a reuse hash.
    ///
    /// - Parameter hash: Reuse fingerprint hash
    /// - Returns: The newest matching running container, if any
    func findReusableContainer(hash: String) async throws -> ContainerListItem? {
        let containers = try await listContainers(labels: [
            ReuseLabels.enabled: "true",
            ReuseLabels.hash: hash,
            ReuseLabels.version: ReuseLabels.versionValue,
        ])
        return Self.selectReusableContainer(from: containers)
    }

    /// Selects the newest running container from a candidate list.
    static func selectReusableContainer(from containers: [ContainerListItem]) -> ContainerListItem? {
        containers
            .filter { $0.state == "running" }
            .max { lhs, rhs in lhs.created < rhs.created }
    }

    /// Remove multiple containers in parallel.
    ///
    /// - Parameters:
    ///   - ids: Array of container IDs to remove
    ///   - force: Whether to force removal (default: true)
    /// - Returns: Dictionary mapping container ID to optional error (nil if successful)
    func removeContainers(ids: [String], force: Bool = true) async -> [String: Error?] {
        var results: [String: Error?] = [:]

        await withTaskGroup(of: (String, Error?).self) { group in
            for id in ids {
                group.addTask {
                    do {
                        var args = ["rm"]
                        if force {
                            args.append("-f")
                        }
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

    /// Build the docker ps command arguments for listing containers.
    ///
    /// This is exposed as a static method for testing purposes.
    ///
    /// - Parameter labels: Dictionary of label key-value pairs to filter by
    /// - Returns: Array of command line arguments for docker ps
    static func listContainersArgs(labels: [String: String]) -> [String] {
        var args: [String] = ["ps", "-a", "--no-trunc", "--format", "{{json .}}"]

        // Add label filters sorted for deterministic output
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            args += ["--filter", "label=\(key)=\(value)"]
        }

        return args
    }

    /// Parse docker ps JSON output into ContainerListItem array.
    ///
    /// This is exposed as a static method for testing purposes.
    ///
    /// - Parameter output: The stdout from docker ps --format "{{json .}}"
    /// - Returns: Array of parsed container list items
    /// - Throws: DecodingError if JSON parsing fails
    static func parseContainerList(_ output: String) throws -> [ContainerListItem] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        var items: [ContainerListItem] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let data = Data(trimmed.utf8)
            let item = try JSONDecoder().decode(ContainerListItem.self, from: data)
            items.append(item)
        }

        return items
    }
}
