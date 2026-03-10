import Foundation

/// Protocol defining the interface for container runtimes.
///
/// Both `DockerClient` and `AppleContainerClient` conform to this protocol,
/// allowing users to choose their preferred container runtime.
///
/// - Important: Public APIs that previously accepted a `docker:` argument now
///   use `runtime:` and accept `any ContainerRuntime`.
public protocol ContainerRuntime: Sendable {
    // MARK: - Availability

    func isAvailable() async -> Bool

    // MARK: - Registry

    func authenticateRegistry(_ auth: RegistryAuth, environment: inout [String: String]) async throws

    // MARK: - Images

    func imageExists(_ image: String, platform: String?) async -> Bool
    func pullImage(_ image: String, platform: String?, environment: [String: String], registryAuth: RegistryAuth?) async throws
    func inspectImage(_ image: String, platform: String?) async throws -> ImageInspection
    func buildImage(_ config: ImageFromDockerfile, tag: String) async throws -> String
    func removeImage(_ tag: String) async throws

    // MARK: - Container Lifecycle

    func runContainer(_ request: ContainerRequest) async throws -> String
    func createContainer(_ request: ContainerRequest) async throws -> String
    func startContainer(id: String) async throws
    func stopContainer(id: String, timeout: Duration) async throws
    func removeContainer(id: String) async throws
    func removeContainers(ids: [String], force: Bool) async -> [String: Error?]

    // MARK: - Container Info

    func logs(id: String) async throws -> String
    func logsTail(id: String, lines: Int) async throws -> String
    func streamLogs(id: String, options: LogStreamOptions) -> AsyncThrowingStream<LogEntry, Error>
    func port(id: String, containerPort: Int) async throws -> Int
    func inspect(id: String) async throws -> ContainerInspection
    func healthStatus(id: String) async throws -> ContainerHealthStatus

    // MARK: - Exec

    func exec(id: String, command: [String]) async throws -> Int32
    func exec(id: String, command: [String], options: ExecOptions) async throws -> ExecResult

    // MARK: - Copy

    func copyToContainer(id: String, sourcePath: String, destinationPath: String) async throws
    func copyDataToContainer(id: String, data: Data, destinationPath: String) async throws
    func copyFromContainer(id: String, containerPath: String, hostPath: String, archive: Bool) async throws

    // MARK: - Networks

    func createNetwork(name: String, driver: String, internal: Bool) async throws -> String
    func createNetwork(_ request: NetworkRequest) async throws -> (id: String, name: String)
    func removeNetwork(id: String) async throws
    func connectToNetwork(containerId: String, networkName: String, aliases: [String], ipv4Address: String?, ipv6Address: String?) async throws
    func networkExists(_ nameOrID: String) async throws -> Bool

    // MARK: - Volumes

    func createVolume(name: String, config: VolumeConfig) async throws -> String
    func removeVolume(name: String) async throws

    // MARK: - Listing

    func listContainers(labels: [String: String]) async throws -> [ContainerListItem]
    func findReusableContainer(hash: String) async throws -> ContainerListItem?
}

/// Default parameter values for protocol methods.
public extension ContainerRuntime {
    func imageExists(_ image: String) async -> Bool {
        await imageExists(image, platform: nil)
    }

    func pullImage(_ image: String, platform: String? = nil, environment: [String: String] = [:], registryAuth: RegistryAuth? = nil) async throws {
        try await pullImage(image, platform: platform, environment: environment, registryAuth: registryAuth)
    }

    func inspectImage(_ image: String) async throws -> ImageInspection {
        try await inspectImage(image, platform: nil)
    }

    func removeContainers(ids: [String]) async -> [String: Error?] {
        await removeContainers(ids: ids, force: true)
    }

    func createNetwork(name: String, driver: String = "bridge", internal: Bool = false) async throws -> String {
        try await createNetwork(name: name, driver: driver, internal: `internal`)
    }

    func connectToNetwork(containerId: String, networkName: String, aliases: [String] = []) async throws {
        try await connectToNetwork(containerId: containerId, networkName: networkName, aliases: aliases, ipv4Address: nil, ipv6Address: nil)
    }

    func createVolume(name: String) async throws -> String {
        try await createVolume(name: name, config: VolumeConfig())
    }

    func listContainers() async throws -> [ContainerListItem] {
        try await listContainers(labels: [:])
    }
}
