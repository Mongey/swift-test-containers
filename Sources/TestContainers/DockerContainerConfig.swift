import Foundation

/// Converts a `ContainerRequest` into the JSON body for `POST /containers/create`.
enum DockerContainerConfig {

    /// Build the container create request body from a ContainerRequest.
    static func buildCreateBody(from request: ContainerRequest) -> ContainerCreateBody {
        var body = ContainerCreateBody(Image: request.resolvedImage)

        // User
        if let user = request.user {
            body.User = user.dockerFlag
        }

        // Environment
        if !request.environment.isEmpty {
            body.Env = request.environment
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
        }

        // Command
        if !request.command.isEmpty {
            // Handle multi-part entrypoint: elements after the first become command prefix
            if let entrypoint = request.entrypoint, entrypoint.count > 1 {
                body.Cmd = Array(entrypoint[1...]) + request.command
            } else {
                body.Cmd = request.command
            }
        } else if let entrypoint = request.entrypoint, entrypoint.count > 1 {
            body.Cmd = Array(entrypoint[1...])
        }

        // Working directory
        body.WorkingDir = request.workingDirectory

        // Entrypoint
        if let entrypoint = request.entrypoint {
            if entrypoint.isEmpty {
                body.Entrypoint = [""]
            } else {
                body.Entrypoint = [entrypoint[0]]
            }
        }

        // Labels
        if !request.labels.isEmpty {
            body.Labels = request.labels
        }

        // Exposed ports
        if !request.ports.isEmpty {
            var exposed: [String: EmptyEncodableObject] = [:]
            for port in request.ports {
                exposed["\(port.containerPort)/tcp"] = EmptyEncodableObject()
            }
            body.ExposedPorts = exposed
        }

        // Health check
        if let healthCheck = request.healthCheck {
            body.Healthcheck = buildHealthcheck(healthCheck)
        }

        // HostConfig
        body.HostConfig = buildHostConfig(from: request)

        // NetworkingConfig
        body.NetworkingConfig = buildNetworkingConfig(from: request)

        return body
    }

    /// Build query parameters for the create container endpoint.
    static func buildQueryParams(from request: ContainerRequest) -> [(String, String)] {
        var params: [(String, String)] = []

        if let name = request.resolvedName() {
            params.append(("name", name))
        }

        if let platform = request.platform {
            params.append(("platform", platform))
        }

        return params
    }

    // MARK: - Private Builders

    private static func buildHealthcheck(_ config: HealthCheckConfig) -> APIHealthcheck {
        let cmdString = config.command.joined(separator: " ")
        return APIHealthcheck(
            Test: ["CMD-SHELL", cmdString],
            Interval: config.interval.map { durationToNanoseconds($0) },
            Timeout: config.timeout.map { durationToNanoseconds($0) },
            StartPeriod: config.startPeriod.map { durationToNanoseconds($0) },
            Retries: config.retries
        )
    }

    private static func buildHostConfig(from request: ContainerRequest) -> APIHostConfig {
        var hc = APIHostConfig()

        // Port bindings
        if !request.ports.isEmpty {
            var bindings: [String: [APIPortBinding]] = [:]
            for port in request.ports {
                let key = "\(port.containerPort)/tcp"
                let binding = APIPortBinding(
                    HostIp: "",
                    HostPort: port.hostPort.map { String($0) } ?? ""
                )
                bindings[key, default: []].append(binding)
            }
            hc.PortBindings = bindings
        }

        // Binds (volumes + bind mounts)
        var binds: [String] = []
        for mount in request.volumes.sorted(by: { $0.volumeName < $1.volumeName }) {
            binds.append(mount.dockerFlag)
        }
        for mount in request.bindMounts.sorted(by: { $0.hostPath < $1.hostPath }) {
            binds.append(mount.dockerFlag)
        }
        if !binds.isEmpty {
            hc.Binds = binds
        }

        // Tmpfs mounts
        if !request.tmpfsMounts.isEmpty {
            var tmpfs: [String: String] = [:]
            for mount in request.tmpfsMounts.sorted(by: { $0.containerPath < $1.containerPath }) {
                var options: [String] = []
                if let size = mount.sizeLimit {
                    options.append("size=\(size)")
                }
                if let mode = mount.mode {
                    options.append("mode=\(mode)")
                }
                tmpfs[mount.containerPath] = options.joined(separator: ",")
            }
            hc.Tmpfs = tmpfs
        }

        // Resource limits
        let limits = request.resourceLimits
        if let memory = limits.memory {
            hc.Memory = parseMemoryString(memory)
        }
        if let memoryReservation = limits.memoryReservation {
            hc.MemoryReservation = parseMemoryString(memoryReservation)
        }
        if let memorySwap = limits.memorySwap {
            hc.MemorySwap = parseMemoryString(memorySwap)
        }
        if let cpus = limits.cpus {
            hc.NanoCPUs = parseCpusString(cpus)
        }
        if let cpuShares = limits.cpuShares {
            hc.CpuShares = Int64(cpuShares)
        }
        if let cpuPeriod = limits.cpuPeriod {
            hc.CpuPeriod = Int64(cpuPeriod)
        }
        if let cpuQuota = limits.cpuQuota {
            hc.CpuQuota = Int64(cpuQuota)
        }

        // Security
        if request.privileged {
            hc.Privileged = true
        }
        if !request.capabilitiesToAdd.isEmpty {
            hc.CapAdd = request.capabilitiesToAdd
                .sorted(by: { $0.rawValue < $1.rawValue })
                .map { $0.rawValue }
        }
        if !request.capabilitiesToDrop.isEmpty {
            hc.CapDrop = request.capabilitiesToDrop
                .sorted(by: { $0.rawValue < $1.rawValue })
                .map { $0.rawValue }
        }

        // Network mode
        if let mode = request.networkMode {
            hc.NetworkMode = mode.dockerFlag
        } else if let firstNetwork = request.networks.first {
            hc.NetworkMode = firstNetwork.networkName
        }

        // Extra hosts
        if !request.extraHosts.isEmpty {
            hc.ExtraHosts = request.extraHosts
                .sorted(by: {
                    if $0.hostname == $1.hostname { return $0.ip < $1.ip }
                    return $0.hostname < $1.hostname
                })
                .map { $0.dockerFlag }
        }

        return hc
    }

    private static func buildNetworkingConfig(from request: ContainerRequest) -> APINetworkingConfig? {
        guard request.networkMode == nil, let firstNetwork = request.networks.first else {
            return nil
        }

        var ipamConfig: APIEndpointIPAMConfig?
        if firstNetwork.ipv4Address != nil || firstNetwork.ipv6Address != nil {
            ipamConfig = APIEndpointIPAMConfig(
                IPv4Address: firstNetwork.ipv4Address,
                IPv6Address: firstNetwork.ipv6Address
            )
        }

        let settings = APIEndpointSettings(
            Aliases: firstNetwork.aliases.isEmpty ? nil : firstNetwork.aliases,
            IPAMConfig: ipamConfig
        )

        return APINetworkingConfig(
            EndpointsConfig: [firstNetwork.networkName: settings]
        )
    }

    // MARK: - Unit Parsing

    /// Parse a Docker memory string (e.g., "512m", "1g", "1024") to bytes.
    static func parseMemoryString(_ value: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let suffixMultipliers: [(String, Int64)] = [
            ("gb", 1024 * 1024 * 1024),
            ("g", 1024 * 1024 * 1024),
            ("mb", 1024 * 1024),
            ("m", 1024 * 1024),
            ("kb", 1024),
            ("k", 1024),
            ("b", 1),
        ]

        for (suffix, multiplier) in suffixMultipliers {
            if trimmed.hasSuffix(suffix) {
                let numberPart = String(trimmed.dropLast(suffix.count))
                if let number = Int64(numberPart) {
                    return number * multiplier
                }
                if let number = Double(numberPart) {
                    return Int64(number * Double(multiplier))
                }
                return nil
            }
        }

        // Raw bytes (no suffix)
        return Int64(trimmed)
    }

    /// Parse a Docker CPUs string (e.g., "0.5", "1.5") to nanoseconds.
    static func parseCpusString(_ value: String) -> Int64? {
        guard let cpus = Double(value) else { return nil }
        return Int64(cpus * 1_000_000_000)
    }

    /// Convert a Swift Duration to nanoseconds (used by Docker API for health check intervals).
    static func durationToNanoseconds(_ duration: Duration) -> Int64 {
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
