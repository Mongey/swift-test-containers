import Foundation
import Testing
@testable import TestContainers

// MARK: - RegistryAuth Type Tests

@Test func registryAuth_credentials_storesValues() {
    let auth = RegistryAuth.credentials(
        registry: "ghcr.io",
        username: "testuser",
        password: "testpass"
    )

    if case let .credentials(registry, username, password) = auth {
        #expect(registry == "ghcr.io")
        #expect(username == "testuser")
        #expect(password == "testpass")
    } else {
        Issue.record("Expected .credentials case")
    }
}

@Test func registryAuth_configFile_storesPath() {
    let auth = RegistryAuth.configFile(path: "/tmp/docker-config")

    if case let .configFile(path) = auth {
        #expect(path == "/tmp/docker-config")
    } else {
        Issue.record("Expected .configFile case")
    }
}

@Test func registryAuth_systemDefault_matchesCase() {
    let auth = RegistryAuth.systemDefault

    if case .systemDefault = auth {
        // Success
    } else {
        Issue.record("Expected .systemDefault case")
    }
}

@Test func registryAuth_conformsToHashable() {
    let auth1 = RegistryAuth.credentials(registry: "r1", username: "u1", password: "p1")
    let auth2 = RegistryAuth.credentials(registry: "r1", username: "u1", password: "p1")
    let auth3 = RegistryAuth.credentials(registry: "r2", username: "u2", password: "p2")

    #expect(auth1 == auth2)
    #expect(auth1 != auth3)
}

@Test func registryAuth_differentCases_notEqual() {
    let credentials = RegistryAuth.credentials(registry: "r", username: "u", password: "p")
    let configFile = RegistryAuth.configFile(path: "/tmp")
    let systemDefault = RegistryAuth.systemDefault

    #expect(credentials != configFile)
    #expect(credentials != systemDefault)
    #expect(configFile != systemDefault)
}

@Test func registryAuth_configFile_differentPaths_notEqual() {
    let auth1 = RegistryAuth.configFile(path: "/path/a")
    let auth2 = RegistryAuth.configFile(path: "/path/b")

    #expect(auth1 != auth2)
}

// MARK: - ContainerRequest.registryAuth Tests

@Test func containerRequest_registryAuth_defaultsToNil() {
    let request = ContainerRequest(image: "alpine:3")
    #expect(request.registryAuth == nil)
}

@Test func containerRequest_registryAuth_dockerfileInit_defaultsToNil() {
    let request = ContainerRequest(imageFromDockerfile: ImageFromDockerfile())
    #expect(request.registryAuth == nil)
}

@Test func containerRequest_withRegistryAuth_credentials() {
    let request = ContainerRequest(image: "ghcr.io/myorg/private:latest")
        .withRegistryAuth(.credentials(
            registry: "ghcr.io",
            username: "myuser",
            password: "mytoken"
        ))

    #expect(request.registryAuth != nil)
    if case let .credentials(registry, username, password) = request.registryAuth {
        #expect(registry == "ghcr.io")
        #expect(username == "myuser")
        #expect(password == "mytoken")
    } else {
        Issue.record("Expected .credentials auth")
    }
}

@Test func containerRequest_withRegistryAuth_configFile() {
    let request = ContainerRequest(image: "private.registry.io/app:v1")
        .withRegistryAuth(.configFile(path: "/tmp/test-docker-config"))

    if case let .configFile(path) = request.registryAuth {
        #expect(path == "/tmp/test-docker-config")
    } else {
        Issue.record("Expected .configFile auth")
    }
}

@Test func containerRequest_withRegistryAuth_systemDefault() {
    let request = ContainerRequest(image: "myuser/private:latest")
        .withRegistryAuth(.systemDefault)

    if case .systemDefault = request.registryAuth {
        // Success
    } else {
        Issue.record("Expected .systemDefault auth")
    }
}

@Test func containerRequest_withRegistryAuth_returnsNewInstance() {
    let original = ContainerRequest(image: "alpine:3")
    let modified = original.withRegistryAuth(.systemDefault)

    #expect(original.registryAuth == nil)
    #expect(modified.registryAuth != nil)
}

@Test func containerRequest_withRegistryAuth_chainsWithOtherBuilders() {
    let request = ContainerRequest(image: "ghcr.io/myorg/app:v1")
        .withRegistryAuth(.credentials(
            registry: "ghcr.io",
            username: "user",
            password: "pass"
        ))
        .withExposedPort(8080)
        .withEnvironment(["DB_HOST": "localhost"])
        .waitingFor(.tcpPort(8080))

    #expect(request.registryAuth != nil)
    #expect(request.ports.count == 1)
    #expect(request.environment["DB_HOST"] == "localhost")
}

@Test func containerRequest_withRegistryAuth_conformsToHashable() {
    let request1 = ContainerRequest(image: "alpine:3")
        .withRegistryAuth(.credentials(registry: "r", username: "u", password: "p"))
    let request2 = ContainerRequest(image: "alpine:3")
        .withRegistryAuth(.credentials(registry: "r", username: "u", password: "p"))
    let request3 = ContainerRequest(image: "alpine:3")

    #expect(request1 == request2)
    #expect(request1 != request3)
}

// MARK: - DockerClient.loginArgs Tests

@Test func dockerClient_loginArgs_buildsCorrectArguments() {
    let args = DockerClient.loginArgs(registry: "ghcr.io", username: "myuser")

    #expect(args == ["login", "ghcr.io", "-u", "myuser", "--password-stdin"])
}

@Test func dockerClient_loginArgs_dockerHub() {
    let args = DockerClient.loginArgs(registry: "https://index.docker.io/v1/", username: "dockeruser")

    #expect(args == ["login", "https://index.docker.io/v1/", "-u", "dockeruser", "--password-stdin"])
}

// MARK: - DockerClient Login Integration Tests (Mock Script)

@Test func dockerClient_runContainer_withCredentials_callsLoginBeforeRun() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeRegistryAuthMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "ghcr.io/myorg/private:latest")
        .withRegistryAuth(.credentials(
            registry: "ghcr.io",
            username: "testuser",
            password: "testtoken"
        ))

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    // Read all captured calls
    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let calls = argsText.components(separatedBy: "---\n").filter { !$0.isEmpty }

    // Should have at least 2 calls: login + run
    #expect(calls.count >= 2)

    // First call should be docker login
    let loginArgs = calls[0].split(separator: "\n").map(String.init)
    #expect(loginArgs.contains("login"))
    #expect(loginArgs.contains("ghcr.io"))
    #expect(loginArgs.contains("-u"))
    #expect(loginArgs.contains("testuser"))
    #expect(loginArgs.contains("--password-stdin"))

    // Second call should be docker run
    let runArgs = calls[1].split(separator: "\n").map(String.init)
    #expect(runArgs.contains("run"))
    #expect(runArgs.contains("-d"))
    #expect(runArgs.contains("ghcr.io/myorg/private:latest"))
}

@Test func dockerClient_runContainer_withConfigFile_passesDockerConfigEnv() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let envFileURL = tempDir.appendingPathComponent("env.txt")
    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeRegistryAuthMockScriptWithEnv(in: tempDir, argsFileURL: argsFileURL, envFileURL: envFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "private.registry.io/app:v1")
        .withRegistryAuth(.configFile(path: "/tmp/custom-docker-config"))

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    // The DOCKER_CONFIG env should have been set
    let envText = try String(contentsOf: envFileURL, encoding: .utf8)
    #expect(envText.contains("DOCKER_CONFIG=/tmp/custom-docker-config"))
}

@Test func dockerClient_runContainer_withSystemDefault_noExtraCalls() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeRegistryAuthMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "myuser/private:latest")
        .withRegistryAuth(.systemDefault)

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    // Should only have one call (run), no login
    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let calls = argsText.components(separatedBy: "---\n").filter { !$0.isEmpty }
    #expect(calls.count == 1)

    let runArgs = calls[0].split(separator: "\n").map(String.init)
    #expect(runArgs.contains("run"))
    #expect(!runArgs.contains("login"))
}

@Test func dockerClient_runContainer_withoutAuth_noLoginCall() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeRegistryAuthMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    // Should only have one call (run), no login
    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let calls = argsText.components(separatedBy: "---\n").filter { !$0.isEmpty }
    #expect(calls.count == 1)

    let runArgs = calls[0].split(separator: "\n").map(String.init)
    #expect(runArgs.contains("run"))
}

@Test func dockerClient_runContainer_credentials_passwordViaStdin() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let stdinFileURL = tempDir.appendingPathComponent("stdin.txt")
    let scriptURL = try makeRegistryAuthMockScriptWithStdin(in: tempDir, argsFileURL: argsFileURL, stdinFileURL: stdinFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "ghcr.io/myorg/app:v1")
        .withRegistryAuth(.credentials(
            registry: "ghcr.io",
            username: "user",
            password: "s3cret-tok3n"
        ))

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    // Verify password was passed via stdin (not as CLI arg)
    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    #expect(!argsText.contains("s3cret-tok3n"))

    // Verify stdin captured the password for the login call
    let stdinText = try String(contentsOf: stdinFileURL, encoding: .utf8)
    #expect(stdinText.contains("s3cret-tok3n"))
}

// MARK: - Mock Script Helpers

/// Mock script that tracks all calls (separating them with "---").
/// Reads and discards stdin to prevent SIGPIPE when stdinData is provided.
private func makeRegistryAuthMockScript(in tempDir: URL, argsFileURL: URL) throws -> URL {
    let scriptURL = tempDir.appendingPathComponent("docker-mock.sh")
    let script = [
        "#!/bin/sh",
        "cat > /dev/null",
        "for arg in \"$@\"; do echo \"$arg\" >> \"\(argsFileURL.path)\"; done",
        "echo '---' >> \"\(argsFileURL.path)\"",
        "echo fake-container-id",
    ].joined(separator: "\n")
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
}

/// Mock script that captures both args and DOCKER_CONFIG env var
private func makeRegistryAuthMockScriptWithEnv(in tempDir: URL, argsFileURL: URL, envFileURL: URL) throws -> URL {
    let scriptURL = tempDir.appendingPathComponent("docker-mock.sh")
    let script = [
        "#!/bin/sh",
        "cat > /dev/null",
        "for arg in \"$@\"; do echo \"$arg\" >> \"\(argsFileURL.path)\"; done",
        "echo '---' >> \"\(argsFileURL.path)\"",
        "echo \"DOCKER_CONFIG=$DOCKER_CONFIG\" >> \"\(envFileURL.path)\"",
        "echo fake-container-id",
    ].joined(separator: "\n")
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
}

/// Mock script that captures stdin for login calls and args for all calls
private func makeRegistryAuthMockScriptWithStdin(in tempDir: URL, argsFileURL: URL, stdinFileURL: URL) throws -> URL {
    let scriptURL = tempDir.appendingPathComponent("docker-mock.sh")
    let script = [
        "#!/bin/sh",
        "for arg in \"$@\"; do echo \"$arg\" >> \"\(argsFileURL.path)\"; done",
        "echo '---' >> \"\(argsFileURL.path)\"",
        "if [ \"$1\" = \"login\" ]; then",
        "  cat > \"\(stdinFileURL.path)\"",
        "  echo 'Login Succeeded'",
        "else",
        "  cat > /dev/null",
        "  echo fake-container-id",
        "fi",
    ].joined(separator: "\n")
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
}
