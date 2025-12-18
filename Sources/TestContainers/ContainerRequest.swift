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

/// Represents a tmpfs (RAM-backed) mount configuration for Docker containers.
///
/// Tmpfs mounts provide fast, ephemeral storage that:
/// - Exists entirely in memory (never written to disk)
/// - Is destroyed when the container stops
/// - Provides faster I/O than disk-backed storage
///
/// Example:
/// ```swift
/// let mount = TmpfsMount(containerPath: "/tmp", sizeLimit: "100m", mode: "1777")
/// ```
public struct TmpfsMount: Sendable, Hashable {
    /// Absolute path inside the container where tmpfs will be mounted.
    public var containerPath: String

    /// Optional size limit (e.g., "100m", "1g").
    /// If nil, tmpfs grows up to 50% of host memory by default.
    public var sizeLimit: String?

    /// Optional Unix permission mode (e.g., "1777", "0755").
    /// If nil, uses default permissions (typically 0755).
    public var mode: String?

    public init(containerPath: String, sizeLimit: String? = nil, mode: String? = nil) {
        self.containerPath = containerPath
        self.sizeLimit = sizeLimit
        self.mode = mode
    }

    /// Generates Docker CLI flag for this tmpfs mount.
    /// Examples:
    ///   - `/tmp`
    ///   - `/cache:size=100m`
    ///   - `/data:mode=0755`
    ///   - `/work:size=1g,mode=1777`
    var dockerFlag: String {
        var options: [String] = []

        if let size = sizeLimit {
            options.append("size=\(size)")
        }

        if let mode = mode {
            options.append("mode=\(mode)")
        }

        if options.isEmpty {
            return containerPath
        }
        return "\(containerPath):\(options.joined(separator: ","))"
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
    public var tmpfsMounts: [TmpfsMount]
    public var workingDirectory: String?
    public var waitStrategy: WaitStrategy
    public var host: String
    public var healthCheck: HealthCheckConfig?
    public var retryPolicy: RetryPolicy?
    public var imageFromDockerfile: ImageFromDockerfile?
    public var artifactConfig: ArtifactConfig

    // Lifecycle hooks
    public var preStartHooks: [LifecycleHook]
    public var postStartHooks: [LifecycleHook]
    public var preStopHooks: [LifecycleHook]
    public var postStopHooks: [LifecycleHook]
    public var preTerminateHooks: [LifecycleHook]
    public var postTerminateHooks: [LifecycleHook]

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
        self.tmpfsMounts = []
        self.workingDirectory = nil
        self.waitStrategy = .none
        self.host = "127.0.0.1"
        self.healthCheck = nil
        self.retryPolicy = nil
        self.imageFromDockerfile = nil
        self.artifactConfig = .default
        self.preStartHooks = []
        self.postStartHooks = []
        self.preStopHooks = []
        self.postStopHooks = []
        self.preTerminateHooks = []
        self.postTerminateHooks = []
    }

    /// Initialize with Dockerfile to build.
    ///
    /// Creates a container request that will build an image from the specified Dockerfile
    /// before running the container. The built image is automatically tagged with a
    /// unique name and cleaned up after the test.
    ///
    /// - Parameter imageFromDockerfile: Configuration for building the Docker image
    public init(imageFromDockerfile: ImageFromDockerfile) {
        // Generate unique image tag for this build
        self.image = "testcontainers-swift-\(UUID().uuidString.lowercased()):latest"
        self.name = nil
        self.command = []
        self.entrypoint = nil
        self.environment = [:]
        self.labels = ["testcontainers.swift": "true"]
        self.ports = []
        self.volumes = []
        self.bindMounts = []
        self.tmpfsMounts = []
        self.workingDirectory = nil
        self.waitStrategy = .none
        self.host = "127.0.0.1"
        self.healthCheck = nil
        self.retryPolicy = nil
        self.imageFromDockerfile = imageFromDockerfile
        self.artifactConfig = .default
        self.preStartHooks = []
        self.postStartHooks = []
        self.preStopHooks = []
        self.postStopHooks = []
        self.preTerminateHooks = []
        self.postTerminateHooks = []
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

    /// Adds multiple labels to the container.
    /// Labels are merged with existing labels; new values override existing keys.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "redis:7")
    ///     .withLabels([
    ///         "app.name": "redis-cache",
    ///         "app.environment": "test",
    ///         "app.version": "1.0.0"
    ///     ])
    /// ```
    public func withLabels(_ labels: [String: String]) -> Self {
        var copy = self
        for (key, value) in labels {
            copy.labels[key] = value
        }
        return copy
    }

    /// Adds multiple labels with a common prefix.
    /// Useful for organizational label conventions.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "postgres:15")
    ///     .withLabels(prefix: "com.mycompany.db", [
    ///         "name": "users-db",
    ///         "tier": "integration-test",
    ///         "owner": "platform-team"
    ///     ])
    /// // Results in labels:
    /// // - com.mycompany.db.name=users-db
    /// // - com.mycompany.db.tier=integration-test
    /// // - com.mycompany.db.owner=platform-team
    /// ```
    public func withLabels(prefix: String, _ labels: [String: String]) -> Self {
        var copy = self
        for (key, value) in labels {
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            copy.labels[fullKey] = value
        }
        return copy
    }

    /// Removes a label by key if it exists.
    /// Useful for removing default labels or cleaning up during request building.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "alpine:3")
    ///     .withoutLabel("testcontainers.swift")
    /// ```
    public func withoutLabel(_ key: String) -> Self {
        var copy = self
        copy.labels.removeValue(forKey: key)
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

    /// Mounts a tmpfs (RAM-backed temporary filesystem) at the specified container path.
    ///
    /// Tmpfs mounts provide fast, ephemeral storage that exists entirely in memory
    /// and is destroyed when the container stops.
    ///
    /// - Parameters:
    ///   - containerPath: Absolute path in the container where tmpfs will be mounted
    ///   - sizeLimit: Optional size limit (e.g., "100m", "1g"). Defaults to 50% of host memory if nil.
    ///   - mode: Optional Unix permission mode (e.g., "1777", "0755"). Defaults to "0755" if nil.
    /// - Returns: Updated ContainerRequest with the tmpfs mount added
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "alpine:3")
    ///     .withTmpfs("/tmp", sizeLimit: "100m", mode: "1777")
    ///     .withTmpfs("/cache", sizeLimit: "500m")
    /// ```
    public func withTmpfs(
        _ containerPath: String,
        sizeLimit: String? = nil,
        mode: String? = nil
    ) -> Self {
        var copy = self
        copy.tmpfsMounts.append(TmpfsMount(
            containerPath: containerPath,
            sizeLimit: sizeLimit,
            mode: mode
        ))
        return copy
    }

    /// Adds a tmpfs mount using a pre-constructed TmpfsMount value.
    ///
    /// - Parameter mount: The tmpfs mount configuration
    /// - Returns: Updated ContainerRequest with the tmpfs mount added
    ///
    /// Example:
    /// ```swift
    /// let mount = TmpfsMount(containerPath: "/data", sizeLimit: "256m", mode: "0755")
    /// let request = ContainerRequest(image: "alpine:3")
    ///     .withTmpfsMount(mount)
    /// ```
    public func withTmpfsMount(_ mount: TmpfsMount) -> Self {
        var copy = self
        copy.tmpfsMounts.append(mount)
        return copy
    }

    /// Sets the working directory inside the container.
    ///
    /// The working directory is the path where the container's command will execute.
    /// If the directory doesn't exist, Docker will create it.
    ///
    /// - Parameter workingDirectory: Absolute path to use as the working directory
    /// - Returns: Updated ContainerRequest with the working directory set
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "node:20")
    ///     .withWorkingDirectory("/app")
    ///     .withCommand(["node", "index.js"])
    /// ```
    public func withWorkingDirectory(_ workingDirectory: String) -> Self {
        var copy = self
        copy.workingDirectory = workingDirectory
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

    // MARK: - Dockerfile Build

    /// Specify a Dockerfile to build the container image from.
    ///
    /// When this is set, the image will be built from the specified Dockerfile
    /// before running the container. The built image is automatically cleaned up
    /// after the test.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "unused")
    ///     .withImageFromDockerfile(
    ///         ImageFromDockerfile(dockerfilePath: "test/Dockerfile")
    ///             .withBuildArg("VERSION", "1.0")
    ///     )
    ///     .withExposedPort(8080)
    /// ```
    ///
    /// - Parameter dockerfileImage: Configuration for building the Docker image
    /// - Returns: Updated ContainerRequest with Dockerfile configuration
    public func withImageFromDockerfile(_ dockerfileImage: ImageFromDockerfile) -> Self {
        var copy = self
        copy.imageFromDockerfile = dockerfileImage
        copy.image = "testcontainers-swift-\(UUID().uuidString.lowercased()):latest"
        return copy
    }

    // MARK: - Artifact Configuration

    /// Configure artifact collection for this container.
    ///
    /// Artifacts include container logs, metadata, and request configuration,
    /// which are saved when tests fail to aid debugging.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "postgres:15")
    ///     .withArtifacts(ArtifactConfig()
    ///         .withOutputDirectory("/tmp/test-artifacts")
    ///         .withTrigger(.always))
    /// ```
    ///
    /// - Parameter config: The artifact configuration to use
    /// - Returns: Updated ContainerRequest with artifact configuration
    public func withArtifacts(_ config: ArtifactConfig) -> Self {
        var copy = self
        copy.artifactConfig = config
        return copy
    }

    /// Disable artifact collection for this container.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "redis:7")
    ///     .withoutArtifacts()  // No artifacts will be collected
    /// ```
    ///
    /// - Returns: Updated ContainerRequest with artifacts disabled
    public func withoutArtifacts() -> Self {
        withArtifacts(.disabled)
    }

    // MARK: - Session Labels

    /// Apply current session labels to this container request.
    ///
    /// Session labels enable cleanup of containers from a specific test session.
    /// Labels added:
    /// - `testcontainers.swift.session.id`: Unique session identifier
    /// - `testcontainers.swift.session.pid`: Process ID
    /// - `testcontainers.swift.session.started`: Unix timestamp of session start
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "postgres:15")
    ///     .withExposedPort(5432)
    ///     .withSessionLabels()  // Enable session tracking
    /// ```
    ///
    /// - Returns: Updated ContainerRequest with session labels applied
    public func withSessionLabels() -> Self {
        var copy = self
        for (key, value) in currentTestSession.sessionLabels {
            copy.labels[key] = value
        }
        return copy
    }

    // MARK: - Lifecycle Hooks

    /// Adds a pre-start hook that runs before the container is created.
    /// - Parameter action: Async action to execute
    /// - Returns: Updated ContainerRequest with the hook added
    public func onPreStart(_ action: @escaping @Sendable (LifecycleContext) async throws -> Void) -> Self {
        withLifecycleHook(LifecycleHook(action), phase: .preStart)
    }

    /// Adds a post-start hook that runs after the container has started and is ready.
    /// - Parameter action: Async action to execute
    /// - Returns: Updated ContainerRequest with the hook added
    public func onPostStart(_ action: @escaping @Sendable (LifecycleContext) async throws -> Void) -> Self {
        withLifecycleHook(LifecycleHook(action), phase: .postStart)
    }

    /// Adds a pre-stop hook that runs before the container is stopped.
    /// - Parameter action: Async action to execute
    /// - Returns: Updated ContainerRequest with the hook added
    public func onPreStop(_ action: @escaping @Sendable (LifecycleContext) async throws -> Void) -> Self {
        withLifecycleHook(LifecycleHook(action), phase: .preStop)
    }

    /// Adds a post-stop hook that runs after the container has stopped.
    /// - Parameter action: Async action to execute
    /// - Returns: Updated ContainerRequest with the hook added
    public func onPostStop(_ action: @escaping @Sendable (LifecycleContext) async throws -> Void) -> Self {
        withLifecycleHook(LifecycleHook(action), phase: .postStop)
    }

    /// Adds a pre-terminate hook that runs before the container is terminated/removed.
    /// - Parameter action: Async action to execute
    /// - Returns: Updated ContainerRequest with the hook added
    public func onPreTerminate(_ action: @escaping @Sendable (LifecycleContext) async throws -> Void) -> Self {
        withLifecycleHook(LifecycleHook(action), phase: .preTerminate)
    }

    /// Adds a post-terminate hook that runs after the container has been terminated/removed.
    /// - Parameter action: Async action to execute
    /// - Returns: Updated ContainerRequest with the hook added
    public func onPostTerminate(_ action: @escaping @Sendable (LifecycleContext) async throws -> Void) -> Self {
        withLifecycleHook(LifecycleHook(action), phase: .postTerminate)
    }

    /// Adds a lifecycle hook for a specific phase.
    /// - Parameters:
    ///   - hook: The lifecycle hook to add
    ///   - phase: The phase when the hook should execute
    /// - Returns: Updated ContainerRequest with the hook added
    public func withLifecycleHook(_ hook: LifecycleHook, phase: LifecyclePhase) -> Self {
        var copy = self
        switch phase {
        case .preStart:
            copy.preStartHooks.append(hook)
        case .postStart:
            copy.postStartHooks.append(hook)
        case .preStop:
            copy.preStopHooks.append(hook)
        case .postStop:
            copy.postStopHooks.append(hook)
        case .preTerminate:
            copy.preTerminateHooks.append(hook)
        case .postTerminate:
            copy.postTerminateHooks.append(hook)
        }
        return copy
    }
}

