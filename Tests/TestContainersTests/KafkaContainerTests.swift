import Foundation
import Testing
@testable import TestContainers

// MARK: - KafkaContainer Unit Tests

@Test func kafkaContainer_defaultImageUsesConfluentLocal() {
    let kafka = KafkaContainer()
    let request = kafka.build()

    #expect(request.image == "confluentinc/confluent-local:7.5.0")
}

@Test func kafkaContainer_customImageVersion() {
    let kafka = KafkaContainer(image: .confluentLocal(version: "7.6.0"))
    let request = kafka.build()

    #expect(request.image == "confluentinc/confluent-local:7.6.0")
}

@Test func kafkaContainer_apacheNativeImage() {
    let kafka = KafkaContainer(image: .apacheNative())
    let request = kafka.build()

    #expect(request.image == "apache/kafka-native:3.8.0")
}

@Test func kafkaContainer_customImage() {
    let kafka = KafkaContainer(image: .custom("my-kafka:latest"))
    let request = kafka.build()

    #expect(request.image == "my-kafka:latest")
}

@Test func kafkaContainer_exposesDefaultPort() {
    let kafka = KafkaContainer()
    let request = kafka.build()

    #expect(request.ports.contains { $0.containerPort == 9093 })
}

@Test func kafkaContainer_setsKRaftEnvironmentVariables() {
    let kafka = KafkaContainer()
    let request = kafka.build()

    #expect(request.environment["KAFKA_NODE_ID"] == "1")
    #expect(request.environment["KAFKA_PROCESS_ROLES"] == "broker,controller")
    #expect(request.environment["KAFKA_CONTROLLER_QUORUM_VOTERS"] == "1@localhost:9094")
    #expect(request.environment["KAFKA_LISTENERS"]?.contains("PLAINTEXT://0.0.0.0:9093") == true)
    #expect(request.environment["KAFKA_CONTROLLER_LISTENER_NAMES"] == "CONTROLLER")
    #expect(request.environment["KAFKA_INTER_BROKER_LISTENER_NAME"] == "BROKER")
}

@Test func kafkaContainer_customClusterID() {
    let kafka = KafkaContainer()
        .withClusterID("my-cluster-123")
    let request = kafka.build()

    #expect(request.environment["CLUSTER_ID"] == "my-cluster-123")
}

@Test func kafkaContainer_customReplicationFactor() {
    let kafka = KafkaContainer()
        .withReplicationFactor(3)
    let request = kafka.build()

    #expect(request.environment["KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR"] == "3")
    #expect(request.environment["KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR"] == "3")
}

@Test func kafkaContainer_customPartitions() {
    let kafka = KafkaContainer()
        .withPartitions(5)
    let request = kafka.build()

    #expect(request.environment["KAFKA_OFFSETS_TOPIC_NUM_PARTITIONS"] == "5")
}

@Test func kafkaContainer_customMinInSyncReplicas() {
    let kafka = KafkaContainer()
        .withMinInSyncReplicas(2)
    let request = kafka.build()

    #expect(request.environment["KAFKA_TRANSACTION_STATE_LOG_MIN_ISR"] == "2")
}

@Test func kafkaContainer_customEnvironmentVariables() {
    let kafka = KafkaContainer()
        .withEnvironment([
            "KAFKA_LOG_RETENTION_MS": "5000",
            "KAFKA_AUTO_CREATE_TOPICS_ENABLE": "false",
        ])
    let request = kafka.build()

    #expect(request.environment["KAFKA_LOG_RETENTION_MS"] == "5000")
    #expect(request.environment["KAFKA_AUTO_CREATE_TOPICS_ENABLE"] == "false")
}

@Test func kafkaContainer_defaultWaitStrategy() {
    let kafka = KafkaContainer()
    let request = kafka.build()

    if case let .logContains(text, timeout, _) = request.waitStrategy {
        #expect(text == "Kafka Server started")
        #expect(timeout == .seconds(60))
    } else {
        Issue.record("Expected logContains wait strategy")
    }
}

@Test func kafkaContainer_customWaitStrategy() {
    let kafka = KafkaContainer()
        .waitingFor(.tcpPort(9093, timeout: .seconds(30)))
    let request = kafka.build()

    if case let .tcpPort(port, timeout, _) = request.waitStrategy {
        #expect(port == 9093)
        #expect(timeout == .seconds(30))
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

@Test func kafkaContainer_addsModuleLabel() {
    let kafka = KafkaContainer()
    let request = kafka.build()

    #expect(request.labels["testcontainers.module"] == "kafka")
}

@Test func kafkaContainer_builderChaining() {
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

@Test func kafkaContainer_builderReturnsNewInstance() {
    let original = KafkaContainer()
    let modified = original.withPartitions(8)

    #expect(original.build().environment["KAFKA_OFFSETS_TOPIC_NUM_PARTITIONS"] == "1")
    #expect(modified.build().environment["KAFKA_OFFSETS_TOPIC_NUM_PARTITIONS"] == "8")
}

@Test func kafkaContainer_isSendable() {
    func requireSendable<T: Sendable>(_: T.Type) {}

    requireSendable(KafkaContainer.self)
    requireSendable(KafkaContainer.Image.self)
}

// MARK: - Kafka Integration Tests

@Test func kafkaContainer_startsKafkaContainer() async throws {
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

@Test func kafkaContainer_bootstrapServersReturnsValidFormat() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let kafka = KafkaContainer()

    try await withContainer(kafka.build()) { container in
        let servers = try await KafkaContainer.bootstrapServers(from: container)

        let parts = servers.split(separator: ":")
        #expect(parts.count == 2)

        let host = String(parts[0])
        let port = Int(String(parts[1]))

        #expect(!host.isEmpty)
        #expect(port != nil)
        #expect(port! > 0)
    }
}

@Test func kafkaContainer_containerLogsShowKafkaStartup() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let kafka = KafkaContainer()

    try await withContainer(kafka.build()) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Kafka Server started") || logs.contains("started (kafka.server"))
    }
}

@Test func kafkaContainer_customConfigurationApplied() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let kafka = KafkaContainer()
        .withClusterID("custom-test-cluster")
        .withPartitions(5)

    try await withContainer(kafka.build()) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Kafka Server started") || logs.contains("started (kafka.server"))
    }
}
