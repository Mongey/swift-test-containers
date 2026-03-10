import Foundation

/// Configuration for creating an OpenSearch container suitable for testing.
/// Provides defaults for single-node startup, credentials, and health readiness.
public struct OpenSearchContainer: Sendable, Hashable {
    /// Docker image to use for OpenSearch.
    public var image: String

    /// Port for the OpenSearch HTTP API (default: 9200).
    public var port: Int

    /// Username used for OpenSearch authentication.
    public var username: String

    /// Password used for OpenSearch authentication.
    public var password: String

    /// Whether the OpenSearch security plugin is enabled.
    public var securityEnabled: Bool

    /// Additional environment variables to apply to the container.
    public var environment: [String: String]

    /// Custom wait strategy. If nil, defaults to cluster-health HTTP wait.
    public var waitStrategy: WaitStrategy?

    /// Host address used for endpoint helpers (default: 127.0.0.1).
    public var host: String

    /// Default OpenSearch image.
    public static let defaultImage = "opensearchproject/opensearch:2.11.1"

    /// Default OpenSearch HTTP API port.
    public static let defaultPort = 9200

    /// Creates a new OpenSearch container configuration with sensible defaults.
    /// - Parameter image: Docker image to use (default: "opensearchproject/opensearch:2.11.1")
    public init(image: String = OpenSearchContainer.defaultImage) {
        self.image = image
        self.port = OpenSearchContainer.defaultPort
        self.username = "admin"
        self.password = "admin"
        self.securityEnabled = true
        self.environment = [
            "discovery.type": "single-node",
            "OPENSEARCH_JAVA_OPTS": "-Xms512m -Xmx512m",
            "DISABLE_INSTALL_DEMO_CONFIG": "true",
            "plugins.security.ssl.http.enabled": "false",
        ]
        self.waitStrategy = nil
        self.host = "127.0.0.1"
    }

    /// Sets a custom username for OpenSearch authentication.
    /// - Parameter username: Username to use.
    public func withUsername(_ username: String) -> Self {
        var copy = self
        copy.username = username
        return copy
    }

    /// Sets a custom password for OpenSearch authentication.
    /// - Parameter password: Password to use.
    public func withPassword(_ password: String) -> Self {
        var copy = self
        copy.password = password
        return copy
    }

    /// Disables the OpenSearch security plugin.
    public func withSecurityDisabled() -> Self {
        var copy = self
        copy.securityEnabled = false
        return copy
    }

    /// Sets the OpenSearch HTTP API port.
    /// - Parameter port: Port number (default: 9200)
    public func withPort(_ port: Int) -> Self {
        var copy = self
        copy.port = port
        return copy
    }

    /// Sets the host address used for endpoint helpers.
    /// - Parameter host: Host address (default: 127.0.0.1)
    public func withHost(_ host: String) -> Self {
        var copy = self
        copy.host = host
        return copy
    }

    /// Overrides JVM heap settings.
    /// - Parameters:
    ///   - min: Minimum heap size (for example, "256m" or "1g")
    ///   - max: Maximum heap size (for example, "256m" or "1g")
    public func withJvmHeap(min: String, max: String) -> Self {
        var copy = self
        copy.environment["OPENSEARCH_JAVA_OPTS"] = "-Xms\(min) -Xmx\(max)"
        return copy
    }

    /// Adds or overrides OpenSearch environment configuration.
    /// - Parameter configuration: Environment variables to merge.
    public func withConfiguration(_ configuration: [String: String]) -> Self {
        var copy = self
        for (key, value) in configuration {
            copy.environment[key] = value
        }
        return copy
    }

    /// Sets a custom wait strategy for readiness checks.
    /// - Parameter strategy: Wait strategy to use.
    public func waitingFor(_ strategy: WaitStrategy) -> Self {
        var copy = self
        copy.waitStrategy = strategy
        return copy
    }

    /// Converts this OpenSearch configuration to a generic `ContainerRequest`.
    internal func toContainerRequest() -> ContainerRequest {
        var env = environment

        if securityEnabled {
            env.removeValue(forKey: "DISABLE_SECURITY_PLUGIN")

            if shouldSetInitialAdminPassword {
                env["OPENSEARCH_INITIAL_ADMIN_PASSWORD"] = password
            } else {
                env.removeValue(forKey: "OPENSEARCH_INITIAL_ADMIN_PASSWORD")
            }
        } else {
            env["DISABLE_SECURITY_PLUGIN"] = "true"
            env.removeValue(forKey: "OPENSEARCH_INITIAL_ADMIN_PASSWORD")
        }

        var request = ContainerRequest(image: image)
            .withEnvironment(env)
            .withExposedPort(port)
            .withHost(host)

        if let waitStrategy {
            request = request.waitingFor(waitStrategy)
        } else {
            request = request.waitingFor(defaultWaitStrategy())
        }

        return request
    }

    private var shouldSetInitialAdminPassword: Bool {
        Self.requiresInitialAdminPassword(for: image) || password != "admin"
    }

    private func defaultWaitStrategy() -> WaitStrategy {
        var config = HTTPWaitConfig(port: port)
            .withPath("/_cluster/health")
            .withStatusCode(200)
            .withBodyMatcher(.regex(#"\"status\"\s*:\s*\"(yellow|green|red)\""#))
            .withTimeout(.seconds(60))
            .withPollInterval(.milliseconds(500))

        if securityEnabled {
            config = config.withHeader(
                "Authorization",
                Self.basicAuthorizationHeader(username: username, password: password)
            )
        }

        return .http(config)
    }

    private static func basicAuthorizationHeader(username: String, password: String) -> String {
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    private static func requiresInitialAdminPassword(for image: String) -> Bool {
        let version = imageVersion(from: image)

        guard let major = version.major else {
            return true
        }

        if major > 2 {
            return true
        }

        if major < 2 {
            return false
        }

        guard let minor = version.minor else {
            return false
        }

        return minor >= 12
    }

    private static func imageVersion(from image: String) -> (major: Int?, minor: Int?) {
        guard let tag = imageTag(from: image) else {
            return (nil, nil)
        }

        let cleanTag = tag.split(separator: "-").first ?? tag
        let segments = cleanTag.split(separator: ".")

        guard !segments.isEmpty else {
            return (nil, nil)
        }

        let major = leadingInteger(in: segments[0])
        let minor: Int?
        if segments.count > 1 {
            minor = leadingInteger(in: segments[1])
        } else {
            minor = nil
        }

        return (major, minor)
    }

    private static func imageTag(from image: String) -> Substring? {
        let start = image.lastIndex(of: "/")
            .map { image.index(after: $0) }
            ?? image.startIndex

        guard let colon = image[start...].lastIndex(of: ":") else {
            return nil
        }

        let tagStart = image.index(after: colon)
        let tag = image[tagStart...]
        return tag.isEmpty ? nil : tag
    }

    private static func leadingInteger(in value: Substring) -> Int? {
        guard let firstDigit = value.firstIndex(where: { $0.isNumber }) else {
            return nil
        }

        let digits = value[firstDigit...].prefix(while: { $0.isNumber })
        return Int(digits)
    }
}

/// Connection settings for OpenSearch clients.
public struct OpenSearchSettings: Sendable, Hashable {
    /// Base HTTP address, for example "http://127.0.0.1:9200".
    public let address: String

    /// Username when security is enabled; otherwise nil.
    public let username: String?

    /// Password when security is enabled; otherwise nil.
    public let password: String?

    public init(address: String, username: String?, password: String?) {
        self.address = address
        self.username = username
        self.password = password
    }
}

/// A running OpenSearch container with typed accessors.
public struct RunningOpenSearchContainer: Sendable {
    private let container: Container
    private let config: OpenSearchContainer
    private let runtime: any ContainerRuntime

    internal init(container: Container, config: OpenSearchContainer, runtime: any ContainerRuntime) {
        self.container = container
        self.config = config
        self.runtime = runtime
    }

    /// Returns the HTTP address for OpenSearch.
    public func httpAddress() async throws -> String {
        let hostPort = try await container.hostPort(config.port)
        return "http://\(config.host):\(hostPort)"
    }

    /// Returns structured connection settings.
    public func settings() async throws -> OpenSearchSettings {
        let address = try await httpAddress()

        if config.securityEnabled {
            return OpenSearchSettings(
                address: address,
                username: config.username,
                password: config.password
            )
        }

        return OpenSearchSettings(
            address: address,
            username: nil,
            password: nil
        )
    }

    /// Returns the mapped host port for OpenSearch.
    public func port() async throws -> Int {
        try await container.hostPort(config.port)
    }

    /// Returns the configured host.
    public func host() -> String {
        config.host
    }

    /// Retrieves container logs.
    public func logs() async throws -> String {
        try await container.logs()
    }

    /// Executes a command inside the container.
    public func exec(_ command: [String]) async throws -> ExecResult {
        try await runtime.exec(id: container.id, command: command, options: ExecOptions())
    }

    /// Access underlying generic `Container` for advanced operations.
    public var underlyingContainer: Container {
        container
    }
}

/// Creates and starts an OpenSearch container for testing.
/// The container is automatically cleaned up when the operation completes.
public func withOpenSearchContainer<T>(
    _ config: OpenSearchContainer,
    runtime: any ContainerRuntime = DockerClient(),
    operation: @Sendable (RunningOpenSearchContainer) async throws -> T
) async throws -> T {
    let request = config.toContainerRequest()
    return try await withContainer(request, runtime: runtime) { container in
        let openSearch = RunningOpenSearchContainer(container: container, config: config, runtime: runtime)
        return try await operation(openSearch)
    }
}
