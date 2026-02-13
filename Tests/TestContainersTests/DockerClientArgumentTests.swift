import Foundation
import Testing
@testable import TestContainers

@Test func dockerClient_runContainer_includesPrivilegeAndCapabilitiesFlags() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withPrivileged()
        .withCapabilityAdd([.netRaw, .netAdmin])
        .withCapabilityDrop(.sysTime)

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.contains("--privileged"))
    #expect(containsSequence(["--cap-add", "NET_ADMIN", "--cap-add", "NET_RAW"], in: args))
    #expect(containsSequence(["--cap-drop", "SYS_TIME"], in: args))
}

@Test func dockerClient_runContainer_includesUserFlag() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withName("user-flag-test")
        .withUser(uid: 1000, gid: 1000)

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["--name", "user-flag-test", "--user", "1000:1000"], in: args))
    #expect(args.contains("alpine:3"))
}

@Test func dockerClient_runContainer_includesPlatformFlag_whenConfigured() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withPlatform("linux/amd64")
        .withName("platform-test")

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["run", "-d", "--platform", "linux/amd64", "--name", "platform-test"], in: args))
}

@Test func dockerClient_runContainer_omitsPlatformFlag_whenNotConfigured() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.contains("--platform") == false)
}

@Test func dockerClient_runContainer_invalidPlatform_throwsInvalidInput() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withPlatform("linux")

    do {
        _ = try await docker.runContainer(request)
        Issue.record("Expected invalidInput error for malformed platform")
    } catch let error as TestContainersError {
        if case let .invalidInput(message) = error {
            #expect(message.contains("platform"))
            #expect(message.contains("linux"))
        } else {
            Issue.record("Expected invalidInput error, got: \(error)")
        }
    }

    #expect(fileManager.fileExists(atPath: argsFileURL.path) == false)
}

@Test func dockerClient_runContainer_includesResourceLimitFlags() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    var limits = ResourceLimits()
    limits.memory = "512m"
    limits.memoryReservation = "256m"
    limits.memorySwap = "1g"
    limits.cpus = "1.5"
    limits.cpuShares = 2048
    limits.cpuPeriod = 100_000
    limits.cpuQuota = 50_000

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withResourceLimits(limits)

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["--memory", "512m"], in: args))
    #expect(containsSequence(["--memory-reservation", "256m"], in: args))
    #expect(containsSequence(["--memory-swap", "1g"], in: args))
    #expect(containsSequence(["--cpus", "1.5"], in: args))
    #expect(containsSequence(["--cpu-shares", "2048"], in: args))
    #expect(containsSequence(["--cpu-period", "100000"], in: args))
    #expect(containsSequence(["--cpu-quota", "50000"], in: args))
}

@Test func dockerClient_runContainer_omitsResourceLimitFlags_whenUnset() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.contains("--memory") == false)
    #expect(args.contains("--memory-reservation") == false)
    #expect(args.contains("--memory-swap") == false)
    #expect(args.contains("--cpus") == false)
    #expect(args.contains("--cpu-shares") == false)
    #expect(args.contains("--cpu-period") == false)
    #expect(args.contains("--cpu-quota") == false)
}

@Test func dockerClient_runContainer_autoGeneratesNameByDefault() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    guard let nameIndex = args.firstIndex(of: "--name"), nameIndex + 1 < args.count else {
        Issue.record("Expected --name argument in docker run command")
        return
    }

    let generatedName = args[nameIndex + 1]
    #expect(generatedName.hasPrefix("tc-swift-"))
    #expect(generatedName.range(of: #"^tc-swift-\d+-[a-f0-9]{8}$"#, options: .regularExpression) != nil)
}

@Test func dockerClient_runContainer_withFixedName_usesExactName() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withFixedName("fixed-container-name")

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["--name", "fixed-container-name"], in: args))
}

@Test func dockerClient_runContainer_includesAddHostFlags_sortedByHostname() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withExtraHost(hostname: "db.local", ip: "10.0.0.3")
        .withExtraHost(.gateway(hostname: "host.internal"))
        .withExtraHost(hostname: "api.local", ip: "10.0.0.4")

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence([
        "--add-host", "api.local:10.0.0.4",
        "--add-host", "db.local:10.0.0.3",
        "--add-host", "host.internal:host-gateway",
    ], in: args))
}

@Test func dockerClient_runContainer_invalidExtraHost_throwsInvalidInput() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withExtraHost(hostname: "", ip: "10.0.0.3")

    do {
        _ = try await docker.runContainer(request)
        Issue.record("Expected invalidInput error for malformed extra host")
    } catch let error as TestContainersError {
        if case let .invalidInput(message) = error {
            #expect(message.contains("extra host"))
        } else {
            Issue.record("Expected invalidInput error, got: \(error)")
        }
    }

    #expect(fileManager.fileExists(atPath: argsFileURL.path) == false)
}

// MARK: - Image Pull Policy Tests

@Test func dockerClient_runContainer_alwaysPullPolicy_callsPullBeforeRun() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL, trackAllCalls: true)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.always)

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    // The script logs all invocations; first should be "pull alpine:3", then "run -d ..."
    #expect(argsText.contains("pull\nalpine:3"))
    #expect(argsText.contains("run"))
}

@Test func dockerClient_runContainer_ifNotPresentPullPolicy_doesNotPull() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL, trackAllCalls: true)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.ifNotPresent)

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    #expect(!argsText.contains("pull\n"))
    #expect(argsText.contains("run"))
}

@Test func dockerClient_runContainer_neverPullPolicy_checksImageExists() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    // This script succeeds for all commands (image inspect returns success = image exists)
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL, trackAllCalls: true)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.never)

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    // Should have called "image inspect" before "run"
    #expect(argsText.contains("image\ninspect"))
    #expect(argsText.contains("run"))
}

@Test func dockerClient_runContainer_neverPullPolicy_throwsWhenImageMissing() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    // Create a script that fails for "image inspect" (image not found)
    let scriptURL = tempDir.appendingPathComponent("docker-mock.sh")
    let script = """
    #!/bin/sh
    if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
        exit 1
    fi
    echo "fake-container-id"
    """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "nonexistent:tag")
        .withImagePullPolicy(.never)

    do {
        _ = try await docker.runContainer(request)
        Issue.record("Expected imageNotFoundLocally error")
    } catch let error as TestContainersError {
        if case let .imageNotFoundLocally(image, _) = error {
            #expect(image == "nonexistent:tag")
        } else {
            Issue.record("Expected imageNotFoundLocally error, got: \(error)")
        }
    }
}

@Test func dockerClient_runContainer_defaultPolicy_doesNotPull() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL, trackAllCalls: true)

    let docker = DockerClient(dockerPath: scriptURL.path)
    // Default policy - no withImagePullPolicy call
    let request = ContainerRequest(image: "alpine:3")

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    #expect(!argsText.contains("pull\n"))
    #expect(!argsText.contains("image\ninspect"))
}

private func makeDockerMockScript(in tempDir: URL, argsFileURL: URL, trackAllCalls: Bool) throws -> URL {
    let scriptURL = tempDir.appendingPathComponent("docker-mock.sh")
    let script: String
    if trackAllCalls {
        script = """
        #!/bin/sh
        printf '%s\\n' "$@" >> "\(argsFileURL.path)"
        printf '---\\n' >> "\(argsFileURL.path)"
        echo "fake-container-id"
        """
    } else {
        script = """
        #!/bin/sh
        echo "fake-container-id"
        printf '%s\\n' "$@" > "\(argsFileURL.path)"
        """
    }
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
}

private func makeDockerMockScript(in tempDir: URL, argsFileURL: URL) throws -> URL {
    let scriptURL = tempDir.appendingPathComponent("docker-mock.sh")
    let script = """
    #!/bin/sh
    echo "fake-container-id"
    printf '%s\\n' "$@" > "\(argsFileURL.path)"
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
}

// MARK: - Network Create Argument Tests

@Test func dockerClient_createNetwork_basicBridgeNetwork() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = NetworkRequest()
        .withName("test-network")

    let (id, name) = try await docker.createNetwork(request)
    #expect(id == "fake-container-id")
    #expect(name == "test-network")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["network", "create"], in: args))
    #expect(containsSequence(["--driver", "bridge"], in: args))
    #expect(args.contains("test-network"))
    #expect(containsSequence(["--label", "testcontainers.swift=true"], in: args))
}

@Test func dockerClient_createNetwork_withDriver() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = NetworkRequest()
        .withName("overlay-net")
        .withDriver(.overlay)

    _ = try await docker.createNetwork(request)

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["--driver", "overlay"], in: args))
}

@Test func dockerClient_createNetwork_withIPAM() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = NetworkRequest()
        .withName("ipam-net")
        .withIPAM(IPAMConfig(
            subnet: "172.20.0.0/16",
            gateway: "172.20.0.1",
            ipRange: "172.20.10.0/24"
        ))

    _ = try await docker.createNetwork(request)

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["--subnet", "172.20.0.0/16"], in: args))
    #expect(containsSequence(["--gateway", "172.20.0.1"], in: args))
    #expect(containsSequence(["--ip-range", "172.20.10.0/24"], in: args))
}

@Test func dockerClient_createNetwork_withOptions() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = NetworkRequest()
        .withName("opt-net")
        .withOption("com.docker.network.driver.mtu", "1500")

    _ = try await docker.createNetwork(request)

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["--opt", "com.docker.network.driver.mtu=1500"], in: args))
}

@Test func dockerClient_createNetwork_withLabels() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = NetworkRequest()
        .withName("label-net")
        .withLabel("env", "test")

    _ = try await docker.createNetwork(request)

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["--label", "env=test"], in: args))
    #expect(containsSequence(["--label", "testcontainers.swift=true"], in: args))
}

@Test func dockerClient_createNetwork_withFlags() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = NetworkRequest()
        .withName("flag-net")
        .withIPv6(true)
        .asInternal(true)
        .asAttachable(true)

    _ = try await docker.createNetwork(request)

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.contains("--ipv6"))
    #expect(args.contains("--internal"))
    #expect(args.contains("--attachable"))
}

@Test func dockerClient_createNetwork_generatesNameIfNotProvided() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = NetworkRequest()

    let (_, name) = try await docker.createNetwork(request)
    #expect(name.hasPrefix("tc-network-"))
}

@Test func dockerClient_removeNetwork_passesCorrectArgs() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    try await docker.removeNetwork(id: "abc123")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["network", "rm", "abc123"], in: args))
}

// MARK: - Network Attach Argument Tests

@Test func dockerClient_runContainer_includesNetworkFlag_forSingleNetwork() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withNetwork("test-network")

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["--network", "test-network"], in: args))
}

@Test func dockerClient_runContainer_includesNetworkAliases_forFirstNetwork() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withNetwork("app-net", aliases: ["db", "postgres"])

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["--network", "app-net"], in: args))
    #expect(containsSequence(["--network-alias", "db"], in: args))
    #expect(containsSequence(["--network-alias", "postgres"], in: args))
}

@Test func dockerClient_runContainer_includesIPAddress_forFirstNetwork() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withNetwork(NetworkConnection(
            networkName: "custom-net",
            ipv4Address: "172.20.0.10",
            ipv6Address: "fd00::10"
        ))

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["--network", "custom-net"], in: args))
    #expect(containsSequence(["--ip", "172.20.0.10"], in: args))
    #expect(containsSequence(["--ip6", "fd00::10"], in: args))
}

@Test func dockerClient_runContainer_includesNetworkModeFlag() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withNetworkMode(.host)

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["--network", "host"], in: args))
}

@Test func dockerClient_runContainer_networkModePrecedence() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    // Set both networkMode and a network - mode should take precedence for primary
    let request = ContainerRequest(image: "alpine:3")
        .withNetworkMode(.host)
        .withNetwork("some-network")

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["--network", "host"], in: args))
}

@Test func dockerClient_runContainer_omitsNetworkFlags_whenNoNetworkConfigured() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.contains("--network") == false)
    #expect(args.contains("--network-alias") == false)
    #expect(args.contains("--ip") == false)
    #expect(args.contains("--ip6") == false)
}

@Test func dockerClient_runContainer_multipleNetworks_connectsExtra() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL, trackAllCalls: true)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")
        .withNetwork("network1")
        .withNetwork(NetworkConnection(
            networkName: "network2",
            aliases: ["svc"]
        ))

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)

    // First call should be "run" with --network network1
    #expect(argsText.contains("--network\nnetwork1"))
    // Second call should be "network connect" with network2
    #expect(argsText.contains("network\nconnect"))
    #expect(argsText.contains("network2"))
    #expect(argsText.contains("--alias\nsvc"))
}

@Test func dockerClient_connectToNetwork_passesCorrectArgs() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    try await docker.connectToNetwork(
        containerId: "abc123",
        networkName: "my-network",
        aliases: ["svc", "app"],
        ipv4Address: "172.20.0.5"
    )

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["network", "connect"], in: args))
    #expect(containsSequence(["--alias", "svc"], in: args))
    #expect(containsSequence(["--alias", "app"], in: args))
    #expect(containsSequence(["--ip", "172.20.0.5"], in: args))
    #expect(args.contains("my-network"))
    #expect(args.contains("abc123"))
}

@Test func dockerClient_connectToNetwork_withIPv6() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    try await docker.connectToNetwork(
        containerId: "xyz789",
        networkName: "ipv6-net",
        ipv6Address: "fd00::5"
    )

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["network", "connect"], in: args))
    #expect(containsSequence(["--ip6", "fd00::5"], in: args))
    #expect(args.contains("ipv6-net"))
    #expect(args.contains("xyz789"))
}

@Test func dockerClient_connectToNetwork_minimalArgs() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    try await docker.connectToNetwork(
        containerId: "cid",
        networkName: "net"
    )

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["network", "connect", "net", "cid"], in: args))
    #expect(args.contains("--alias") == false)
    #expect(args.contains("--ip") == false)
    #expect(args.contains("--ip6") == false)
}

// MARK: - Create Container Argument Tests

@Test func dockerClient_createContainer_usesCreateCommand() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "alpine:3")

    let id = try await docker.createContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.first == "create")
    #expect(args.contains("run") == false)
    #expect(args.contains("-d") == false)
    #expect(args.contains("alpine:3"))
}

@Test func dockerClient_createContainer_includesPortAndEnvFlags() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .withEnvironment(["REDIS_PASSWORD": "secret"])

    let id = try await docker.createContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.first == "create")
    #expect(containsSequence(["-e", "REDIS_PASSWORD=secret"], in: args))
    #expect(args.contains { $0.contains("6379") })
    #expect(args.contains("redis:7"))
}

// MARK: - Start Container Argument Tests

@Test func dockerClient_startContainer_passesCorrectArgs() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    try await docker.startContainer(id: "abc123")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["start", "abc123"], in: args))
}

// MARK: - Stop Container Argument Tests

@Test func dockerClient_stopContainer_passesCorrectArgs() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    try await docker.stopContainer(id: "abc123", timeout: .seconds(15))

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["stop", "--time", "15", "abc123"], in: args))
}

@Test func dockerClient_stopContainer_defaultTimeout() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    try await docker.stopContainer(id: "abc123", timeout: .seconds(10))

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["stop", "--time", "10", "abc123"], in: args))
}

// MARK: - Image Substitutor Argument Tests

@Test func dockerClient_runContainer_withSubstitutor_usesResolvedImage() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "redis:7")
        .withImageSubstitutor(.registryMirror("mirror.company.com"))

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    // Should use the resolved image, not the original
    #expect(args.contains("mirror.company.com/redis:7"))
    #expect(!args.contains("redis:7"))
}

@Test func dockerClient_runContainer_withoutSubstitutor_usesOriginalImage() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "redis:7")

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.contains("redis:7"))
}

@Test func dockerClient_runContainer_withSubstitutor_repositoryPrefix() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "postgres:16")
        .withImageSubstitutor(.repositoryPrefix("myorg"))

    let id = try await docker.runContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.contains("myorg/postgres:16"))
    #expect(!args.contains("postgres:16"))
}

@Test func dockerClient_createContainer_withSubstitutor_usesResolvedImage() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let request = ContainerRequest(image: "redis:7")
        .withImageSubstitutor(.registryMirror("mirror.co"))

    let id = try await docker.createContainer(request)
    #expect(id == "fake-container-id")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(args.contains("mirror.co/redis:7"))
    #expect(!args.contains("redis:7"))
}

// MARK: - Volume Create Argument Tests

@Test func dockerClient_createVolume_basicLocalVolume() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let name = try await docker.createVolume(name: "test-vol")
    #expect(name == "test-vol")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["volume", "create"], in: args))
    #expect(args.contains("test-vol"))
}

@Test func dockerClient_createVolume_withDriverAndOptions() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    let config = VolumeConfig(driver: "local")
        .withOption("type", "tmpfs")
        .withOption("device", "tmpfs")
    let name = try await docker.createVolume(name: "tmpfs-vol", config: config)
    #expect(name == "tmpfs-vol")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["volume", "create"], in: args))
    #expect(containsSequence(["--driver", "local"], in: args))
    #expect(args.contains("tmpfs-vol"))
    // Options should be passed as --opt key=value
    #expect(containsSequence(["--opt", "device=tmpfs"], in: args))
    #expect(containsSequence(["--opt", "type=tmpfs"], in: args))
}

@Test func dockerClient_removeVolume_generatesCorrectArgs() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDockerMockScript(in: tempDir, argsFileURL: argsFileURL)

    let docker = DockerClient(dockerPath: scriptURL.path)
    try await docker.removeVolume(name: "test-vol")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let args = argsText.split(separator: "\n").map(String.init)

    #expect(containsSequence(["volume", "rm", "-f", "test-vol"], in: args))
}

private func containsSequence(_ sequence: [String], in array: [String]) -> Bool {
    guard !sequence.isEmpty, sequence.count <= array.count else {
        return false
    }

    for start in 0...(array.count - sequence.count) {
        let window = Array(array[start..<(start + sequence.count)])
        if window == sequence {
            return true
        }
    }

    return false
}
