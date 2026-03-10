import Foundation
import Testing
@testable import TestContainers

@Test func withStack_startsInDependencyOrder_andCleansUp() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeStackDockerMockScript(in: tempDir, argsFileURL: argsFileURL)
    let docker = DockerClient(dockerPath: scriptURL.path)

    let stack = ContainerStack()
        .withEnvironment(["STACK_ENV": "1", "OVERRIDE": "stack"])
        .withLabel("stack.label", "yes")
        .withContainer(
            "db",
            ContainerRequest(image: "db-image:latest")
                .withEnvironment(["OVERRIDE": "db"])
                .withLabel("container.label", "db")
        )
        .withContainer("app", ContainerRequest(image: "app-image:latest"))
        .withDependency("app", dependsOn: "db")

    let result = try await withStack(stack, runtime: docker) { running in
        let db = try await running.container("db")
        let app = try await running.container("app")

        #expect(db.id == "stack-container-1")
        #expect(app.id == "stack-container-2")

        let networkName = await running.networkName()
        #expect(networkName != nil)

        let all = await running.allContainers()
        #expect(all.keys.sorted() == ["app", "db"])

        return "ok"
    }

    #expect(result == "ok")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let invocations = parseInvocations(argsText)

    let runInvocations = invocations.filter { $0.first == "run" }
    #expect(runInvocations.count == 2)
    guard runInvocations.count == 2 else {
        Issue.record("Expected 2 run invocations, got \(runInvocations.count). Invocations: \(invocations)")
        return
    }
    #expect(runInvocations[0].last == "db-image:latest")
    #expect(runInvocations[1].last == "app-image:latest")

    #expect(containsSequence(["--network-alias", "db"], in: runInvocations[0]))
    #expect(containsSequence(["--network-alias", "app"], in: runInvocations[1]))

    #expect(containsSequence(["-e", "STACK_ENV=1"], in: runInvocations[0]))
    #expect(containsSequence(["-e", "OVERRIDE=db"], in: runInvocations[0]))

    #expect(containsSequence(["--label", "stack.label=yes"], in: runInvocations[0]))
    #expect(containsSequence(["--label", "testcontainers.swift.stack=true"], in: runInvocations[0]))

    let rmInvocations = invocations.filter { $0.first == "rm" }
    let removedIds = rmInvocations.compactMap(\.last)
    #expect(removedIds == ["stack-container-2", "stack-container-1"])

    #expect(invocations.contains(where: { containsSequence(["network", "rm", "stack-network-id"], in: $0) }))
}

@Test func withStack_operationFailure_cleansUpContainersAndNetwork() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeStackDockerMockScript(in: tempDir, argsFileURL: argsFileURL)
    let docker = DockerClient(dockerPath: scriptURL.path)

    enum OperationError: Error { case failed }

    let stack = ContainerStack()
        .withContainer("db", ContainerRequest(image: "db-image:latest"))
        .withContainer("app", ContainerRequest(image: "app-image:latest"))
        .withDependency("app", dependsOn: "db")

    await #expect(throws: OperationError.self) {
        try await withStack(stack, runtime: docker) { _ in
            throw OperationError.failed
        }
    }

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let invocations = parseInvocations(argsText)

    let rmInvocations = invocations.filter { $0.first == "rm" }
    let removedIds = rmInvocations.compactMap(\.last)
    #expect(removedIds == ["stack-container-2", "stack-container-1"])

    #expect(invocations.contains(where: { containsSequence(["network", "rm", "stack-network-id"], in: $0) }))
}

@Test func withStack_containerStartupFailure_cleansUpStartedContainersAndNetwork() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeStackDockerMockScript(
        in: tempDir,
        argsFileURL: argsFileURL,
        behavior: .failSecondRun
    )
    let docker = DockerClient(dockerPath: scriptURL.path)

    let stack = ContainerStack()
        .withContainer("db", ContainerRequest(image: "db-image:latest"))
        .withContainer("app", ContainerRequest(image: "app-image:latest"))
        .withDependency("app", dependsOn: "db")

    do {
        _ = try await withStack(stack, runtime: docker) { _ in
            Issue.record("Operation should not run when startup fails")
        }
        Issue.record("Expected startup failure")
    } catch let error as TestContainersError {
        if case .commandFailed = error {
            // expected
        } else {
            Issue.record("Expected commandFailed error, got: \(error)")
        }
    } catch {
        Issue.record("Expected TestContainersError, got: \(error)")
    }

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let invocations = parseInvocations(argsText)

    let runInvocations = invocations.filter { $0.first == "run" }
    #expect(runInvocations.count == 2)

    let rmInvocations = invocations.filter { $0.first == "rm" }
    let removedIds = rmInvocations.compactMap(\.last)
    #expect(removedIds == ["stack-container-1"])

    #expect(invocations.contains(where: { containsSequence(["network", "rm", "stack-network-id"], in: $0) }))
}

@Test func withStack_createsAndCleansUpSharedVolumes() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeStackDockerMockScript(in: tempDir, argsFileURL: argsFileURL)
    let docker = DockerClient(dockerPath: scriptURL.path)

    let stack = ContainerStack()
        .withVolume("shared-data", VolumeConfig())
        .withVolume("cache-vol", VolumeConfig(driver: "local").withOption("type", "tmpfs"))
        .withContainer(
            "db",
            ContainerRequest(image: "db-image:latest")
                .withVolume("shared-data", mountedAt: "/data")
        )

    let result = try await withStack(stack, runtime: docker) { running in
        let names = await running.volumeNames()
        #expect(names.sorted() == ["cache-vol", "shared-data"])
        return "ok"
    }

    #expect(result == "ok")

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let invocations = parseInvocations(argsText)

    // Volumes should be created before containers
    let volumeCreateInvocations = invocations.filter {
        containsSequence(["volume", "create"], in: $0)
    }
    #expect(volumeCreateInvocations.count == 2)

    let createdNames = volumeCreateInvocations.compactMap(\.last)
    #expect(createdNames.sorted() == ["cache-vol", "shared-data"])

    // Volumes should be cleaned up after containers
    let volumeRmInvocations = invocations.filter {
        containsSequence(["volume", "rm"], in: $0)
    }
    #expect(volumeRmInvocations.count == 2)
}

@Test func withStack_operationFailure_cleansUpVolumes() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeStackDockerMockScript(in: tempDir, argsFileURL: argsFileURL)
    let docker = DockerClient(dockerPath: scriptURL.path)

    enum OperationError: Error { case failed }

    let stack = ContainerStack()
        .withVolume("shared-data", VolumeConfig())
        .withContainer("db", ContainerRequest(image: "db-image:latest"))

    await #expect(throws: OperationError.self) {
        try await withStack(stack, runtime: docker) { _ in
            throw OperationError.failed
        }
    }

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let invocations = parseInvocations(argsText)

    // Volume should still be cleaned up on failure
    let volumeRmInvocations = invocations.filter {
        containsSequence(["volume", "rm"], in: $0)
    }
    #expect(volumeRmInvocations.count == 1)
}

private enum StackDockerMockBehavior {
    case success
    case failSecondRun
}

private func makeStackDockerMockScript(
    in tempDir: URL,
    argsFileURL: URL,
    behavior: StackDockerMockBehavior = .success
) throws -> URL {
    let counterFileURL = tempDir.appendingPathComponent("run-count.txt")
    let scriptURL = tempDir.appendingPathComponent("docker-stack-mock.sh")
    let failSecondRun = behavior == .failSecondRun ? "1" : "0"

    let script = """
    #!/bin/sh
    printf '%s\\n' "$@" >> "\(argsFileURL.path)"
    echo '---' >> "\(argsFileURL.path)"

    case "$1" in
      version)
        echo "24.0.0"
        exit 0
        ;;

      network)
        if [ "$2" = "create" ]; then
          echo "stack-network-id"
          exit 0
        fi

        if [ "$2" = "inspect" ]; then
          echo "[]"
          exit 0
        fi

        if [ "$2" = "rm" ]; then
          exit 0
        fi
        ;;

      volume)
        if [ "$2" = "create" ]; then
          echo "volume-ok"
          exit 0
        fi

        if [ "$2" = "rm" ]; then
          exit 0
        fi
        ;;

      run)
        count=0
        if [ -f "\(counterFileURL.path)" ]; then
          count=$(cat "\(counterFileURL.path)")
        fi
        count=$((count + 1))
        echo "$count" > "\(counterFileURL.path)"

        if [ "\(failSecondRun)" = "1" ] && [ "$count" -eq 2 ]; then
          echo "simulated run failure" >&2
          exit 45
        fi

        echo "stack-container-$count"
        exit 0
        ;;

      stop)
        exit 0
        ;;

      rm)
        exit 0
        ;;
    esac

    echo "ok"
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
}

private func parseInvocations(_ argsText: String) -> [[String]] {
    var invocations: [[String]] = []
    var current: [String] = []

    for line in argsText.split(whereSeparator: \.isNewline).map(String.init) {
        if line == "---" {
            if !current.isEmpty {
                invocations.append(current)
            }
            current = []
            continue
        }

        current.append(line)
    }

    if !current.isEmpty {
        invocations.append(current)
    }

    return invocations
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
