import Foundation

public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable("`docker` CLI not found or Docker engine not running.")
    }

    let id = try await docker.runContainer(request)
    let container = Container(id: id, request: request, docker: docker)

    return try await withTaskCancellationHandler {
        do {
            try await container.waitUntilReady()
            let result = try await operation(container)
            try await container.terminate()
            return result
        } catch {
            try? await container.terminate()
            throw error
        }
    } onCancel: {
        Task { try? await container.terminate() }
    }
}
