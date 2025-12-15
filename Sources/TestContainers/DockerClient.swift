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
    private let runner = ProcessRunner()

    public init(dockerPath: String = "docker") {
        self.dockerPath = dockerPath
    }

    public func isAvailable() async -> Bool {
        do {
            let result = try await runner.run(executable: dockerPath, arguments: ["version", "--format", "{{.Server.Version}}"])
            return result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    func runDocker(_ args: [String]) async throws -> CommandOutput {
        let output = try await runner.run(executable: dockerPath, arguments: args)
        if output.exitCode != 0 {
            throw TestContainersError.commandFailed(command: [dockerPath] + args, exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
        }
        return output
    }

    func runContainer(_ request: ContainerRequest) async throws -> String {
        var args: [String] = ["run", "-d"]

        if let name = request.name {
            args += ["--name", name]
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

        args.append(request.image)
        args += request.command

        let output = try await runDocker(args)
        let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw TestContainersError.unexpectedDockerOutput(output.stdout) }
        return id
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
        _ = try await runDocker(["rm", "-f", id])
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
}
