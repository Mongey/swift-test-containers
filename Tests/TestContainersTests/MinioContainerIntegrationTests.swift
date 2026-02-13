import Foundation
import Testing
@testable import TestContainers

// MARK: - MinioContainer Integration Tests

@Test func minioContainer_startsSuccessfully() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let minio = MinioContainer()

    try await withMinioContainer(minio) { container in
        let endpoint = try await container.s3Endpoint()
        #expect(endpoint.hasPrefix("http://"))
        #expect(endpoint.contains("127.0.0.1"))
    }
}

@Test func minioContainer_withCustomCredentials() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let minio = MinioContainer()
        .withCredentials(accessKey: "testuser", secretKey: "testpassword123")

    try await withMinioContainer(minio) { container in
        #expect(container.accessKey() == "testuser")
        #expect(container.secretKey() == "testpassword123")

        let endpoint = try await container.s3Endpoint()
        #expect(!endpoint.isEmpty)
    }
}

@Test func minioContainer_portMapping() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let minio = MinioContainer()

    try await withMinioContainer(minio) { container in
        let port = try await container.port()
        #expect(port > 0)

        let host = container.host()
        #expect(host == "127.0.0.1")
    }
}

@Test func minioContainer_consoleEndpoint() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let minio = MinioContainer()

    try await withMinioContainer(minio) { container in
        let consoleURL = try await container.consoleEndpoint()
        #expect(consoleURL.hasPrefix("http://127.0.0.1:"))
    }
}

@Test func minioContainer_connectionStringMatchesS3Endpoint() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let minio = MinioContainer()

    try await withMinioContainer(minio) { container in
        let s3 = try await container.s3Endpoint()
        let conn = try await container.connectionString()
        #expect(s3 == conn)
    }
}

@Test func minioContainer_logs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let minio = MinioContainer()

    try await withMinioContainer(minio) { container in
        let logs = try await container.logs()
        #expect(!logs.isEmpty)
    }
}

@Test func minioContainer_underlyingContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let minio = MinioContainer()

    try await withMinioContainer(minio) { container in
        let underlying = container.underlyingContainer
        let id = underlying.id
        #expect(!id.isEmpty)
    }
}

@Test func minioContainer_withBucketCreation() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let minio = MinioContainer()
        .withBucket("test-bucket")

    try await withMinioContainer(minio) { container in
        // Verify bucket was created by listing buckets
        let result = try await container.exec([
            "mc", "alias", "set", "local", "http://localhost:9000", "minioadmin", "minioadmin",
        ])
        #expect(result.exitCode == 0)

        let listResult = try await container.exec(["mc", "ls", "local/"])
        #expect(listResult.exitCode == 0)
        #expect(listResult.stdout.contains("test-bucket"))
    }
}

@Test func minioContainer_healthEndpointWorks() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let minio = MinioContainer()

    try await withMinioContainer(minio) { container in
        // Verify the health endpoint responds (which the wait strategy used)
        let result = try await container.exec([
            "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "http://localhost:9000/minio/health/ready",
        ])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("200"))
    }
}
