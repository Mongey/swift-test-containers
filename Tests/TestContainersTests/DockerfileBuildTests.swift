import Foundation
import Testing
@testable import TestContainers

// MARK: - DockerClient.buildImageArgs Tests

@Test func dockerClient_buildImageArgs_basicBuild() {
    let config = ImageFromDockerfile(
        dockerfilePath: "Dockerfile",
        buildContext: "."
    )

    let args = DockerClient.buildImageArgs(config: config, tag: "test:latest")

    #expect(args.contains("build"))
    #expect(args.contains("-t"))
    #expect(args.contains("test:latest"))
    #expect(args.contains("-f"))
    #expect(args.contains("Dockerfile"))
    #expect(args.last == ".")
}

@Test func dockerClient_buildImageArgs_withBuildArgs() {
    let config = ImageFromDockerfile()
        .withBuildArg("VERSION", "1.0.0")
        .withBuildArg("ENV", "test")

    let args = DockerClient.buildImageArgs(config: config, tag: "test:latest")

    // Build args should be sorted alphabetically for deterministic output
    let buildArgIndex = args.firstIndex(of: "--build-arg")!
    #expect(args[buildArgIndex + 1] == "ENV=test")

    // Find the second --build-arg
    let secondBuildArgIndex = args[(buildArgIndex + 2)...].firstIndex(of: "--build-arg")!
    #expect(args[secondBuildArgIndex + 1] == "VERSION=1.0.0")
}

@Test func dockerClient_buildImageArgs_withTargetStage() {
    let config = ImageFromDockerfile()
        .withTargetStage("builder")

    let args = DockerClient.buildImageArgs(config: config, tag: "test:latest")

    #expect(args.contains("--target"))
    #expect(args.contains("builder"))
}

@Test func dockerClient_buildImageArgs_withNoCache() {
    let config = ImageFromDockerfile()
        .withNoCache()

    let args = DockerClient.buildImageArgs(config: config, tag: "test:latest")

    #expect(args.contains("--no-cache"))
}

@Test func dockerClient_buildImageArgs_withPullBaseImages() {
    let config = ImageFromDockerfile()
        .withPullBaseImages()

    let args = DockerClient.buildImageArgs(config: config, tag: "test:latest")

    #expect(args.contains("--pull"))
}

@Test func dockerClient_buildImageArgs_allOptions() {
    let config = ImageFromDockerfile(
        dockerfilePath: "docker/Dockerfile.test",
        buildContext: "./src"
    )
        .withBuildArg("VERSION", "2.0")
        .withTargetStage("production")
        .withNoCache()
        .withPullBaseImages()

    let args = DockerClient.buildImageArgs(config: config, tag: "myapp:v2")

    #expect(args.contains("build"))
    #expect(args.contains("-t"))
    #expect(args.contains("myapp:v2"))
    #expect(args.contains("-f"))
    #expect(args.contains("docker/Dockerfile.test"))
    #expect(args.contains("--build-arg"))
    #expect(args.contains("VERSION=2.0"))
    #expect(args.contains("--target"))
    #expect(args.contains("production"))
    #expect(args.contains("--no-cache"))
    #expect(args.contains("--pull"))
    #expect(args.last == "./src")  // Build context must be last
}

@Test func dockerClient_buildImageArgs_contextIsLast() {
    let config = ImageFromDockerfile(
        dockerfilePath: "Dockerfile",
        buildContext: "/path/to/context"
    )
        .withBuildArg("A", "1")
        .withTargetStage("test")
        .withNoCache()
        .withPullBaseImages()

    let args = DockerClient.buildImageArgs(config: config, tag: "test:latest")

    // Build context must always be the last argument
    #expect(args.last == "/path/to/context")
}

// MARK: - TestContainersError.imageBuildFailed Tests

@Test func imageBuildFailed_error_description() {
    let error = TestContainersError.imageBuildFailed(
        dockerfile: "test/Dockerfile",
        context: "test",
        exitCode: 1,
        stdout: "Step 1/3 : FROM alpine",
        stderr: "Error: invalid reference format"
    )

    let description = error.description

    #expect(description.contains("Docker image build failed"))
    #expect(description.contains("exit 1"))
    #expect(description.contains("test/Dockerfile"))
    #expect(description.contains("Context"))  // Note: Capital C as in error message
    #expect(description.contains("invalid reference format"))
}
