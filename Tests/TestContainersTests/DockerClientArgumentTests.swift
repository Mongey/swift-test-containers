import Foundation
import Testing
@testable import TestContainers

@Test func dockerClient_runContainer_includesPrivilegeAndCapabilitiesFlags() async throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }

    let scriptURL = tempDir.appendingPathComponent("docker-mock.sh")
    let argsFileURL = tempDir.appendingPathComponent("args.txt")

    let script = """
    #!/bin/sh
    echo "fake-container-id"
    if [ -n "$TESTCONTAINERS_ARGS_FILE" ]; then
      printf '%s\\n' "$@" > "$TESTCONTAINERS_ARGS_FILE"
    fi
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    setenv("TESTCONTAINERS_ARGS_FILE", argsFileURL.path, 1)
    defer { unsetenv("TESTCONTAINERS_ARGS_FILE") }

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
