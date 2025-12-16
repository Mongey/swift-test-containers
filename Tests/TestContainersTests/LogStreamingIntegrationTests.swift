import Foundation
import Testing
@testable import TestContainers

// MARK: - Log Streaming Integration Tests

/// Integration tests for Container.streamLogs()
/// These tests require Docker to be running.
/// Enable with: TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test

private func dockerTestsEnabled() -> Bool {
    ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
}

@Test func streamLogs_capturesOutput() async throws {
    guard dockerTestsEnabled() else { return }

    // Note: waitStrategy defaults to .none, no need to set explicitly
    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "echo Line1; echo Line2; echo Line3"])

    try await withContainer(request) { container in
        // Wait for the container to finish
        try await Task.sleep(for: .seconds(1))

        // Stream with no follow (container already exited)
        let options = LogStreamOptions(follow: false)
        var lines: [String] = []

        for try await entry in container.streamLogs(options: options) {
            lines.append(entry.message)
        }

        #expect(lines.count == 3)
        #expect(lines.contains("Line1"))
        #expect(lines.contains("Line2"))
        #expect(lines.contains("Line3"))
    }
}

@Test func streamLogs_withTail_limitsOutput() async throws {
    guard dockerTestsEnabled() else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "for i in $(seq 1 20); do echo Line$i; done"])
        

    try await withContainer(request) { container in
        // Wait for the container to finish
        try await Task.sleep(for: .seconds(1))

        // Stream only last 5 lines
        let options = LogStreamOptions(follow: false, tail: 5)
        var lines: [String] = []

        for try await entry in container.streamLogs(options: options) {
            lines.append(entry.message)
        }

        #expect(lines.count == 5)
        #expect(lines.contains("Line16"))
        #expect(lines.contains("Line20"))
        #expect(!lines.contains("Line1"))
    }
}

@Test func streamLogs_withTimestamps_includesTimestamps() async throws {
    guard dockerTestsEnabled() else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "echo Hello"])
        

    try await withContainer(request) { container in
        // Wait for the container to finish
        try await Task.sleep(for: .seconds(1))

        // Stream with timestamps
        let options = LogStreamOptions(follow: false, timestamps: true)

        for try await entry in container.streamLogs(options: options) {
            #expect(entry.timestamp != nil)
            #expect(entry.message == "Hello")
            break
        }
    }
}

@Test func streamLogs_followsRealTimeOutput() async throws {
    guard dockerTestsEnabled() else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "for i in 1 2 3; do echo Line$i; sleep 0.2; done"])
        

    try await withContainer(request) { container in
        var lines: [String] = []
        let startTime = Date()

        // Follow logs in real-time
        let options = LogStreamOptions(follow: true)
        for try await entry in container.streamLogs(options: options) {
            lines.append(entry.message)
            if lines.count >= 3 {
                break
            }
        }

        let duration = Date().timeIntervalSince(startTime)

        #expect(lines.count == 3)
        #expect(lines[0] == "Line1")
        #expect(lines[2] == "Line3")
        // Should take at least 0.4 seconds (2 * 0.2s sleep between lines)
        #expect(duration >= 0.3)
    }
}

@Test func streamLogs_canBreakEarly() async throws {
    guard dockerTestsEnabled() else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "for i in $(seq 1 100); do echo Line$i; done"])
        

    try await withContainer(request) { container in
        // Wait for the container to finish
        try await Task.sleep(for: .seconds(1))

        let options = LogStreamOptions(follow: false)
        var count = 0

        // Only read first 5 lines
        for try await _ in container.streamLogs(options: options) {
            count += 1
            if count >= 5 {
                break
            }
        }

        #expect(count == 5)
    }
}

@Test func streamLogs_handlesEmptyOutput() async throws {
    guard dockerTestsEnabled() else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "exit 0"])
        

    try await withContainer(request) { container in
        // Wait for the container to finish
        try await Task.sleep(for: .seconds(1))

        let options = LogStreamOptions(follow: false)
        var lines: [String] = []

        for try await entry in container.streamLogs(options: options) {
            lines.append(entry.message)
        }

        #expect(lines.isEmpty)
    }
}

@Test func streamLogs_handlesStderr() async throws {
    guard dockerTestsEnabled() else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "echo stdout_msg; echo stderr_msg >&2"])
        

    try await withContainer(request) { container in
        // Wait for the container to finish
        try await Task.sleep(for: .seconds(1))

        let options = LogStreamOptions(follow: false)
        var messages: [String] = []

        for try await entry in container.streamLogs(options: options) {
            messages.append(entry.message)
        }

        // Both stdout and stderr should be captured
        #expect(messages.count == 2)
        #expect(messages.contains("stdout_msg"))
        #expect(messages.contains("stderr_msg"))
    }
}

@Test func streamLogs_withMultilineOutput() async throws {
    guard dockerTestsEnabled() else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "printf 'Line1\\nLine2\\nLine3\\n'"])
        

    try await withContainer(request) { container in
        // Wait for the container to finish
        try await Task.sleep(for: .seconds(1))

        let options = LogStreamOptions(follow: false)
        var lines: [String] = []

        for try await entry in container.streamLogs(options: options) {
            lines.append(entry.message)
        }

        #expect(lines.count == 3)
        #expect(lines[0] == "Line1")
        #expect(lines[1] == "Line2")
        #expect(lines[2] == "Line3")
    }
}

@Test func streamLogs_defaultOptions_followsLogs() async throws {
    guard dockerTestsEnabled() else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "echo Hello; sleep 0.1; echo World"])
        

    try await withContainer(request) { container in
        var lines: [String] = []

        // Use default options (should follow)
        for try await entry in container.streamLogs() {
            lines.append(entry.message)
            if lines.count >= 2 {
                break
            }
        }

        #expect(lines.count == 2)
        #expect(lines[0] == "Hello")
        #expect(lines[1] == "World")
    }
}

@Test func streamLogs_withLongLines() async throws {
    guard dockerTestsEnabled() else { return }

    // Generate a line with a repeating pattern
    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "head -c 500 /dev/zero | tr '\\0' 'A'; echo"])

    try await withContainer(request) { container in
        // Wait for the container to finish
        try await Task.sleep(for: .seconds(1))

        let options = LogStreamOptions(follow: false)
        var lines: [String] = []

        for try await entry in container.streamLogs(options: options) {
            lines.append(entry.message)
        }

        // Should have captured the long line
        #expect(lines.count == 1)
        // Long line should have many characters (500 A's)
        #expect(lines[0].count >= 400)
        #expect(lines[0].hasPrefix("AAAA"))
    }
}
