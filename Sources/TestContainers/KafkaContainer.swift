import Foundation

/// Pre-configured Apache Kafka container for integration testing.
///
/// This module configures Kafka in single-node KRaft mode (broker + controller)
/// with sensible defaults for local and CI tests.
///
/// Example:
/// ```swift
/// let kafka = KafkaContainer()
///
/// try await withContainer(kafka.build()) { container in
///     let bootstrap = try await KafkaContainer.bootstrapServers(from: container)
///     // Use bootstrap with your Kafka client.
/// }
/// ```
public struct KafkaContainer: Sendable, Hashable {
    /// Common Kafka-compatible image presets.
    public enum Image: Sendable, Hashable {
        case confluentLocal(version: String = "7.5.0")
        case apacheNative(version: String = "3.8.0")
        case custom(String)

        var imageName: String {
            switch self {
            case let .confluentLocal(version):
                return "confluentinc/confluent-local:\(version)"
            case let .apacheNative(version):
                return "apache/kafka-native:\(version)"
            case let .custom(image):
                return image
            }
        }
    }

    /// Default Kafka client port in the container.
    public static let defaultPort = 9093

    /// Default startup log marker for readiness.
    public static let defaultStartupLog = "Kafka Server started"

    /// Default cluster ID known to work for single-node KRaft mode.
    public static let defaultClusterID = "MkU3OEVBNTcwNTJENDM2Qk"

    /// Image preset for this container.
    public var image: Image

    /// Cluster ID used by KRaft.
    public var clusterID: String

    /// Replication factor used for internal topics in tests.
    public var replicationFactor: Int

    /// Default number of partitions for offsets topic.
    public var partitions: Int

    /// Minimum in-sync replicas for transaction state log.
    public var minInSyncReplicas: Int

    /// Additional environment values merged on top of defaults.
    public var environment: [String: String]

    /// Custom wait strategy override.
    public var waitStrategy: WaitStrategy?

    /// Host address used when building endpoint helpers.
    public var host: String

    /// Creates a Kafka container configuration with sensible defaults.
    ///
    /// - Parameter image: Image preset (default: `.confluentLocal()`)
    public init(image: Image = .confluentLocal()) {
        self.image = image
        self.clusterID = Self.defaultClusterID
        self.replicationFactor = 1
        self.partitions = 1
        self.minInSyncReplicas = 1
        self.environment = [:]
        self.waitStrategy = nil
        self.host = "127.0.0.1"
    }

    /// Sets a custom KRaft cluster ID.
    /// - Parameter clusterID: Cluster identifier string.
    public func withClusterID(_ clusterID: String) -> Self {
        var copy = self
        copy.clusterID = clusterID
        return copy
    }

    /// Sets replication factor for Kafka internal topics.
    /// - Parameter factor: Replication factor (typically 1 in single-node tests).
    public func withReplicationFactor(_ factor: Int) -> Self {
        var copy = self
        copy.replicationFactor = factor
        return copy
    }

    /// Sets the partition count for offsets topic defaults.
    /// - Parameter count: Partition count.
    public func withPartitions(_ count: Int) -> Self {
        var copy = self
        copy.partitions = count
        return copy
    }

    /// Sets minimum in-sync replicas for transaction state log.
    /// - Parameter count: Minimum ISR count.
    public func withMinInSyncReplicas(_ count: Int) -> Self {
        var copy = self
        copy.minInSyncReplicas = count
        return copy
    }

    /// Merges custom environment variables into the Kafka configuration.
    /// - Parameter environment: Environment values to merge.
    public func withEnvironment(_ environment: [String: String]) -> Self {
        var copy = self
        for (key, value) in environment {
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

    /// Overrides the host used for endpoint helpers.
    /// - Parameter host: Host address (default: `127.0.0.1`).
    public func withHost(_ host: String) -> Self {
        var copy = self
        copy.host = host
        return copy
    }

    /// Builds the final `ContainerRequest` with Kafka defaults and user overrides.
    public func build() -> ContainerRequest {
        var mergedEnvironment = buildKafkaEnvironment()
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }

        var request = ContainerRequest(image: image.imageName)
            .withExposedPort(Self.defaultPort)
            .withHost(host)
            .withEnvironment(mergedEnvironment)
            .withLabel("testcontainers.module", "kafka")

        if let waitStrategy {
            request = request.waitingFor(waitStrategy)
        } else {
            request = request.waitingFor(
                .logContains(Self.defaultStartupLog, timeout: .seconds(60), pollInterval: .milliseconds(500))
            )
        }

        return request
    }

    /// Returns bootstrap servers string for a running Kafka container.
    ///
    /// The returned value is in `host:port` format and can be used directly by Kafka clients.
    ///
    /// - Parameter container: Running Kafka container.
    /// - Returns: Bootstrap address, for example `127.0.0.1:52341`.
    public static func bootstrapServers(from container: Container) async throws -> String {
        let hostPort = try await container.hostPort(defaultPort)
        let host = await container.host()
        return "\(host):\(hostPort)"
    }

    private func buildKafkaEnvironment() -> [String: String] {
        var env: [String: String] = [:]

        // KRaft single-node (broker + controller)
        env["KAFKA_NODE_ID"] = "1"
        env["KAFKA_PROCESS_ROLES"] = "broker,controller"
        env["KAFKA_CONTROLLER_QUORUM_VOTERS"] = "1@localhost:9094"
        env["CLUSTER_ID"] = clusterID

        // Listener layout for containerized single-node startup.
        env["KAFKA_LISTENERS"] =
            "PLAINTEXT://0.0.0.0:9093,BROKER://0.0.0.0:9092,CONTROLLER://0.0.0.0:9094"
        env["KAFKA_ADVERTISED_LISTENERS"] =
            "PLAINTEXT://\(host):9093,BROKER://localhost:9092"
        env["KAFKA_LISTENER_SECURITY_PROTOCOL_MAP"] =
            "CONTROLLER:PLAINTEXT,BROKER:PLAINTEXT,PLAINTEXT:PLAINTEXT"
        env["KAFKA_CONTROLLER_LISTENER_NAMES"] = "CONTROLLER"
        env["KAFKA_INTER_BROKER_LISTENER_NAME"] = "BROKER"

        // Test-friendly single-node topic defaults.
        env["KAFKA_BROKER_ID"] = "1"
        env["KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR"] = String(replicationFactor)
        env["KAFKA_OFFSETS_TOPIC_NUM_PARTITIONS"] = String(partitions)
        env["KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR"] = String(replicationFactor)
        env["KAFKA_TRANSACTION_STATE_LOG_MIN_ISR"] = String(minInSyncReplicas)
        env["KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS"] = "0"

        // Helpful for Confluent-local images; ignored by images that do not use it.
        env["KAFKA_REST_BOOTSTRAP_SERVERS"] = "PLAINTEXT://localhost:9093"

        return env
    }
}
