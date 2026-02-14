#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

struct ReuseLabels {
    static let enabled = "testcontainers.swift.reuse"
    static let hash = "testcontainers.swift.reuse.hash"
    static let version = "testcontainers.swift.reuse.version"
    static let versionValue = "1"
}

public struct ReuseConfig: Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    public static let enabled = ReuseConfig(enabled: true)
    public static let disabled = ReuseConfig(enabled: false)

    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        propertiesFilePath: String? = nil,
        fileManager: FileManager = .default
    ) -> Self {
        if parseEnabled(environment["TESTCONTAINERS_REUSE_ENABLE"]) {
            return .enabled
        }

        let path = propertiesFilePath ?? defaultPropertiesFilePath()
        guard fileManager.fileExists(atPath: path) else {
            return .disabled
        }

        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .disabled
        }

        let properties = parseProperties(contents)
        if parseEnabled(properties["testcontainers.reuse.enable"]) {
            return .enabled
        }

        return .disabled
    }

    static func defaultPropertiesFilePath(homeDirectoryPath: String = NSHomeDirectory()) -> String {
        let home = homeDirectoryPath.isEmpty ? NSHomeDirectory() : homeDirectoryPath
        return URL(fileURLWithPath: home).appendingPathComponent(".testcontainers.properties").path
    }

    static func parseEnabled(_ rawValue: String?) -> Bool {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return value == "true" || value == "1"
    }

    static func parseProperties(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") {
                continue
            }

            if let separatorIndex = line.firstIndex(where: { $0 == "=" || $0 == ":" }) {
                let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespaces)
                result[key] = value
            }
        }

        return result
    }
}

enum ReuseFingerprint {
    static func hash(for request: ContainerRequest) -> String {
        let payload = ReuseFingerprintV1(request: request)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            // Fallback to deterministic UTF-8 content if encoding unexpectedly fails.
            data = Data("{}".utf8)
        }

        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct ReuseFingerprintV1: Codable {
        let image: String
        let command: [String]
        let entrypoint: [String]?
        let environment: [KeyValuePair]
        let ports: [PortValue]
        let volumes: [VolumeValue]
        let bindMounts: [BindMountValue]
        let tmpfsMounts: [TmpfsValue]
        let workingDirectory: String?
        let privileged: Bool
        let capabilitiesToAdd: [String]
        let capabilitiesToDrop: [String]
        let waitStrategy: WaitStrategyValue
        let healthCheck: HealthCheckValue?
        let host: String
        let labels: [KeyValuePair]

        init(request: ContainerRequest) {
            image = request.image
            command = request.command
            entrypoint = request.entrypoint
            environment = Self.keyValuePairs(from: request.environment)
            ports = request.ports
                .map { PortValue(containerPort: $0.containerPort, hostPort: $0.hostPort) }
                .sorted { lhs, rhs in
                    if lhs.containerPort == rhs.containerPort {
                        return (lhs.hostPort ?? -1) < (rhs.hostPort ?? -1)
                    }
                    return lhs.containerPort < rhs.containerPort
                }
            volumes = request.volumes
                .map { VolumeValue(volumeName: $0.volumeName, containerPath: $0.containerPath, readOnly: $0.readOnly) }
                .sorted { lhs, rhs in
                    if lhs.volumeName == rhs.volumeName {
                        return lhs.containerPath < rhs.containerPath
                    }
                    return lhs.volumeName < rhs.volumeName
                }
            bindMounts = request.bindMounts
                .map {
                    BindMountValue(
                        hostPath: $0.hostPath,
                        containerPath: $0.containerPath,
                        readOnly: $0.readOnly,
                        consistency: $0.consistency.rawValue
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.hostPath == rhs.hostPath {
                        return lhs.containerPath < rhs.containerPath
                    }
                    return lhs.hostPath < rhs.hostPath
                }
            tmpfsMounts = request.tmpfsMounts
                .map { TmpfsValue(containerPath: $0.containerPath, sizeLimit: $0.sizeLimit, mode: $0.mode) }
                .sorted { lhs, rhs in lhs.containerPath < rhs.containerPath }
            workingDirectory = request.workingDirectory
            privileged = request.privileged
            capabilitiesToAdd = request.capabilitiesToAdd.map(\.rawValue).sorted()
            capabilitiesToDrop = request.capabilitiesToDrop.map(\.rawValue).sorted()
            waitStrategy = WaitStrategyValue(request.waitStrategy)
            healthCheck = request.healthCheck.map(HealthCheckValue.init)
            host = request.host
            labels = Self.keyValuePairs(from: request.labels.filter { !Self.isVolatileLabel($0.key) })
        }

        private static func keyValuePairs(from values: [String: String]) -> [KeyValuePair] {
            values
                .map { KeyValuePair(key: $0.key, value: $0.value) }
                .sorted { lhs, rhs in lhs.key < rhs.key }
        }

        private static func isVolatileLabel(_ key: String) -> Bool {
            if key.hasPrefix("testcontainers.swift.session.") {
                return true
            }

            switch key {
            case ReuseLabels.enabled, ReuseLabels.hash, ReuseLabels.version:
                return true
            default:
                return false
            }
        }
    }

    private struct KeyValuePair: Codable {
        let key: String
        let value: String
    }

    private struct PortValue: Codable {
        let containerPort: Int
        let hostPort: Int?
    }

    private struct VolumeValue: Codable {
        let volumeName: String
        let containerPath: String
        let readOnly: Bool
    }

    private struct BindMountValue: Codable {
        let hostPath: String
        let containerPath: String
        let readOnly: Bool
        let consistency: String
    }

    private struct TmpfsValue: Codable {
        let containerPath: String
        let sizeLimit: String?
        let mode: String?
    }

    private struct HealthCheckValue: Codable {
        let command: [String]
        let intervalNanos: Int64?
        let timeoutNanos: Int64?
        let startPeriodNanos: Int64?
        let retries: Int?

        init(_ value: HealthCheckConfig) {
            command = value.command
            intervalNanos = value.interval.map(durationToNanoseconds)
            timeoutNanos = value.timeout.map(durationToNanoseconds)
            startPeriodNanos = value.startPeriod.map(durationToNanoseconds)
            retries = value.retries
        }
    }

    private indirect enum WaitStrategyValue: Codable {
        case none
        case tcpPort(port: Int, timeoutNanos: Int64, pollIntervalNanos: Int64)
        case logContains(needle: String, timeoutNanos: Int64, pollIntervalNanos: Int64)
        case logMatches(pattern: String, timeoutNanos: Int64, pollIntervalNanos: Int64)
        case http(HTTPWaitValue)
        case exec(command: [String], timeoutNanos: Int64, pollIntervalNanos: Int64)
        case healthCheck(timeoutNanos: Int64, pollIntervalNanos: Int64)
        case all(strategies: [WaitStrategyValue], timeoutNanos: Int64?)
        case any(strategies: [WaitStrategyValue], timeoutNanos: Int64?)

        init(_ strategy: WaitStrategy) {
            switch strategy {
            case .none:
                self = .none
            case let .tcpPort(port, timeout, pollInterval):
                self = .tcpPort(
                    port: port,
                    timeoutNanos: durationToNanoseconds(timeout),
                    pollIntervalNanos: durationToNanoseconds(pollInterval)
                )
            case let .logContains(needle, timeout, pollInterval):
                self = .logContains(
                    needle: needle,
                    timeoutNanos: durationToNanoseconds(timeout),
                    pollIntervalNanos: durationToNanoseconds(pollInterval)
                )
            case let .logMatches(pattern, timeout, pollInterval):
                self = .logMatches(
                    pattern: pattern,
                    timeoutNanos: durationToNanoseconds(timeout),
                    pollIntervalNanos: durationToNanoseconds(pollInterval)
                )
            case let .http(config):
                self = .http(HTTPWaitValue(config))
            case let .exec(command, timeout, pollInterval):
                self = .exec(
                    command: command,
                    timeoutNanos: durationToNanoseconds(timeout),
                    pollIntervalNanos: durationToNanoseconds(pollInterval)
                )
            case let .healthCheck(timeout, pollInterval):
                self = .healthCheck(
                    timeoutNanos: durationToNanoseconds(timeout),
                    pollIntervalNanos: durationToNanoseconds(pollInterval)
                )
            case let .all(strategies, timeout):
                self = .all(
                    strategies: strategies.map(WaitStrategyValue.init),
                    timeoutNanos: timeout.map(durationToNanoseconds)
                )
            case let .any(strategies, timeout):
                self = .any(
                    strategies: strategies.map(WaitStrategyValue.init),
                    timeoutNanos: timeout.map(durationToNanoseconds)
                )
            }
        }
    }

    private struct HTTPWaitValue: Codable {
        let port: Int
        let path: String
        let method: String
        let statusMatcher: StatusCodeMatcherValue
        let bodyMatcher: BodyMatcherValue?
        let headers: [KeyValuePair]
        let useTLS: Bool
        let allowInsecureTLS: Bool
        let timeoutNanos: Int64
        let pollIntervalNanos: Int64
        let requestTimeoutNanos: Int64

        init(_ config: HTTPWaitConfig) {
            port = config.port
            path = config.path
            method = config.method.rawValue
            statusMatcher = StatusCodeMatcherValue(config.statusCodeMatcher)
            bodyMatcher = config.bodyMatcher.map(BodyMatcherValue.init)
            headers = config.headers
                .map { KeyValuePair(key: $0.key, value: $0.value) }
                .sorted { lhs, rhs in lhs.key < rhs.key }
            useTLS = config.useTLS
            allowInsecureTLS = config.allowInsecureTLS
            timeoutNanos = durationToNanoseconds(config.timeout)
            pollIntervalNanos = durationToNanoseconds(config.pollInterval)
            requestTimeoutNanos = durationToNanoseconds(config.requestTimeout)
        }
    }

    private enum StatusCodeMatcherValue: Codable {
        case exact(Int)
        case range(Int, Int)
        case anyOf([Int])

        init(_ matcher: StatusCodeMatcher) {
            switch matcher {
            case let .exact(value):
                self = .exact(value)
            case let .range(range):
                self = .range(range.lowerBound, range.upperBound)
            case let .anyOf(values):
                self = .anyOf(values.sorted())
            }
        }
    }

    private enum BodyMatcherValue: Codable {
        case contains(String)
        case regex(String)

        init(_ matcher: BodyMatcher) {
            switch matcher {
            case let .contains(value):
                self = .contains(value)
            case let .regex(value):
                self = .regex(value)
            }
        }
    }

    private static func durationToNanoseconds(_ duration: Duration) -> Int64 {
        let seconds = duration.components.seconds
        let nanoseconds = duration.components.attoseconds / 1_000_000_000
        return (seconds * 1_000_000_000) + nanoseconds
    }
}

extension ContainerRequest {
    func withReuseLabels(hash: String) -> Self {
        var copy = self
        copy.labels[ReuseLabels.enabled] = "true"
        copy.labels[ReuseLabels.hash] = hash
        copy.labels[ReuseLabels.version] = ReuseLabels.versionValue
        return copy
    }
}
