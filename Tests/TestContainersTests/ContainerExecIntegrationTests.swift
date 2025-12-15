import Foundation
import Testing
@testable import TestContainers

// MARK: - Container Exec Integration Tests
// These tests require Docker and are gated by TESTCONTAINERS_RUN_DOCKER_TESTS=1

private var dockerTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
}

@Test func exec_simpleCommand() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let result = try await container.exec(["echo", "hello"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(result.succeeded)
    }
}

@Test func exec_nonZeroExitCode() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let result = try await container.exec(["sh", "-c", "exit 42"])
        #expect(result.exitCode == 42)
        #expect(result.failed)
    }
}

@Test func exec_withWorkingDirectory() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let result = try await container.exec(
            ["pwd"],
            options: ExecOptions().withWorkingDirectory("/tmp")
        )
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp")
    }
}

@Test func exec_withEnvironment() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let result = try await container.exec(
            ["sh", "-c", "echo $MY_VAR"],
            options: ExecOptions().withEnvironment(["MY_VAR": "test123"])
        )
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "test123")
    }
}

@Test func exec_withMultipleEnvironmentVariables() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let result = try await container.exec(
            ["sh", "-c", "echo $FOO-$BAR"],
            options: ExecOptions().withEnvironment(["FOO": "hello", "BAR": "world"])
        )
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello-world")
    }
}

@Test func exec_withUser() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let result = try await container.exec(["whoami"], user: "root")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "root")
    }
}

@Test func exec_capturesStdout() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let result = try await container.exec(["sh", "-c", "echo 'line1'; echo 'line2'"])
        #expect(result.stdout.contains("line1"))
        #expect(result.stdout.contains("line2"))
    }
}

@Test func exec_capturesStderr() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let result = try await container.exec(["sh", "-c", "echo error >&2"])
        #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == "error")
    }
}

@Test func exec_capturesBothStdoutAndStderr() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let result = try await container.exec(["sh", "-c", "echo out; echo err >&2"])
        #expect(result.stdout.contains("out"))
        #expect(result.stderr.contains("err"))
    }
}

@Test func exec_commandNotFound() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let result = try await container.exec(["nonexistent_command_xyz"])
        // Command not found typically returns 127
        #expect(result.failed)
        #expect(result.exitCode == 127 || result.stderr.contains("not found"))
    }
}

@Test func execOutput_success() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let output = try await container.execOutput(["echo", "test"])
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "test")
    }
}

@Test func execOutput_throwsOnFailure() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        do {
            _ = try await container.execOutput(["sh", "-c", "exit 1"])
            Issue.record("Expected execCommandFailed error")
        } catch let error as TestContainersError {
            if case .execCommandFailed(let command, let exitCode, _, _, _) = error {
                #expect(command == ["sh", "-c", "exit 1"])
                #expect(exitCode == 1)
            } else {
                Issue.record("Wrong error type: \(error)")
            }
        }
    }
}

@Test func exec_chainedOptions() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let options = ExecOptions()
            .withWorkingDirectory("/tmp")
            .withEnvironment(["TEST_VAR": "value"])

        let result = try await container.exec(
            ["sh", "-c", "pwd && echo $TEST_VAR"],
            options: options
        )
        #expect(result.stdout.contains("/tmp"))
        #expect(result.stdout.contains("value"))
    }
}

@Test func exec_multipleCommandsSequentially() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        // Create a file
        let createResult = try await container.exec(["sh", "-c", "echo 'content' > /tmp/test.txt"])
        #expect(createResult.succeeded)

        // Read the file
        let readResult = try await container.exec(["cat", "/tmp/test.txt"])
        #expect(readResult.succeeded)
        #expect(readResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "content")

        // Delete the file
        let deleteResult = try await container.exec(["rm", "/tmp/test.txt"])
        #expect(deleteResult.succeeded)

        // Verify deletion
        let verifyResult = try await container.exec(["test", "-f", "/tmp/test.txt"])
        #expect(verifyResult.failed) // File should not exist
    }
}

@Test func exec_withLongOutput() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        // Generate 1000 lines of output
        let result = try await container.exec(["sh", "-c", "seq 1 1000"])
        #expect(result.succeeded)
        let lines = result.stdout.split(separator: "\n")
        #expect(lines.count == 1000)
        #expect(lines.first == "1")
        #expect(lines.last == "1000")
    }
}
