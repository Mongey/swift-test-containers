import Foundation

/// Comprehensive container inspection information from `docker inspect`.
public struct ContainerInspection: Sendable, Equatable {
    public let id: String
    public let created: Date
    public let name: String
    public let state: ContainerState
    public let config: ContainerConfig
    public let networkSettings: NetworkSettings

    /// Internal memberwise initializer for constructing from non-Docker formats.
    init(id: String, created: Date, name: String, state: ContainerState, config: ContainerConfig, networkSettings: NetworkSettings) {
        self.id = id
        self.created = created
        self.name = name
        self.state = state
        self.config = config
        self.networkSettings = networkSettings
    }

    /// Parse container inspection from Docker CLI JSON output (array format).
    ///
    /// - Parameter json: JSON string from `docker inspect` command
    /// - Returns: Parsed `ContainerInspection`
    /// - Throws: `TestContainersError.unexpectedDockerOutput` if JSON is empty or invalid
    public static func parse(from json: String) throws -> ContainerInspection {
        guard let data = json.data(using: .utf8) else {
            throw TestContainersError.unexpectedDockerOutput("Invalid UTF-8 in JSON")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeDockerDate)

        let inspections = try decoder.decode([ContainerInspection].self, from: data)
        guard let inspection = inspections.first else {
            throw TestContainersError.unexpectedDockerOutput("docker inspect returned empty array")
        }

        return inspection
    }

    /// Parse container inspection from Docker Engine API JSON response (single object).
    ///
    /// The API endpoint `GET /containers/{id}/json` returns a single object,
    /// unlike the CLI which wraps it in an array.
    ///
    /// - Parameter data: Raw JSON data from the API response
    /// - Returns: Parsed `ContainerInspection`
    public static func parseFromAPI(data: Data) throws -> ContainerInspection {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeDockerDate)
        return try decoder.decode(ContainerInspection.self, from: data)
    }
}

/// Container runtime state.
public struct ContainerState: Sendable, Equatable {
    public let status: Status
    public let running: Bool
    public let paused: Bool
    public let restarting: Bool
    public let oomKilled: Bool
    public let dead: Bool
    public let pid: Int
    public let exitCode: Int
    public let error: String
    public let startedAt: Date?
    public let finishedAt: Date?
    public let health: HealthStatus?

    public enum Status: String, Sendable, Equatable {
        case created
        case running
        case paused
        case restarting
        case removing
        case exited
        case dead
    }

    /// Internal memberwise initializer for constructing from non-Docker formats.
    init(status: Status, running: Bool, paused: Bool, restarting: Bool, oomKilled: Bool, dead: Bool, pid: Int, exitCode: Int, error: String, startedAt: Date?, finishedAt: Date?, health: HealthStatus?) {
        self.status = status
        self.running = running
        self.paused = paused
        self.restarting = restarting
        self.oomKilled = oomKilled
        self.dead = dead
        self.pid = pid
        self.exitCode = exitCode
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.health = health
    }
}

/// Container health check status.
public struct HealthStatus: Sendable, Equatable {
    public let status: Status
    public let failingStreak: Int
    public let log: [HealthLog]

    public enum Status: String, Sendable, Equatable {
        case none
        case starting
        case healthy
        case unhealthy
    }
}

/// A single health check log entry.
public struct HealthLog: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let exitCode: Int
    public let output: String
}

/// Container configuration details.
public struct ContainerConfig: Sendable, Equatable {
    public let hostname: String
    public let user: String
    public let env: [String]
    public let cmd: [String]
    public let image: String
    public let workingDir: String
    public let entrypoint: [String]
    public let labels: [String: String]

    /// Internal memberwise initializer for constructing from non-Docker formats.
    init(hostname: String, user: String, env: [String], cmd: [String], image: String, workingDir: String, entrypoint: [String], labels: [String: String]) {
        self.hostname = hostname
        self.user = user
        self.env = env
        self.cmd = cmd
        self.image = image
        self.workingDir = workingDir
        self.entrypoint = entrypoint
        self.labels = labels
    }
}

/// Network configuration and IP addresses.
public struct NetworkSettings: Sendable, Equatable {
    public let bridge: String
    public let sandboxID: String
    public let ports: [PortBinding]
    public let ipAddress: String
    public let gateway: String
    public let macAddress: String
    public let networks: [String: NetworkAttachment]

    /// Internal memberwise initializer for constructing from non-Docker formats.
    init(bridge: String, sandboxID: String, ports: [PortBinding], ipAddress: String, gateway: String, macAddress: String, networks: [String: NetworkAttachment]) {
        self.bridge = bridge
        self.sandboxID = sandboxID
        self.ports = ports
        self.ipAddress = ipAddress
        self.gateway = gateway
        self.macAddress = macAddress
        self.networks = networks
    }
}

/// A port binding from container port to host.
public struct PortBinding: Sendable, Equatable, Hashable {
    public let containerPort: Int
    public let `protocol`: String
    public let hostIP: String?
    public let hostPort: Int?
}

/// A network attachment with IP and configuration.
public struct NetworkAttachment: Sendable, Equatable {
    public let networkID: String
    public let endpointID: String
    public let gateway: String
    public let ipAddress: String
    public let ipPrefixLen: Int
    public let macAddress: String
    public let aliases: [String]

    /// Internal memberwise initializer for constructing from non-Docker formats.
    init(networkID: String, endpointID: String, gateway: String, ipAddress: String, ipPrefixLen: Int, macAddress: String, aliases: [String]) {
        self.networkID = networkID
        self.endpointID = endpointID
        self.gateway = gateway
        self.ipAddress = ipAddress
        self.ipPrefixLen = ipPrefixLen
        self.macAddress = macAddress
        self.aliases = aliases
    }
}

// MARK: - Codable Conformance

extension ContainerInspection: Decodable {
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case created = "Created"
        case name = "Name"
        case state = "State"
        case config = "Config"
        case networkSettings = "NetworkSettings"
    }
}

extension ContainerState: Decodable {
    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case running = "Running"
        case paused = "Paused"
        case restarting = "Restarting"
        case oomKilled = "OOMKilled"
        case dead = "Dead"
        case pid = "Pid"
        case exitCode = "ExitCode"
        case error = "Error"
        case startedAt = "StartedAt"
        case finishedAt = "FinishedAt"
        case health = "Health"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        status = try container.decode(Status.self, forKey: .status)
        running = try container.decode(Bool.self, forKey: .running)
        paused = try container.decode(Bool.self, forKey: .paused)
        restarting = try container.decode(Bool.self, forKey: .restarting)
        oomKilled = try container.decode(Bool.self, forKey: .oomKilled)
        dead = try container.decode(Bool.self, forKey: .dead)
        pid = try container.decode(Int.self, forKey: .pid)
        exitCode = try container.decode(Int.self, forKey: .exitCode)
        error = try container.decode(String.self, forKey: .error)
        health = try container.decodeIfPresent(HealthStatus.self, forKey: .health)

        // Handle Docker's zero dates as nil
        let startedDate = try container.decode(Date.self, forKey: .startedAt)
        startedAt = isZeroDate(startedDate) ? nil : startedDate

        let finishedDate = try container.decode(Date.self, forKey: .finishedAt)
        finishedAt = isZeroDate(finishedDate) ? nil : finishedDate
    }
}

extension ContainerState.Status: Decodable {}

extension HealthStatus: Decodable {
    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case failingStreak = "FailingStreak"
        case log = "Log"
    }
}

extension HealthStatus.Status: Decodable {}

extension HealthLog: Decodable {
    enum CodingKeys: String, CodingKey {
        case start = "Start"
        case end = "End"
        case exitCode = "ExitCode"
        case output = "Output"
    }
}

extension ContainerConfig: Decodable {
    enum CodingKeys: String, CodingKey {
        case hostname = "Hostname"
        case user = "User"
        case env = "Env"
        case cmd = "Cmd"
        case image = "Image"
        case workingDir = "WorkingDir"
        case entrypoint = "Entrypoint"
        case labels = "Labels"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        hostname = try container.decode(String.self, forKey: .hostname)
        user = try container.decode(String.self, forKey: .user)
        env = try container.decodeIfPresent([String].self, forKey: .env) ?? []
        cmd = try container.decodeIfPresent([String].self, forKey: .cmd) ?? []
        image = try container.decode(String.self, forKey: .image)
        workingDir = try container.decode(String.self, forKey: .workingDir)
        entrypoint = try container.decodeIfPresent([String].self, forKey: .entrypoint) ?? []
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }
}

extension NetworkSettings: Decodable {
    enum CodingKeys: String, CodingKey {
        case bridge = "Bridge"
        case sandboxID = "SandboxID"
        case ports = "Ports"
        case ipAddress = "IPAddress"
        case gateway = "Gateway"
        case macAddress = "MacAddress"
        case networks = "Networks"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // These top-level fields were removed in Docker 29+ (only present inside Networks)
        bridge = try container.decodeIfPresent(String.self, forKey: .bridge) ?? ""
        sandboxID = try container.decodeIfPresent(String.self, forKey: .sandboxID) ?? ""
        ipAddress = try container.decodeIfPresent(String.self, forKey: .ipAddress) ?? ""
        gateway = try container.decodeIfPresent(String.self, forKey: .gateway) ?? ""
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress) ?? ""
        networks = try container.decodeIfPresent([String: NetworkAttachment].self, forKey: .networks) ?? [:]

        // Custom port parsing - Docker uses format "6379/tcp": [{"HostIp": "...", "HostPort": "..."}]
        let portsDict = try container.decode([String: [DockerPortBinding]?].self, forKey: .ports)
        var portBindings: [PortBinding] = []

        for (portProto, bindings) in portsDict {
            let parts = portProto.split(separator: "/")
            guard parts.count == 2, let port = Int(parts[0]) else { continue }
            let proto = String(parts[1])

            if let bindings = bindings {
                for binding in bindings {
                    portBindings.append(PortBinding(
                        containerPort: port,
                        protocol: proto,
                        hostIP: binding.hostIP.isEmpty ? nil : binding.hostIP,
                        hostPort: Int(binding.hostPort)
                    ))
                }
            } else {
                // Exposed but not bound
                portBindings.append(PortBinding(
                    containerPort: port,
                    protocol: proto,
                    hostIP: nil,
                    hostPort: nil
                ))
            }
        }

        ports = portBindings
    }
}

extension NetworkAttachment: Decodable {
    enum CodingKeys: String, CodingKey {
        case networkID = "NetworkID"
        case endpointID = "EndpointID"
        case gateway = "Gateway"
        case ipAddress = "IPAddress"
        case ipPrefixLen = "IPPrefixLen"
        case macAddress = "MacAddress"
        case aliases = "Aliases"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        networkID = try container.decode(String.self, forKey: .networkID)
        endpointID = try container.decode(String.self, forKey: .endpointID)
        gateway = try container.decode(String.self, forKey: .gateway)
        ipAddress = try container.decode(String.self, forKey: .ipAddress)
        ipPrefixLen = try container.decode(Int.self, forKey: .ipPrefixLen)
        macAddress = try container.decode(String.self, forKey: .macAddress)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }
}

// MARK: - Internal Types

/// Internal struct for parsing Docker's port binding format.
private struct DockerPortBinding: Decodable {
    let hostIP: String
    let hostPort: String

    enum CodingKeys: String, CodingKey {
        case hostIP = "HostIp"
        case hostPort = "HostPort"
    }
}

// MARK: - Date Helpers

/// Docker's zero date representing "not set".
private let dockerZeroDateString = "0001-01-01T00:00:00Z"

/// Check if a date is Docker's zero date.
private func isZeroDate(_ date: Date) -> Bool {
    // Docker's zero date is year 1, which is before Unix epoch (1970)
    // Any date before 1970 is considered a zero date
    return date.timeIntervalSince1970 < 0
}

/// Custom date decoder for Docker's date format.
private func decodeDockerDate(_ decoder: Decoder) throws -> Date {
    let container = try decoder.singleValueContainer()
    let dateString = try container.decode(String.self)

    // Handle Docker's zero date
    if dateString.hasPrefix("0001-01-01") {
        return Date(timeIntervalSince1970: -62135596800) // Year 1 CE
    }

    // Try ISO8601 with fractional seconds
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: dateString) {
        return date
    }

    // Try without fractional seconds
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: dateString) {
        return date
    }

    throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid date format: \(dateString)"
    )
}
