import Foundation
import Testing
@testable import TestContainers

@Test func containerRequest_dependsOn_singleDependency_defaultWait() {
    let request = ContainerRequest(image: "alpine:3")
        .dependsOn("db")

    #expect(request.dependencies.count == 1)
    #expect(request.dependencies[0].name == "db")
    #expect(request.dependencies[0].waitStrategy == .ready)
}

@Test func containerRequest_dependsOn_multipleDependencies_customWait() {
    let request = ContainerRequest(image: "alpine:3")
        .dependsOn(["db", "cache"], waitFor: .healthy)

    #expect(request.dependencies.count == 2)
    #expect(Set(request.dependencies.map(\.name)) == ["db", "cache"])
    let strategies = Set<DependencyWaitStrategy>(request.dependencies.map(\.waitStrategy))
    #expect(strategies == [.healthy])
}

@Test func containerStack_withContainer_importsRequestDependencies() {
    let app = ContainerRequest(image: "app:latest")
        .dependsOn("db", waitFor: .started)

    let stack = ContainerStack()
        .withContainer("db", ContainerRequest(image: "postgres:15"))
        .withContainer("app", app)

    #expect(stack.dependencies["app"] == ["db"])
    #expect(stack.dependencyWaitStrategy(for: "app", dependency: "db") == .started)
}

@Test func containerStack_withDependency_customWaitOverridesRequestDependencyWait() {
    let app = ContainerRequest(image: "app:latest")
        .dependsOn("db", waitFor: .started)

    let stack = ContainerStack()
        .withContainer("db", ContainerRequest(image: "postgres:15"))
        .withContainer("app", app)
        .withDependency("app", dependsOn: "db", waitFor: .custom(.tcpPort(5432)))

    #expect(stack.dependencyWaitStrategy(for: "app", dependency: "db") == .custom(.tcpPort(5432)))
}

@Test func withContainerGroup_aliasesWithStack() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDependencyDockerMockScript(in: tempDir, argsFileURL: argsFileURL)
    let docker = DockerClient(dockerPath: scriptURL.path)

    let group = ContainerGroup()
        .withContainer("db", ContainerRequest(image: "db-image:latest"))
        .withContainer("app", ContainerRequest(image: "app-image:latest"))
        .withDependency("app", dependsOn: "db")

    let names = try await withContainerGroup(group, runtime: docker) { running in
        await running.containerNames().sorted()
    }

    #expect(names == ["app", "db"])

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let invocations = parseDependencyInvocations(argsText)
    let runInvocations = invocations.filter { $0.first == "run" }

    #expect(runInvocations.count == 2)
}

@Test func withStack_parallelizesIndependentContainers() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let overlapEventsFileURL = tempDir.appendingPathComponent("overlap-events.txt")
    let scriptURL = try makeDependencyDockerMockScript(
        in: tempDir,
        argsFileURL: argsFileURL,
        behavior: .slowRun,
        overlapEventsFileURL: overlapEventsFileURL
    )
    let docker = DockerClient(dockerPath: scriptURL.path)

    let stack = ContainerStack()
        .withContainer("a", ContainerRequest(image: "a-image:latest"))
        .withContainer("b", ContainerRequest(image: "b-image:latest"))

    _ = try await withStack(stack, runtime: docker) { _ in
        true
    }

    let overlapEvents = (try? String(contentsOf: overlapEventsFileURL, encoding: .utf8)) ?? ""
    let markers = Set(overlapEvents.split(whereSeparator: \.isNewline).map(String.init))

    #expect(markers.contains("overlap"))
}

@Test func withStack_dependencyWaitStrategyHealthy_waitsBeforeDependentStarts() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let argsFileURL = tempDir.appendingPathComponent("args.txt")
    let scriptURL = try makeDependencyDockerMockScript(in: tempDir, argsFileURL: argsFileURL)
    let docker = DockerClient(dockerPath: scriptURL.path)

    let stack = ContainerStack()
        .withContainer("db", ContainerRequest(image: "db-image:latest"))
        .withContainer("app", ContainerRequest(image: "app-image:latest"))
        .withDependency("app", dependsOn: "db", waitFor: .healthy)

    _ = try await withStack(stack, runtime: docker) { _ in
        true
    }

    let argsText = try String(contentsOf: argsFileURL, encoding: .utf8)
    let invocations = parseDependencyInvocations(argsText)
    let runIndices = invocations.indices.filter { invocations[$0].first == "run" }
    let healthInspectIndex = invocations.firstIndex {
        containsSequence(["inspect", "--format", "{{json .State.Health}}"], in: $0)
    }

    #expect(runIndices.count == 2)
    #expect(healthInspectIndex != nil)
    #expect(healthInspectIndex! < runIndices[1])
}

private enum DependencyDockerMockBehavior {
    case success
    case slowRun
}

private func makeDependencyDockerMockScript(
    in tempDir: URL,
    argsFileURL: URL,
    behavior: DependencyDockerMockBehavior = .success,
    overlapEventsFileURL: URL? = nil
) throws -> URL {
    let scriptURL = tempDir.appendingPathComponent("docker-dependency-mock.sh")
    let slowRun = behavior == .slowRun ? "1" : "0"
    let overlapEventsPath = overlapEventsFileURL?.path ?? ""
    let overlapLockPath = tempDir.appendingPathComponent("run-overlap-lock").path

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

      run)
        if [ "\(slowRun)" = "1" ]; then
          if [ -n "\(overlapEventsPath)" ]; then
            if mkdir "\(overlapLockPath)" 2>/dev/null; then
              :
            else
              echo "overlap" >> "\(overlapEventsPath)"
            fi
          fi
          sleep 1.5
          if [ -n "\(overlapEventsPath)" ]; then
            rmdir "\(overlapLockPath)" 2>/dev/null || true
          fi
        fi
        echo "stack-container-$(date +%s)-$$-$RANDOM"
        exit 0
        ;;

      logs)
        echo "PONG"
        exit 0
        ;;

      inspect)
        if [ "$2" = "--format" ]; then
          echo '{"Status":"healthy"}'
          exit 0
        fi
        echo '[{"State":{"Status":"running","Running":true,"ExitCode":0,"OOMKilled":false,"Health":{"Status":"healthy"}},"NetworkSettings":{"Networks":{"bridge":{"IPAddress":"172.18.0.2"}}}}]'
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

private func parseDependencyInvocations(_ argsText: String) -> [[String]] {
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
