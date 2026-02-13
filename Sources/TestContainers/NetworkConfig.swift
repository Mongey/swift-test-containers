import Foundation

/// Network configuration for multi-container stacks.
public struct NetworkConfig: Sendable, Hashable {
    /// Network name. If nil and `createIfMissing` is true, a unique name is generated.
    public var name: String?

    /// Docker network driver (for example, `bridge`, `overlay`, `macvlan`).
    public var driver: String

    /// If true, the stack creates the network when it starts.
    /// If false, `name` must reference an existing network.
    public var createIfMissing: Bool

    /// If true, creates an internal network (`docker network create --internal`).
    public var `internal`: Bool

    public init(name: String? = nil, createIfMissing: Bool = true) {
        self.name = name
        self.driver = "bridge"
        self.createIfMissing = createIfMissing
        self.internal = false
    }

    public func withName(_ name: String) -> Self {
        var copy = self
        copy.name = name
        return copy
    }

    public func withDriver(_ driver: String) -> Self {
        var copy = self
        copy.driver = driver
        return copy
    }

    public func withInternal(_ internal: Bool) -> Self {
        var copy = self
        copy.internal = `internal`
        return copy
    }

    public func withCreateIfMissing(_ createIfMissing: Bool) -> Self {
        var copy = self
        copy.createIfMissing = createIfMissing
        return copy
    }
}

/// Shared named volume configuration for multi-container stacks.
public struct VolumeConfig: Sendable, Hashable {
    /// Docker volume driver.
    public var driver: String

    /// Driver options passed during volume creation.
    public var options: [String: String]

    public init(driver: String = "local") {
        self.driver = driver
        self.options = [:]
    }

    public func withDriver(_ driver: String) -> Self {
        var copy = self
        copy.driver = driver
        return copy
    }

    public func withOption(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.options[key] = value
        return copy
    }
}
