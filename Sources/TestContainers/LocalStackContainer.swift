import Foundation

/// AWS services supported by LocalStack.
public enum AWSService: String, Sendable, Hashable, CaseIterable {
    // Storage
    case s3
    case dynamodb
    case rds
    case redshift
    case elasticache

    // Compute
    case lambda
    case ec2

    // Messaging
    case sqs
    case sns
    case kinesis
    case firehose
    case eventbridge

    // API & Integration
    case apigateway
    case stepfunctions

    // Security
    case iam
    case sts
    case kms
    case secretsmanager
    case cognito

    // Monitoring & Management
    case cloudwatch
    case logs
    case cloudformation
    case ssm

    // Analytics
    case athena

    /// The service name string used in LocalStack's `SERVICES` environment variable.
    public var serviceName: String {
        rawValue
    }
}

/// Configuration for creating a LocalStack (AWS emulation) container suitable for testing.
/// Provides a convenient API for LocalStack container configuration with sensible defaults.
///
/// Example:
/// ```swift
/// let localstack = LocalStackContainer()
///     .withServices([.s3, .sqs])
///     .withRegion("us-west-2")
///
/// try await withLocalStackContainer(localstack) { container in
///     let endpoint = try await container.endpointURL()
///     // Configure AWS SDK with endpoint
/// }
/// ```
public struct LocalStackContainer: Sendable, Hashable {
    /// Docker image to use for the LocalStack container.
    public var image: String

    /// AWS services to enable. `nil` means all services (LocalStack default).
    public var services: Set<AWSService>?

    /// AWS region (default: "us-east-1").
    public var region: String

    /// LocalStack edge port (default: 4566).
    public var port: Int

    /// Additional environment variables.
    public var environment: [String: String]

    /// Wait strategy timeout.
    public var timeout: Duration

    /// Whether to enable LocalStack persistence (requires volume mount).
    public var enablePersistence: Bool

    /// Custom wait strategy. If nil, defaults to HTTP health check.
    public var waitStrategy: WaitStrategy?

    /// Host address for connecting to the container.
    public var host: String

    /// Default LocalStack image.
    public static let defaultImage = "localstack/localstack:3.4"

    /// Default edge port.
    public static let defaultPort = 4566

    /// Default AWS region.
    public static let defaultRegion = "us-east-1"

    /// Creates a new LocalStack container configuration with default settings.
    /// - Parameter image: Docker image to use (default: "localstack/localstack:3.4")
    public init(image: String = LocalStackContainer.defaultImage) {
        self.image = image
        self.services = nil
        self.region = LocalStackContainer.defaultRegion
        self.port = LocalStackContainer.defaultPort
        self.environment = [:]
        self.timeout = .seconds(60)
        self.enablePersistence = false
        self.waitStrategy = nil
        self.host = "127.0.0.1"
    }

    /// Sets the Docker image.
    public func withImage(_ image: String) -> Self {
        var copy = self
        copy.image = image
        return copy
    }

    /// Sets the AWS services to enable.
    /// - Parameter services: Set of services to enable
    public func withServices(_ services: Set<AWSService>) -> Self {
        var copy = self
        copy.services = services
        return copy
    }

    /// Adds a single AWS service to enable.
    /// - Parameter service: Service to add
    public func withService(_ service: AWSService) -> Self {
        var copy = self
        if copy.services == nil {
            copy.services = []
        }
        copy.services?.insert(service)
        return copy
    }

    /// Sets the AWS region.
    /// - Parameter region: AWS region string (e.g., "us-east-1", "eu-west-1")
    public func withRegion(_ region: String) -> Self {
        var copy = self
        copy.region = region
        return copy
    }

    /// Merges additional environment variables.
    /// - Parameter env: Environment variables to add
    public func withEnvironment(_ env: [String: String]) -> Self {
        var copy = self
        for (k, v) in env {
            copy.environment[k] = v
        }
        return copy
    }

    /// Sets the wait strategy timeout.
    /// - Parameter timeout: Duration to wait for container readiness
    public func withTimeout(_ timeout: Duration) -> Self {
        var copy = self
        copy.timeout = timeout
        return copy
    }

    /// Enables or disables LocalStack state persistence.
    /// When enabled, a named volume is mounted at `/var/lib/localstack`.
    /// - Parameter enabled: Whether to enable persistence
    public func withPersistence(_ enabled: Bool) -> Self {
        var copy = self
        copy.enablePersistence = enabled
        return copy
    }

    /// Sets a custom wait strategy for container readiness.
    /// If not specified, defaults to HTTP health check on `/_localstack/health`.
    /// - Parameter strategy: Wait strategy to use
    public func waitingFor(_ strategy: WaitStrategy) -> Self {
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

    /// Converts this LocalStack-specific configuration to a generic ContainerRequest.
    internal func toContainerRequest() -> ContainerRequest {
        var env = environment

        env["DEFAULT_REGION"] = region

        if let services = services {
            let serviceList = services
                .map { $0.serviceName }
                .sorted()
                .joined(separator: ",")
            env["SERVICES"] = serviceList
        }

        env["LOCALSTACK_HOST"] = "localhost.localstack.cloud:\(port)"

        var request = ContainerRequest(image: image)
            .withExposedPort(port)
            .withHost(host)
            .withEnvironment(env)
            .withLabel("testcontainers.module", "localstack")

        if let waitStrategy = waitStrategy {
            request = request.waitingFor(waitStrategy)
        } else {
            request = request.waitingFor(.http(
                HTTPWaitConfig(port: port)
                    .withPath("/_localstack/health")
                    .withTimeout(timeout)
            ))
        }

        if enablePersistence {
            request = request.withVolume("localstack-data", mountedAt: "/var/lib/localstack")
        }

        return request
    }

    // MARK: - Endpoint Helpers

    /// Builds an endpoint URL from host and port.
    /// - Parameters:
    ///   - host: LocalStack host
    ///   - port: LocalStack edge port
    /// - Returns: Formatted endpoint URL (e.g., `http://host:port`)
    public static func buildEndpoint(host: String, port: Int) -> String {
        "http://\(host):\(port)"
    }
}

/// A running LocalStack container with AWS-specific accessors.
/// Provides convenient access to endpoint URLs, region, and credentials.
public struct RunningLocalStackContainer: Sendable {
    private let container: Container
    private let config: LocalStackContainer
    private let runtime: any ContainerRuntime

    internal init(container: Container, config: LocalStackContainer, runtime: any ContainerRuntime) {
        self.container = container
        self.config = config
        self.runtime = runtime
    }

    /// Returns the base LocalStack endpoint URL (e.g., `http://127.0.0.1:49152`).
    public func endpointURL() async throws -> String {
        let hostPort = try await container.hostPort(config.port)
        return LocalStackContainer.buildEndpoint(host: config.host, port: hostPort)
    }

    /// Returns a service-specific endpoint URL.
    /// LocalStack uses the same endpoint for all services.
    /// - Parameter service: The AWS service
    /// - Returns: Service endpoint URL
    public func serviceEndpoint(for service: AWSService) async throws -> String {
        try await endpointURL()
    }

    /// Returns the configured AWS region.
    public func region() -> String {
        config.region
    }

    /// Returns the host address.
    public func host() -> String {
        config.host
    }

    /// Returns the mapped host port for the LocalStack edge port.
    public func port() async throws -> Int {
        try await container.hostPort(config.port)
    }

    /// Retrieves container logs.
    public func logs() async throws -> String {
        try await container.logs()
    }

    /// Executes a command inside the container.
    /// - Parameter command: Command and arguments to execute
    /// - Returns: ExecResult with exit code, stdout, and stderr
    public func exec(_ command: [String]) async throws -> ExecResult {
        try await runtime.exec(id: container.id, command: command, options: ExecOptions())
    }

    /// Access underlying generic Container for advanced operations.
    public var underlyingContainer: Container {
        container
    }
}

/// Creates and starts a LocalStack container for testing.
/// The container is automatically cleaned up when the operation completes.
///
/// - Parameters:
///   - config: LocalStack container configuration
///   - docker: Docker client instance (default: shared client)
///   - operation: Async operation to perform with the running container
/// - Returns: Result of the operation
/// - Throws: Docker errors or operation errors
///
/// Example:
/// ```swift
/// let localstack = LocalStackContainer()
///     .withServices([.s3, .sqs])
///
/// try await withLocalStackContainer(localstack) { container in
///     let endpoint = try await container.endpointURL()
///     // Configure AWS SDK with endpoint
/// }
/// ```
public func withLocalStackContainer<T>(
    _ config: LocalStackContainer = LocalStackContainer(),
    runtime: any ContainerRuntime = DockerClient(),
    operation: @Sendable (RunningLocalStackContainer) async throws -> T
) async throws -> T {
    let containerRequest = config.toContainerRequest()
    return try await withContainer(containerRequest, runtime: runtime) { container in
        let localStackContainer = RunningLocalStackContainer(
            container: container,
            config: config,
            runtime: runtime
        )
        return try await operation(localStackContainer)
    }
}
