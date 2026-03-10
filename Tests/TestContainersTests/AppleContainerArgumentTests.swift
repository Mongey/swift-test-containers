import Foundation
import Testing
@testable import TestContainers

// MARK: - Argument Building Tests (no CLI needed)

@Test func appleContainer_buildRunArgs_basicImage() {
    let request = ContainerRequest(image: "alpine:3")
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(args[0] == "run")
    #expect(args[1] == "-d")
    #expect(args.contains("alpine:3"))
}

@Test func appleContainer_buildRunArgs_withName() {
    let request = ContainerRequest(image: "alpine:3")
        .withFixedName("my-container")
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(containsAppleSequence(["--name", "my-container"], in: args))
}

@Test func appleContainer_buildRunArgs_withPorts() {
    let request = ContainerRequest(image: "nginx:latest")
        .withExposedPort(80)
        .withExposedPort(8080, hostPort: 9090)
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(args.contains("-p"))
    #expect(args.contains("80"))
    #expect(args.contains("9090:8080"))
}

@Test func appleContainer_buildRunArgs_withEnvironment() {
    let request = ContainerRequest(image: "postgres:15")
        .withEnvironment(["POSTGRES_PASSWORD": "secret"])
        .withEnvironment(["POSTGRES_DB": "testdb"])
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(containsAppleSequence(["-e", "POSTGRES_DB=testdb"], in: args))
    #expect(containsAppleSequence(["-e", "POSTGRES_PASSWORD=secret"], in: args))
}

@Test func appleContainer_buildRunArgs_withLabels() {
    let request = ContainerRequest(image: "alpine:3")
        .withLabel("app", "test")
        .withLabel("env", "ci")
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(containsAppleSequence(["--label", "app=test"], in: args))
    #expect(containsAppleSequence(["--label", "env=ci"], in: args))
}

@Test func appleContainer_buildRunArgs_withCommand() {
    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
    let args = AppleContainerClient.buildContainerRunArgs(request)

    let imageIndex = args.firstIndex(of: "alpine:3")!
    #expect(args[imageIndex + 1] == "sleep")
    #expect(args[imageIndex + 2] == "30")
}

@Test func appleContainer_buildRunArgs_withPrivilegedAndCapabilities() {
    let request = ContainerRequest(image: "alpine:3")
        .withPrivileged()
        .withCapabilityAdd([.netAdmin, .netRaw])
        .withCapabilityDrop(.sysTime)
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(args.contains("--privileged"))
    #expect(containsAppleSequence(["--cap-add", "NET_ADMIN"], in: args))
    #expect(containsAppleSequence(["--cap-add", "NET_RAW"], in: args))
    #expect(containsAppleSequence(["--cap-drop", "SYS_TIME"], in: args))
}

@Test func appleContainer_buildRunArgs_withUser() {
    let request = ContainerRequest(image: "alpine:3")
        .withUser(uid: 1000, gid: 1000)
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(containsAppleSequence(["-u", "1000:1000"], in: args))
}

@Test func appleContainer_buildRunArgs_withPlatform() {
    let request = ContainerRequest(image: "alpine:3")
        .withPlatform("linux/amd64")
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(containsAppleSequence(["--platform", "linux/amd64"], in: args))
}

@Test func appleContainer_buildRunArgs_withNetwork() {
    let request = ContainerRequest(image: "alpine:3")
        .withNetwork(NetworkConnection(networkName: "my-net", aliases: ["app"]))
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(containsAppleSequence(["--network", "my-net"], in: args))
    #expect(containsAppleSequence(["--network-alias", "app"], in: args))
}

@Test func appleContainer_buildRunArgs_withNetworkMode() {
    let request = ContainerRequest(image: "alpine:3")
        .withNetworkMode(.host)
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(containsAppleSequence(["--network", "host"], in: args))
}

@Test func appleContainer_buildRunArgs_withBindMount() {
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(hostPath: "/tmp/data", containerPath: "/data", readOnly: true)
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(containsAppleSequence(["-v", "/tmp/data:/data:ro"], in: args))
}

@Test func appleContainer_buildRunArgs_withTmpfs() {
    let request = ContainerRequest(image: "alpine:3")
        .withTmpfs("/tmp/cache")
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(containsAppleSequence(["--tmpfs", "/tmp/cache"], in: args))
}

@Test func appleContainer_buildRunArgs_withHealthCheck() {
    let request = ContainerRequest(image: "alpine:3")
        .withHealthCheck(HealthCheckConfig(
            command: ["CMD-SHELL", "curl -f http://localhost/ || exit 1"],
            interval: .seconds(10),
            timeout: .seconds(5),
            retries: 3
        ))
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(containsAppleSequence(["--health-cmd", "CMD-SHELL curl -f http://localhost/ || exit 1"], in: args))
    #expect(containsAppleSequence(["--health-interval", "10s"], in: args))
    #expect(containsAppleSequence(["--health-timeout", "5s"], in: args))
    #expect(containsAppleSequence(["--health-retries", "3"], in: args))
}

@Test func appleContainer_buildRunArgs_withResourceLimits() {
    let request = ContainerRequest(image: "alpine:3")
        .withMemoryLimit("512m")
        .withCpuLimit("1.5")
    let args = AppleContainerClient.buildContainerRunArgs(request)

    #expect(containsAppleSequence(["-m", "512m"], in: args))
    #expect(containsAppleSequence(["--cpus", "1.5"], in: args))
}

@Test func appleContainer_buildCreateArgs_basicImage() {
    let request = ContainerRequest(image: "alpine:3")
    let args = AppleContainerClient.buildContainerCreateArgs(request)

    #expect(args[0] == "create")
    #expect(args.contains("alpine:3"))
    #expect(!args.contains("-d"))
}

// MARK: - Exec Args Tests

@Test func appleContainer_buildExecArgs_basic() {
    let args = AppleContainerClient.buildExecArgs(
        id: "abc123",
        command: ["ls", "-la"],
        options: ExecOptions()
    )

    #expect(args[0] == "exec")
    #expect(args.contains("abc123"))
    #expect(args.contains("ls"))
    #expect(args.contains("-la"))
}

@Test func appleContainer_buildExecArgs_withOptions() {
    let options = ExecOptions()
        .withUser("root")
        .withWorkingDirectory("/app")
        .withEnvironment(["FOO": "bar"])
    let args = AppleContainerClient.buildExecArgs(
        id: "abc123",
        command: ["whoami"],
        options: options
    )

    #expect(containsAppleSequence(["-u", "root"], in: args))
    #expect(containsAppleSequence(["-w", "/app"], in: args))
    #expect(containsAppleSequence(["-e", "FOO=bar"], in: args))
}

// MARK: - Build Args Tests

@Test func appleContainer_buildImageArgs_basic() {
    let config = ImageFromDockerfile(
        dockerfilePath: "Dockerfile",
        buildContext: "."
    )
    let args = AppleContainerClient.buildImageArgs(config, tag: "test:latest")

    #expect(args[0] == "build")
    #expect(containsAppleSequence(["-t", "test:latest"], in: args))
    #expect(containsAppleSequence(["-f", "Dockerfile"], in: args))
    #expect(args.last == ".")
}

@Test func appleContainer_buildImageArgs_withBuildArgs() {
    let config = ImageFromDockerfile(
        dockerfilePath: "test/Dockerfile",
        buildContext: "test"
    )
    .withBuildArg("VERSION", "1.0")
    let args = AppleContainerClient.buildImageArgs(config, tag: "myapp:v1")

    #expect(containsAppleSequence(["--build-arg", "VERSION=1.0"], in: args))
    #expect(args.last == "test")
}

// MARK: - Container List Parsing

@Test func appleContainer_parseContainerList_emptyOutput() throws {
    let result = try AppleContainerClient.parseContainerList("")
    #expect(result.isEmpty)
}

// MARK: - Utility Tests

@Test func appleContainer_formatDuration() {
    #expect(AppleContainerClient.formatDuration(.seconds(30)) == "30s")
    #expect(AppleContainerClient.formatDuration(.seconds(0)) == "0s")
    #expect(AppleContainerClient.formatDuration(.seconds(120)) == "120s")
}

@Test func appleContainer_shellEscape() {
    #expect(AppleContainerClient.shellEscape("/tmp/test") == "/tmp/test")
    #expect(AppleContainerClient.shellEscape("it's") == "it'\\''s")
}

@Test func appleContainer_shellQuote() {
    #expect(AppleContainerClient.shellQuote("/tmp/test") == "'/tmp/test'")
    #expect(AppleContainerClient.shellQuote("it's") == "'it'\\''s'")
}

// MARK: - Runtime Detection

@Test func runtimeDetection_defaultsToDocker() {
    let runtime = detectRuntime()
    #expect(runtime is DockerClient)
}

@Test func runtimeDetection_explicitDocker() {
    let runtime = detectRuntime(preferred: .docker)
    #expect(runtime is DockerClient)
}

@Test func runtimeDetection_explicitApple() {
    let runtime = detectRuntime(preferred: .appleContainer)
    #expect(runtime is AppleContainerClient)
}

@Test func runtimeDetection_unsupportedByRuntimeError() {
    let error = TestContainersError.unsupportedByRuntime("network connect not supported")
    #expect(error.description.contains("Unsupported by runtime"))
    #expect(error.description.contains("network connect not supported"))
}

// MARK: - Protocol Conformance

@Test func appleContainerClient_conformsToContainerRuntime() {
    let client = AppleContainerClient()
    let runtime: any ContainerRuntime = client
    #expect(runtime is AppleContainerClient)
}

@Test func dockerClient_conformsToContainerRuntime() {
    let client = DockerClient()
    let runtime: any ContainerRuntime = client
    #expect(runtime is DockerClient)
}

// MARK: - ConnectToNetwork throws unsupported

@Test func appleContainer_connectToNetwork_throwsUnsupported() async throws {
    let client = AppleContainerClient(containerPath: "/usr/bin/false", logger: .null, forTesting: true)
    await #expect(throws: TestContainersError.self) {
        try await client.connectToNetwork(containerId: "abc", networkName: "net")
    }
}

@Test func appleContainer_copyFromContainer_file_preservesBinaryData() async throws {
    let scriptPath = try makeAppleRuntimeMockScript(
        """
        #!/bin/sh
        if [ "$1" = "exec" ] && [ "$2" = "cid" ] && [ "$3" = "sh" ] && [ "$4" = "-c" ] && [ "$5" = "[ -d '/var/data.bin' ]" ]; then
          exit 1
        fi
        if [ "$1" = "exec" ] && [ "$2" = "cid" ] && [ "$3" = "sh" ] && [ "$4" = "-c" ] && [ "$5" = "cat -- '/var/data.bin'" ]; then
          printf '\\377\\000ABC'
          exit 0
        fi
        exit 2
        """
    )
    let client = AppleContainerClient(containerPath: scriptPath, logger: .null, forTesting: true)

    let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("apple-copy-out-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: outFile) }

    try await client.copyFromContainer(
        id: "cid",
        containerPath: "/var/data.bin",
        hostPath: outFile.path,
        archive: false
    )

    let data = try Data(contentsOf: outFile)
    #expect(Array(data) == [0xFF, 0x00, 0x41, 0x42, 0x43])
}

@Test func appleContainer_copyFromContainer_directory_throwsUnsupported() async throws {
    let scriptPath = try makeAppleRuntimeMockScript(
        """
        #!/bin/sh
        if [ "$1" = "exec" ] && [ "$2" = "cid" ] && [ "$3" = "sh" ] && [ "$4" = "-c" ] && [ "$5" = "[ -d '/var/app' ]" ]; then
          exit 0
        fi
        exit 1
        """
    )
    let client = AppleContainerClient(containerPath: scriptPath, logger: .null, forTesting: true)
    let outPath = FileManager.default.temporaryDirectory.appendingPathComponent("apple-copy-dir-\(UUID().uuidString)").path

    do {
        try await client.copyFromContainer(
            id: "cid",
            containerPath: "/var/app",
            hostPath: outPath,
            archive: true
        )
        Issue.record("Expected copyFromContainer to throw for directory copy")
    } catch let error as TestContainersError {
        if case .unsupportedByRuntime = error {
            // expected
        } else {
            Issue.record("Expected unsupportedByRuntime, got \(error)")
        }
    }
}

@Test func appleContainer_copyToContainer_file_quotesDestinationPath() async throws {
    let scriptPath = try makeAppleRuntimeMockScript(
        """
        #!/bin/sh
        if [ "$1" = "exec" ] && [ "$2" = "cid" ] && [ "$3" = "sh" ] && [ "$4" = "-c" ] && [ "$5" = "cat > '/tmp/with space/config.txt'" ]; then
          cat >/dev/null
          exit 0
        fi
        exit 1
        """
    )
    let client = AppleContainerClient(containerPath: scriptPath, logger: .null, forTesting: true)

    let sourceFile = FileManager.default.temporaryDirectory.appendingPathComponent("apple-copy-in-\(UUID().uuidString)")
    try Data("hello".utf8).write(to: sourceFile)
    defer { try? FileManager.default.removeItem(at: sourceFile) }

    try await client.copyToContainer(
        id: "cid",
        sourcePath: sourceFile.path,
        destinationPath: "/tmp/with space/config.txt"
    )
}

// MARK: - Helpers

private func containsAppleSequence(_ sequence: [String], in args: [String]) -> Bool {
    guard sequence.count > 0 else { return true }
    let searchLen = sequence.count
    for i in 0...(args.count - searchLen) {
        if Array(args[i..<(i + searchLen)]) == sequence {
            return true
        }
    }
    return false
}

private func makeAppleRuntimeMockScript(_ contents: String) throws -> String {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("apple-runtime-mock-\(UUID().uuidString).sh")
    try Data(contents.utf8).write(to: fileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
    return fileURL.path
}
