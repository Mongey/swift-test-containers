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

/// Represents a custom hostname to IP mapping added via `docker run --add-host`.
public struct ExtraHost: Hashable, Sendable {
    public var hostname: String
    public var ip: String

    public init(hostname: String, ip: String) {
        self.hostname = hostname
        self.ip = ip
    }

    /// Uses Docker's special `host-gateway` value for container-to-host access.
    public static func gateway(hostname: String) -> Self {
        ExtraHost(hostname: hostname, ip: "host-gateway")
    }

    var dockerFlag: String {
        "\(hostname):\(ip)"
    }

    var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Represents a network connection configuration for attaching a container to a Docker network.
public struct NetworkConnection: Sendable, Hashable {
    public var networkName: String
    public var aliases: [String]
    public var ipv4Address: String?
    public var ipv6Address: String?

    public init(
        networkName: String,
        aliases: [String] = [],
        ipv4Address: String? = nil,
        ipv6Address: String? = nil
    ) {
        self.networkName = networkName
        self.aliases = aliases
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
    }
}

/// Network mode for container networking.
public enum NetworkMode: Sendable, Hashable {
    case bridge
    case host
    case none
    case container(String)
    case custom(String)

    var dockerFlag: String {
        switch self {
        case .bridge: return "bridge"
        case .host: return "host"
        case .none: return "none"
        case .container(let nameOrId): return "container:\(nameOrId)"
        case .custom(let name): return name
        }
    }
}

/// Authentication configuration for pulling images from private Docker registries.
///
/// Supports three modes:
/// - `.credentials`: Direct username/password authentication (uses `docker login --password-stdin`)
/// - `.configFile`: Use a custom Docker config directory (sets `DOCKER_CONFIG` env var)
/// - `.systemDefault`: Use the default `~/.docker/config.json` (no action needed)
public enum RegistryAuth: Sendable, Hashable {
    /// Authenticate with username and password via `docker login --password-stdin`.
    /// The password is passed via stdin to avoid shell exposure.
    case credentials(registry: String, username: String, password: String)

    /// Use a custom Docker config directory containing `config.json`.
    /// The path should point to the directory, not the file itself.
    case configFile(path: String)

    /// Use the system default Docker config (`~/.docker/config.json`).
    case systemDefault
}

/// Determines when Docker should pull container images from registries.
public enum ImagePullPolicy: Sendable, Hashable {
    /// Always pull the image from the registry, even if cached locally.
    case always

    /// Pull the image only if it doesn't exist locally (default).
    case ifNotPresent

    /// Never pull the image; only use images already available locally.
    case never
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

/// Represents a Linux capability that can be granted or dropped from a container.
/// Full list: https://man7.org/linux/man-pages/man7/capabilities.7.html
public struct Capability: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let netAdmin = Capability(rawValue: "NET_ADMIN")
    public static let netRaw = Capability(rawValue: "NET_RAW")
    public static let sysAdmin = Capability(rawValue: "SYS_ADMIN")
    public static let sysTime = Capability(rawValue: "SYS_TIME")
    public static let sysModule = Capability(rawValue: "SYS_MODULE")
    public static let sysRawio = Capability(rawValue: "SYS_RAWIO")
    public static let auditControl = Capability(rawValue: "AUDIT_CONTROL")
    public static let auditRead = Capability(rawValue: "AUDIT_READ")
    public static let chown = Capability(rawValue: "CHOWN")
    public static let dacOverride = Capability(rawValue: "DAC_OVERRIDE")
    public static let fowner = Capability(rawValue: "FOWNER")
    public static let fsetid = Capability(rawValue: "FSETID")
    public static let kill = Capability(rawValue: "KILL")
    public static let setgid = Capability(rawValue: "SETGID")
    public static let setuid = Capability(rawValue: "SETUID")
    public static let setpcap = Capability(rawValue: "SETPCAP")
    public static let netBindService = Capability(rawValue: "NET_BIND_SERVICE")
    public static let netBroadcast = Capability(rawValue: "NET_BROADCAST")
    public static let ipcLock = Capability(rawValue: "IPC_LOCK")
    public static let ipcOwner = Capability(rawValue: "IPC_OWNER")
    public static let sysChroot = Capability(rawValue: "SYS_CHROOT")
    public static let sysPtrace = Capability(rawValue: "SYS_PTRACE")
    public static let sysPacct = Capability(rawValue: "SYS_PACCT")
    public static let sysResource = Capability(rawValue: "SYS_RESOURCE")
    public static let sysBoot = Capability(rawValue: "SYS_BOOT")
    public static let sysNice = Capability(rawValue: "SYS_NICE")
    public static let sysTtyConfig = Capability(rawValue: "SYS_TTY_CONFIG")
    public static let mknod = Capability(rawValue: "MKNOD")
    public static let lease = Capability(rawValue: "LEASE")
    public static let auditWrite = Capability(rawValue: "AUDIT_WRITE")
    public static let setfcap = Capability(rawValue: "SETFCAP")
    public static let macOverride = Capability(rawValue: "MAC_OVERRIDE")
    public static let macAdmin = Capability(rawValue: "MAC_ADMIN")
    public static let syslog = Capability(rawValue: "SYSLOG")
    public static let wakeAlarm = Capability(rawValue: "WAKE_ALARM")
    public static let blockSuspend = Capability(rawValue: "BLOCK_SUSPEND")
    public static let perfmon = Capability(rawValue: "PERFMON")
    public static let bpf = Capability(rawValue: "BPF")
    public static let checkpointRestore = Capability(rawValue: "CHECKPOINT_RESTORE")
}

/// Represents a Docker container user specification passed to `docker run --user`.
///
/// Supported formats:
/// - `uid`
/// - `uid:gid`
/// - `username`
/// - `username:group`
/// - `username:gid`
public struct ContainerUser: Sendable, Hashable {
    public let dockerFlag: String

    /// Run the container as a numeric user ID.
    public init(uid: Int) {
        self.dockerFlag = "\(uid)"
    }

    /// Run the container as a numeric user ID and group ID.
    public init(uid: Int, gid: Int) {
        self.dockerFlag = "\(uid):\(gid)"
    }

    /// Run the container as a username.
    public init(username: String) {
        precondition(!username.isEmpty, "username cannot be empty")
        self.dockerFlag = username
    }

    /// Run the container as username and group name.
    public init(username: String, group: String) {
        precondition(!username.isEmpty, "username cannot be empty")
        precondition(!group.isEmpty, "group cannot be empty")
        self.dockerFlag = "\(username):\(group)"
    }

    /// Run the container as username and numeric group ID.
    public init(username: String, gid: Int) {
        precondition(!username.isEmpty, "username cannot be empty")
        self.dockerFlag = "\(username):\(gid)"
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

/// Defines what readiness condition to wait for on a dependency edge.
public enum DependencyWaitStrategy: Sendable, Hashable {
    /// Wait only until the dependency container has been started.
    case started

    /// Wait until the dependency container reaches its configured request readiness.
    case ready

    /// Wait until Docker health check reports "healthy" for the dependency container.
    case healthy

    /// Wait using a custom strategy against the dependency container.
    case custom(WaitStrategy)
}

/// Represents a dependency relationship for a container request when used in a stack/group.
public struct ContainerDependency: Sendable, Hashable {
    public let name: String
    public let waitStrategy: DependencyWaitStrategy

    public init(name: String, waitStrategy: DependencyWaitStrategy = .ready) {
        self.name = name
        self.waitStrategy = waitStrategy
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

/// Resource constraints applied at container runtime.
///
/// Values are passed directly to Docker's `run` flags:
/// - `memory` -> `--memory` (for example, `512m`, `1g`)
/// - `memoryReservation` -> `--memory-reservation`
/// - `memorySwap` -> `--memory-swap` (or `-1` for unlimited swap)
/// - `cpus` -> `--cpus` (for example, `0.5`, `1.5`)
/// - `cpuShares` -> `--cpu-shares`
/// - `cpuPeriod` -> `--cpu-period`
/// - `cpuQuota` -> `--cpu-quota`
public struct ResourceLimits: Sendable, Hashable {
    public var memory: String?
    public var memoryReservation: String?
    public var memorySwap: String?
    public var cpus: String?
    public var cpuShares: Int?
    public var cpuPeriod: Int?
    public var cpuQuota: Int?

    public init() {
        self.memory = nil
        self.memoryReservation = nil
        self.memorySwap = nil
        self.cpus = nil
        self.cpuShares = nil
        self.cpuPeriod = nil
        self.cpuQuota = nil
    }
}

/// Configuration for diagnostic information collected on container failures.
///
/// When a wait strategy times out, diagnostics capture container logs and state
/// to help developers quickly identify issues without manual inspection.
public struct DiagnosticsConfig: Sendable, Hashable {
    /// Whether to capture container logs on failure.
    public var captureLogsOnFailure: Bool
    /// Number of log lines to capture (from the end of logs).
    public var logTailLines: Int
    /// Whether to capture container state (running, exited, exit code, etc.) on failure.
    public var captureStateOnFailure: Bool

    /// Default diagnostics: capture 50 lines of logs and container state.
    public static let `default` = DiagnosticsConfig(
        captureLogsOnFailure: true,
        logTailLines: 50,
        captureStateOnFailure: true
    )

    /// Disable all diagnostic collection.
    public static let disabled = DiagnosticsConfig(
        captureLogsOnFailure: false,
        logTailLines: 0,
        captureStateOnFailure: false
    )

    /// Verbose diagnostics: capture 200 lines of logs and container state.
    public static let verbose = DiagnosticsConfig(
        captureLogsOnFailure: true,
        logTailLines: 200,
        captureStateOnFailure: true
    )

    public init(
        captureLogsOnFailure: Bool = true,
        logTailLines: Int = 50,
        captureStateOnFailure: Bool = true
    ) {
        self.captureLogsOnFailure = captureLogsOnFailure
        self.logTailLines = max(0, logTailLines)
        self.captureStateOnFailure = captureStateOnFailure
    }
}

public struct ContainerRequest: Sendable, Hashable {
    private static let platformSegmentAllowedCharacters = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "._-")
    )

    public var image: String
    public var name: String?
    public var autoGenerateName: Bool
    public var command: [String]
    public var entrypoint: [String]?
    public var environment: [String: String]
    public var labels: [String: String]
    public var ports: [ContainerPort]
    public var extraHosts: [ExtraHost]
    public var volumes: [VolumeMount]
    public var bindMounts: [BindMount]
    public var tmpfsMounts: [TmpfsMount]
    public var workingDirectory: String?
    public var user: ContainerUser?
    public var privileged: Bool
    public var capabilitiesToAdd: Set<Capability>
    public var capabilitiesToDrop: Set<Capability>
    public var waitStrategy: WaitStrategy
    public var host: String
    public var platform: String?
    public var healthCheck: HealthCheckConfig?
    public var retryPolicy: RetryPolicy?
    public var imageFromDockerfile: ImageFromDockerfile?
    public var artifactConfig: ArtifactConfig
    public var reuse: Bool
    public var resourceLimits: ResourceLimits
    public var imagePullPolicy: ImagePullPolicy
    public var networks: [NetworkConnection]
    public var networkMode: NetworkMode?
    public var dependencies: [ContainerDependency]
    public var diagnostics: DiagnosticsConfig
    public var imageSubstitutor: ImageSubstitutorConfig?
    public var registryAuth: RegistryAuth?

    // Lifecycle hooks
    public var preStartHooks: [LifecycleHook]
    public var postStartHooks: [LifecycleHook]
    public var preStopHooks: [LifecycleHook]
    public var postStopHooks: [LifecycleHook]
    public var preTerminateHooks: [LifecycleHook]
    public var postTerminateHooks: [LifecycleHook]

    // Log consumers
    public var logConsumers: [LogConsumerEntry]

    public init(image: String) {
        self.image = image
        self.name = nil
        self.autoGenerateName = true
        self.command = []
        self.entrypoint = nil
        self.environment = [:]
        self.labels = ["testcontainers.swift": "true"]
        self.ports = []
        self.extraHosts = []
        self.volumes = []
        self.bindMounts = []
        self.tmpfsMounts = []
        self.workingDirectory = nil
        self.user = nil
        self.privileged = false
        self.capabilitiesToAdd = []
        self.capabilitiesToDrop = []
        self.waitStrategy = .none
        self.host = "127.0.0.1"
        self.platform = nil
        self.healthCheck = nil
        self.retryPolicy = nil
        self.imageFromDockerfile = nil
        self.artifactConfig = .default
        self.reuse = false
        self.resourceLimits = ResourceLimits()
        self.imagePullPolicy = .ifNotPresent
        self.networks = []
        self.networkMode = nil
        self.dependencies = []
        self.diagnostics = .default
        self.imageSubstitutor = nil
        self.registryAuth = nil
        self.preStartHooks = []
        self.postStartHooks = []
        self.preStopHooks = []
        self.postStopHooks = []
        self.preTerminateHooks = []
        self.postTerminateHooks = []
        self.logConsumers = []
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
        self.autoGenerateName = true
        self.command = []
        self.entrypoint = nil
        self.environment = [:]
        self.labels = ["testcontainers.swift": "true"]
        self.ports = []
        self.extraHosts = []
        self.volumes = []
        self.bindMounts = []
        self.tmpfsMounts = []
        self.workingDirectory = nil
        self.user = nil
        self.privileged = false
        self.capabilitiesToAdd = []
        self.capabilitiesToDrop = []
        self.waitStrategy = .none
        self.host = "127.0.0.1"
        self.platform = nil
        self.healthCheck = nil
        self.retryPolicy = nil
        self.imageFromDockerfile = imageFromDockerfile
        self.artifactConfig = .default
        self.reuse = false
        self.resourceLimits = ResourceLimits()
        self.imagePullPolicy = .ifNotPresent
        self.networks = []
        self.networkMode = nil
        self.dependencies = []
        self.diagnostics = .default
        self.imageSubstitutor = nil
        self.registryAuth = nil
        self.preStartHooks = []
        self.postStartHooks = []
        self.preStopHooks = []
        self.postStopHooks = []
        self.preTerminateHooks = []
        self.postTerminateHooks = []
        self.logConsumers = []
    }

    public func withName(_ name: String, autoGenerate: Bool = false) -> Self {
        var copy = self
        copy.name = name
        copy.autoGenerateName = autoGenerate
        return copy
    }

    /// Configures a generated container name using a deterministic prefix.
    ///
    /// Each `docker run` call receives a unique name in the format
    /// `<prefix>-<timestamp>-<uuid8>`.
    public func withAutoGeneratedName(_ prefix: String = "tc-swift") -> Self {
        var copy = self
        copy.name = prefix
        copy.autoGenerateName = true
        return copy
    }

    /// Configures a fixed container name.
    ///
    /// Fixed names can conflict when tests run concurrently.
    public func withFixedName(_ name: String) -> Self {
        var copy = self
        copy.name = name
        copy.autoGenerateName = false
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

    /// Expose a container port.
    ///
    /// - Parameters:
    ///   - containerPort: Container-side port to expose.
    ///   - hostPort: Optional host-side port. Leave `nil` to use Docker's random host
    ///     port allocation (recommended for parallel tests). Setting a fixed host port
    ///     can cause conflicts in parallel execution.
    public func withExposedPort(_ containerPort: Int, hostPort: Int? = nil) -> Self {
        var copy = self
        copy.ports.append(ContainerPort(containerPort: containerPort, hostPort: hostPort))
        return copy
    }

    /// Expose a container port using Docker's random host port allocation.
    public func withRandomPort(_ containerPort: Int) -> Self {
        withExposedPort(containerPort, hostPort: nil)
    }

    /// Adds a custom host mapping for `/etc/hosts` via `--add-host`.
    public func withExtraHost(hostname: String, ip: String) -> Self {
        withExtraHost(ExtraHost(hostname: hostname, ip: ip))
    }

    /// Adds a custom host mapping for `/etc/hosts` via `--add-host`.
    public func withExtraHost(_ host: ExtraHost) -> Self {
        var copy = self
        copy.extraHosts.append(host)
        return copy
    }

    /// Adds multiple custom host mappings for `/etc/hosts`.
    public func withExtraHosts(_ hosts: [ExtraHost]) -> Self {
        var copy = self
        copy.extraHosts.append(contentsOf: hosts)
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

    /// Sets the container runtime user (`docker run --user`).
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "alpine:3")
    ///     .withUser(uid: 1000, gid: 1000)
    /// ```
    public func withUser(_ user: ContainerUser) -> Self {
        var copy = self
        copy.user = user
        return copy
    }

    /// Sets the container runtime user as a numeric UID.
    public func withUser(uid: Int) -> Self {
        withUser(ContainerUser(uid: uid))
    }

    /// Sets the container runtime user as numeric UID:GID.
    public func withUser(uid: Int, gid: Int) -> Self {
        withUser(ContainerUser(uid: uid, gid: gid))
    }

    /// Sets the container runtime user as a username.
    public func withUser(username: String) -> Self {
        withUser(ContainerUser(username: username))
    }

    /// Sets the container runtime user as username:group.
    public func withUser(username: String, group: String) -> Self {
        withUser(ContainerUser(username: username, group: group))
    }

    /// Sets the container runtime user as username:gid.
    public func withUser(username: String, gid: Int) -> Self {
        withUser(ContainerUser(username: username, gid: gid))
    }

    /// Run the container in privileged mode, granting all capabilities.
    ///
    /// Privileged mode gives the container nearly all capabilities of the host machine.
    /// This is typically used for Docker-in-Docker, device access, or system administration tasks.
    ///
    /// - Parameter privileged: Whether to run in privileged mode (default: true)
    /// - Returns: Updated ContainerRequest with privileged mode configured
    public func withPrivileged(_ privileged: Bool = true) -> Self {
        var copy = self
        copy.privileged = privileged
        return copy
    }

    /// Add specific Linux capabilities to the container.
    ///
    /// Capabilities are a fine-grained alternative to privileged mode, allowing you to
    /// grant specific permissions without full host access.
    ///
    /// - Parameter capabilities: Set of capabilities to add
    /// - Returns: Updated ContainerRequest with capabilities added
    public func withCapabilityAdd(_ capabilities: Set<Capability>) -> Self {
        var copy = self
        copy.capabilitiesToAdd.formUnion(capabilities)
        return copy
    }

    /// Add a single Linux capability to the container.
    ///
    /// - Parameter capability: The capability to add
    /// - Returns: Updated ContainerRequest with the capability added
    public func withCapabilityAdd(_ capability: Capability) -> Self {
        withCapabilityAdd([capability])
    }

    /// Drop specific Linux capabilities from the container.
    ///
    /// Use this to remove default capabilities for defense-in-depth security.
    ///
    /// - Parameter capabilities: Set of capabilities to drop
    /// - Returns: Updated ContainerRequest with capabilities dropped
    public func withCapabilityDrop(_ capabilities: Set<Capability>) -> Self {
        var copy = self
        copy.capabilitiesToDrop.formUnion(capabilities)
        return copy
    }

    /// Drop a single Linux capability from the container.
    ///
    /// - Parameter capability: The capability to drop
    /// - Returns: Updated ContainerRequest with the capability dropped
    public func withCapabilityDrop(_ capability: Capability) -> Self {
        withCapabilityDrop([capability])
    }

    public func waitingFor(_ strategy: WaitStrategy) -> Self {
        var copy = self
        copy.waitStrategy = strategy
        return copy
    }

    /// Declares a dependency when this request is used in a container stack/group.
    ///
    /// If the same dependency is declared multiple times, the latest wait strategy wins.
    public func dependsOn(_ containerName: String, waitFor: DependencyWaitStrategy = .ready) -> Self {
        var copy = self
        copy.dependencies.removeAll { $0.name == containerName }
        copy.dependencies.append(ContainerDependency(name: containerName, waitStrategy: waitFor))
        return copy
    }

    /// Declares multiple dependencies with a shared wait strategy.
    ///
    /// If any dependency appears multiple times, the latest declaration wins.
    public func dependsOn(_ containerNames: [String], waitFor: DependencyWaitStrategy = .ready) -> Self {
        var copy = self
        for dependency in containerNames {
            copy.dependencies.removeAll { $0.name == dependency }
            copy.dependencies.append(ContainerDependency(name: dependency, waitStrategy: waitFor))
        }
        return copy
    }

    public func withHost(_ host: String) -> Self {
        var copy = self
        copy.host = host
        return copy
    }

    /// Sets a hard memory limit (`docker run --memory`).
    ///
    /// Example values: `"512m"`, `"1g"`.
    public func withMemoryLimit(_ limit: String) -> Self {
        var copy = self
        copy.resourceLimits.memory = limit
        return copy
    }

    /// Sets a soft memory reservation (`docker run --memory-reservation`).
    ///
    /// Example values: `"256m"`, `"768m"`.
    public func withMemoryReservation(_ reservation: String) -> Self {
        var copy = self
        copy.resourceLimits.memoryReservation = reservation
        return copy
    }

    /// Sets total memory+swap limit (`docker run --memory-swap`).
    ///
    /// Example values: `"1g"`, `"-1"` for unlimited swap.
    public func withMemorySwap(_ swap: String) -> Self {
        var copy = self
        copy.resourceLimits.memorySwap = swap
        return copy
    }

    /// Sets CPU limit (`docker run --cpus`).
    ///
    /// Example values: `"0.5"`, `"1.5"`.
    public func withCpuLimit(_ cpus: String) -> Self {
        var copy = self
        copy.resourceLimits.cpus = cpus
        return copy
    }

    /// Sets CPU share weight (`docker run --cpu-shares`).
    ///
    /// Docker default is 1024.
    public func withCpuShares(_ shares: Int) -> Self {
        var copy = self
        copy.resourceLimits.cpuShares = shares
        return copy
    }

    /// Sets CFS scheduler period in microseconds (`docker run --cpu-period`).
    public func withCpuPeriod(_ period: Int) -> Self {
        var copy = self
        copy.resourceLimits.cpuPeriod = period
        return copy
    }

    /// Sets CFS scheduler quota in microseconds (`docker run --cpu-quota`).
    public func withCpuQuota(_ quota: Int) -> Self {
        var copy = self
        copy.resourceLimits.cpuQuota = quota
        return copy
    }

    /// Sets all resource limits at once.
    public func withResourceLimits(_ limits: ResourceLimits) -> Self {
        var copy = self
        copy.resourceLimits = limits
        return copy
    }

    /// Sets the container platform passed to `docker run --platform`.
    ///
    /// Platform values should follow Docker's `<os>/<architecture>[/variant]` format,
    /// such as `linux/amd64`, `linux/arm64`, or `linux/arm/v7`.
    ///
    /// Use this when you need deterministic architecture behavior, such as running
    /// `linux/amd64` images on Apple Silicon via emulation.
    ///
    /// Invalid platform formats are rejected before Docker is invoked.
    public func withPlatform(_ platform: String) -> Self {
        var copy = self
        copy.platform = platform
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

    /// Enables or disables container reuse.
    ///
    /// Reuse is opt-in per container request and still requires global reuse
    /// enablement via `ReuseConfig`.
    ///
    /// - Parameter enabled: Whether reuse is enabled for this request. Default: true.
    /// - Returns: Updated container request.
    public func withReuse(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.reuse = enabled
        return copy
    }

    /// Specify when the container image should be pulled from the registry.
    ///
    /// - Parameter policy: The pull policy to use
    /// - Returns: A new ContainerRequest with the specified pull policy
    public func withImagePullPolicy(_ policy: ImagePullPolicy) -> Self {
        var copy = self
        copy.imagePullPolicy = policy
        return copy
    }

    // MARK: - Network Configuration

    /// Attach the container to a named network.
    ///
    /// - Parameter networkName: The Docker network name to attach to
    /// - Returns: Updated ContainerRequest with the network added
    public func withNetwork(_ networkName: String) -> Self {
        var copy = self
        copy.networks.append(NetworkConnection(networkName: networkName))
        return copy
    }

    /// Attach the container to a network with a full configuration.
    ///
    /// - Parameter connection: The network connection configuration
    /// - Returns: Updated ContainerRequest with the network added
    public func withNetwork(_ connection: NetworkConnection) -> Self {
        var copy = self
        copy.networks.append(connection)
        return copy
    }

    /// Attach the container to a named network with DNS aliases.
    ///
    /// - Parameters:
    ///   - networkName: The Docker network name to attach to
    ///   - aliases: DNS aliases for service discovery within the network
    /// - Returns: Updated ContainerRequest with the network added
    public func withNetwork(_ networkName: String, aliases: [String]) -> Self {
        var copy = self
        copy.networks.append(NetworkConnection(networkName: networkName, aliases: aliases))
        return copy
    }

    /// Set the network mode for the container.
    ///
    /// - Parameter mode: The network mode (bridge, host, none, container)
    /// - Returns: Updated ContainerRequest with the network mode set
    public func withNetworkMode(_ mode: NetworkMode) -> Self {
        var copy = self
        copy.networkMode = mode
        return copy
    }

    // MARK: - Registry Authentication

    /// Configure authentication for pulling images from private registries.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "ghcr.io/myorg/app:v1")
    ///     .withRegistryAuth(.credentials(
    ///         registry: "ghcr.io",
    ///         username: "user",
    ///         password: ProcessInfo.processInfo.environment["GITHUB_TOKEN"]!
    ///     ))
    /// ```
    public func withRegistryAuth(_ auth: RegistryAuth) -> Self {
        var copy = self
        copy.registryAuth = auth
        return copy
    }

    // MARK: - Image Substitutor

    /// Sets an image substitutor for this container request.
    ///
    /// The substitutor transforms the image reference before the container is created.
    /// This enables registry mirroring, organization prefixes, and custom transformations.
    ///
    /// - Parameter substitutor: Image transformation configuration
    /// - Returns: Updated ContainerRequest with the substitutor set
    public func withImageSubstitutor(_ substitutor: ImageSubstitutorConfig) -> Self {
        var copy = self
        copy.imageSubstitutor = substitutor
        return copy
    }

    /// The image reference after applying any configured substitutor.
    ///
    /// If no substitutor is set, returns the original image.
    public var resolvedImage: String {
        if let substitutor = imageSubstitutor {
            return substitutor.substitute(image)
        }
        return image
    }

    // MARK: - Diagnostics Configuration

    /// Configure diagnostic collection for timeout failures.
    ///
    /// - Parameter config: The diagnostics configuration to use
    /// - Returns: Updated ContainerRequest with diagnostics configured
    public func withDiagnostics(_ config: DiagnosticsConfig) -> Self {
        var copy = self
        copy.diagnostics = config
        return copy
    }

    /// Set the number of log lines to capture on timeout failure.
    ///
    /// - Parameter lines: Number of lines from the end of container logs to capture
    /// - Returns: Updated ContainerRequest with log tail lines configured
    public func withLogTailLines(_ lines: Int) -> Self {
        var copy = self
        copy.diagnostics.logTailLines = max(0, lines)
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

    /// Adds labels useful for test-level parallel diagnostics and cleanup.
    ///
    /// Labels added:
    /// - `testcontainers.swift.test`
    /// - `testcontainers.swift.session`
    /// - `testcontainers.swift.timestamp`
    public func withTestLabels(testName: String? = nil, sessionID: String? = nil) -> Self {
        var copy = self

        if let testName {
            copy.labels["testcontainers.swift.test"] = testName
        }

        if let sessionID {
            copy.labels["testcontainers.swift.session"] = sessionID
        }

        copy.labels["testcontainers.swift.timestamp"] = String(Int(Date().timeIntervalSince1970))
        return copy
    }

    /// Applies parallel safety defaults to the container request.
    public func withParallelSafety(_ config: ParallelSafetyConfig = .default) -> Self {
        var copy = self
        copy.autoGenerateName = config.autoGenerateNames

        if let sessionID = config.sessionID {
            copy.labels["testcontainers.swift.session"] = sessionID
        }

        if config.validatePortAllocation {
            for mapping in copy.ports where mapping.hostPort != nil {
                FileHandle.standardError.write(
                    Data("Warning: fixed host port \(mapping.hostPort!) may conflict in parallel tests.\n".utf8)
                )
            }
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

    // MARK: - Log Consumers

    /// Register a log consumer to receive container log output.
    ///
    /// Log consumers receive log lines in real-time as the container produces output.
    /// Multiple consumers can be registered and all will receive the same log lines.
    ///
    /// - Parameter consumer: The log consumer to register
    /// - Returns: Updated ContainerRequest with the consumer added
    public func withLogConsumer(_ consumer: any LogConsumer) -> Self {
        var copy = self
        copy.logConsumers.append(LogConsumerEntry(consumer))
        return copy
    }

    /// Register multiple log consumers at once.
    ///
    /// - Parameter consumers: Array of log consumers to register
    /// - Returns: Updated ContainerRequest with consumers added
    public func withLogConsumers(_ consumers: [any LogConsumer]) -> Self {
        var copy = self
        for consumer in consumers {
            copy.logConsumers.append(LogConsumerEntry(consumer))
        }
        return copy
    }

    static func isValidPlatform(_ platform: String) -> Bool {
        let segments = platform.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2 || segments.count == 3 else { return false }

        return segments.allSatisfy { segment in
            guard !segment.isEmpty else { return false }

            return segment.unicodeScalars.allSatisfy { scalar in
                platformSegmentAllowedCharacters.contains(scalar)
            }
        }
    }

    func resolvedName() -> String? {
        guard autoGenerateName else { return name }

        let rawPrefix = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = (rawPrefix?.isEmpty == false) ? rawPrefix! : "tc-swift"
        return ContainerNameGenerator.generateUniqueName(prefix: prefix)
    }
}
