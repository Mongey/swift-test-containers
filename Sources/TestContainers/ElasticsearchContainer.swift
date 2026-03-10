import Foundation

/// Configuration for creating an Elasticsearch container suitable for testing.
/// Provides a typed API for security defaults, cluster configuration, and health readiness.
public struct ElasticsearchContainer: Sendable, Hashable {
    /// Docker image to use for Elasticsearch.
    public var image: String

    /// Port for the Elasticsearch HTTP API (default: 9200).
    public var port: Int

    /// Username used when security is enabled.
    public var username: String

    /// Password used when security is enabled.
    public var password: String

    /// Whether Elasticsearch security features are enabled.
    public var securityEnabled: Bool

    /// Additional environment variables to apply to the container.
    public var environment: [String: String]

    /// Custom wait strategy. If nil, defaults to cluster-health HTTP wait.
    public var waitStrategy: WaitStrategy?

    /// Host address used for endpoint helpers (default: 127.0.0.1).
    public var host: String

    /// Default Elasticsearch image.
    public static let defaultImage = "elasticsearch:8.11.0"

    /// Default Elasticsearch HTTP API port.
    public static let defaultPort = 9200

    static let defaultCACertificatePath = "/usr/share/elasticsearch/config/certs/http_ca.crt"

    /// Creates a new Elasticsearch container configuration with sensible defaults.
    ///
    /// Version-aware security behavior:
    /// - 8.x and later: security enabled by default with password "changeme"
    /// - 7.x: security disabled by default
    ///
    /// - Parameter image: Docker image to use (default: "elasticsearch:8.11.0")
    public init(image: String = ElasticsearchContainer.defaultImage) {
        self.image = image
        self.port = ElasticsearchContainer.defaultPort
        self.username = "elastic"
        self.password = "changeme"
        self.securityEnabled = Self.defaultSecurityEnabled(for: image)
        self.environment = [
            "discovery.type": "single-node",
            "ES_JAVA_OPTS": "-Xms512m -Xmx512m",
        ]
        self.waitStrategy = nil
        self.host = "127.0.0.1"
    }

    /// Sets a custom password and enables security.
    /// - Parameter password: Password for the `elastic` user.
    public func withPassword(_ password: String) -> Self {
        var copy = self
        copy.password = password
        copy.securityEnabled = true
        return copy
    }

    /// Disables Elasticsearch security.
    public func withSecurityDisabled() -> Self {
        var copy = self
        copy.securityEnabled = false
        return copy
    }

    /// Sets the Elasticsearch HTTP API port.
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
        copy.environment["ES_JAVA_OPTS"] = "-Xms\(min) -Xmx\(max)"
        return copy
    }

    /// Adds or overrides Elasticsearch environment configuration.
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

    /// Converts this Elasticsearch configuration to a generic `ContainerRequest`.
    internal func toContainerRequest() -> ContainerRequest {
        var env = environment

        if securityEnabled {
            env["xpack.security.enabled"] = "true"
            env["ELASTIC_PASSWORD"] = password
        } else {
            env["xpack.security.enabled"] = "false"
            env.removeValue(forKey: "ELASTIC_PASSWORD")
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

    var usesTLS: Bool {
        guard securityEnabled else { return false }
        guard let major = Self.majorVersion(from: image) else { return true }
        return major >= 8
    }

    var shouldExposeCACertificate: Bool {
        securityEnabled && usesTLS
    }

    private func defaultWaitStrategy() -> WaitStrategy {
        var config = HTTPWaitConfig(port: port)
            .withPath("/_cluster/health")
            .withStatusCode(200)
            .withBodyMatcher(.regex(#"\"status\"\s*:\s*\"(yellow|green)\""#))
            .withTimeout(.seconds(60))
            .withPollInterval(.milliseconds(500))

        if securityEnabled {
            config = config.withHeader(
                "Authorization",
                Self.basicAuthorizationHeader(username: username, password: password)
            )
        }

        if usesTLS {
            config = config.withTLS(allowInsecure: true)
        }

        return .http(config)
    }

    private static func basicAuthorizationHeader(username: String, password: String) -> String {
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    private static func defaultSecurityEnabled(for image: String) -> Bool {
        guard let major = majorVersion(from: image) else {
            return true
        }
        return major >= 8
    }

    private static func majorVersion(from image: String) -> Int? {
        guard let tag = imageTag(from: image) else {
            return nil
        }
        return leadingInteger(in: tag)
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

/// Connection settings for Elasticsearch clients.
public struct ElasticsearchSettings: Sendable, Hashable {
    /// Base HTTP(S) address, for example "https://127.0.0.1:9200".
    public let address: String

    /// Username when security is enabled; otherwise nil.
    public let username: String?

    /// Password when security is enabled; otherwise nil.
    public let password: String?

    /// CA certificate bytes for TLS-enabled Elasticsearch (8.x+), if available.
    public let caCert: Data?

    public init(address: String, username: String?, password: String?, caCert: Data?) {
        self.address = address
        self.username = username
        self.password = password
        self.caCert = caCert
    }
}

/// A running Elasticsearch container with typed accessors.
public struct RunningElasticsearchContainer: Sendable {
    private let container: Container
    private let config: ElasticsearchContainer
    private let runtime: any ContainerRuntime

    internal init(container: Container, config: ElasticsearchContainer, runtime: any ContainerRuntime) {
        self.container = container
        self.config = config
        self.runtime = runtime
    }

    /// Returns the HTTP(S) address for Elasticsearch.
    public func httpAddress() async throws -> String {
        let hostPort = try await container.hostPort(config.port)
        let scheme = config.usesTLS ? "https" : "http"
        return "\(scheme)://\(config.host):\(hostPort)"
    }

    /// Returns structured connection settings.
    public func settings() async throws -> ElasticsearchSettings {
        let address = try await httpAddress()
        let caCert = try await caCertificate()

        if config.securityEnabled {
            return ElasticsearchSettings(
                address: address,
                username: config.username,
                password: config.password,
                caCert: caCert
            )
        }

        return ElasticsearchSettings(
            address: address,
            username: nil,
            password: nil,
            caCert: nil
        )
    }

    /// Returns the mapped host port for Elasticsearch.
    public func port() async throws -> Int {
        try await container.hostPort(config.port)
    }

    /// Returns the configured host.
    public func host() -> String {
        config.host
    }

    /// Returns the configured username when security is enabled.
    public func username() -> String? {
        config.securityEnabled ? config.username : nil
    }

    /// Returns the configured password when security is enabled.
    public func password() -> String? {
        config.securityEnabled ? config.password : nil
    }

    /// Attempts to read the Elasticsearch CA certificate for TLS-enabled 8.x images.
    public func caCertificate() async throws -> Data? {
        guard config.shouldExposeCACertificate else {
            return nil
        }

        do {
            return try await container.copyFileToData(ElasticsearchContainer.defaultCACertificatePath)
        } catch {
            return nil
        }
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

/// Creates and starts an Elasticsearch container for testing.
/// The container is automatically cleaned up when the operation completes.
public func withElasticsearchContainer<T>(
    _ config: ElasticsearchContainer,
    runtime: any ContainerRuntime = DockerClient(),
    operation: @Sendable (RunningElasticsearchContainer) async throws -> T
) async throws -> T {
    let request = config.toContainerRequest()
    return try await withContainer(request, runtime: runtime) { container in
        let elasticsearch = RunningElasticsearchContainer(container: container, config: config, runtime: runtime)
        return try await operation(elasticsearch)
    }
}
