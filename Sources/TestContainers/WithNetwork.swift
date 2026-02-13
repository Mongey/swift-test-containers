import Foundation

public func withNetwork<T>(
    _ request: NetworkRequest = NetworkRequest(),
    docker: DockerClient = DockerClient(),
    logger: TCLogger = .null,
    operation: @Sendable (Network) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable(
            "`docker` CLI not found or Docker engine not running."
        )
    }

    let (id, name) = try await docker.createNetwork(request)
    let network = Network(id: id, name: name, request: request, docker: docker)

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
