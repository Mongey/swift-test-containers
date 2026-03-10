import Foundation

public actor Network {
    public let id: String
    public let name: String
    public let request: NetworkRequest

    private let runtime: any ContainerRuntime

    init(id: String, name: String, request: NetworkRequest, runtime: any ContainerRuntime) {
        self.id = id
        self.name = name
        self.request = request
        self.runtime = runtime
    }

    public func remove() async throws {
        try await runtime.removeNetwork(id: id)
    }
}
