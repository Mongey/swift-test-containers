import Foundation

/// Pre-configured Nginx container for integration testing.
/// Provides a convenient API for running Nginx containers with sensible defaults,
/// static file serving, and custom configuration support.
///
/// Example:
/// ```swift
/// let nginx = NginxContainer()
///     .withStaticFiles(from: "/path/to/html")
///
/// try await nginx.run { container in
///     let url = try await container.url()
///     // Make HTTP requests to Nginx
/// }
/// ```
public struct NginxContainer: Sendable {
    /// The underlying container request configuration.
    public var request: ContainerRequest

    /// Default Nginx image (nginx:alpine - small, secure, maintained).
    public static let defaultImage = "nginx:alpine"

    /// Default Nginx HTTP port.
    public static let defaultPort = 80

    /// Default document root in Nginx containers.
    public static let defaultDocumentRoot = "/usr/share/nginx/html"

    /// Creates a new NginxContainer with default configuration.
    /// - Parameter image: Docker image (default: nginx:alpine)
    public init(image: String = NginxContainer.defaultImage) {
        let httpConfig = HTTPWaitConfig(port: NginxContainer.defaultPort)
            .withPath("/")
            .withStatusCode(200)
            .withTimeout(.seconds(30))

        self.request = ContainerRequest(image: image)
            .withExposedPort(NginxContainer.defaultPort)
            .waitingFor(.http(httpConfig))
    }

    // MARK: - Configuration Methods

    /// Mount a custom nginx.conf file into the container.
    /// This replaces the main Nginx configuration file.
    /// - Parameter configPath: Absolute path to nginx.conf on host filesystem
    /// - Returns: Updated NginxContainer configuration
    public func withCustomConfig(_ configPath: String) -> Self {
        var copy = self
        copy.request = request.withBindMount(
            hostPath: configPath,
            containerPath: "/etc/nginx/nginx.conf",
            readOnly: true
        )
        return copy
    }

    /// Mount additional configuration file to conf.d directory.
    /// These files are included by the default nginx.conf.
    /// - Parameters:
    ///   - configPath: Absolute path to .conf file on host
    ///   - filename: Filename in conf.d (default: basename of configPath)
    /// - Returns: Updated NginxContainer configuration
    public func withConfigFile(_ configPath: String, as filename: String? = nil) -> Self {
        let name = filename ?? URL(fileURLWithPath: configPath).lastPathComponent
        var copy = self
        copy.request = request.withBindMount(
            hostPath: configPath,
            containerPath: "/etc/nginx/conf.d/\(name)",
            readOnly: true
        )
        return copy
    }

    /// Serve static files from a host directory.
    /// - Parameters:
    ///   - hostPath: Absolute path to directory containing static files
    ///   - containerPath: Document root in container (default: /usr/share/nginx/html)
    /// - Returns: Updated NginxContainer configuration
    public func withStaticFiles(from hostPath: String, at containerPath: String = NginxContainer.defaultDocumentRoot) -> Self {
        var copy = self
        copy.request = request.withBindMount(
            hostPath: hostPath,
            containerPath: containerPath,
            readOnly: true
        )
        return copy
    }

    /// Configure custom wait strategy.
    /// - Parameter strategy: Wait strategy to use
    /// - Returns: Updated NginxContainer configuration
    public func waitingFor(_ strategy: WaitStrategy) -> Self {
        var copy = self
        copy.request = request.waitingFor(strategy)
        return copy
    }

    /// Expose additional ports beyond the default.
    /// - Parameters:
    ///   - port: Container port to expose
    ///   - hostPort: Optional specific host port to map to
    /// - Returns: Updated NginxContainer configuration
    public func withExposedPort(_ port: Int, hostPort: Int? = nil) -> Self {
        var copy = self
        copy.request = request.withExposedPort(port, hostPort: hostPort)
        return copy
    }

    /// Add environment variables to the container.
    /// - Parameter environment: Dictionary of environment variables
    /// - Returns: Updated NginxContainer configuration
    public func withEnvironment(_ environment: [String: String]) -> Self {
        var copy = self
        copy.request = request.withEnvironment(environment)
        return copy
    }
}

// MARK: - Running NginxContainer

extension NginxContainer {
    /// Start the Nginx container and execute an operation.
    /// The container is automatically cleaned up when the operation completes.
    /// - Parameters:
    ///   - docker: DockerClient instance (default: new instance)
    ///   - operation: Async operation to run with the container
    /// - Returns: Result of the operation
    public func run<T>(
        runtime: any ContainerRuntime = DockerClient(),
        operation: @Sendable (RunningNginxContainer) async throws -> T
    ) async throws -> T {
        try await withContainer(request, runtime: runtime) { container in
            let nginx = RunningNginxContainer(container: container)
            return try await operation(nginx)
        }
    }
}

/// Running Nginx container with typed accessors for HTTP operations.
public struct RunningNginxContainer: Sendable {
    private let container: Container

    init(container: Container) {
        self.container = container
    }

    /// Get the base HTTP URL for the Nginx server.
    /// - Returns: HTTP URL (e.g., "http://127.0.0.1:12345")
    public func url() async throws -> String {
        let endpoint = try await container.endpoint(for: NginxContainer.defaultPort)
        return "http://\(endpoint)"
    }

    /// Get HTTP URL with custom path.
    /// - Parameter path: URL path (should start with /)
    /// - Returns: Full HTTP URL
    public func url(path: String) async throws -> String {
        let base = try await url()
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return "\(base)\(normalizedPath)"
    }

    /// Get the host:port endpoint.
    /// - Returns: Endpoint string (e.g., "127.0.0.1:12345")
    public func endpoint() async throws -> String {
        try await container.endpoint(for: NginxContainer.defaultPort)
    }

    /// Get the mapped host port for Nginx.
    /// - Returns: Host port number
    public func port() async throws -> Int {
        try await container.hostPort(NginxContainer.defaultPort)
    }

    /// Get container logs.
    /// - Returns: Log output as string
    public func logs() async throws -> String {
        try await container.logs()
    }

    /// Access underlying generic Container for advanced operations.
    public var underlyingContainer: Container {
        container
    }
}
