import Foundation

/// A multi-container stack for coordinated lifecycle management.
public struct ContainerStack: Sendable, Hashable {
    /// Containers keyed by logical stack name.
    public var containers: [String: ContainerRequest]

    /// Dependency map where key is the dependent container name and value is required dependencies.
    public var dependencies: [String: Set<String>]

    /// Per-edge dependency wait strategy overrides.
    /// Keyed by dependent -> dependency -> wait strategy.
    public var dependencyWaitStrategies: [String: [String: DependencyWaitStrategy]]

    /// Shared network configuration for all containers in the stack.
    public var network: NetworkConfig?

    /// Shared named volume configurations.
    public var volumes: [String: VolumeConfig]

    /// Stack-level default environment variables applied to each container.
    public var environment: [String: String]

    /// Stack-level default labels applied to each container.
    public var labels: [String: String]

    public init() {
        self.containers = [:]
        self.dependencies = [:]
        self.dependencyWaitStrategies = [:]
        self.network = NetworkConfig(name: nil, createIfMissing: true)
        self.volumes = [:]
        self.environment = [:]
        self.labels = ["testcontainers.swift.stack": "true"]
    }

    /// Adds or replaces a named container request in the stack.
    public func withContainer(_ name: String, _ request: ContainerRequest) -> Self {
        var copy = self
        copy.containers[name] = request

        for dependency in request.dependencies {
            copy.dependencies[name, default: []].insert(dependency.name)
            copy.dependencyWaitStrategies[name, default: [:]][dependency.name] = dependency.waitStrategy
        }

        return copy
    }

    /// Declares that `dependent` requires `dependsOn` to be started first.
    public func withDependency(_ dependent: String, dependsOn: String) -> Self {
        withDependency(dependent, dependsOn: dependsOn, waitFor: .ready)
    }

    /// Declares that `dependent` requires `dependsOn` to satisfy the provided wait strategy first.
    public func withDependency(
        _ dependent: String,
        dependsOn: String,
        waitFor: DependencyWaitStrategy
    ) -> Self {
        var copy = self
        copy.dependencies[dependent, default: []].insert(dependsOn)
        copy.dependencyWaitStrategies[dependent, default: [:]][dependsOn] = waitFor
        return copy
    }

    /// Declares multiple dependencies for a single dependent container.
    public func withDependencies(_ dependent: String, dependsOn: [String]) -> Self {
        withDependencies(dependent, dependsOn: dependsOn, waitFor: .ready)
    }

    /// Declares multiple dependencies for a single dependent container with a shared wait strategy.
    public func withDependencies(
        _ dependent: String,
        dependsOn: [String],
        waitFor: DependencyWaitStrategy
    ) -> Self {
        var copy = self
        for dependency in dependsOn {
            copy.dependencies[dependent, default: []].insert(dependency)
            copy.dependencyWaitStrategies[dependent, default: [:]][dependency] = waitFor
        }
        return copy
    }

    /// Sets the shared network configuration.
    public func withNetwork(_ config: NetworkConfig) -> Self {
        var copy = self
        copy.network = config
        return copy
    }

    /// Disables stack-level networking.
    public func withoutNetwork() -> Self {
        var copy = self
        copy.network = nil
        return copy
    }

    /// Adds or replaces a shared volume configuration.
    public func withVolume(_ name: String, _ config: VolumeConfig) -> Self {
        var copy = self
        copy.volumes[name] = config
        return copy
    }

    /// Adds stack-level environment variable defaults.
    public func withEnvironment(_ environment: [String: String]) -> Self {
        var copy = self
        for (key, value) in environment {
            copy.environment[key] = value
        }
        return copy
    }

    /// Adds or replaces a stack-level label.
    public func withLabel(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.labels[key] = value
        return copy
    }

    /// Validates stack configuration before execution.
    public func validate() throws {
        for name in containers.keys {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw TestContainersError.invalidInput("Container stack names cannot be empty")
            }
        }

        if let network, !network.createIfMissing {
            let name = network.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == nil || name == "" {
                throw TestContainersError.invalidInput(
                    "Network name must be provided when createIfMissing is false"
                )
            }
        }

        _ = try startupOrder()
    }

    /// Returns container names in dependency startup order.
    public func startupOrder() throws -> [String] {
        try DependencyGraph.topologicalSort(
            containers: Set(containers.keys),
            dependencies: dependencies
        )
    }

    func dependencyWaitStrategy(for dependent: String, dependency: String) -> DependencyWaitStrategy {
        dependencyWaitStrategies[dependent]?[dependency] ?? .ready
    }
}
