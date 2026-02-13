import Foundation
import Testing
@testable import TestContainers

// MARK: - DockerClient.inspectImage Argument Tests

@Test func dockerClient_inspectImage_passesCorrectArgs() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeImageInspectMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let inspection = try await docker.inspectImage("redis:7-alpine")

    // Verify correct docker args
    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.contains("image"))
    #expect(args.contains("inspect"))
    #expect(args.contains("redis:7-alpine"))

    // Verify parsed result
    #expect(inspection.id == "sha256:abc123")
    #expect(inspection.architecture == "amd64")
    #expect(inspection.config.exposedPorts.keys.contains("6379/tcp"))
}

@Test func dockerClient_inspectImage_withPlatform_passesPlatformFlag() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeImageInspectMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let _ = try await docker.inspectImage("alpine:3", platform: "linux/arm64")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.contains("image"))
    #expect(args.contains("inspect"))
    #expect(args.contains("--platform"))
    #expect(args.contains("linux/arm64"))
    #expect(args.contains("alpine:3"))
}

// MARK: - DockerClient.imageExists Public Access

@Test func dockerClient_imageExists_isPubliclyAccessible() async {
    let docker = DockerClient(dockerPath: "/usr/bin/false")
    // This should compile if imageExists is public
    let _: Bool = await docker.imageExists("nonexistent:99")
}

@Test func dockerClient_imageExists_withPlatform_passesArgs() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeImageInspectMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let exists = await docker.imageExists("redis:7", platform: "linux/amd64")

    #expect(exists == true)

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.contains("image"))
    #expect(args.contains("inspect"))
    #expect(args.contains("--platform"))
    #expect(args.contains("linux/amd64"))
}

@Test func dockerClient_imageExists_returnsFalseOnFailure() async {
    let docker = DockerClient(dockerPath: "/usr/bin/false")
    let exists = await docker.imageExists("nonexistent:99")
    #expect(exists == false)
}

// MARK: - DockerClient.pullImage Public Access

@Test func dockerClient_pullImage_isPubliclyAccessible() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeImageInspectMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    // This should compile if pullImage is public
    try await docker.pullImage("alpine:3")
}

@Test func dockerClient_pullImage_withPlatform_passesPlatformFlag() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeImageInspectMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    try await docker.pullImage("alpine:3", platform: "linux/arm64")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.contains("pull"))
    #expect(args.contains("--platform"))
    #expect(args.contains("linux/arm64"))
    #expect(args.contains("alpine:3"))
}

// MARK: - Mock Script Helper

/// Creates a mock docker script that outputs JSON for image inspect commands
/// and records arguments for verification.
private func makeImageInspectMockScript(in tempDir: URL, argsFileURL: URL) throws -> URL {
    let scriptURL = tempDir.appendingPathComponent("docker-mock.sh")
    let json = """
    [{"Id":"sha256:abc123","RepoTags":["redis:7-alpine"],"RepoDigests":[],"Created":"2024-12-10T00:00:00Z","Size":100,"Architecture":"amd64","Os":"linux","Author":"","Config":{"User":"","Env":[],"Cmd":null,"WorkingDir":"","Entrypoint":null,"ExposedPorts":{"6379/tcp":{}},"Labels":null,"Volumes":null,"OnBuild":null},"RootFS":{"Type":"layers","Layers":[]}}]
    """

    let script = """
    #!/bin/sh
    printf '%s\\n' "$@" > "\(argsFileURL.path)"
    cat << 'ENDJSON'
    \(json)
    ENDJSON
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
}
