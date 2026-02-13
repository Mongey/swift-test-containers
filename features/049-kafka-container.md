# Feature 049: KafkaContainer Module

**Status:** Proposed
**Priority:** Tier 4 (Module System - Service-Specific Helpers)
**Estimated Effort:** Medium (8-12 hours)

---

## Summary

Implement a `KafkaContainer` module for swift-test-containers that provides a pre-configured Apache Kafka container with a typed Swift API, sensible defaults, and helper methods for common Kafka testing scenarios. This module will support modern KRaft mode (Kafka without ZooKeeper), making it easy to integration test Kafka producers, consumers, and stream processing applications.

**Key capabilities:**
- Pre-configured Kafka broker with KRaft mode (no ZooKeeper required)
- Bootstrap servers helper method for client connections
- Configurable broker settings (replication factors, partition counts)
- Automatic port mapping and exposure
- Appropriate wait strategies for broker readiness
- Support for both Confluent and Apache Kafka images

---

## Current State

### Generic Container API

The library currently provides a generic `ContainerRequest` API that can run any Docker container, including Kafka:

```swift
let request = ContainerRequest(image: "confluentinc/confluent-local:7.5.0")
    .withExposedPort(9093)
    .withEnvironment([
        "KAFKA_NODE_ID": "1",
        "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP": "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT",
        "KAFKA_ADVERTISED_LISTENERS": "PLAINTEXT://localhost:9093",
        "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR": "1",
        // ... many more environment variables needed
    ])
    .waitingFor(.tcpPort(9093))

try await withContainer(request) { container in
    let port = try await container.hostPort(9093)
    let bootstrapServers = "localhost:\(port)"
    // Connect Kafka client using bootstrapServers
}
```

### Current Limitations

- ❌ Users must know all required Kafka environment variables for KRaft mode
- ❌ No helper for constructing bootstrap servers connection string
- ❌ Complex broker configuration (listeners, advertised listeners, security protocol map)
- ❌ No sensible defaults for common test scenarios
- ❌ No automatic broker readiness detection beyond basic TCP port check
- ❌ Users must manually construct connection strings from exposed ports
- ❌ No support for common Kafka testing patterns (multiple brokers, custom topics)

---

## Requirements

### Functional Requirements

1. **Default Image Support**
   - Default to Confluent's KRaft-ready image: `confluentinc/confluent-local:7.5.0` or later
   - Support for Apache Kafka native images: `apache/kafka-native:3.8.0` or later
   - Allow users to specify custom Kafka-compatible images (e.g., Redpanda)

2. **KRaft Mode Configuration**
   - Run Kafka in KRaft combined mode (broker + controller in single container)
   - No ZooKeeper dependency required
   - Minimal configuration required from users
   - Support cluster ID customization (optional)

3. **Broker Configuration**
   - Expose Kafka on a random host port mapped to container port 9093
   - Configure listeners: PLAINTEXT, BROKER, CONTROLLER
   - Set sensible test defaults:
     - Replication factor: 1
     - Partition count: 1
     - Min ISR: 1
     - Transaction log replication factor: 1
   - Allow overriding default settings via builder methods

4. **Bootstrap Servers Helper**
   - Provide `bootstrapServers() async throws -> String` method
   - Return connection string in format: `host:port` (e.g., `127.0.0.1:52341`)
   - Handle dynamic port resolution automatically

5. **Wait Strategy**
   - Wait for broker to be ready (not just TCP port open)
   - Check for log message indicating broker is fully started
   - Default wait strategy: `.logContains("Kafka Server started", timeout: .seconds(60))`
   - Allow custom wait strategy override

6. **API Ergonomics**
   - Fluent builder pattern consistent with existing `ContainerRequest`
   - Type-safe configuration methods
   - Integration with existing `withContainer(_:_:)` lifecycle helper
   - Minimal boilerplate for common use cases

### Non-Functional Requirements

1. **Performance**
   - Container startup time should be reasonable for integration tests (< 30 seconds)
   - Consider recommending faster alternatives (Redpanda) for CI/CD environments

2. **Compatibility**
   - Support macOS (arm64 and x86_64) and Linux
   - Compatible with Kafka client libraries (e.g., swift-kafka-client, kafka-nio)
   - Works with Docker Desktop and Colima

3. **Documentation**
   - Clear examples for common Kafka testing patterns
   - Migration guide from generic container to KafkaContainer
   - Troubleshooting guide for common issues

4. **Testing**
   - Unit tests for builder API correctness
   - Integration tests with real Kafka operations (produce/consume messages)
   - Opt-in integration tests via `TESTCONTAINERS_RUN_DOCKER_TESTS=1`

---

## API Design

### Proposed Module Structure

Create new file: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Modules/KafkaContainer.swift`

```swift
import Foundation

/// A pre-configured Kafka container with KRaft mode support (no ZooKeeper required).
///
/// This module provides sensible defaults for testing Kafka applications:
/// - KRaft combined mode (broker + controller)
/// - Single broker with replication factor 1
/// - Random host port mapping for parallel test execution
/// - Bootstrap servers helper for client connections
///
/// Example usage:
/// ```swift
/// let kafka = KafkaContainer(image: .confluentLocal())
///     .withClusterID("test-cluster")
///
/// try await withContainer(kafka.build()) { container in
///     let bootstrapServers = try await KafkaContainer.bootstrapServers(from: container)
///     // Use bootstrapServers to connect Kafka client
/// }
/// ```
public struct KafkaContainer {
    public static let defaultPort: Int = 9093

    /// Pre-defined Kafka images
    public enum Image {
        case confluentLocal(version: String = "7.5.0")
        case apacheNative(version: String = "3.8.0")
        case custom(String)

        var imageName: String {
            switch self {
            case .confluentLocal(let version):
                return "confluentinc/confluent-local:\(version)"
            case .apacheNative(let version):
                return "apache/kafka-native:\(version)"
            case .custom(let name):
                return name
            }
        }
    }

    private var request: ContainerRequest
    private var clusterID: String
    private var replicationFactor: Int
    private var partitions: Int
    private var minInSyncReplicas: Int

    /// Creates a new Kafka container configuration.
    ///
    /// - Parameter image: The Kafka Docker image to use (defaults to Confluent Local 7.5.0)
    public init(image: Image = .confluentLocal()) {
        self.request = ContainerRequest(image: image.imageName)
            .withExposedPort(Self.defaultPort)
        self.clusterID = "testcontainers-kafka-\(UUID().uuidString.prefix(8))"
        self.replicationFactor = 1
        self.partitions = 1
        self.minInSyncReplicas = 1
    }

    /// Sets a custom cluster ID for the Kafka cluster.
    ///
    /// - Parameter clusterID: The cluster ID to use (must be valid base64-encoded UUID)
    /// - Returns: Modified KafkaContainer
    public func withClusterID(_ clusterID: String) -> Self {
        var copy = self
        copy.clusterID = clusterID
        return copy
    }

    /// Sets the default replication factor for auto-created topics.
    ///
    /// - Parameter factor: Number of replicas (typically 1 for single-broker tests)
    /// - Returns: Modified KafkaContainer
    public func withReplicationFactor(_ factor: Int) -> Self {
        var copy = self
        copy.replicationFactor = factor
        return copy
    }

    /// Sets the default partition count for auto-created topics.
    ///
    /// - Parameter count: Number of partitions
    /// - Returns: Modified KafkaContainer
    public func withPartitions(_ count: Int) -> Self {
        var copy = self
        copy.partitions = count
        return copy
    }

    /// Sets the minimum in-sync replicas requirement.
    ///
    /// - Parameter count: Minimum ISR count (typically 1 for tests)
    /// - Returns: Modified KafkaContainer
    public func withMinInSyncReplicas(_ count: Int) -> Self {
        var copy = self
        copy.minInSyncReplicas = count
        return copy
    }

    /// Applies custom environment variables to the Kafka container.
    ///
    /// Use this to override default Kafka broker settings or add new configuration.
    ///
    /// - Parameter environment: Environment variables (KAFKA_* prefixed)
    /// - Returns: Modified KafkaContainer
    public func withEnvironment(_ environment: [String: String]) -> Self {
        var copy = self
        copy.request = copy.request.withEnvironment(environment)
        return copy
    }

    /// Overrides the default wait strategy.
    ///
    /// By default, waits for "Kafka Server started" log message.
    ///
    /// - Parameter strategy: Custom wait strategy
    /// - Returns: Modified KafkaContainer
    public func waitingFor(_ strategy: WaitStrategy) -> Self {
        var copy = self
        copy.request = copy.request.waitingFor(strategy)
        return copy
    }

    /// Builds the final ContainerRequest with all Kafka-specific configuration applied.
    ///
    /// This method:
    /// 1. Configures KRaft mode environment variables
    /// 2. Sets up listeners and advertised listeners
    /// 3. Applies broker configuration defaults
    /// 4. Sets appropriate wait strategy
    ///
    /// - Returns: A configured ContainerRequest ready to be started
    public func build() -> ContainerRequest {
        let environment = buildKafkaEnvironment()

        var finalRequest = request
            .withEnvironment(environment)
            .withLabel("testcontainers.module", "kafka")

        // Apply default wait strategy if not already set
        if finalRequest.waitStrategy == .none {
            finalRequest = finalRequest.waitingFor(
                .logContains("Kafka Server started", timeout: .seconds(60))
            )
        }

        return finalRequest
    }

    /// Gets the bootstrap servers connection string from a running Kafka container.
    ///
    /// This is the primary method for obtaining the connection string to use with Kafka clients.
    ///
    /// Example:
    /// ```swift
    /// try await withContainer(kafka.build()) { container in
    ///     let servers = try await KafkaContainer.bootstrapServers(from: container)
    ///     let producer = KafkaProducer(bootstrapServers: servers)
    /// }
    /// ```
    ///
    /// - Parameter container: The running Kafka container
    /// - Returns: Bootstrap servers string (e.g., "127.0.0.1:52341")
    public static func bootstrapServers(from container: Container) async throws -> String {
        let port = try await container.hostPort(defaultPort)
        let host = container.host()
        return "\(host):\(port)"
    }

    private func buildKafkaEnvironment() -> [String: String] {
        var env: [String: String] = [:]

        // KRaft mode configuration (combined mode: broker + controller)
        env["KAFKA_NODE_ID"] = "1"
        env["KAFKA_PROCESS_ROLES"] = "broker,controller"
        env["KAFKA_CONTROLLER_QUORUM_VOTERS"] = "1@localhost:9094"
        env["CLUSTER_ID"] = clusterID

        // Listener configuration
        // - PLAINTEXT: External clients (exposed port)
        // - BROKER: Inter-broker communication
        // - CONTROLLER: KRaft controller protocol
        env["KAFKA_LISTENERS"] = "PLAINTEXT://0.0.0.0:9093,BROKER://0.0.0.0:9092,CONTROLLER://0.0.0.0:9094"
        env["KAFKA_ADVERTISED_LISTENERS"] = "PLAINTEXT://host.docker.internal:9093,BROKER://localhost:9092"
        env["KAFKA_LISTENER_SECURITY_PROTOCOL_MAP"] = "CONTROLLER:PLAINTEXT,BROKER:PLAINTEXT,PLAINTEXT:PLAINTEXT"
        env["KAFKA_CONTROLLER_LISTENER_NAMES"] = "CONTROLLER"
        env["KAFKA_INTER_BROKER_LISTENER_NAME"] = "BROKER"

        // Broker configuration (optimized for single-broker testing)
        env["KAFKA_BROKER_ID"] = "1"
        env["KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR"] = "\(replicationFactor)"
        env["KAFKA_OFFSETS_TOPIC_NUM_PARTITIONS"] = "\(partitions)"
        env["KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR"] = "\(replicationFactor)"
        env["KAFKA_TRANSACTION_STATE_LOG_MIN_ISR"] = "\(minInSyncReplicas)"
        env["KAFKA_LOG_FLUSH_INTERVAL_MESSAGES"] = "1"  // Fast flush for tests
        env["KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS"] = "0"  // No rebalance delay

        // Confluent REST Proxy configuration (for Confluent images)
        env["KAFKA_REST_BOOTSTRAP_SERVERS"] = "PLAINTEXT://localhost:9093"

        return env
    }
}
```

### API Usage Examples

#### Example 1: Basic Kafka Container

```swift
import Testing
import TestContainers

@Test func kafkaProducerConsumer() async throws {
    let kafka = KafkaContainer()

    try await withContainer(kafka.build()) { container in
        let bootstrapServers = try await KafkaContainer.bootstrapServers(from: container)

        // Use with any Kafka client library
        let producer = KafkaProducer(bootstrapServers: bootstrapServers)
        try await producer.send(topic: "test-topic", message: "Hello Kafka!")

        let consumer = KafkaConsumer(
            bootstrapServers: bootstrapServers,
            groupId: "test-group"
        )
        let messages = try await consumer.poll(timeout: .seconds(5))
        #expect(messages.count == 1)
    }
}
```

#### Example 2: Custom Configuration

```swift
@Test func kafkaWithCustomConfig() async throws {
    let kafka = KafkaContainer(image: .apacheNative(version: "3.8.0"))
        .withClusterID("my-test-cluster")
        .withPartitions(3)
        .withReplicationFactor(1)
        .withEnvironment([
            "KAFKA_LOG_RETENTION_MS": "10000",
            "KAFKA_LOG_SEGMENT_BYTES": "1048576"
        ])

    try await withContainer(kafka.build()) { container in
        let servers = try await KafkaContainer.bootstrapServers(from: container)
        // Test application with custom Kafka settings
    }
}
```

#### Example 3: Using Redpanda (Kafka-Compatible)

```swift
@Test func redpandaContainer() async throws {
    let kafka = KafkaContainer(image: .custom("docker.redpanda.com/redpandadata/redpanda:v23.3.3"))
        .withEnvironment([
            "REDPANDA_ADVERTISED_KAFKA_API": "host.docker.internal:9093"
        ])
        .waitingFor(.logContains("Successfully started Redpanda", timeout: .seconds(30)))

    try await withContainer(kafka.build()) { container in
        let servers = try await KafkaContainer.bootstrapServers(from: container)
        // Redpanda is Kafka-compatible, use same client libraries
    }
}
```

#### Example 4: Integration with Swift Kafka Clients

```swift
import SwiftKafka
import Testing
import TestContainers

@Test func kafkaStreamProcessing() async throws {
    let kafka = KafkaContainer()

    try await withContainer(kafka.build()) { container in
        let servers = try await KafkaContainer.bootstrapServers(from: container)

        // Producer
        let config = KafkaProducerConfig(bootstrapServers: [servers])
        let producer = try KafkaProducer(config: config)

        for i in 0..<100 {
            try await producer.send(
                ProducerRecord(topic: "events", value: "Event \(i)")
            )
        }

        // Consumer
        let consumerConfig = KafkaConsumerConfig(
            bootstrapServers: [servers],
            groupId: "test-consumer-group"
        )
        let consumer = try KafkaConsumer(config: consumerConfig)
        try await consumer.subscribe(topics: ["events"])

        let records = try await consumer.poll(timeout: .seconds(10))
        #expect(records.count == 100)
    }
}
```

---

## Implementation Steps

### 1. Create KafkaContainer Module File

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Modules/KafkaContainer.swift`

**Tasks:**
- Create new `Modules` directory under `Sources/TestContainers/`
- Implement `KafkaContainer` struct with builder pattern
- Implement `Image` enum for common Kafka images
- Implement `build()` method to construct `ContainerRequest`
- Implement `buildKafkaEnvironment()` helper for KRaft configuration
- Implement `bootstrapServers(from:)` static helper method
- Add comprehensive documentation comments
- Ensure `Sendable` conformance

**Estimated time:** 3-4 hours

### 2. Add KafkaContainer to Public API

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainers.swift`

If a main module file doesn't exist, create it to export the KafkaContainer:

```swift
// Main module file
@_exported import struct TestContainers.Container
@_exported import struct TestContainers.ContainerRequest
@_exported import struct TestContainers.KafkaContainer
```

Alternatively, ensure `KafkaContainer.swift` has `public` visibility and is included in the module.

**Estimated time:** 30 minutes

### 3. Handle Dynamic Port Resolution in Advertised Listeners

**Challenge:** Kafka's `KAFKA_ADVERTISED_LISTENERS` must include the host-mapped port, but Docker assigns this randomly at runtime.

**Solution approaches:**

**Option A: Use Docker host networking tricks**
- Use `host.docker.internal` for advertised listeners
- This works on Docker Desktop for Mac/Windows
- May require additional configuration for Linux (add `--add-host=host.docker.internal:host-gateway`)

**Option B: Post-start configuration**
- Start container with placeholder advertised listeners
- After port resolution, exec into container to update configuration
- More complex but offers maximum flexibility
- Requires container exec support (Feature 007)

**Option C: Use KAFKA_ADVERTISED_LISTENERS with variable substitution**
- Some Kafka images support environment variable substitution
- Example: `KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://_{HOSTNAME_COMMAND}:9093`
- Not universally supported across all images

**Recommended approach for MVP:** Option A (host.docker.internal)
- Works for most development scenarios on macOS
- Document Linux workaround in README
- Future enhancement: Detect platform and adjust configuration

**Estimated time:** 2 hours (includes testing different approaches)

### 4. Create Unit Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/KafkaContainerTests.swift`

**Test cases:**

```swift
import Testing
@testable import TestContainers

@Suite struct KafkaContainerTests {
    @Test func defaultImageUsesConfluentLocal() {
        let kafka = KafkaContainer()
        let request = kafka.build()
        #expect(request.image == "confluentinc/confluent-local:7.5.0")
    }

    @Test func customImageVersion() {
        let kafka = KafkaContainer(image: .confluentLocal(version: "7.6.0"))
        let request = kafka.build()
        #expect(request.image == "confluentinc/confluent-local:7.6.0")
    }

    @Test func apacheNativeImage() {
        let kafka = KafkaContainer(image: .apacheNative())
        let request = kafka.build()
        #expect(request.image == "apache/kafka-native:3.8.0")
    }

    @Test func customImage() {
        let kafka = KafkaContainer(image: .custom("my-kafka:latest"))
        let request = kafka.build()
        #expect(request.image == "my-kafka:latest")
    }

    @Test func exposesDefaultPort() {
        let kafka = KafkaContainer()
        let request = kafka.build()
        #expect(request.ports.contains { $0.containerPort == 9093 })
    }

    @Test func setsKRaftEnvironmentVariables() {
        let kafka = KafkaContainer()
        let request = kafka.build()

        #expect(request.environment["KAFKA_NODE_ID"] == "1")
        #expect(request.environment["KAFKA_PROCESS_ROLES"] == "broker,controller")
        #expect(request.environment["KAFKA_LISTENERS"]?.contains("PLAINTEXT://0.0.0.0:9093") == true)
    }

    @Test func customClusterID() {
        let kafka = KafkaContainer()
            .withClusterID("my-cluster-123")
        let request = kafka.build()

        #expect(request.environment["CLUSTER_ID"] == "my-cluster-123")
    }

    @Test func customReplicationFactor() {
        let kafka = KafkaContainer()
            .withReplicationFactor(3)
        let request = kafka.build()

        #expect(request.environment["KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR"] == "3")
        #expect(request.environment["KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR"] == "3")
    }

    @Test func customPartitions() {
        let kafka = KafkaContainer()
            .withPartitions(5)
        let request = kafka.build()

        #expect(request.environment["KAFKA_OFFSETS_TOPIC_NUM_PARTITIONS"] == "5")
    }

    @Test func customEnvironmentVariables() {
        let kafka = KafkaContainer()
            .withEnvironment([
                "KAFKA_LOG_RETENTION_MS": "5000",
                "KAFKA_AUTO_CREATE_TOPICS_ENABLE": "false"
            ])
        let request = kafka.build()

        #expect(request.environment["KAFKA_LOG_RETENTION_MS"] == "5000")
        #expect(request.environment["KAFKA_AUTO_CREATE_TOPICS_ENABLE"] == "false")
    }

    @Test func defaultWaitStrategy() {
        let kafka = KafkaContainer()
        let request = kafka.build()

        if case .logContains(let text, _, _) = request.waitStrategy {
            #expect(text == "Kafka Server started")
        } else {
            Issue.record("Expected logContains wait strategy")
        }
    }

    @Test func customWaitStrategy() {
        let kafka = KafkaContainer()
            .waitingFor(.tcpPort(9093, timeout: .seconds(30)))
        let request = kafka.build()

        if case .tcpPort(let port, _, _) = request.waitStrategy {
            #expect(port == 9093)
        } else {
            Issue.record("Expected tcpPort wait strategy")
        }
    }

    @Test func addsModuleLabel() {
        let kafka = KafkaContainer()
        let request = kafka.build()

        #expect(request.labels["testcontainers.module"] == "kafka")
    }

    @Test func builderChaining() {
        let kafka = KafkaContainer(image: .apacheNative())
            .withClusterID("test")
            .withPartitions(10)
            .withReplicationFactor(1)
            .withMinInSyncReplicas(1)
            .withEnvironment(["CUSTOM": "value"])

        let request = kafka.build()
        #expect(request.image == "apache/kafka-native:3.8.0")
        #expect(request.environment["CLUSTER_ID"] == "test")
        #expect(request.environment["KAFKA_OFFSETS_TOPIC_NUM_PARTITIONS"] == "10")
        #expect(request.environment["CUSTOM"] == "value")
    }
}
```

**Estimated time:** 2-3 hours

### 5. Create Integration Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/KafkaIntegrationTests.swift`

**Test cases:**

```swift
import Testing
import TestContainers

@Suite struct KafkaIntegrationTests {
    @Test func startsKafkaContainer() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let kafka = KafkaContainer()

        try await withContainer(kafka.build()) { container in
            #expect(!container.id.isEmpty)

            let servers = try await KafkaContainer.bootstrapServers(from: container)
            #expect(servers.contains(":"))
            #expect(servers.hasPrefix("127.0.0.1:"))
        }
    }

    @Test func bootstrapServersReturnsValidFormat() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let kafka = KafkaContainer()

        try await withContainer(kafka.build()) { container in
            let servers = try await KafkaContainer.bootstrapServers(from: container)

            // Validate format: host:port
            let parts = servers.split(separator: ":")
            #expect(parts.count == 2)

            let host = String(parts[0])
            let port = Int(String(parts[1]))

            #expect(!host.isEmpty)
            #expect(port != nil)
            #expect(port! > 0)
        }
    }

    @Test func containerLogsShowKafkaStartup() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let kafka = KafkaContainer()

        try await withContainer(kafka.build()) { container in
            let logs = try await container.logs()
            #expect(logs.contains("Kafka Server started") || logs.contains("started (kafka.server"))
        }
    }

    @Test func apacheNativeImageStarts() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let kafka = KafkaContainer(image: .apacheNative())
            .waitingFor(.logContains("Kafka Server started", timeout: .seconds(90)))

        try await withContainer(kafka.build()) { container in
            let servers = try await KafkaContainer.bootstrapServers(from: container)
            #expect(!servers.isEmpty)
        }
    }

    @Test func customConfigurationApplied() async throws {
        let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
        guard optedIn else { return }

        let kafka = KafkaContainer()
            .withClusterID("custom-test-cluster")
            .withPartitions(5)

        try await withContainer(kafka.build()) { container in
            let logs = try await container.logs()
            // Verify cluster started successfully
            #expect(logs.contains("Kafka Server started"))
        }
    }
}
```

**Note:** Full end-to-end tests with actual Kafka client produce/consume operations would require adding a Kafka client library dependency. For now, integration tests verify container startup and configuration correctness.

**Estimated time:** 2 hours

### 6. Update Documentation

**Files to update:**
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/README.md`
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md`

**README.md addition:**

```markdown
## Modules

### KafkaContainer

Pre-configured Apache Kafka container with KRaft mode (no ZooKeeper required):

```swift
import Testing
import TestContainers

@Test func testKafkaProducer() async throws {
    let kafka = KafkaContainer()

    try await withContainer(kafka.build()) { container in
        let bootstrapServers = try await KafkaContainer.bootstrapServers(from: container)

        // Use with any Kafka client
        let producer = KafkaProducer(bootstrapServers: bootstrapServers)
        try await producer.send(topic: "test-topic", message: "Hello Kafka!")
    }
}
```

Supports Confluent, Apache Kafka native, and Redpanda images.
```

**FEATURES.md update:**
- Mark line 117 as implemented: `- [x] KafkaContainer`
- Update implementation date and version

**Estimated time:** 1 hour

### 7. Add Example Integration Test with Kafka Client (Optional)

If a Swift Kafka client library is available, add an example showing full produce/consume cycle.

**Dependency considerations:**
- Add as optional test-only dependency
- Document which Kafka client libraries are compatible
- Show example with popular libraries (swift-kafka-client, etc.)

**Estimated time:** 2-3 hours (if implemented)

---

## Testing Plan

### Unit Tests (Required)

**Focus:** Builder API correctness, configuration generation, environment variable setup

**Test coverage:**
1. ✅ Default image selection
2. ✅ Custom image versions (Confluent, Apache Native, custom)
3. ✅ Port exposure (9093)
4. ✅ KRaft environment variable generation
5. ✅ Custom cluster ID
6. ✅ Replication factor configuration
7. ✅ Partition count configuration
8. ✅ Min ISR configuration
9. ✅ Custom environment variable overlay
10. ✅ Default wait strategy (log contains)
11. ✅ Custom wait strategy override
12. ✅ Module label application
13. ✅ Builder method chaining
14. ✅ Sendable conformance (compile-time check)

**Execution:**
```bash
swift test --filter KafkaContainerTests
```

**Expected result:** All unit tests pass in < 1 second

### Integration Tests (Required)

**Focus:** Real container startup, port mapping, log verification

**Test coverage:**
1. ✅ Container starts successfully with default configuration
2. ✅ Bootstrap servers helper returns valid connection string
3. ✅ Container logs show Kafka startup completion
4. ✅ Apache Native image compatibility
5. ✅ Custom configuration is applied correctly
6. ✅ Multiple containers can run in parallel (port assignment)

**Execution:**
```bash
TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test --filter KafkaIntegrationTests
```

**Expected result:** All integration tests pass in < 2 minutes (including container pull/start time)

### End-to-End Tests with Kafka Clients (Optional)

**Focus:** Real Kafka operations (produce/consume messages)

**Test coverage:**
1. ✅ Produce messages to topic
2. ✅ Consume messages from topic
3. ✅ Consumer group management
4. ✅ Multiple partitions
5. ✅ Offset management

**Prerequisites:**
- Swift Kafka client library dependency
- Extended timeout for test execution

**Execution:**
```bash
TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test --filter KafkaE2ETests
```

### Manual Testing

For development and validation:

```bash
# Start container manually to inspect configuration
docker run -d \
  -p 9093:9093 \
  -e KAFKA_NODE_ID=1 \
  -e KAFKA_PROCESS_ROLES=broker,controller \
  -e CLUSTER_ID=test-cluster \
  # ... (other environment variables)
  confluentinc/confluent-local:7.5.0

# Verify broker is reachable
docker exec <container-id> kafka-broker-api-versions --bootstrap-server localhost:9093

# Check logs
docker logs <container-id>

# Clean up
docker rm -f <container-id>
```

---

## Acceptance Criteria

### Definition of Done

- [ ] `KafkaContainer` struct implemented with builder pattern
- [ ] `Image` enum with Confluent, Apache Native, and custom image support
- [ ] `build()` method generates correct KRaft configuration
- [ ] `bootstrapServers(from:)` static helper method implemented
- [ ] All builder methods follow existing patterns
- [ ] Comprehensive unit tests (13+ test cases)
- [ ] Integration tests verify real container startup
- [ ] All tests pass (unit + integration)
- [ ] Documentation added to README.md
- [ ] FEATURES.md updated (line 117 marked complete)
- [ ] Code follows Swift API design guidelines
- [ ] Public API has documentation comments
- [ ] Module is properly exposed in package
- [ ] No breaking changes to existing API

### Success Criteria

Users can:
1. Create a Kafka container with one line: `KafkaContainer()`
2. Get bootstrap servers connection string easily
3. Override default configuration via builder methods
4. Choose between different Kafka images
5. Test Kafka producers and consumers without manual configuration
6. Run parallel tests without port conflicts
7. Understand wait strategy behavior (logs or custom)

### Performance Criteria

- Container startup time: < 30 seconds (Confluent), < 20 seconds (Apache Native)
- Unit test execution: < 1 second
- Integration test execution: < 2 minutes (including first-time image pull)
- Memory overhead: Minimal (< 10% increase over generic container)

### Out of Scope (Future Enhancements)

- **Multi-broker clusters** - Current implementation is single-broker only
- **Schema Registry integration** - Separate module for Confluent Schema Registry
- **Kafka Connect** - Pre-configured Kafka Connect containers
- **TLS/SASL authentication** - Security configuration for test scenarios
- **Custom topic creation** - Automatic topic setup before test execution
- **Transactional producer/consumer helpers** - High-level testing utilities
- **Redpanda module** - Dedicated `RedpandaContainer` with Redpanda-specific features
- **Network aliases** - Container-to-container Kafka communication (requires Feature 024)
- **Startup script injection** - Custom initialization scripts
- **Metrics/monitoring endpoints** - JMX or Prometheus configuration

---

## Dependencies

### Upstream Dependencies

**Required features (already implemented):**
- ✅ ContainerRequest builder API
- ✅ Container lifecycle (withContainer)
- ✅ Port mapping and resolution
- ✅ Environment variable configuration
- ✅ Wait strategies (logContains)
- ✅ Container logs retrieval

**Optional features (nice to have):**
- [ ] Container inspection (Feature 010) - Would enable verification of applied configuration
- [ ] Container exec (Feature 007) - Would enable dynamic advertised listener configuration
- [ ] Network creation (Feature 024) - Would enable multi-broker clusters

### Downstream Dependencies

None - this is a leaf module that other features can reference but doesn't block anything.

### External Dependencies

**Docker images:**
- `confluentinc/confluent-local:7.5.0` (default)
- `apache/kafka-native:3.8.0` (alternative)
- Any Kafka-compatible image

**Swift Kafka clients (for user applications, not library dependencies):**
- [swift-kafka-client](https://github.com/swift-server/swift-kafka-client) (recommended)
- [kafka-nio](https://github.com/swift-server-community/kafka-nio)
- Any Kafka client compatible with standard Kafka protocol

---

## References

### Testcontainers Go - Kafka Module

- [Kafka (KRaft) - Testcontainers for Go](https://golang.testcontainers.org/modules/kafka/)
- [Testcontainers Kafka Module](https://testcontainers.com/modules/kafka/)

Key learnings from testcontainers-go:
- Uses KRaft mode (no ZooKeeper) with minimum version `confluentinc/confluent-local:7.4.0`
- Provides `Brokers(ctx)` method to get bootstrap servers
- Supports `WithClusterID()` option for cluster identification
- Single-broker configuration with sensible test defaults
- Default wait strategy for broker readiness

### Testcontainers Java - Kafka Module

- [Kafka Module - Testcontainers for Java](https://java.testcontainers.org/modules/kafka/)
- [testcontainers-java kafka module](https://github.com/testcontainers/testcontainers-java/blob/main/docs/modules/kafka.md)

Key features:
- `getBootstrapServers()` method returns connection string
- Supports `withKraft()` for KRaft mode
- Backward compatibility with ZooKeeper mode
- Embedded network configuration for container-to-container communication

### Kafka Docker Images

- [Confluent Platform Docker Images](https://docs.confluent.io/platform/current/installation/docker/image-reference.html)
- [Apache Kafka Docker Documentation](https://kafka.apache.org/documentation/#docker)
- [Redpanda vs Kafka Performance](https://www.redpanda.com/blog/kafka-application-testing)

Image recommendations:
- **Confluent Local** (`confluentinc/confluent-local`): Full Kafka platform, ~500MB, 15-30s startup
- **Apache Kafka Native** (`apache/kafka-native`): GraalVM-based, ~200MB, 10-20s startup
- **Redpanda** (`docker.redpanda.com/redpandadata/redpanda`): Kafka-compatible, ~128MB, 3-5s startup (2x faster)

### Kafka KRaft Configuration

- [KRaft Overview - Apache Kafka](https://kafka.apache.org/documentation/#kraft)
- [KRaft Mode Configuration](https://developer.confluent.io/learn/kraft/)

Essential KRaft environment variables:
- `KAFKA_NODE_ID`: Unique node identifier
- `KAFKA_PROCESS_ROLES`: `broker`, `controller`, or `broker,controller` (combined mode)
- `KAFKA_CONTROLLER_QUORUM_VOTERS`: Controller voter endpoints
- `CLUSTER_ID`: Base64-encoded UUID for cluster identification
- `KAFKA_LISTENERS`: Protocol://host:port for each listener
- `KAFKA_ADVERTISED_LISTENERS`: Public addresses for client connections

### Related Code

- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` - Builder pattern reference
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift` - Container actor API
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift` - Wait strategy implementation
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift` - Integration test patterns

---

## Implementation Notes

### Design Decisions

1. **Why KRaft mode only (no ZooKeeper)?**
   - ZooKeeper is deprecated in Kafka 3.x+ and will be removed in Kafka 4.0
   - KRaft mode simplifies test setup (single container vs. Kafka + ZooKeeper)
   - Faster startup time and lower resource usage
   - Production Kafka is moving to KRaft, so tests should reflect production architecture
   - Backward compatibility can be added later if needed

2. **Why static `bootstrapServers(from:)` instead of instance method?**
   - The container is an actor, making method calls async
   - Static method clearly indicates it operates on a running container
   - Consistent with pattern where module builds request, lifecycle is managed separately
   - Allows flexibility: users can pass container to helper functions without coupling to KafkaContainer instance

3. **Why separate `build()` method instead of returning ContainerRequest directly?**
   - Explicit build step makes it clear when configuration is finalized
   - Allows lazy evaluation of environment variables
   - Consistent with builder pattern (construct, configure, build)
   - Future enhancement: `build()` could detect platform and adjust configuration

4. **Why single-broker only for MVP?**
   - 99% of integration tests only need single broker
   - Multi-broker adds complexity (networking, volume sharing, coordination)
   - Multi-broker clusters require network creation (Feature 024 not yet implemented)
   - Single-broker is sufficient for testing message ordering, offset management, consumer groups
   - Multi-broker support can be added in future via `withBrokers(count:)` method

5. **Why `host.docker.internal` for advertised listeners?**
   - Docker Desktop (Mac/Windows) provides this alias for host machine
   - Allows container to advertise address that's reachable from host
   - Alternative (direct IP detection) is complex and platform-specific
   - Linux workaround is well-documented in Docker community
   - Future: Detect platform and use appropriate strategy

### Known Limitations

1. **Linux host networking**
   - `host.docker.internal` requires `--add-host` flag on Linux
   - Workaround: Users can add custom environment variable for advertised listeners
   - Future enhancement: Auto-detect Linux and add host mapping

2. **Container-to-container communication**
   - Current implementation optimized for host-to-container
   - Container-to-container Kafka requires network aliases (Feature 024)
   - Workaround: Use `withEnvironment()` to set custom listeners

3. **TLS/SASL authentication**
   - MVP supports PLAINTEXT only
   - Most integration tests don't require security
   - Future enhancement: `withSecurity()` builder method

4. **Dynamic port resolution timing**
   - Advertised listeners are set before container starts
   - This works because we use host-network tricks, not actual dynamic port
   - Alternative approach (exec-based reconfiguration) would require Feature 007

### Alternative Approaches Considered

#### 1. Protocol-based Configuration (Rejected)

```swift
protocol KafkaContainerProtocol {
    func bootstrapServers() async throws -> String
}
```

**Pros:** Extensible for different Kafka-compatible systems (Redpanda, etc.)
**Cons:** Over-engineered for current needs, protocols with async methods are complex
**Decision:** YAGNI - stick with concrete struct for now

#### 2. Container Subclass (Rejected)

```swift
class KafkaContainer: Container {
    func bootstrapServers() async -> String { ... }
}
```

**Pros:** Natural inheritance hierarchy
**Cons:** Container is an actor, not a class; mixing actors and classes is problematic
**Decision:** Use separate module struct + static helper pattern

#### 3. Global Configuration Registry (Rejected)

```swift
KafkaContainer.configure(.defaultReplicationFactor(1))
```

**Pros:** Less repetition for common settings
**Cons:** Global state, thread safety concerns, implicit configuration
**Decision:** Explicit builder pattern is clearer and safer

### Performance Considerations

**Container startup time benchmarks (approximate):**
- Confluent Local 7.5.0: 20-30 seconds (first start), 15-20 seconds (cached)
- Apache Kafka Native 3.8.0: 15-20 seconds (first start), 10-15 seconds (cached)
- Redpanda v23.3.3: 5-8 seconds (first start), 3-5 seconds (cached)

**Recommendations for CI/CD:**
- Cache Docker images to avoid repeated downloads
- Consider Redpanda for faster test execution (2-3x faster than Confluent)
- Run Kafka tests in parallel where possible (each gets unique port)
- Set reasonable wait timeouts (60 seconds is usually sufficient)

**Memory usage:**
- Confluent Local: ~512MB-1GB
- Apache Native: ~256MB-512MB
- Redpanda: ~128MB-256MB

### Security Considerations

**Current implementation (MVP):**
- PLAINTEXT protocol only (no encryption)
- No authentication required
- Suitable for local integration tests

**Future security enhancements:**
- TLS encryption support
- SASL authentication (PLAIN, SCRAM, OAuth)
- ACL configuration for authorization testing
- Certificate generation and injection

**Recommendation:** Keep MVP simple (PLAINTEXT), add security features on demand.

### Troubleshooting Guide

**Common issues and solutions:**

1. **Container fails to start**
   - Check Docker is running: `docker version`
   - Verify image is available: `docker pull confluentinc/confluent-local:7.5.0`
   - Check port availability: `lsof -i :9093`
   - Review container logs: `container.logs()`

2. **Timeout waiting for broker**
   - Increase wait timeout: `.waitingFor(.logContains("...", timeout: .seconds(90)))`
   - Check system resources (CPU/memory)
   - Try faster image (Apache Native or Redpanda)

3. **Connection refused from Kafka client**
   - Verify bootstrap servers: `let servers = try await KafkaContainer.bootstrapServers(from: container)`
   - Check advertised listeners configuration
   - Ensure client uses correct protocol (PLAINTEXT)

4. **Linux host.docker.internal not found**
   - Add custom environment: `.withEnvironment(["KAFKA_ADVERTISED_LISTENERS": "PLAINTEXT://172.17.0.1:9093"])`
   - Or use `--add-host=host.docker.internal:host-gateway` in Docker (future feature)

---

## Future Enhancements

### Near-term (Next 3-6 months)

1. **Redpanda-specific module** (`RedpandaContainer`)
   - Leverage faster startup time
   - Redpanda-specific configuration (Pandaproxy, Schema Registry)
   - Compatible API with KafkaContainer

2. **Multi-broker support**
   - `withBrokers(count: 3)` for cluster testing
   - Automatic network creation and attachment
   - Inter-broker communication configuration
   - Depends on: Network creation (Feature 024)

3. **TLS/SASL security**
   - `withTLS()`, `withSASL()` builder methods
   - Automatic certificate generation
   - Keystore/truststore setup

4. **Topic pre-creation**
   - `withTopic(name:partitions:replicas:)` builder method
   - Automatic topic creation before container is ready
   - Depends on: Container exec (Feature 007)

### Medium-term (6-12 months)

5. **Schema Registry integration**
   - `SchemaRegistryContainer` module
   - Automatic linking with KafkaContainer
   - Schema registration helpers

6. **Kafka Connect**
   - `KafkaConnectContainer` module
   - Connector plugin installation
   - Integration with Kafka cluster

7. **Transaction/idempotence helpers**
   - Built-in configuration for transactional testing
   - Idempotent producer settings

### Long-term (12+ months)

8. **Observability**
   - JMX metrics exposure
   - Prometheus integration
   - Custom monitoring setup

9. **Advanced networking**
   - Custom listener configuration
   - Multiple external ports
   - IPv6 support

10. **Performance testing utilities**
    - Built-in load generation
    - Throughput measurement
    - Latency benchmarking
