import Foundation
import Testing
@testable import TestContainers

// MARK: - MinioContainer Unit Tests

@Test func minioContainer_defaultValues() {
    let minio = MinioContainer()

    #expect(minio.image == "minio/minio:latest")
    #expect(minio.port == 9000)
    #expect(minio.consolePort == 9001)
    #expect(minio.accessKey == "minioadmin")
    #expect(minio.secretKey == "minioadmin")
    #expect(minio.consoleEnabled == true)
    #expect(minio.buckets.isEmpty)
    #expect(minio.host == "127.0.0.1")
}

@Test func minioContainer_customImage() {
    let minio = MinioContainer(image: "minio/minio:RELEASE.2024-01-16T16-07-38Z")

    #expect(minio.image == "minio/minio:RELEASE.2024-01-16T16-07-38Z")
}

@Test func minioContainer_withCredentials() {
    let minio = MinioContainer()
        .withCredentials(accessKey: "myuser", secretKey: "mypassword123")

    #expect(minio.accessKey == "myuser")
    #expect(minio.secretKey == "mypassword123")
}

@Test func minioContainer_withAccessKey() {
    let minio = MinioContainer()
        .withAccessKey("custom-access")

    #expect(minio.accessKey == "custom-access")
    #expect(minio.secretKey == "minioadmin") // unchanged
}

@Test func minioContainer_withSecretKey() {
    let minio = MinioContainer()
        .withSecretKey("custom-secret")

    #expect(minio.secretKey == "custom-secret")
    #expect(minio.accessKey == "minioadmin") // unchanged
}

@Test func minioContainer_withConsoleDisabled() {
    let minio = MinioContainer()
        .withConsole(false)

    #expect(minio.consoleEnabled == false)
}

@Test func minioContainer_withBucket() {
    let minio = MinioContainer()
        .withBucket("test-bucket")

    #expect(minio.buckets == ["test-bucket"])
}

@Test func minioContainer_withMultipleBuckets() {
    let minio = MinioContainer()
        .withBucket("bucket1")
        .withBucket("bucket2")

    #expect(minio.buckets == ["bucket1", "bucket2"])
}

@Test func minioContainer_withBucketsArray() {
    let minio = MinioContainer()
        .withBuckets(["uploads", "exports", "backups"])

    #expect(minio.buckets == ["uploads", "exports", "backups"])
}

@Test func minioContainer_withHost() {
    let minio = MinioContainer()
        .withHost("localhost")

    #expect(minio.host == "localhost")
}

@Test func minioContainer_methodChaining() {
    let minio = MinioContainer(image: "minio/minio:RELEASE.2024-01-16T16-07-38Z")
        .withCredentials(accessKey: "user", secretKey: "password123")
        .withConsole(false)
        .withBuckets(["bucket1", "bucket2"])
        .withHost("localhost")

    #expect(minio.image == "minio/minio:RELEASE.2024-01-16T16-07-38Z")
    #expect(minio.accessKey == "user")
    #expect(minio.secretKey == "password123")
    #expect(minio.consoleEnabled == false)
    #expect(minio.buckets == ["bucket1", "bucket2"])
    #expect(minio.host == "localhost")
}

@Test func minioContainer_builderReturnsNewInstance() {
    let original = MinioContainer()
    let modified = original.withAccessKey("custom")

    #expect(original.accessKey == "minioadmin")
    #expect(modified.accessKey == "custom")
}

@Test func minioContainer_isHashable() {
    let minio1 = MinioContainer()
        .withAccessKey("user1")
    let minio2 = MinioContainer()
        .withAccessKey("user1")
    let minio3 = MinioContainer()
        .withAccessKey("user2")

    #expect(minio1 == minio2)
    #expect(minio1 != minio3)
}

// MARK: - toContainerRequest Tests

@Test func minioContainer_toContainerRequest_setsImage() {
    let minio = MinioContainer(image: "minio/minio:RELEASE.2024-01-16T16-07-38Z")

    let request = minio.toContainerRequest()

    #expect(request.image == "minio/minio:RELEASE.2024-01-16T16-07-38Z")
}

@Test func minioContainer_toContainerRequest_setsS3Port() {
    let minio = MinioContainer()

    let request = minio.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 9000 })
}

@Test func minioContainer_toContainerRequest_setsConsolePortWhenEnabled() {
    let minio = MinioContainer()

    let request = minio.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 9001 })
}

@Test func minioContainer_toContainerRequest_omitsConsolePortWhenDisabled() {
    let minio = MinioContainer()
        .withConsole(false)

    let request = minio.toContainerRequest()

    #expect(!request.ports.contains { $0.containerPort == 9001 })
    #expect(request.ports.contains { $0.containerPort == 9000 })
}

@Test func minioContainer_toContainerRequest_setsCredentialEnvVars() {
    let minio = MinioContainer()
        .withCredentials(accessKey: "myuser", secretKey: "mypass123")

    let request = minio.toContainerRequest()

    #expect(request.environment["MINIO_ROOT_USER"] == "myuser")
    #expect(request.environment["MINIO_ROOT_PASSWORD"] == "mypass123")
}

@Test func minioContainer_toContainerRequest_setsDefaultCredentialEnvVars() {
    let minio = MinioContainer()

    let request = minio.toContainerRequest()

    #expect(request.environment["MINIO_ROOT_USER"] == "minioadmin")
    #expect(request.environment["MINIO_ROOT_PASSWORD"] == "minioadmin")
}

@Test func minioContainer_toContainerRequest_setsCommand() {
    let minio = MinioContainer()

    let request = minio.toContainerRequest()

    #expect(request.command.contains("server"))
    #expect(request.command.contains("/data"))
    #expect(request.command.contains("--console-address"))
    #expect(request.command.contains(":9001"))
}

@Test func minioContainer_toContainerRequest_setsHost() {
    let minio = MinioContainer()
        .withHost("localhost")

    let request = minio.toContainerRequest()

    #expect(request.host == "localhost")
}

@Test func minioContainer_toContainerRequest_setsHttpWaitStrategy() {
    let minio = MinioContainer()

    let request = minio.toContainerRequest()

    if case let .http(config) = request.waitStrategy {
        #expect(config.port == 9000)
        #expect(config.path == "/minio/health/ready")
    } else {
        Issue.record("Expected .http wait strategy, got \(request.waitStrategy)")
    }
}

@Test func minioContainer_toContainerRequest_customWaitStrategy() {
    let minio = MinioContainer()
        .waitingFor(.tcpPort(9000, timeout: .seconds(30)))

    let request = minio.toContainerRequest()

    if case let .tcpPort(port, timeout, _) = request.waitStrategy {
        #expect(port == 9000)
        #expect(timeout == .seconds(30))
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

// MARK: - Connection String Tests

@Test func minioContainer_connectionString_basic() {
    let connStr = MinioContainer.buildS3Endpoint(
        host: "localhost",
        port: 9000
    )

    #expect(connStr == "http://localhost:9000")
}

@Test func minioContainer_connectionString_customPort() {
    let connStr = MinioContainer.buildS3Endpoint(
        host: "127.0.0.1",
        port: 49152
    )

    #expect(connStr == "http://127.0.0.1:49152")
}

// MARK: - Default Constants Tests

@Test func minioContainer_defaultConstants() {
    #expect(MinioContainer.defaultImage == "minio/minio:latest")
    #expect(MinioContainer.defaultPort == 9000)
    #expect(MinioContainer.defaultConsolePort == 9001)
    #expect(MinioContainer.defaultAccessKey == "minioadmin")
    #expect(MinioContainer.defaultSecretKey == "minioadmin")
}
