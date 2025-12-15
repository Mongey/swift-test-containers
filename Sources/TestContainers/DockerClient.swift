import Foundation

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

        args.append(request.image)
        args += request.command

        let output = try await runDocker(args)
        let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw TestContainersError.unexpectedDockerOutput(output.stdout) }
        return id
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
