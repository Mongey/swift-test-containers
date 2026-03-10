import Foundation

/// Create a scoped network with automatic cleanup.
///
/// - Important: In the runtime abstraction release, the `docker:` parameter was
///   renamed to `runtime:`.
public func withNetwork<T>(
    _ request: NetworkRequest = NetworkRequest(),
    runtime: any ContainerRuntime = DockerClient(),
    logger: TCLogger = .null,
    operation: @Sendable (Network) async throws -> T
) async throws -> T {
    if !(await runtime.isAvailable()) {
        throw TestContainersError.dockerNotAvailable(
            "`docker` CLI not found or Docker engine not running."
        )
    }

    let (id, name) = try await runtime.createNetwork(request)
    let network = Network(id: id, name: name, request: request, runtime: runtime)

    return try await withTaskCancellationHandler {
        do {
            let result = try await operation(network)
            try await network.remove()
            return result
        } catch {
            try? await network.remove()
            throw error
        }
    } onCancel: {
        Task { try? await network.remove() }
    }
}
