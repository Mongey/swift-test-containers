import Foundation

public struct ContainerPort: Hashable, Sendable {
    public var containerPort: Int
    public var hostPort: Int?

    public init(containerPort: Int, hostPort: Int? = nil) {
        self.containerPort = containerPort
        self.hostPort = hostPort
    }

    var dockerFlag: String {
        if let hostPort {
            return "\(hostPort):\(containerPort)"
        }
        return "\(containerPort)"
    }
}

public indirect enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logMatches(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case http(HTTPWaitConfig)
    case exec([String], timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    /// Waits for Docker's built-in HEALTHCHECK to report "healthy" status.
    /// The container image must have a HEALTHCHECK instruction configured.
    case healthCheck(timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))

    /// Waits for all strategies to succeed. All conditions must pass.
    /// - Parameters:
    ///   - strategies: Array of wait strategies that must all succeed
    ///   - timeout: Optional composite timeout that overrides individual strategy timeouts
    case all([WaitStrategy], timeout: Duration? = nil)

    /// Waits for any strategy to succeed. First success wins.
    /// - Parameters:
    ///   - strategies: Array of wait strategies where any one succeeding is sufficient
    ///   - timeout: Optional composite timeout that overrides individual strategy timeouts
    case any([WaitStrategy], timeout: Duration? = nil)

    /// Returns the maximum timeout for this strategy (recursively for composites).
    public func maxTimeout() -> Duration {
        switch self {
        case .none:
            return .seconds(0)
        case let .tcpPort(_, timeout, _):
            return timeout
        case let .logContains(_, timeout, _):
            return timeout
        case let .logMatches(_, timeout, _):
            return timeout
        case let .http(config):
            return config.timeout
        case let .exec(_, timeout, _):
            return timeout
        case let .healthCheck(timeout, _):
            return timeout
        case let .all(strategies, compositeTimeout):
            if let compositeTimeout {
                return compositeTimeout
            }
            return strategies.map { $0.maxTimeout() }.max() ?? .seconds(0)
        case let .any(strategies, compositeTimeout):
            if let compositeTimeout {
                return compositeTimeout
            }
            return strategies.map { $0.maxTimeout() }.max() ?? .seconds(0)
        }
    }
}

public struct ContainerRequest: Sendable, Hashable {
    public var image: String
    public var name: String?
    public var command: [String]
    public var environment: [String: String]
    public var labels: [String: String]
    public var ports: [ContainerPort]
    public var waitStrategy: WaitStrategy
    public var host: String

    public init(image: String) {
        self.image = image
        self.name = nil
        self.command = []
        self.environment = [:]
        self.labels = ["testcontainers.swift": "true"]
        self.ports = []
        self.waitStrategy = .none
        self.host = "127.0.0.1"
    }

    public func withName(_ name: String) -> Self {
        var copy = self
        copy.name = name
        return copy
    }

    public func withCommand(_ command: [String]) -> Self {
        var copy = self
        copy.command = command
        return copy
    }

    public func withEnvironment(_ environment: [String: String]) -> Self {
        var copy = self
        for (k, v) in environment { copy.environment[k] = v }
        return copy
    }

    public func withLabel(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.labels[key] = value
        return copy
    }

    public func withExposedPort(_ containerPort: Int, hostPort: Int? = nil) -> Self {
        var copy = self
        copy.ports.append(ContainerPort(containerPort: containerPort, hostPort: hostPort))
        return copy
    }

    public func waitingFor(_ strategy: WaitStrategy) -> Self {
        var copy = self
        copy.waitStrategy = strategy
        return copy
    }

    public func withHost(_ host: String) -> Self {
        var copy = self
        copy.host = host
        return copy
    }
}

