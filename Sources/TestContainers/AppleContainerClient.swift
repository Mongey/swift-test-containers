import Foundation

/// Container runtime client for Apple's `container` CLI.
///
/// Apple's `container` CLI runs Linux containers as lightweight VMs on Apple Silicon Macs (macOS 26+).
/// This client translates the `ContainerRuntime` protocol operations into `container` CLI commands.
///
/// Some operations that are not supported by the Apple container CLI will throw
/// `TestContainersError.unsupportedByRuntime`.
public struct AppleContainerClient: ContainerRuntime, Sendable {
    private let containerPath: String
    private let runner: ProcessRunner
    private let logger: TCLogger

    /// Create an AppleContainerClient.
    ///
    /// - Parameters:
    ///   - containerPath: Path to the `container` CLI binary (default: "container")
    ///   - logger: Logger for diagnostic output
    public init(containerPath: String = "container", logger: TCLogger = .null) {
        self.containerPath = containerPath
        self.runner = ProcessRunner(logger: logger)
        self.logger = logger
    }

    /// Create a CLI-only AppleContainerClient (for tests with mock scripts).
    public init(containerPath: String, logger: TCLogger = .null, forTesting: Bool) {
        self.containerPath = containerPath
        self.runner = ProcessRunner(logger: logger)
        self.logger = logger
    }

    // MARK: - Internal helpers

    private func runCmd(_ args: [String], environment: [String: String] = [:]) async throws -> CommandOutput {
        let output = try await runner.run(executable: containerPath, arguments: args, environment: environment)
        if output.exitCode != 0 {
            throw TestContainersError.commandFailed(
                command: [containerPath] + args,
                exitCode: output.exitCode,
                stdout: output.stdout,
                stderr: output.stderr
            )
        }
        return output
    }

    // MARK: - Availability

    public func isAvailable() async -> Bool {
        do {
            let output = try await runner.run(executable: containerPath, arguments: ["system", "version", "--format", "json"])
            return output.exitCode == 0
        } catch {
            return false
        }
    }

    // MARK: - Registry

    public func authenticateRegistry(_ auth: RegistryAuth, environment: inout [String: String]) async throws {
        switch auth {
        case .credentials:
            break
        case let .configFile(path):
            environment["DOCKER_CONFIG"] = path
        case .systemDefault:
            break
        }
    }

    // MARK: - Images

    public func imageExists(_ image: String, platform: String? = nil) async -> Bool {
        do {
            let output = try await runner.run(executable: containerPath, arguments: ["image", "inspect", image])
            return output.exitCode == 0
        } catch {
            return false
        }
    }

    public func pullImage(_ image: String, platform: String? = nil, environment: [String: String] = [:], registryAuth: RegistryAuth? = nil) async throws {
        var args = ["image", "pull"]
        if let platform {
            args += ["--platform", platform]
        }
        args.append(image)
        let output = try await runner.run(executable: containerPath, arguments: args, environment: environment)
        if output.exitCode != 0 {
            throw TestContainersError.imagePullFailed(
                image: image, exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr
            )
        }
    }

    public func inspectImage(_ image: String, platform: String? = nil) async throws -> ImageInspection {
        var args = ["image", "inspect"]
        if let platform {
            args += ["--platform", platform]
        }
        args.append(image)
        let output = try await runCmd(args)
        return try ImageInspection.parse(from: output.stdout)
    }

    public func buildImage(_ config: ImageFromDockerfile, tag: String) async throws -> String {
        let args = Self.buildImageArgs(config, tag: tag)
        let output = try await runner.run(executable: containerPath, arguments: args)
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

    public func removeImage(_ tag: String) async throws {
        _ = try await runCmd(["image", "delete", tag])
    }

    // MARK: - Container Lifecycle

    public func runContainer(_ request: ContainerRequest) async throws -> String {
        let args = Self.buildContainerRunArgs(request)
        let output = try await runCmd(args)
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func createContainer(_ request: ContainerRequest) async throws -> String {
        let args = Self.buildContainerCreateArgs(request)
        let output = try await runCmd(args)
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func startContainer(id: String) async throws {
        _ = try await runCmd(["start", id])
    }

    public func stopContainer(id: String, timeout: Duration) async throws {
        let seconds = Int(timeout.components.seconds)
        _ = try await runCmd(["stop", "--time", "\(seconds)", id])
    }

    public func removeContainer(id: String) async throws {
        _ = try await runCmd(["delete", "--force", id])
    }

    public func removeContainers(ids: [String], force: Bool = true) async -> [String: Error?] {
        var results: [String: Error?] = [:]
        for id in ids {
            do {
                var args = ["delete"]
                if force { args.append("--force") }
                args.append(id)
                _ = try await runCmd(args)
                results[id] = nil as Error?
            } catch {
                results[id] = error
            }
        }
        return results
    }

    // MARK: - Container Info

    public func logs(id: String) async throws -> String {
        let output = try await runCmd(["logs", id])
        return output.stdout
    }

    public func logsTail(id: String, lines: Int) async throws -> String {
        let output = try await runCmd(["logs", "-n", "\(lines)", id])
        return output.stdout
    }

    public func streamLogs(id: String, options: LogStreamOptions) -> AsyncThrowingStream<LogEntry, Error> {
        var args = ["logs"]

        if options.follow {
            args.append("-f")
        }

        if options.timestamps {
            args.append("--timestamps")
        }

        if let tail = options.tail {
            args += ["-n", "\(tail)"]
        }

        args.append(id)

        let hasTimestamps = options.timestamps
        let stream = runner.streamLines(executable: containerPath, arguments: args)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in stream {
                        continuation.yield(LogEntry.parse(line: line, hasTimestamps: hasTimestamps))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func port(id: String, containerPort: Int) async throws -> Int {
        // Apple container CLI doesn't have a direct `port` command.
        // Parse port mappings from `container inspect` JSON output.
        let inspection = try await inspect(id: id)

        if let binding = inspection.networkSettings.ports.first(where: { $0.containerPort == containerPort }),
           let hostPort = binding.hostPort {
            return hostPort
        }

        throw TestContainersError.unexpectedDockerOutput(
            "No host port mapping found for container port \(containerPort)"
        )
    }

    public func inspect(id: String) async throws -> ContainerInspection {
        let output = try await runCmd(["inspect", id])
        return try Self.parseAppleInspect(output.stdout)
    }

    public func healthStatus(id: String) async throws -> ContainerHealthStatus {
        let inspection = try await inspect(id: id)
        if let health = inspection.state.health {
            let status = ContainerHealthStatus.Status(rawValue: health.status.rawValue)
            return ContainerHealthStatus(status: status, hasHealthCheck: true)
        }
        return ContainerHealthStatus(status: nil, hasHealthCheck: false)
    }

    // MARK: - Exec

    public func exec(id: String, command: [String]) async throws -> Int32 {
        let args = ["exec", id] + command
        let output = try await runner.run(executable: containerPath, arguments: args)
        return output.exitCode
    }

    public func exec(id: String, command: [String], options: ExecOptions) async throws -> ExecResult {
        let args = Self.buildExecArgs(id: id, command: command, options: options)
        let output = try await runner.run(executable: containerPath, arguments: args)
        return ExecResult(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
    }

    // MARK: - Copy

    public func copyToContainer(id: String, sourcePath: String, destinationPath: String) async throws {
        // Apple container CLI may not have a direct `cp` command.
        // Emulate file copy with `cat > <dest>` and directory copy with tar extraction.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDirectory)
        guard exists else {
            throw TestContainersError.invalidInput("Source path does not exist: \(sourcePath)")
        }

        if isDirectory.boolValue {
            let quotedDest = Self.shellQuote(destinationPath)
            let tarArgs = ["exec", id, "sh", "-c", "tar xf - -C \(quotedDest)"]
            let tarData = try Self.createTarData(sourcePath: sourcePath)
            let output = try await runner.run(
                executable: containerPath,
                arguments: tarArgs,
                stdinData: tarData
            )
            if output.exitCode != 0 {
                throw TestContainersError.unsupportedByRuntime(
                    "Directory copy to container failed. The Apple container runtime may not support this operation."
                )
            }
            return
        }

        let fileData = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        let quotedDest = Self.shellQuote(destinationPath)
        let fileArgs = ["exec", id, "sh", "-c", "cat > \(quotedDest)"]
        let output = try await runner.run(
            executable: containerPath,
            arguments: fileArgs,
            stdinData: fileData
        )
        if output.exitCode != 0 {
            throw TestContainersError.unsupportedByRuntime(
                "File copy to container failed. The Apple container runtime may not support this operation."
            )
        }
    }

    public func copyDataToContainer(id: String, data: Data, destinationPath: String) async throws {
        // Write data to temp file, then copy
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("testcontainers-\(UUID().uuidString)")
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        try await copyToContainer(id: id, sourcePath: tempFile.path, destinationPath: destinationPath)
    }

    public func copyFromContainer(id: String, containerPath: String, hostPath: String, archive: Bool) async throws {
        // Attempt file copy via binary-safe `cat` output.
        // Directory copy is currently unsupported.
        let quotedPath = Self.shellQuote(containerPath)
        let isDirectoryArgs = ["exec", id, "sh", "-c", "[ -d \(quotedPath) ]"]
        let isDirectoryResult = try await runner.run(executable: self.containerPath, arguments: isDirectoryArgs)
        if isDirectoryResult.exitCode == 0 {
            throw TestContainersError.unsupportedByRuntime(
                "Directory copy from container is not currently supported by the Apple container runtime."
            )
        }

        let catArgs = ["exec", id, "sh", "-c", "cat -- \(quotedPath)"]
        let output = try Self.runBinaryProcess(
            executable: self.containerPath,
            arguments: catArgs
        )
        if output.exitCode != 0 {
            throw TestContainersError.commandFailed(
                command: [self.containerPath] + catArgs,
                exitCode: output.exitCode,
                stdout: "",
                stderr: String(data: output.stderr, encoding: .utf8) ?? ""
            )
        }

        // NOTE: `archive` flag is currently ignored for file copy emulation.
        _ = archive

        try output.stdout.write(to: URL(fileURLWithPath: hostPath))
    }

    // MARK: - Networks

    public func createNetwork(name: String, driver: String = "bridge", internal: Bool = false) async throws -> String {
        var args = ["network", "create"]
        if driver != "bridge" {
            args += ["--driver", driver]
        }
        if `internal` {
            args += ["--internal"]
        }
        args.append(name)
        let output = try await runCmd(args)
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func createNetwork(_ request: NetworkRequest) async throws -> (id: String, name: String) {
        let name = request.name ?? "tc-\(UUID().uuidString.prefix(8).lowercased())"
        var args = ["network", "create"]
        if request.driver != .bridge {
            args += ["--driver", request.driver.rawValue]
        }
        if request.internal {
            args += ["--internal"]
        }
        for (key, value) in request.labels {
            args += ["--label", "\(key)=\(value)"]
        }
        args.append(name)
        let output = try await runCmd(args)
        let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id: id.isEmpty ? name : id, name: name)
    }

    public func removeNetwork(id: String) async throws {
        _ = try await runCmd(["network", "delete", id])
    }

    public func connectToNetwork(containerId: String, networkName: String, aliases: [String] = [], ipv4Address: String? = nil, ipv6Address: String? = nil) async throws {
        throw TestContainersError.unsupportedByRuntime(
            "Network connect after container creation is not supported by the Apple container runtime. " +
            "Attach networks at container creation time instead."
        )
    }

    public func networkExists(_ nameOrID: String) async throws -> Bool {
        do {
            let output = try await runner.run(executable: containerPath, arguments: ["network", "inspect", nameOrID])
            return output.exitCode == 0
        } catch {
            return false
        }
    }

    // MARK: - Volumes

    public func createVolume(name: String, config: VolumeConfig = VolumeConfig()) async throws -> String {
        var args = ["volume", "create"]
        if config.driver != "local" {
            args += ["--driver", config.driver]
        }
        for (key, value) in config.options {
            args += ["--opt", "\(key)=\(value)"]
        }
        args.append(name)
        let output = try await runCmd(args)
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func removeVolume(name: String) async throws {
        _ = try await runCmd(["volume", "delete", name])
    }

    // MARK: - Listing

    public func listContainers(labels: [String: String] = [:]) async throws -> [ContainerListItem] {
        let args = ["list", "-a", "--format", "json"]
        let output = try await runCmd(args)

        let allContainers = try Self.parseAppleContainerList(output.stdout)

        // Client-side label filtering
        if labels.isEmpty {
            return allContainers
        }

        return allContainers.filter { container in
            let containerLabels = container.parsedLabels
            return labels.allSatisfy { key, value in
                containerLabels[key] == value
            }
        }
    }

    public func findReusableContainer(hash: String) async throws -> ContainerListItem? {
        let containers = try await listContainers(labels: [
            "testcontainers.swift.reuse": "true",
            "testcontainers.swift.reuse.hash": hash,
        ])
        return containers.first { $0.state.lowercased() == "running" }
    }

    // MARK: - Argument Building

    static func buildContainerRunArgs(_ request: ContainerRequest) -> [String] {
        var args = ["run", "-d"]
        args += buildContainerFlags(request)
        args.append(request.image)
        if !request.command.isEmpty {
            args += request.command
        }
        return args
    }

    static func buildContainerCreateArgs(_ request: ContainerRequest) -> [String] {
        var args = ["create"]
        args += buildContainerFlags(request)
        args.append(request.image)
        if !request.command.isEmpty {
            args += request.command
        }
        return args
    }

    static func buildContainerFlags(_ request: ContainerRequest) -> [String] {
        var args: [String] = []

        if let name = request.name {
            args += ["--name", name]
        }

        if let entrypoint = request.entrypoint {
            args += ["--entrypoint", entrypoint.joined(separator: " ")]
        }

        for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
            args += ["-e", "\(key)=\(value)"]
        }

        for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
            args += ["--label", "\(key)=\(value)"]
        }

        for port in request.ports {
            if let hostPort = port.hostPort {
                args += ["-p", "\(hostPort):\(port.containerPort)"]
            } else {
                args += ["-p", "\(port.containerPort)"]
            }
        }

        for host in request.extraHosts {
            args += ["--add-host", "\(host.hostname):\(host.ip)"]
        }

        for mount in request.bindMounts {
            var mountStr = "\(mount.hostPath):\(mount.containerPath)"
            if mount.readOnly {
                mountStr += ":ro"
            }
            args += ["-v", mountStr]
        }

        for mount in request.volumes {
            var mountStr = "\(mount.volumeName):\(mount.containerPath)"
            if mount.readOnly {
                mountStr += ":ro"
            }
            args += ["-v", mountStr]
        }

        for mount in request.tmpfsMounts {
            var mountStr = mount.containerPath
            if let sizeLimit = mount.sizeLimit {
                mountStr += ":size=\(sizeLimit)"
            }
            args += ["--tmpfs", mountStr]
        }

        if let workDir = request.workingDirectory {
            args += ["-w", workDir]
        }

        if let user = request.user {
            args += ["-u", user.dockerFlag]
        }

        if request.privileged {
            args += ["--privileged"]
        }

        for cap in request.capabilitiesToAdd.sorted(by: { $0.rawValue < $1.rawValue }) {
            args += ["--cap-add", cap.rawValue]
        }

        for cap in request.capabilitiesToDrop.sorted(by: { $0.rawValue < $1.rawValue }) {
            args += ["--cap-drop", cap.rawValue]
        }

        if let platform = request.platform {
            args += ["--platform", platform]
        }

        if let networkMode = request.networkMode {
            args += ["--network", networkMode.dockerFlag]
        } else if let firstNetwork = request.networks.first {
            args += ["--network", firstNetwork.networkName]
            for alias in firstNetwork.aliases {
                args += ["--network-alias", alias]
            }
        }

        if let healthCheck = request.healthCheck {
            args += ["--health-cmd", healthCheck.command.joined(separator: " ")]
            if let interval = healthCheck.interval {
                args += ["--health-interval", Self.formatDuration(interval)]
            }
            if let timeout = healthCheck.timeout {
                args += ["--health-timeout", Self.formatDuration(timeout)]
            }
            if let retries = healthCheck.retries {
                args += ["--health-retries", "\(retries)"]
            }
            if let startPeriod = healthCheck.startPeriod {
                args += ["--health-start-period", Self.formatDuration(startPeriod)]
            }
        }

        if let memory = request.resourceLimits.memory {
            args += ["-m", memory]
        }
        if let cpus = request.resourceLimits.cpus {
            args += ["--cpus", cpus]
        }

        return args
    }

    static func buildExecArgs(id: String, command: [String], options: ExecOptions) -> [String] {
        var args = ["exec"]

        if let user = options.user {
            args += ["-u", user]
        }

        if let workDir = options.workingDirectory {
            args += ["-w", workDir]
        }

        for (key, value) in options.environment.sorted(by: { $0.key < $1.key }) {
            args += ["-e", "\(key)=\(value)"]
        }

        if options.tty {
            args += ["-t"]
        }

        if options.interactive {
            args += ["-i"]
        }

        if options.detached {
            args += ["-d"]
        }

        args.append(id)
        args += command

        return args
    }

    static func buildImageArgs(_ config: ImageFromDockerfile, tag: String) -> [String] {
        var args = ["build", "-t", tag]
        args += ["-f", config.dockerfilePath]
        for (key, value) in config.buildArgs.sorted(by: { $0.key < $1.key }) {
            args += ["--build-arg", "\(key)=\(value)"]
        }
        args.append(config.buildContext)
        return args
    }

    // MARK: - Apple Container JSON Parsing

    /// Parse Apple container `inspect` JSON into a `ContainerInspection`.
    ///
    /// The Apple `container inspect` JSON format is completely different from Docker's.
    /// This method translates from Apple's format to our internal `ContainerInspection` type.
    static func parseAppleInspect(_ json: String) throws -> ContainerInspection {
        guard let data = json.data(using: .utf8) else {
            throw TestContainersError.unexpectedDockerOutput("Invalid UTF-8 in JSON")
        }

        let items = try JSONDecoder().decode([AppleInspectItem].self, from: data)
        guard let item = items.first else {
            throw TestContainersError.unexpectedDockerOutput("container inspect returned empty array")
        }

        return item.toContainerInspection()
    }

    /// Parse Apple container `list --format json` output into `[ContainerListItem]`.
    static func parseAppleContainerList(_ output: String) throws -> [ContainerListItem] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let data = trimmed.data(using: .utf8) else {
            throw TestContainersError.unexpectedDockerOutput("Failed to parse container list output as UTF-8")
        }

        let items = try JSONDecoder().decode([AppleInspectItem].self, from: data)
        return items.map { $0.toContainerListItem() }
    }

    // Keep the old Docker-format parser for unit tests
    static func parseContainerList(_ output: String) throws -> [ContainerListItem] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let data = trimmed.data(using: .utf8) else {
            throw TestContainersError.unexpectedDockerOutput("Failed to parse container list output as UTF-8")
        }

        let decoder = JSONDecoder()
        if let items = try? decoder.decode([ContainerListItem].self, from: data) {
            return items
        }
        return try trimmed.split(separator: "\n").compactMap { line in
            guard let lineData = String(line).data(using: .utf8) else { return nil }
            return try decoder.decode(ContainerListItem.self, from: lineData)
        }
    }

    // MARK: - Utility

    static func formatDuration(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return "\(seconds)s"
    }

    static func shellEscape(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    static func shellQuote(_ value: String) -> String {
        "'\(shellEscape(value))'"
    }

    private static func createTarData(sourcePath: String) throws -> Data {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["cf", "-", "-C", URL(fileURLWithPath: sourcePath).deletingLastPathComponent().path, URL(fileURLWithPath: sourcePath).lastPathComponent]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            throw TestContainersError.commandFailed(
                command: ["/usr/bin/tar"] + (process.arguments ?? []),
                exitCode: process.terminationStatus,
                stdout: String(data: stdout, encoding: .utf8) ?? "",
                stderr: String(data: stderr, encoding: .utf8) ?? ""
            )
        }

        return stdout
    }

    private static func runBinaryProcess(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        stdinData: Data? = nil
    ) throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        if let stdinData {
            stdinPipe.fileHandleForWriting.write(stdinData)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return (stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }
}

// MARK: - Apple Container JSON Types

/// Represents a single item from Apple's `container inspect` or `container list --format json` output.
struct AppleInspectItem: Decodable {
    let configuration: AppleConfiguration
    let status: String
    let startedDate: Double?
    let networks: [AppleNetworkStatus]?

    struct AppleConfiguration: Decodable {
        let id: String
        let image: AppleImage
        let initProcess: AppleInitProcess?
        let publishedPorts: [ApplePublishedPort]
        let labels: [String: String]
        let networks: [AppleConfigNetwork]?
        let mounts: [AppleMount]?
        let platform: ApplePlatform?
        let resources: AppleResources?
    }

    struct AppleImage: Decodable {
        let reference: String
        let descriptor: AppleDescriptor?
    }

    struct AppleDescriptor: Decodable {
        let digest: String?
        let size: Int?
        let mediaType: String?
    }

    struct AppleInitProcess: Decodable {
        let executable: String
        let arguments: [String]?
        let environment: [String]?
        let workingDirectory: String?
        let user: AppleUser?
    }

    struct AppleUser: Decodable {
        let id: AppleUserID?
    }

    struct AppleUserID: Decodable {
        let uid: Int
        let gid: Int
    }

    struct ApplePublishedPort: Decodable {
        let containerPort: Int
        let hostPort: Int
        let proto: String?
        let hostAddress: String?
        let count: Int?
    }

    struct AppleConfigNetwork: Decodable {
        let network: String
        let options: AppleNetworkOptions?
    }

    struct AppleNetworkOptions: Decodable {
        let hostname: String?
    }

    struct AppleMount: Decodable {
        // Apple container mount format - details TBD
    }

    struct ApplePlatform: Decodable {
        let os: String?
        let architecture: String?
    }

    struct AppleResources: Decodable {
        let cpus: Int?
        let memoryInBytes: Int?
    }

    func toContainerInspection() -> ContainerInspection {
        let id = configuration.id
        let startDate: Date? = startedDate.map { Date(timeIntervalSinceReferenceDate: $0) }

        // Map status string to ContainerState.Status
        let stateStatus: ContainerState.Status
        switch status.lowercased() {
        case "running": stateStatus = .running
        case "stopped", "exited": stateStatus = .exited
        case "created": stateStatus = .created
        case "paused": stateStatus = .paused
        default: stateStatus = .exited
        }

        let state = ContainerState(
            status: stateStatus,
            running: stateStatus == .running,
            paused: stateStatus == .paused,
            restarting: false,
            oomKilled: false,
            dead: false,
            pid: 0,
            exitCode: 0,
            error: "",
            startedAt: startDate,
            finishedAt: nil,
            health: nil
        )

        // Build hostname from network config or id
        let hostname = configuration.networks?.first?.options?.hostname ?? id

        // Build user string
        let userStr: String
        if let user = configuration.initProcess?.user?.id {
            userStr = "\(user.uid):\(user.gid)"
        } else {
            userStr = ""
        }

        // Build command from executable + arguments
        var cmd: [String] = []
        if let initProcess = configuration.initProcess {
            cmd = initProcess.arguments ?? []
        }

        // Build entrypoint
        let entrypoint: [String]
        if let exec = configuration.initProcess?.executable {
            entrypoint = [exec]
        } else {
            entrypoint = []
        }

        let config = ContainerConfig(
            hostname: hostname,
            user: userStr,
            env: configuration.initProcess?.environment ?? [],
            cmd: cmd,
            image: configuration.image.reference,
            workingDir: configuration.initProcess?.workingDirectory ?? "/",
            entrypoint: entrypoint,
            labels: configuration.labels
        )

        // Build port bindings
        let portBindings = configuration.publishedPorts.map { port in
            PortBinding(
                containerPort: port.containerPort,
                protocol: port.proto ?? "tcp",
                hostIP: port.hostAddress,
                hostPort: port.hostPort
            )
        }

        // Build network attachments from runtime network info
        var networkAttachments: [String: NetworkAttachment] = [:]
        if let runtimeNetworks = networks {
            for net in runtimeNetworks {
                let ipAddr = net.ipv4Address?.components(separatedBy: "/").first ?? ""
                networkAttachments[net.network] = NetworkAttachment(
                    networkID: net.network,
                    endpointID: "",
                    gateway: net.ipv4Gateway ?? "",
                    ipAddress: ipAddr,
                    ipPrefixLen: 0,
                    macAddress: net.macAddress ?? "",
                    aliases: []
                )
            }
        }

        let primaryIP = networks?.first.flatMap { $0.ipv4Address?.components(separatedBy: "/").first } ?? ""
        let primaryGateway = networks?.first?.ipv4Gateway ?? ""
        let primaryMac = networks?.first?.macAddress ?? ""

        let networkSettings = NetworkSettings(
            bridge: "",
            sandboxID: "",
            ports: portBindings,
            ipAddress: primaryIP,
            gateway: primaryGateway,
            macAddress: primaryMac,
            networks: networkAttachments
        )

        return ContainerInspection(
            id: id,
            created: startDate ?? Date(),
            name: hostname,
            state: state,
            config: config,
            networkSettings: networkSettings
        )
    }

    func toContainerListItem() -> ContainerListItem {
        let labelsStr = configuration.labels
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")

        let created: Int
        if let startedDate {
            created = Int(Date(timeIntervalSinceReferenceDate: startedDate).timeIntervalSince1970)
        } else {
            created = 0
        }

        return ContainerListItem(
            id: configuration.id,
            names: configuration.id,
            image: configuration.image.reference,
            created: created,
            labels: labelsStr,
            state: status
        )
    }
}

struct AppleNetworkStatus: Decodable {
    let network: String
    let ipv4Address: String?
    let ipv4Gateway: String?
    let ipv6Address: String?
    let macAddress: String?
    let hostname: String?
}
