import Foundation

/// Represents bind mount consistency mode for cross-platform performance tuning.
/// On macOS with Docker Desktop, these modes affect file synchronization performance.
/// On Linux, these modes are ignored (native filesystem, no virtualization layer).
public enum BindMountConsistency: String, Sendable, Hashable {
    /// No explicit consistency mode (uses Docker default).
    case `default` = ""
    /// Host is authoritative - fastest for read-heavy workloads (config files).
    case cached = "cached"
    /// Container is authoritative - fastest for write-heavy workloads (build artifacts, logs).
    case delegated = "delegated"
    /// Perfect consistency - slowest, rarely needed.
    case consistent = "consistent"
}

/// Represents a bind mount from a host path to a container path.
/// Bind mounts allow you to mount a host file or directory into a container.
public struct BindMount: Sendable, Hashable {
    /// Absolute path on the host filesystem.
    public var hostPath: String
    /// Absolute path inside the container where the mount will be accessible.
    public var containerPath: String
    /// Whether the mount is read-only (container cannot modify the mounted path).
    public var readOnly: Bool
    /// Performance tuning for macOS (ignored on Linux).
    public var consistency: BindMountConsistency

    public init(
        hostPath: String,
        containerPath: String,
        readOnly: Bool = false,
        consistency: BindMountConsistency = .default
    ) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.readOnly = readOnly
        self.consistency = consistency
    }

    /// Generates Docker CLI flag for this bind mount.
    /// Examples:
    ///   - `/host/path:/container/path`
    ///   - `/host/path:/container/path:ro`
    ///   - `/host/path:/container/path:cached`
    ///   - `/host/path:/container/path:ro,delegated`
    var dockerFlag: String {
        var options: [String] = []

        if readOnly {
            options.append("ro")
        }

        if consistency != .default {
            options.append(consistency.rawValue)
        }

        if options.isEmpty {
            return "\(hostPath):\(containerPath)"
        }
        return "\(hostPath):\(containerPath):\(options.joined(separator: ","))"
    }
}

/// Represents a named volume mount configuration for Docker containers.
public struct VolumeMount: Hashable, Sendable {
    /// The name of the Docker volume.
    public var volumeName: String
    /// The absolute path inside the container where the volume is mounted.
    public var containerPath: String
    /// Whether the volume is mounted as read-only.
    public var readOnly: Bool

    public init(volumeName: String, containerPath: String, readOnly: Bool = false) {
        self.volumeName = volumeName
        self.containerPath = containerPath
        self.readOnly = readOnly
    }

    /// Converts to Docker CLI flag format: "volumeName:containerPath" or "volumeName:containerPath:ro"
    var dockerFlag: String {
        if readOnly {
            return "\(volumeName):\(containerPath):ro"
        }
        return "\(volumeName):\(containerPath)"
    }
}

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

/// Configuration for Docker's runtime health check (--health-cmd).
public struct HealthCheckConfig: Sendable, Hashable {
    /// The command to run for health checking.
    public var command: [String]
    /// Time between running the check.
    public var interval: Duration?
    /// Maximum time to wait for a check to complete.
    public var timeout: Duration?
    /// Start period for the container to initialize.
    public var startPeriod: Duration?
    /// Number of consecutive failures needed to report unhealthy.
    public var retries: Int?

    public init(
        command: [String],
        interval: Duration? = nil,
        timeout: Duration? = nil,
        startPeriod: Duration? = nil,
        retries: Int? = nil
    ) {
        self.command = command
        self.interval = interval
        self.timeout = timeout
        self.startPeriod = startPeriod
        self.retries = retries
    }
}

public struct ContainerRequest: Sendable, Hashable {
    public var image: String
    public var name: String?
    public var command: [String]
    public var entrypoint: [String]?
    public var environment: [String: String]
    public var labels: [String: String]
    public var ports: [ContainerPort]
    public var volumes: [VolumeMount]
    public var bindMounts: [BindMount]
    public var waitStrategy: WaitStrategy
    public var host: String
    public var healthCheck: HealthCheckConfig?
    public var retryPolicy: RetryPolicy?

    public init(image: String) {
        self.image = image
        self.name = nil
        self.command = []
        self.entrypoint = nil
        self.environment = [:]
        self.labels = ["testcontainers.swift": "true"]
        self.ports = []
        self.volumes = []
        self.bindMounts = []
        self.waitStrategy = .none
        self.host = "127.0.0.1"
        self.healthCheck = nil
        self.retryPolicy = nil
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

    /// Sets a custom entrypoint for the container, overriding the image's default ENTRYPOINT.
    ///
    /// The entrypoint specifies the executable that runs when the container starts.
    /// When combined with `withCommand()`, the command arguments are passed to the entrypoint.
    ///
    /// - Parameter entrypoint: Array of strings representing the entrypoint command and its arguments.
    ///   Pass an empty array `[]` to disable the default entrypoint.
    ///   Pass `nil` to use the image's default entrypoint (this is also the default).
    /// - Returns: Updated ContainerRequest with the entrypoint configured.
    ///
    /// Example:
    /// ```swift
    /// // Override entrypoint with custom shell
    /// let request = ContainerRequest(image: "alpine:3")
    ///     .withEntrypoint(["/bin/sh", "-c"])
    ///     .withCommand(["echo hello && sleep 10"])
    ///
    /// // Disable entrypoint entirely
    /// let request = ContainerRequest(image: "my-image")
    ///     .withEntrypoint([])
    ///     .withCommand(["/custom-binary", "--flag"])
    /// ```
    public func withEntrypoint(_ entrypoint: [String]) -> Self {
        var copy = self
        copy.entrypoint = entrypoint
        return copy
    }

    /// Sets a single-command entrypoint for the container.
    ///
    /// Convenience method for setting an entrypoint with a single executable.
    /// For entrypoints with arguments, use `withEntrypoint([String])`.
    ///
    /// - Parameter entrypoint: The entrypoint executable path.
    /// - Returns: Updated ContainerRequest with the entrypoint configured.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "alpine:3")
    ///     .withEntrypoint("/bin/bash")
    ///     .withCommand(["-c", "echo hello"])
    /// ```
    public func withEntrypoint(_ entrypoint: String) -> Self {
        withEntrypoint([entrypoint])
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

    /// Mounts a named Docker volume into the container.
    /// - Parameters:
    ///   - volumeName: Docker volume name (must already exist or will be created)
    ///   - containerPath: Absolute path inside container where the volume is mounted
    ///   - readOnly: Whether to mount as read-only (default: false)
    /// - Returns: Updated ContainerRequest
    public func withVolume(_ volumeName: String, mountedAt containerPath: String, readOnly: Bool = false) -> Self {
        var copy = self
        copy.volumes.append(VolumeMount(volumeName: volumeName, containerPath: containerPath, readOnly: readOnly))
        return copy
    }

    /// Mounts a volume using a VolumeMount configuration.
    /// - Parameter mount: The VolumeMount configuration to add
    /// - Returns: Updated ContainerRequest
    public func withVolumeMount(_ mount: VolumeMount) -> Self {
        var copy = self
        copy.volumes.append(mount)
        return copy
    }

    /// Adds a bind mount from host path to container path.
    ///
    /// - Parameters:
    ///   - hostPath: Absolute path on the host filesystem (must exist)
    ///   - containerPath: Absolute path in the container filesystem
    ///   - readOnly: If true, container cannot modify the mounted path (default: false)
    ///   - consistency: Performance tuning for macOS (default: .default)
    /// - Returns: Updated ContainerRequest with the bind mount added
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "nginx:alpine")
    ///     .withBindMount(
    ///         hostPath: "/Users/dev/config/nginx.conf",
    ///         containerPath: "/etc/nginx/nginx.conf",
    ///         readOnly: true
    ///     )
    /// ```
    public func withBindMount(
        hostPath: String,
        containerPath: String,
        readOnly: Bool = false,
        consistency: BindMountConsistency = .default
    ) -> Self {
        var copy = self
        copy.bindMounts.append(BindMount(
            hostPath: hostPath,
            containerPath: containerPath,
            readOnly: readOnly,
            consistency: consistency
        ))
        return copy
    }

    /// Adds a bind mount using a pre-constructed BindMount value.
    ///
    /// - Parameter mount: The bind mount configuration
    /// - Returns: Updated ContainerRequest with the bind mount added
    ///
    /// Example:
    /// ```swift
    /// let mount = BindMount(
    ///     hostPath: "/tmp/data",
    ///     containerPath: "/data",
    ///     readOnly: false,
    ///     consistency: .cached
    /// )
    /// let request = ContainerRequest(image: "alpine:3")
    ///     .withBindMount(mount)
    /// ```
    public func withBindMount(_ mount: BindMount) -> Self {
        var copy = self
        copy.bindMounts.append(mount)
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

    /// Configures a runtime health check for the container.
    /// This adds --health-cmd and related flags to docker run.
    public func withHealthCheck(_ config: HealthCheckConfig) -> Self {
        var copy = self
        copy.healthCheck = config
        return copy
    }

    /// Configures a simple runtime health check command.
    /// - Parameters:
    ///   - command: The command to run for health checking
    ///   - interval: Time between running the check (default: 30s)
    public func withHealthCheck(command: [String], interval: Duration = .seconds(1)) -> Self {
        var copy = self
        copy.healthCheck = HealthCheckConfig(command: command, interval: interval)
        return copy
    }

    /// Enable automatic retries with the default retry policy.
    ///
    /// The default policy uses 3 retry attempts, 1s initial delay, 30s max delay,
    /// 2x exponential backoff, and 10% jitter.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "postgres:15")
    ///     .withExposedPort(5432)
    ///     .waitingFor(.tcpPort(5432))
    ///     .withRetry()
    /// ```
    public func withRetry() -> Self {
        withRetry(.default)
    }

    /// Enable automatic retries with a custom retry policy.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "redis:7")
    ///     .withExposedPort(6379)
    ///     .waitingFor(.tcpPort(6379))
    ///     .withRetry(.aggressive)  // 5 attempts, faster retries
    /// ```
    ///
    /// - Parameter policy: The retry policy to use
    public func withRetry(_ policy: RetryPolicy) -> Self {
        var copy = self
        copy.retryPolicy = policy
        return copy
    }
}

