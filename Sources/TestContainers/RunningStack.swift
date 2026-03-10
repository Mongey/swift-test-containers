import Foundation

struct StackNetworkInfo: Sendable, Hashable {
    let name: String
    let id: String
    let removeOnTermination: Bool
}

/// Tracks a Docker volume created for a stack.
public struct StackVolumeInfo: Sendable, Hashable {
    public let name: String
    public let removeOnTermination: Bool

    public init(name: String, removeOnTermination: Bool) {
        self.name = name
        self.removeOnTermination = removeOnTermination
    }
}

/// A running multi-container stack with access to individual containers.
public actor RunningStack {
    public nonisolated let stackId: String

    private let containers: [String: Container]
    private let network: StackNetworkInfo?
    private let volumes: [StackVolumeInfo]
    private let shutdownOrder: [String]
    private let runtime: any ContainerRuntime
    private var terminated = false

    init(
        stackId: String,
        containers: [String: Container],
        network: StackNetworkInfo?,
        volumes: [StackVolumeInfo],
        shutdownOrder: [String],
        runtime: any ContainerRuntime
    ) {
        self.stackId = stackId
        self.containers = containers
        self.network = network
        self.volumes = volumes
        self.shutdownOrder = shutdownOrder
        self.runtime = runtime
    }

    /// Returns a container by stack name.
    public func container(_ name: String) throws -> Container {
        guard let container = containers[name] else {
            throw TestContainersError.containerNotFound(
                name,
                availableContainers: containers.keys.sorted()
            )
        }

        return container
    }

    /// Returns all running containers keyed by stack name.
    public func allContainers() -> [String: Container] {
        containers
    }

    /// Returns all container names in sorted order.
    public func containerNames() -> [String] {
        containers.keys.sorted()
    }

    /// Returns the shared stack network name, if configured.
    public func networkName() -> String? {
        network?.name
    }

    /// Returns the names of shared volumes created for this stack.
    public func volumeNames() -> [String] {
        volumes.map(\.name)
    }

    /// Terminates all containers in reverse dependency order.
    public func terminate() async throws {
        guard !terminated else { return }
        terminated = true

        var firstError: Error?

        for name in shutdownOrder {
            guard let container = containers[name] else { continue }
            do {
                try await container.terminate()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let network, network.removeOnTermination {
            do {
                try await runtime.removeNetwork(id: network.id)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        for volume in volumes where volume.removeOnTermination {
            do {
                try await runtime.removeVolume(name: volume.name)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            throw firstError
        }
    }
}
