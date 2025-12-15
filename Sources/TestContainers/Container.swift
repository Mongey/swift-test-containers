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

    func waitUntilReady() async throws {
        switch request.waitStrategy {
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
        case .all, .any:
            // TODO: Composite wait strategies not yet implemented (feature 005)
            fatalError("Composite wait strategies (.all, .any) are not yet implemented")
        }
    }
}

