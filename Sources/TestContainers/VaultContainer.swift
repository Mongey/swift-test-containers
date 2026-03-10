import Foundation

/// Configuration for creating a HashiCorp Vault container suitable for testing.
/// Provides a convenient API for Vault container configuration with dev mode defaults.
///
/// Example:
/// ```swift
/// let request = VaultContainerRequest()
///     .withRootToken("my-token")
///     .withSecret("secret/myapp", ["api-key": "test123"])
///
/// try await withVaultContainer(request) { vault in
///     let address = try await vault.httpHostAddress()
///     // Use Vault HTTP API
/// }
/// ```
public struct VaultContainerRequest: Sendable, Hashable {
    /// Docker image to use for the Vault container.
    public var image: String

    /// Port for Vault HTTP API (default: 8200).
    public var vaultPort: Int

    /// Root token for Vault authentication.
    public var rootToken: String

    /// Commands to execute after Vault starts (using vault CLI).
    public var initCommands: [String]

    /// Additional environment variables for the container.
    public var environment: [String: String]

    /// Custom wait strategy. If nil, defaults to HTTP health check.
    public var waitStrategy: WaitStrategy?

    /// Host address for connecting to the container.
    public var host: String

    /// Creates a new Vault container request with default configuration.
    /// - Parameter image: Docker image to use (default: "hashicorp/vault:latest")
    public init(image: String = "hashicorp/vault:latest") {
        self.image = image
        self.vaultPort = 8200
        self.rootToken = UUID().uuidString
        self.initCommands = []
        self.environment = [:]
        self.waitStrategy = nil
        self.host = "127.0.0.1"
    }

    /// Sets the Vault HTTP API port.
    /// - Parameter port: Port number (default: 8200)
    public func withVaultPort(_ port: Int) -> Self {
        var copy = self
        copy.vaultPort = port
        return copy
    }

    /// Sets the root token for Vault authentication.
    /// - Parameter token: Root token string
    public func withRootToken(_ token: String) -> Self {
        var copy = self
        copy.rootToken = token
        return copy
    }

    /// Adds an initialization command to execute after Vault starts.
    /// Commands are executed using `vault` CLI inside the container.
    /// - Parameter command: Vault CLI command (without "vault" prefix)
    /// - Returns: Updated request
    /// - Example: `.withInitCommand("secrets enable transit")`
    public func withInitCommand(_ command: String) -> Self {
        var copy = self
        copy.initCommands.append(command)
        return copy
    }

    /// Adds multiple initialization commands to execute after Vault starts.
    /// - Parameter commands: Array of Vault CLI commands
    public func withInitCommands(_ commands: [String]) -> Self {
        var copy = self
        copy.initCommands.append(contentsOf: commands)
        return copy
    }

    /// Adds a secret to the KV secret engine at the specified path.
    /// - Parameters:
    ///   - path: Secret path (e.g., "secret/myapp")
    ///   - secrets: Key-value pairs to store
    /// - Returns: Updated request
    /// - Example: `.withSecret("secret/myapp", ["api-key": "test123"])`
    public func withSecret(_ path: String, _ secrets: [String: String]) -> Self {
        var copy = self
        let secretPairs = secrets.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let command = "kv put \(path) \(secretPairs)"
        copy.initCommands.append(command)
        return copy
    }

    /// Sets environment variables for the container.
    /// - Parameter environment: Dictionary of environment variables
    public func withEnvironment(_ environment: [String: String]) -> Self {
        var copy = self
        for (key, value) in environment {
            copy.environment[key] = value
        }
        return copy
    }

    /// Sets the wait strategy for container readiness.
    /// If not specified, defaults to HTTP health check on /v1/sys/health
    /// - Parameter strategy: Wait strategy to use
    public func withWaitStrategy(_ strategy: WaitStrategy) -> Self {
        var copy = self
        copy.waitStrategy = strategy
        return copy
    }

    /// Sets the host address for connecting to the container.
    /// - Parameter host: Host address (default: "127.0.0.1")
    public func withHost(_ host: String) -> Self {
        var copy = self
        copy.host = host
        return copy
    }

    /// Converts this Vault-specific request to a generic ContainerRequest.
    /// Sets up dev mode, port exposure, and wait strategy.
    internal func toContainerRequest() -> ContainerRequest {
        var env = self.environment

        // Configure dev mode
        env["VAULT_DEV_ROOT_TOKEN_ID"] = rootToken
        env["VAULT_DEV_LISTEN_ADDRESS"] = "0.0.0.0:\(vaultPort)"

        var request = ContainerRequest(image: image)
            .withEnvironment(env)
            .withExposedPort(vaultPort)
            .withHost(host)

        // Apply wait strategy (default or custom)
        if let waitStrategy = waitStrategy {
            request = request.waitingFor(waitStrategy)
        } else {
            // Default: wait for Vault HTTP API health endpoint
            let healthConfig = HTTPWaitConfig(port: vaultPort)
                .withPath("/v1/sys/health")
                .withStatusCode(200)
                .withTimeout(.seconds(60))
            request = request.waitingFor(.http(healthConfig))
        }

        return request
    }
}

/// A container running HashiCorp Vault configured for testing.
/// Provides convenient access to Vault's HTTP API and configuration.
public actor VaultContainer {
    private let container: Container
    private let config: VaultContainerRequest
    private let runtime: any ContainerRuntime
    private let hostAddress: String

    internal init(container: Container, config: VaultContainerRequest, runtime: any ContainerRuntime) {
        self.container = container
        self.config = config
        self.runtime = runtime
        self.hostAddress = config.host
    }

    /// The container ID.
    public var id: String {
        get async {
            container.id
        }
    }

    /// Returns the HTTP host address for accessing Vault API.
    /// - Returns: Full HTTP URL (e.g., "http://127.0.0.1:54321")
    public func httpHostAddress() async throws -> String {
        let endpoint = try await container.endpoint(for: config.vaultPort)
        return "http://\(endpoint)"
    }

    /// Returns the mapped host port for the Vault HTTP API.
    /// - Returns: Host port number
    public func hostPort() async throws -> Int {
        try await container.hostPort(config.vaultPort)
    }

    /// Returns the host address.
    /// - Returns: Host IP or hostname
    nonisolated public func host() -> String {
        hostAddress
    }

    /// Returns the root token configured for this Vault instance.
    /// Use this token for authenticating API requests.
    /// - Returns: Root token string
    nonisolated public func rootToken() -> String {
        config.rootToken
    }

    /// Retrieves container logs.
    /// - Returns: Container log output
    public func logs() async throws -> String {
        try await container.logs()
    }

    /// Terminates and removes the container.
    public func terminate() async throws {
        try await container.terminate()
    }

    /// Executes a Vault CLI command inside the container.
    /// - Parameter command: Vault CLI command (without "vault" prefix)
    /// - Returns: Exit code from the command
    internal func execVaultCommand(_ command: String) async throws -> Int32 {
        let containerId = container.id
        let fullCommand = ["vault"] + command.split(separator: " ").map(String.init)

        // Set Vault CLI environment variables for authentication
        let options = ExecOptions(
            environment: [
                "VAULT_ADDR": "http://127.0.0.1:\(config.vaultPort)",
                "VAULT_TOKEN": config.rootToken
            ]
        )

        let result = try await runtime.exec(id: containerId, command: fullCommand, options: options)
        return result.exitCode
    }
}

/// Creates and starts a Vault container for testing.
/// The container is automatically cleaned up when the operation completes.
///
/// - Parameters:
///   - request: Vault container configuration
///   - docker: Docker client instance (default: shared client)
///   - operation: Async operation to perform with the running container
/// - Returns: Result of the operation
/// - Throws: Docker errors or operation errors
///
/// Example:
/// ```swift
/// let vaultRequest = VaultContainerRequest()
///     .withRootToken("mytoken")
///     .withSecret("secret/myapp", ["api-key": "test123"])
///
/// try await withVaultContainer(vaultRequest) { vault in
///     let address = try await vault.httpHostAddress()
///     let token = vault.rootToken()
///     // Make API calls to Vault
/// }
/// ```
public func withVaultContainer<T>(
    _ request: VaultContainerRequest,
    runtime: any ContainerRuntime = DockerClient(),
    operation: @Sendable (VaultContainer) async throws -> T
) async throws -> T {
    let containerRequest = request.toContainerRequest()
    return try await withContainer(containerRequest, runtime: runtime) { container in
        let vaultContainer = VaultContainer(container: container, config: request, runtime: runtime)

        // Execute init commands if any
        if !request.initCommands.isEmpty {
            for command in request.initCommands {
                let exitCode = try await vaultContainer.execVaultCommand(command)
                if exitCode != 0 {
                    throw TestContainersError.commandFailed(
                        command: ["vault"] + command.split(separator: " ").map(String.init),
                        exitCode: exitCode,
                        stdout: "",
                        stderr: "Init command failed with exit code \(exitCode)"
                    )
                }
            }
        }

        return try await operation(vaultContainer)
    }
}
