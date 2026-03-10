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

public struct DockerClient: ContainerRuntime, Sendable {
    private let httpClient: DockerHTTPClient?
    private let dockerPath: String
    private let runner: ProcessRunner
    private let logger: TCLogger

    /// Create a DockerClient that communicates with the Docker Engine API over a Unix socket.
    public init(
        socketPath: String = "/var/run/docker.sock",
        dockerPath: String = "docker",
        logger: TCLogger = .null
    ) {
        self.httpClient = DockerHTTPClient(socketPath: socketPath)
        self.dockerPath = dockerPath
        self.logger = logger
        self.runner = ProcessRunner(logger: logger)
    }

    /// Create a CLI-only DockerClient (no HTTP API connection).
    ///
    /// Used for tests with mock Docker scripts. Operations fall back to CLI commands.
    public init(dockerPath: String, logger: TCLogger = .null) {
        self.httpClient = nil
        self.dockerPath = dockerPath
        self.logger = logger
        self.runner = ProcessRunner(logger: logger)
    }

    // MARK: - Docker Availability

    public func isAvailable() async -> Bool {
        guard let httpClient else {
            // CLI fallback
            logger.debug("Checking Docker availability via CLI")
            do {
                let output = try await runner.run(executable: dockerPath, arguments: ["info"])
                let available = output.exitCode == 0
                if available {
                    logger.info("Docker is available")
                } else {
                    logger.warning("Docker check failed")
                }
                return available
            } catch {
                logger.error("Docker availability check threw error", metadata: ["error": "\(error)"])
                return false
            }
        }

        logger.debug("Checking Docker availability via API")
        let start = ContinuousClock.now
        do {
            let (status, body) = try await httpClient.get("/version")
            let available = (200..<300).contains(status.code)
            let duration = ContinuousClock.now - start
            if available {
                let version = try? JSONDecoder().decode(DockerVersionResponse.self, from: body)
                logger.info("Docker is available", metadata: [
                    "version": version?.Version ?? "unknown",
                    "apiVersion": version?.ApiVersion ?? "unknown",
                    "duration": "\(duration)",
                ])
            } else {
                logger.warning("Docker check failed", metadata: [
                    "statusCode": "\(status.code)",
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

    // MARK: - CLI Helper (for build/cp operations)

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

    /// Build the X-Registry-Auth header value for API image pull requests.
    private func buildRegistryAuthHeader(_ auth: RegistryAuth) -> String? {
        switch auth {
        case let .credentials(registry, username, password):
            let config = DockerAuthConfig(
                username: username,
                password: password,
                serveraddress: registry
            )
            guard let data = try? JSONEncoder().encode(config) else { return nil }
            return data.base64EncodedString()

        case let .configFile(path):
            return readAuthFromDockerConfig(directory: path)

        case .systemDefault:
            return readAuthFromDockerConfig(
                directory: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".docker").path
            )
        }
    }

    /// Read auth token from a Docker config.json file.
    private func readAuthFromDockerConfig(directory: String) -> String? {
        let configPath = directory.hasSuffix("config.json")
            ? directory
            : (directory as NSString).appendingPathComponent("config.json")

        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auths = json["auths"] as? [String: [String: String]]
        else {
            return nil
        }

        // Return the first auth entry's base64 config as the header value
        for (server, authInfo) in auths {
            if let authToken = authInfo["auth"] {
                // authToken is base64(username:password) - reconstruct the API format
                guard let decoded = Data(base64Encoded: authToken),
                      let decodedString = String(data: decoded, encoding: .utf8)
                else { continue }

                let parts = decodedString.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }

                let config = DockerAuthConfig(
                    username: String(parts[0]),
                    password: String(parts[1]),
                    serveraddress: server
                )
                guard let configData = try? JSONEncoder().encode(config) else { continue }
                return configData.base64EncodedString()
            }
        }

        return nil
    }

    /// Authenticate to a Docker registry before pulling/running images.
    /// Kept for backward compatibility with existing callers.
    public func authenticateRegistry(_ auth: RegistryAuth, environment: inout [String: String]) async throws {
        // In the API model, auth is handled via X-Registry-Auth header on pull requests.
        // This method is now a no-op for .credentials and .systemDefault.
        // For .configFile, we preserve compatibility by setting the env var for CLI operations.
        switch auth {
        case .credentials:
            break // Handled via API header in pullImage
        case let .configFile(path):
            environment["DOCKER_CONFIG"] = path
        case .systemDefault:
            break
        }
    }

    // MARK: - Image Operations

    /// Check if an image exists in the local Docker image cache.
    public func imageExists(_ image: String, platform: String? = nil) async -> Bool {
        guard let httpClient else {
            // CLI fallback
            var args = ["image", "inspect"]
            if let platform { args += ["--platform", platform] }
            args.append(image)
            do {
                let output = try await runner.run(executable: dockerPath, arguments: args)
                return output.exitCode == 0
            } catch {
                return false
            }
        }

        do {
            let encodedImage = image.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? image
            let (status, _) = try await httpClient.get("/images/\(encodedImage)/json")
            return status.code == 200
        } catch {
            return false
        }
    }

    /// Pull an image from a registry.
    public func pullImage(
        _ image: String,
        platform: String? = nil,
        environment: [String: String] = [:],
        registryAuth: RegistryAuth? = nil
    ) async throws {
        guard let httpClient else {
            // CLI fallback
            var args = ["pull"]
            if let platform { args += ["--platform", platform] }
            args.append(image)
            let output = try await runner.run(executable: dockerPath, arguments: args, environment: environment)
            if output.exitCode != 0 {
                throw TestContainersError.imagePullFailed(
                    image: image, exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr
                )
            }
            return
        }

        var queryItems: [(String, String)] = [("fromImage", image)]
        if let platform {
            queryItems.append(("platform", platform))
        }

        var headers: [(String, String)] = []
        if let auth = registryAuth {
            if let authHeader = buildRegistryAuthHeader(auth) {
                headers.append(("X-Registry-Auth", authHeader))
            }
        }

        let (status, body) = try await httpClient.postStreaming(
            "/images/create",
            queryItems: queryItems,
            headers: headers
        )

        // Check for errors in the streaming response
        let responseText = String(data: body, encoding: .utf8) ?? ""
        for line in responseText.split(separator: "\n") {
            let lineData = Data(line.utf8)
            if let progress = try? JSONDecoder().decode(PullProgressResponse.self, from: lineData),
               let error = progress.error, !error.isEmpty {
                throw TestContainersError.imagePullFailed(
                    image: image,
                    exitCode: 1,
                    stdout: responseText,
                    stderr: error
                )
            }
        }

        guard (200..<300).contains(status.code) else {
            let message = String(data: body, encoding: .utf8) ?? "Unknown error"
            throw TestContainersError.imagePullFailed(
                image: image,
                exitCode: Int32(status.code),
                stdout: "",
                stderr: message
            )
        }
    }

    /// Pull an image (backward-compatible overload using environment dict for auth).
    func pullImage(
        _ image: String,
        platform: String? = nil,
        environment: [String: String] = [:]
    ) async throws {
        try await pullImage(image, platform: platform, environment: environment, registryAuth: nil)
    }

    /// Inspect an image to retrieve comprehensive metadata.
    public func inspectImage(_ image: String, platform: String? = nil) async throws -> ImageInspection {
        guard let httpClient else {
            // CLI fallback
            var args = ["image", "inspect"]
            if let platform { args += ["--platform", platform] }
            args.append(image)
            let output = try await runDocker(args)
            return try ImageInspection.parse(from: output.stdout)
        }

        let encodedImage = image.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? image
        let (status, body) = try await httpClient.get("/images/\(encodedImage)/json")

        guard (200..<300).contains(status.code) else {
            let message = String(data: body, encoding: .utf8) ?? "Unknown error"
            throw TestContainersError.apiError(statusCode: Int(status.code), message: message)
        }

        return try ImageInspection.parseFromAPI(data: body)
    }

    // MARK: - Container Operations

    public func runContainer(_ request: ContainerRequest) async throws -> String {
        guard let httpClient else {
            // CLI fallback
            logger.info("Starting container", metadata: [
                "image": request.image,
                "name": request.name ?? "auto",
            ])
            let start = ContinuousClock.now

            // Validate request
            try Self.validateRequest(request)

            // Handle registry auth for CLI mode
            var environment: [String: String] = [:]
            if let auth = request.registryAuth {
                try await authenticateRegistry(auth, environment: &environment)
                // For credentials auth, run docker login first
                if case let .credentials(registry, username, password) = auth {
                    let loginArgs = Self.loginArgs(registry: registry, username: username)
                    _ = try await runner.run(
                        executable: dockerPath,
                        arguments: loginArgs,
                        environment: environment,
                        stdinData: password.data(using: .utf8) ?? Data()
                    )
                }
            }

            try await handleImagePullPolicy(request)
            let args = Self.buildContainerRunArgs(from: request)
            let output = try await runner.run(executable: dockerPath, arguments: args, environment: environment)
            if output.exitCode != 0 {
                throw TestContainersError.commandFailed(command: [dockerPath] + args, exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
            }
            let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            // Connect additional networks via CLI
            try await connectAdditionalNetworksCLI(request: request, containerId: id)

            let duration = ContinuousClock.now - start
            logger.notice("Container started", metadata: [
                "containerId": String(id.prefix(12)),
                "image": request.image,
                "duration": "\(duration)",
            ])

            return id
        }

        logger.info("Starting container", metadata: [
            "image": request.image,
            "name": request.name ?? "auto",
        ])
        let start = ContinuousClock.now

        try await handleImagePullPolicy(request)

        // Create container via API
        let createBody = DockerContainerConfig.buildCreateBody(from: request)
        let queryParams = DockerContainerConfig.buildQueryParams(from: request)
        let bodyData = try JSONEncoder().encode(createBody)

        let (createStatus, createResponseData) = try await httpClient.post(
            "/containers/create",
            body: bodyData,
            queryItems: queryParams
        )
        let createResponse: CreateContainerResponse = try httpClient.decodeResponse(
            CreateContainerResponse.self,
            status: createStatus,
            body: createResponseData
        )
        let id = createResponse.Id

        // Start container
        let (startStatus, startBody) = try await httpClient.post("/containers/\(id)/start")
        try httpClient.requireSuccess(status: startStatus, body: startBody)

        // Connect additional networks
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
    public func createContainer(_ request: ContainerRequest) async throws -> String {
        guard let httpClient else {
            // CLI fallback
            try await handleImagePullPolicy(request)
            var args = ["create"]
            args += Self.buildContainerFlags(from: request)
            args.append(request.resolvedImage)
            if !request.command.isEmpty {
                args += request.command
            }
            let output = try await runDocker(args)
            return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        logger.info("Creating container", metadata: [
            "image": request.image,
            "name": request.name ?? "auto",
        ])

        try await handleImagePullPolicy(request)

        let createBody = DockerContainerConfig.buildCreateBody(from: request)
        let queryParams = DockerContainerConfig.buildQueryParams(from: request)
        let bodyData = try JSONEncoder().encode(createBody)

        let (status, responseData) = try await httpClient.post(
            "/containers/create",
            body: bodyData,
            queryItems: queryParams
        )
        let response: CreateContainerResponse = try httpClient.decodeResponse(
            CreateContainerResponse.self,
            status: status,
            body: responseData
        )
        let id = response.Id

        try await connectAdditionalNetworks(request: request, containerId: id)

        logger.notice("Container created", metadata: [
            "containerId": String(id.prefix(12)),
            "image": request.image,
        ])

        return id
    }

    /// Start an existing container.
    public func startContainer(id: String) async throws {
        guard let httpClient else {
            _ = try await runDocker(["start", id])
            return
        }
        logger.debug("Starting container", metadata: ["containerId": String(id.prefix(12))])
        let (status, body) = try await httpClient.post("/containers/\(id)/start")
        // 204 = started, 304 = already started (both OK)
        guard status.code == 204 || status.code == 304 else {
            try httpClient.requireSuccess(status: status, body: body)
            return
        }
    }

    /// Stop a running container gracefully.
    public func stopContainer(id: String, timeout: Duration) async throws {
        guard let httpClient else {
            let seconds = Int(timeout.components.seconds)
            _ = try await runDocker(["stop", "--time", "\(seconds)", id])
            return
        }
        logger.debug("Stopping container", metadata: [
            "containerId": String(id.prefix(12)),
            "timeout": "\(timeout)",
        ])
        let seconds = Int(timeout.components.seconds)
        let (status, body) = try await httpClient.post(
            "/containers/\(id)/stop",
            queryItems: [("t", "\(seconds)")]
        )
        // 204 = stopped, 304 = already stopped (both OK)
        guard status.code == 204 || status.code == 304 else {
            try httpClient.requireSuccess(status: status, body: body)
            return
        }
    }

    private func handleImagePullPolicy(_ request: ContainerRequest) async throws {
        let image = request.resolvedImage
        switch request.imagePullPolicy {
        case .always:
            try await pullImage(image, registryAuth: request.registryAuth)
        case .ifNotPresent:
            if httpClient != nil {
                // Docker API doesn't auto-pull like CLI. Check and pull if needed.
                let exists = await imageExists(image)
                if !exists {
                    try await pullImage(image, registryAuth: request.registryAuth)
                }
            }
            // CLI mode: docker run auto-pulls, no explicit check needed
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

    public func removeContainer(id: String) async throws {
        guard let httpClient else {
            logger.debug("Removing container", metadata: ["containerId": String(id.prefix(12))])
            _ = try await runDocker(["rm", "-f", id])
            return
        }
        logger.debug("Removing container", metadata: ["containerId": String(id.prefix(12))])
        let (status, body) = try await httpClient.delete(
            "/containers/\(id)",
            queryItems: [("force", "true")]
        )
        // 204 = removed, 404 = not found (both OK for forced removal)
        guard status.code == 204 || status.code == 404 else {
            try httpClient.requireSuccess(status: status, body: body)
            return
        }
    }

    // MARK: - Log Operations

    /// Fetch the last N lines of container logs.
    public func logsTail(id: String, lines: Int) async throws -> String {
        guard let httpClient else {
            let output = try await runDocker(Self.logsTailArgs(id: id, lines: lines))
            return output.stdout
        }
        let (status, body) = try await httpClient.get(
            "/containers/\(id)/logs",
            queryItems: [
                ("stdout", "true"),
                ("stderr", "true"),
                ("tail", "\(lines)"),
            ]
        )
        try httpClient.requireSuccess(status: status, body: body)
        return DockerMultiplexedStream.demultiplexToString(from: body)
    }

    /// Build the docker logs --tail command arguments (kept for test compatibility).
    static func logsTailArgs(id: String, lines: Int) -> [String] {
        ["logs", "--tail", "\(lines)", id]
    }

    public func logs(id: String) async throws -> String {
        guard let httpClient else {
            let output = try await runDocker(["logs", id])
            return output.stdout
        }
        let (status, body) = try await httpClient.get(
            "/containers/\(id)/logs",
            queryItems: [
                ("stdout", "true"),
                ("stderr", "true"),
            ]
        )
        try httpClient.requireSuccess(status: status, body: body)
        return DockerMultiplexedStream.demultiplexToString(from: body)
    }

    /// Get the host port for a given container port.
    ///
    /// Extracts the port mapping from the container's inspect data.
    public func port(id: String, containerPort: Int) async throws -> Int {
        guard httpClient != nil else {
            // CLI fallback
            let output = try await runDocker(["port", id, "\(containerPort)"])
            let portString = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // Format: "0.0.0.0:12345" or ":::12345"
            if let lastColon = portString.lastIndex(of: ":"),
               let port = Int(portString[portString.index(after: lastColon)...]) {
                return port
            }
            throw TestContainersError.unexpectedDockerOutput(
                "No host port mapping found for container port \(containerPort)"
            )
        }

        let inspection = try await inspect(id: id)
        for binding in inspection.networkSettings.ports {
            if binding.containerPort == containerPort, let hostPort = binding.hostPort {
                return hostPort
            }
        }

        throw TestContainersError.unexpectedDockerOutput(
            "No host port mapping found for container port \(containerPort)"
        )
    }

    // MARK: - Exec Operations

    public func exec(id: String, command: [String]) async throws -> Int32 {
        guard let httpClient else {
            // CLI fallback
            let args = ["exec", id] + command
            let output = try await runner.run(executable: dockerPath, arguments: args)
            return output.exitCode
        }

        // Create exec instance
        let createBody = ExecCreateRequest(
            AttachStdout: false,
            AttachStderr: false,
            Detach: true,
            Tty: false,
            Cmd: command,
            Env: nil,
            User: nil,
            WorkingDir: nil
        )
        let createData = try JSONEncoder().encode(createBody)
        let (createStatus, createResponseData) = try await httpClient.post(
            "/containers/\(id)/exec",
            body: createData
        )
        let execResponse: ExecCreateResponse = try httpClient.decodeResponse(
            ExecCreateResponse.self,
            status: createStatus,
            body: createResponseData
        )

        // Start exec (detached)
        let startBody = ExecStartRequest(Detach: true, Tty: false)
        let startData = try JSONEncoder().encode(startBody)
        let (startStatus, startResponseBody) = try await httpClient.post(
            "/exec/\(execResponse.Id)/start",
            body: startData
        )
        try httpClient.requireSuccess(status: startStatus, body: startResponseBody)

        // Wait briefly for the command to complete, then inspect for exit code
        try await Task.sleep(for: .milliseconds(100))

        // Poll for completion
        for _ in 0..<100 {
            let (inspectStatus, inspectBody) = try await httpClient.get("/exec/\(execResponse.Id)/json")
            let inspectResponse: ExecInspectResponse = try httpClient.decodeResponse(
                ExecInspectResponse.self,
                status: inspectStatus,
                body: inspectBody
            )
            if !inspectResponse.Running {
                return inspectResponse.ExitCode
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        return -1 // Timeout
    }

    /// Execute a command in a container with options.
    public func exec(id: String, command: [String], options: ExecOptions) async throws -> ExecResult {
        guard let httpClient else {
            // CLI fallback
            var args = ["exec"]
            if let user = options.user { args += ["-u", user] }
            if let workDir = options.workingDirectory { args += ["-w", workDir] }
            for (key, value) in options.environment.sorted(by: { $0.key < $1.key }) {
                args += ["-e", "\(key)=\(value)"]
            }
            if options.tty { args.append("-t") }
            if options.detached { args.append("-d") }
            args.append(id)
            args += command
            let output = try await runner.run(executable: dockerPath, arguments: args)
            return ExecResult(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
        }

        // Build environment array
        var envArray: [String]?
        if !options.environment.isEmpty {
            envArray = options.environment
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
        }

        // Create exec instance
        let createBody = ExecCreateRequest(
            AttachStdout: !options.detached,
            AttachStderr: !options.detached,
            Detach: options.detached,
            Tty: options.tty,
            Cmd: command,
            Env: envArray,
            User: options.user,
            WorkingDir: options.workingDirectory
        )
        let createData = try JSONEncoder().encode(createBody)
        let (createStatus, createResponseData) = try await httpClient.post(
            "/containers/\(id)/exec",
            body: createData
        )
        let execResponse: ExecCreateResponse = try httpClient.decodeResponse(
            ExecCreateResponse.self,
            status: createStatus,
            body: createResponseData
        )

        if options.detached {
            // Detached mode: start and return immediately
            let startBody = ExecStartRequest(Detach: true, Tty: false)
            let startData = try JSONEncoder().encode(startBody)
            let (startStatus, startResponseBody) = try await httpClient.post(
                "/exec/\(execResponse.Id)/start",
                body: startData
            )
            try httpClient.requireSuccess(status: startStatus, body: startResponseBody)
            return ExecResult(exitCode: 0, stdout: "", stderr: "")
        }

        // Attached mode: start and collect output
        let startBody = ExecStartRequest(Detach: false, Tty: options.tty)
        let startData = try JSONEncoder().encode(startBody)
        let (startStatus, responseBody) = try await httpClient.post(
            "/exec/\(execResponse.Id)/start",
            body: startData
        )

        // For non-2xx, throw
        if startStatus.code >= 300 {
            try httpClient.requireSuccess(status: startStatus, body: responseBody)
        }

        // Parse multiplexed stream output
        let (stdout, stderr): (String, String)
        if options.tty {
            // TTY mode: no multiplexing, raw output
            stdout = String(data: responseBody, encoding: .utf8) ?? ""
            stderr = ""
        } else {
            let result = DockerMultiplexedStream.demultiplex(from: responseBody)
            stdout = result.stdout
            stderr = result.stderr
        }

        // Get exit code from exec inspect
        let (inspectStatus, inspectBody) = try await httpClient.get("/exec/\(execResponse.Id)/json")
        let inspectResponse: ExecInspectResponse = try httpClient.decodeResponse(
            ExecInspectResponse.self,
            status: inspectStatus,
            body: inspectBody
        )

        return ExecResult(
            exitCode: inspectResponse.ExitCode,
            stdout: stdout,
            stderr: stderr
        )
    }

    // MARK: - Health Status

    public func healthStatus(id: String) async throws -> ContainerHealthStatus {
        guard httpClient != nil else {
            // CLI fallback
            let output = try await runDocker(["inspect", "--format", "{{json .State.Health}}", id])
            return try Self.parseHealthStatus(output.stdout)
        }

        let inspection = try await inspect(id: id)

        guard let health = inspection.state.health else {
            return ContainerHealthStatus(status: nil, hasHealthCheck: false)
        }

        let status = ContainerHealthStatus.Status(rawValue: health.status.rawValue)
        return ContainerHealthStatus(status: status, hasHealthCheck: true)
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

    // MARK: - Network Operations

    /// Create a Docker network with explicit primitive options.
    public func createNetwork(name: String, driver: String = "bridge", internal: Bool = false) async throws -> String {
        guard let httpClient else {
            var args = ["network", "create", "--driver", driver]
            if `internal` { args.append("--internal") }
            args.append(name)
            let output = try await runDocker(args)
            return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let request = CreateNetworkRequest(
            Name: name,
            Driver: driver,
            Internal: `internal`,
            EnableIPv6: false,
            Attachable: false,
            Labels: nil,
            Options: nil,
            IPAM: nil
        )
        let bodyData = try JSONEncoder().encode(request)
        let (status, responseData) = try await httpClient.post("/networks/create", body: bodyData)
        let response: CreateNetworkResponse = try httpClient.decodeResponse(
            CreateNetworkResponse.self,
            status: status,
            body: responseData
        )
        return response.Id
    }

    public func createNetwork(_ request: NetworkRequest) async throws -> (id: String, name: String) {
        let networkName = request.name ?? "tc-network-\(UUID().uuidString.prefix(8).lowercased())"

        guard let httpClient else {
            var args = ["network", "create", "--driver", request.driver.rawValue]
            if request.internal { args.append("--internal") }
            if request.enableIPv6 { args.append("--ipv6") }
            if request.attachable { args.append("--attachable") }
            for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
                args += ["--label", "\(key)=\(value)"]
            }
            for (key, value) in request.options.sorted(by: { $0.key < $1.key }) {
                args += ["--opt", "\(key)=\(value)"]
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
            args.append(networkName)
            let output = try await runDocker(args)
            let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return (id: id, name: networkName)
        }

        var ipamConfig: APIIPAMConfig?
        if let ipam = request.ipamConfig {
            ipamConfig = APIIPAMConfig(
                Config: [APIIPAMPoolConfig(
                    Subnet: ipam.subnet,
                    Gateway: ipam.gateway,
                    IPRange: ipam.ipRange
                )]
            )
        }

        let createRequest = CreateNetworkRequest(
            Name: networkName,
            Driver: request.driver.rawValue,
            Internal: request.internal,
            EnableIPv6: request.enableIPv6,
            Attachable: request.attachable,
            Labels: request.labels.isEmpty ? nil : request.labels,
            Options: request.options.isEmpty ? nil : request.options,
            IPAM: ipamConfig
        )
        let bodyData = try JSONEncoder().encode(createRequest)
        let (status, responseData) = try await httpClient.post("/networks/create", body: bodyData)
        let response: CreateNetworkResponse = try httpClient.decodeResponse(
            CreateNetworkResponse.self,
            status: status,
            body: responseData
        )

        return (id: response.Id, name: networkName)
    }

    public func removeNetwork(id: String) async throws {
        guard let httpClient else {
            _ = try await runDocker(["network", "rm", id])
            return
        }
        let (status, body) = try await httpClient.delete("/networks/\(id)")
        // 204 = removed, 404 = not found (both OK)
        guard status.code == 204 || status.code == 404 else {
            try httpClient.requireSuccess(status: status, body: body)
            return
        }
    }

    /// Connect a running container to a network.
    public func connectToNetwork(
        containerId: String,
        networkName: String,
        aliases: [String] = [],
        ipv4Address: String? = nil,
        ipv6Address: String? = nil
    ) async throws {
        guard let httpClient else {
            var args = ["network", "connect"]
            for alias in aliases { args += ["--alias", alias] }
            if let ip = ipv4Address { args += ["--ip", ip] }
            if let ip = ipv6Address { args += ["--ip6", ip] }
            args += [networkName, containerId]
            _ = try await runDocker(args)
            return
        }

        var ipamConfig: APIEndpointIPAMConfig?
        if ipv4Address != nil || ipv6Address != nil {
            ipamConfig = APIEndpointIPAMConfig(
                IPv4Address: ipv4Address,
                IPv6Address: ipv6Address
            )
        }

        let endpointConfig = APIEndpointConfig(
            Aliases: aliases.isEmpty ? nil : aliases,
            IPAMConfig: ipamConfig
        )

        let request = NetworkConnectRequest(
            Container: containerId,
            EndpointConfig: (aliases.isEmpty && ipamConfig == nil) ? nil : endpointConfig
        )
        let bodyData = try JSONEncoder().encode(request)
        let (status, body) = try await httpClient.post(
            "/networks/\(networkName)/connect",
            body: bodyData
        )
        try httpClient.requireSuccess(status: status, body: body)
    }

    public func networkExists(_ nameOrID: String) async throws -> Bool {
        guard let httpClient else {
            do {
                let output = try await runner.run(executable: dockerPath, arguments: ["network", "inspect", nameOrID])
                return output.exitCode == 0
            } catch {
                return false
            }
        }
        do {
            let (status, _) = try await httpClient.get("/networks/\(nameOrID)")
            return status.code == 200
        } catch {
            return false
        }
    }

    // MARK: - Volume Operations

    public func createVolume(name: String, config: VolumeConfig = VolumeConfig()) async throws -> String {
        guard let httpClient else {
            var args = ["volume", "create", "--driver", config.driver]
            for (key, value) in config.options.sorted(by: { $0.key < $1.key }) {
                args += ["--opt", "\(key)=\(value)"]
            }
            args.append(name)
            _ = try await runDocker(args)
            return name
        }
        let request = CreateVolumeRequest(
            Name: name,
            Driver: config.driver,
            DriverOpts: config.options.isEmpty ? nil : config.options
        )
        let bodyData = try JSONEncoder().encode(request)
        let (status, body) = try await httpClient.post("/volumes/create", body: bodyData)
        try httpClient.requireSuccess(status: status, body: body)
        return name
    }

    public func removeVolume(name: String) async throws {
        guard let httpClient else {
            _ = try await runDocker(["volume", "rm", "-f", name])
            return
        }
        let (status, body) = try await httpClient.delete(
            "/volumes/\(name)",
            queryItems: [("force", "true")]
        )
        // 204 = removed, 404 = not found (both OK for forced removal)
        guard status.code == 204 || status.code == 404 else {
            try httpClient.requireSuccess(status: status, body: body)
            return
        }
    }

    // MARK: - Copy Operations (stays on CLI via ProcessRunner)

    public func copyToContainer(id: String, sourcePath: String, destinationPath: String) async throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourcePath, isDirectory: &isDirectory) else {
            throw TestContainersError.invalidInput("Source path does not exist: \(sourcePath)")
        }

        let target = "\(id):\(destinationPath)"
        _ = try await runDocker(["cp", sourcePath, target])
    }

    public func copyDataToContainer(id: String, data: Data, destinationPath: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileName = "testcontainers-\(UUID().uuidString)"
        let tempFileURL = tempDir.appendingPathComponent(tempFileName)

        do {
            try data.write(to: tempFileURL)
            try await copyToContainer(id: id, sourcePath: tempFileURL.path, destinationPath: destinationPath)
            try FileManager.default.removeItem(at: tempFileURL)
        } catch {
            try? FileManager.default.removeItem(at: tempFileURL)
            throw error
        }
    }

    public func copyFromContainer(
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

    // MARK: - Log Streaming (stays on CLI for streaming support)

    public func streamLogs(id: String, options: LogStreamOptions) -> AsyncThrowingStream<LogEntry, Error> {
        var args = ["logs"]
        args.append(contentsOf: options.toDockerArgs())
        args.append(id)

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

    public func inspect(id: String) async throws -> ContainerInspection {
        guard let httpClient else {
            // CLI fallback
            let output = try await runDocker(["inspect", id])
            return try ContainerInspection.parse(from: output.stdout)
        }

        let (status, body) = try await httpClient.get("/containers/\(id)/json")

        guard (200..<300).contains(status.code) else {
            let message = String(data: body, encoding: .utf8) ?? "Unknown error"
            throw TestContainersError.apiError(statusCode: Int(status.code), message: message)
        }

        return try ContainerInspection.parseFromAPI(data: body)
    }

    // MARK: - Image Build Operations (stays on CLI via ProcessRunner)

    public func buildImage(_ config: ImageFromDockerfile, tag: String) async throws -> String {
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
    public func removeImage(_ tag: String) async throws {
        guard let httpClient else {
            _ = try? await runDocker(["rmi", "-f", tag])
            return
        }
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        let _ = try? await httpClient.delete(
            "/images/\(encodedTag)",
            queryItems: [("force", "true")]
        )
    }

    static func buildImageArgs(config: ImageFromDockerfile, tag: String) -> [String] {
        var args: [String] = ["build"]

        args += ["-t", tag]
        args += ["-f", config.dockerfilePath]

        for (key, value) in config.buildArgs.sorted(by: { $0.key < $1.key }) {
            args += ["--build-arg", "\(key)=\(value)"]
        }

        if let target = config.targetStage {
            args += ["--target", target]
        }

        if config.noCache {
            args.append("--no-cache")
        }

        if config.pullBaseImages {
            args.append("--pull")
        }

        args.append(config.buildContext)

        return args
    }

    // MARK: - Container List Operations

    public func listContainers(labels: [String: String] = [:]) async throws -> [ContainerListItem] {
        guard let httpClient else {
            // CLI fallback
            let args = Self.listContainersArgs(labels: labels)
            let output = try await runDocker(args)
            return try Self.parseContainerList(output.stdout)
        }

        var queryItems: [(String, String)] = [("all", "true")]

        // Build filters as JSON: {"label": ["key=value", ...]}
        if !labels.isEmpty {
            let labelFilters = labels
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
            let filters: [String: [String]] = ["label": labelFilters]
            if let filtersData = try? JSONEncoder().encode(filters),
               let filtersString = String(data: filtersData, encoding: .utf8) {
                queryItems.append(("filters", filtersString))
            }
        }

        let (status, body) = try await httpClient.get("/containers/json", queryItems: queryItems)
        try httpClient.requireSuccess(status: status, body: body)

        let apiItems = try JSONDecoder().decode([APIContainerListItem].self, from: body)
        return apiItems.map { ContainerListItem(fromAPI: $0) }
    }

    public func findReusableContainer(hash: String) async throws -> ContainerListItem? {
        let containers = try await listContainers(labels: [
            ReuseLabels.enabled: "true",
            ReuseLabels.hash: hash,
            ReuseLabels.version: ReuseLabels.versionValue,
        ])
        return Self.selectReusableContainer(from: containers)
    }

    static func selectReusableContainer(from containers: [ContainerListItem]) -> ContainerListItem? {
        containers
            .filter { $0.state == "running" }
            .max { lhs, rhs in lhs.created < rhs.created }
    }

    public func removeContainers(ids: [String], force: Bool = true) async -> [String: Error?] {
        var results: [String: Error?] = [:]

        await withTaskGroup(of: (String, Error?).self) { group in
            for id in ids {
                group.addTask {
                    do {
                        if let httpClient = self.httpClient {
                            var queryItems: [(String, String)] = []
                            if force {
                                queryItems.append(("force", "true"))
                            }
                            let (status, body) = try await httpClient.delete(
                                "/containers/\(id)",
                                queryItems: queryItems
                            )
                            if status.code != 204 && status.code != 404 {
                                try httpClient.requireSuccess(status: status, body: body)
                            }
                        } else {
                            var args = ["rm"]
                            if force { args.append("-f") }
                            args.append(id)
                            _ = try await self.runDocker(args)
                        }
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

    /// Build the docker ps command arguments (kept for test compatibility).
    static func listContainersArgs(labels: [String: String]) -> [String] {
        var args: [String] = ["ps", "-a", "--no-trunc", "--format", "{{json .}}"]

        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            args += ["--filter", "label=\(key)=\(value)"]
        }

        return args
    }

    /// Parse docker ps JSON output (kept for test compatibility).
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

    private static func formatDuration(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds >= 1.0 {
            return "\(Int(seconds))s"
        } else {
            return "\(Int(seconds * 1000))ms"
        }
    }

    // MARK: - CLI Argument Builders (for CLI fallback mode)

    /// Validate a ContainerRequest before execution.
    private static func validateRequest(_ request: ContainerRequest) throws {
        // Validate platform format
        if let platform = request.platform {
            let parts = platform.split(separator: "/")
            if parts.count < 2 {
                throw TestContainersError.invalidInput(
                    "Invalid platform '\(platform)'. Expected format: os/architecture (e.g., linux/amd64)"
                )
            }
        }

        // Validate extra hosts
        for extraHost in request.extraHosts {
            if !extraHost.isValid {
                throw TestContainersError.invalidInput(
                    "Invalid extra host: hostname and IP must not be empty"
                )
            }
        }
    }

    /// Connect additional networks to a container via CLI (for CLI fallback mode).
    private func connectAdditionalNetworksCLI(request: ContainerRequest, containerId: String) async throws {
        if request.networkMode == nil {
            for network in request.networks.dropFirst() {
                var args = ["network", "connect"]
                for alias in network.aliases {
                    args += ["--alias", alias]
                }
                if let ip = network.ipv4Address {
                    args += ["--ip", ip]
                }
                if let ip = network.ipv6Address {
                    args += ["--ip6", ip]
                }
                args += [network.networkName, containerId]
                _ = try await runDocker(args)
            }
        }
    }

    /// Build `docker run -d ...` CLI arguments from a ContainerRequest.
    static func buildContainerRunArgs(from request: ContainerRequest) -> [String] {
        var args = ["run", "-d"]
        args += buildContainerFlags(from: request)
        args.append(request.resolvedImage)
        if !request.command.isEmpty {
            args += request.command
        }
        return args
    }

    /// Build the common flags for container create/run CLI commands.
    static func buildContainerFlags(from request: ContainerRequest) -> [String] {
        var args: [String] = []

        if let platform = request.platform {
            args += ["--platform", platform]
        }

        // Auto-generate name if not provided and autoGenerateName is set
        if let name = request.name {
            args += ["--name", name]
        } else if request.autoGenerateName {
            let timestamp = Int(Date().timeIntervalSince1970)
            let randomSuffix = String(UUID().uuidString.prefix(8).lowercased())
            args += ["--name", "tc-swift-\(timestamp)-\(randomSuffix)"]
        }

        if let user = request.user {
            args += ["--user", user.dockerFlag]
        }

        for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
            args += ["-e", "\(key)=\(value)"]
        }

        for port in request.ports {
            args += ["-p", port.dockerFlag]
        }

        for label in request.labels.sorted(by: { $0.key < $1.key }) {
            args += ["--label", "\(label.key)=\(label.value)"]
        }

        for mount in request.bindMounts {
            args += ["-v", mount.dockerFlag]
        }

        for mount in request.volumes {
            args += ["-v", mount.dockerFlag]
        }

        for mount in request.tmpfsMounts {
            args += ["--tmpfs", mount.dockerFlag]
        }

        if request.privileged {
            args.append("--privileged")
        }

        for cap in request.capabilitiesToAdd.sorted(by: { $0.rawValue < $1.rawValue }) {
            args += ["--cap-add", cap.rawValue]
        }

        for cap in request.capabilitiesToDrop.sorted(by: { $0.rawValue < $1.rawValue }) {
            args += ["--cap-drop", cap.rawValue]
        }

        if let networkMode = request.networkMode {
            args += ["--network", networkMode.dockerFlag]
        } else if let firstNetwork = request.networks.first {
            args += ["--network", firstNetwork.networkName]
            for alias in firstNetwork.aliases {
                args += ["--network-alias", alias]
            }
            if let ip = firstNetwork.ipv4Address {
                args += ["--ip", ip]
            }
            if let ip = firstNetwork.ipv6Address {
                args += ["--ip6", ip]
            }
        }

        for extraHost in request.extraHosts.sorted(by: { $0.hostname < $1.hostname }) {
            args += ["--add-host", extraHost.dockerFlag]
        }

        if let entrypoint = request.entrypoint {
            args += ["--entrypoint", entrypoint.joined(separator: " ")]
        }

        if let workDir = request.workingDirectory {
            args += ["-w", workDir]
        }

        // Resource limits
        if let memory = request.resourceLimits.memory {
            args += ["--memory", memory]
        }

        if let memoryReservation = request.resourceLimits.memoryReservation {
            args += ["--memory-reservation", memoryReservation]
        }

        if let memorySwap = request.resourceLimits.memorySwap {
            args += ["--memory-swap", memorySwap]
        }

        if let cpus = request.resourceLimits.cpus {
            args += ["--cpus", cpus]
        }

        if let cpuShares = request.resourceLimits.cpuShares {
            args += ["--cpu-shares", "\(cpuShares)"]
        }

        if let cpuPeriod = request.resourceLimits.cpuPeriod {
            args += ["--cpu-period", "\(cpuPeriod)"]
        }

        if let cpuQuota = request.resourceLimits.cpuQuota {
            args += ["--cpu-quota", "\(cpuQuota)"]
        }

        return args
    }
}
