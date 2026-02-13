import Foundation

public actor Network {
    public let id: String
    public let name: String
    public let request: NetworkRequest

    private let docker: DockerClient

    init(id: String, name: String, request: NetworkRequest, docker: DockerClient) {
        self.id = id
        self.name = name
        self.request = request
        self.docker = docker
    }

    public func remove() async throws {
        try await docker.removeNetwork(id: id)
    }
}
