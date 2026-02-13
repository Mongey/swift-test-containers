import Foundation

public enum NetworkDriver: String, Sendable, Hashable {
    case bridge
    case host
    case overlay
    case macvlan
    case none
}

public struct IPAMConfig: Sendable, Hashable {
    public var subnet: String?
    public var gateway: String?
    public var ipRange: String?

    public init(subnet: String? = nil, gateway: String? = nil, ipRange: String? = nil) {
        self.subnet = subnet
        self.gateway = gateway
        self.ipRange = ipRange
    }
}

public struct NetworkRequest: Sendable, Hashable {
    public var name: String?
    public var driver: NetworkDriver
    public var options: [String: String]
    public var labels: [String: String]
    public var ipamConfig: IPAMConfig?
    public var enableIPv6: Bool
    public var `internal`: Bool
    public var attachable: Bool

    public init() {
        self.name = nil
        self.driver = .bridge
        self.options = [:]
        self.labels = ["testcontainers.swift": "true"]
        self.ipamConfig = nil
        self.enableIPv6 = false
        self.internal = false
        self.attachable = false
    }

    public func withName(_ name: String) -> Self {
        var copy = self
        copy.name = name
        return copy
    }

    public func withDriver(_ driver: NetworkDriver) -> Self {
        var copy = self
        copy.driver = driver
        return copy
    }

    public func withOption(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.options[key] = value
        return copy
    }

    public func withLabel(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.labels[key] = value
        return copy
    }

    public func withIPAM(_ config: IPAMConfig) -> Self {
        var copy = self
        copy.ipamConfig = config
        return copy
    }

    public func withIPv6(_ enabled: Bool) -> Self {
        var copy = self
        copy.enableIPv6 = enabled
        return copy
    }

    public func asInternal(_ isInternal: Bool) -> Self {
        var copy = self
        copy.internal = isInternal
        return copy
    }

    public func asAttachable(_ attachable: Bool) -> Self {
        var copy = self
        copy.attachable = attachable
        return copy
    }
}
