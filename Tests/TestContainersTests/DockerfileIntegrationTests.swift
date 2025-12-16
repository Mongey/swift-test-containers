import Foundation
import Testing
@testable import TestContainers

// MARK: - Dockerfile Build Integration Tests

/// Helper to check if Docker integration tests should run
private func shouldRunDockerTests() -> Bool {
    ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
}

/// Creates a temporary directory with a Dockerfile
private func createTempDockerContext(dockerfile: String) throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let dockerfilePath = tempDir.appendingPathComponent("Dockerfile")
    try dockerfile.write(to: dockerfilePath, atomically: true, encoding: .utf8)

    return tempDir
}

/// Cleans up a temporary directory
private func cleanupTempDir(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

@Test func dockerfile_simpleEchoContainer() async throws {
    guard shouldRunDockerTests() else { return }

    let dockerfile = """
    FROM alpine:3
    CMD ["echo", "Hello from Dockerfile"]
    """

    let tempDir = try createTempDockerContext(dockerfile: dockerfile)
    defer { cleanupTempDir(tempDir) }

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
        .waitingFor(.logContains("Hello from Dockerfile", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Hello from Dockerfile"))
    }
}

@Test func dockerfile_withBuildArg() async throws {
    guard shouldRunDockerTests() else { return }

    let dockerfile = """
    FROM alpine:3
    ARG GREETING=Default
    RUN echo "Build arg: $GREETING" > /greeting.txt
    CMD ["cat", "/greeting.txt"]
    """

    let tempDir = try createTempDockerContext(dockerfile: dockerfile)
    defer { cleanupTempDir(tempDir) }

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )
        .withBuildArg("GREETING", "HelloWorld123")

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
        .waitingFor(.logContains("HelloWorld123", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Build arg: HelloWorld123"))
    }
}

@Test func dockerfile_multiStageBuild_targetStage() async throws {
    guard shouldRunDockerTests() else { return }

    let dockerfile = """
    FROM alpine:3 AS builder
    RUN echo "builder stage" > /stage.txt

    FROM alpine:3 AS runtime
    RUN echo "runtime stage" > /stage.txt
    CMD ["cat", "/stage.txt"]
    """

    let tempDir = try createTempDockerContext(dockerfile: dockerfile)
    defer { cleanupTempDir(tempDir) }

    // Target the builder stage
    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )
        .withTargetStage("builder")

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
        .withCommand(["cat", "/stage.txt"])
        .waitingFor(.logContains("builder stage", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("builder stage"))
        #expect(!logs.contains("runtime stage"))
    }
}

@Test func dockerfile_withCopyInstruction() async throws {
    guard shouldRunDockerTests() else { return }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { cleanupTempDir(tempDir) }

    // Create a file to copy
    let testContent = "This is test content from build context"
    try testContent.write(
        to: tempDir.appendingPathComponent("testfile.txt"),
        atomically: true,
        encoding: .utf8
    )

    // Create Dockerfile that copies the file
    let dockerfile = """
    FROM alpine:3
    COPY testfile.txt /app/testfile.txt
    CMD ["cat", "/app/testfile.txt"]
    """
    try dockerfile.write(
        to: tempDir.appendingPathComponent("Dockerfile"),
        atomically: true,
        encoding: .utf8
    )

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
        .waitingFor(.logContains("test content", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains(testContent))
    }
}

@Test func dockerfile_imageIsCleanedUpAfterTest() async throws {
    guard shouldRunDockerTests() else { return }

    let dockerfile = """
    FROM alpine:3
    CMD ["echo", "cleanup test"]
    """

    let tempDir = try createTempDockerContext(dockerfile: dockerfile)
    defer { cleanupTempDir(tempDir) }

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
        .waitingFor(.logContains("cleanup test", timeout: .seconds(30)))

    // Capture the image tag from the request before running
    let capturedImageTag = request.image

    try await withContainer(request) { _ in
        // Container runs successfully
    }

    // Verify the image was removed after test
    // Give a moment for cleanup to complete
    try await Task.sleep(for: .milliseconds(500))

    let docker = DockerClient()
    // Use runDocker which is internal but accessible from tests
    let output = try? await docker.runDocker(["images", "-q", capturedImageTag])

    // Image should not exist or runDocker should fail
    let images = output?.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
    #expect(images.isEmpty, "Built image should have been cleaned up")
}

@Test func dockerfile_buildFailure_throwsError() async throws {
    guard shouldRunDockerTests() else { return }

    // Invalid Dockerfile that will fail to build
    let dockerfile = """
    FROM alpine:3
    RUN /nonexistent-command-that-will-fail
    """

    let tempDir = try createTempDockerContext(dockerfile: dockerfile)
    defer { cleanupTempDir(tempDir) }

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)

    await #expect(throws: TestContainersError.self) {
        try await withContainer(request) { _ in
            Issue.record("Should not reach here - build should fail")
        }
    }
}

@Test func dockerfile_withExposedPort() async throws {
    guard shouldRunDockerTests() else { return }

    // Use busybox httpd as a simple HTTP server
    let dockerfile = """
    FROM busybox:latest
    RUN mkdir -p /www && echo "Hello" > /www/index.html
    EXPOSE 8080
    CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
    """

    let tempDir = try createTempDockerContext(dockerfile: dockerfile)
    defer { cleanupTempDir(tempDir) }

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
        .withExposedPort(8080)
        .waitingFor(.tcpPort(8080, timeout: .seconds(30)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(8080)
        #expect(port > 0)
    }
}

@Test func dockerfile_withEnvironmentVariables() async throws {
    guard shouldRunDockerTests() else { return }

    let dockerfile = """
    FROM alpine:3
    CMD ["sh", "-c", "echo MY_VAR=$MY_VAR"]
    """

    let tempDir = try createTempDockerContext(dockerfile: dockerfile)
    defer { cleanupTempDir(tempDir) }

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
        .withEnvironment(["MY_VAR": "test_value_123"])
        .waitingFor(.logContains("MY_VAR=test_value_123", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("MY_VAR=test_value_123"))
    }
}

@Test func dockerfile_withNoCache() async throws {
    guard shouldRunDockerTests() else { return }

    let dockerfile = """
    FROM alpine:3
    CMD ["echo", "no cache build"]
    """

    let tempDir = try createTempDockerContext(dockerfile: dockerfile)
    defer { cleanupTempDir(tempDir) }

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )
        .withNoCache()

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
        .waitingFor(.logContains("no cache build", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("no cache build"))
    }
}

@Test func dockerfile_multipleBuildArgs() async throws {
    guard shouldRunDockerTests() else { return }

    let dockerfile = """
    FROM alpine:3
    ARG VERSION=unknown
    ARG ENV=unknown
    ARG DEBUG=false
    RUN echo "VERSION=$VERSION ENV=$ENV DEBUG=$DEBUG" > /info.txt
    CMD ["cat", "/info.txt"]
    """

    let tempDir = try createTempDockerContext(dockerfile: dockerfile)
    defer { cleanupTempDir(tempDir) }

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )
        .withBuildArg("VERSION", "1.2.3")
        .withBuildArg("ENV", "testing")
        .withBuildArg("DEBUG", "true")

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
        .waitingFor(.logContains("VERSION=1.2.3", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("VERSION=1.2.3"))
        #expect(logs.contains("ENV=testing"))
        #expect(logs.contains("DEBUG=true"))
    }
}
