import Foundation
import Testing
@testable import TestContainers

// MARK: - Docker Integration Test Helper

private var dockerTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
}

// MARK: - Copy From Container Integration Tests
// These tests require Docker and are gated by TESTCONTAINERS_RUN_DOCKER_TESTS=1

@Test func copyFileFromContainer_copiesSingleFile() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "echo 'Hello from container' > /tmp/test.txt && sleep 30"])

    try await withContainer(request) { container in
        // Wait for file to be created
        try await Task.sleep(for: .milliseconds(500))

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("copied-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Copy file from container
        let resultURL = try await container.copyFileFromContainer(
            "/tmp/test.txt",
            to: tempFile.path
        )

        #expect(FileManager.default.fileExists(atPath: resultURL.path))

        let contents = try String(contentsOf: resultURL, encoding: .utf8)
        #expect(contents.contains("Hello from container"))
    }
}

@Test func copyFileFromContainer_preservesPermissions() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "echo 'executable' > /tmp/script.sh && chmod 755 /tmp/script.sh && sleep 30"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .milliseconds(500))

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let resultURL = try await container.copyFileFromContainer(
            "/tmp/script.sh",
            to: tempFile.path,
            preservePermissions: true
        )

        #expect(FileManager.default.fileExists(atPath: resultURL.path))

        // Check file has execute permission
        let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        #expect(permissions != nil)
    }
}

@Test func copyFileFromContainer_withoutPreservingPermissions() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "echo 'test' > /tmp/test.txt && sleep 30"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .milliseconds(500))

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let resultURL = try await container.copyFileFromContainer(
            "/tmp/test.txt",
            to: tempFile.path,
            preservePermissions: false
        )

        #expect(FileManager.default.fileExists(atPath: resultURL.path))

        let contents = try String(contentsOf: resultURL, encoding: .utf8)
        #expect(contents.contains("test"))
    }
}

@Test func copyFileFromContainer_throwsOnMissingFile() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).txt")

        await #expect(throws: TestContainersError.self) {
            try await container.copyFileFromContainer(
                "/this/path/does/not/exist.txt",
                to: tempFile.path
            )
        }
    }
}

@Test func copyDirectoryFromContainer_copiesDirectory() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand([
            "sh", "-c",
            "mkdir -p /tmp/mydir && echo 'file1' > /tmp/mydir/a.txt && echo 'file2' > /tmp/mydir/b.txt && sleep 30"
        ])

    try await withContainer(request) { container in
        try await Task.sleep(for: .milliseconds(500))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("copied-dir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let resultURL = try await container.copyDirectoryFromContainer(
            "/tmp/mydir",
            to: tempDir.path
        )

        #expect(FileManager.default.fileExists(atPath: resultURL.path))

        // docker cp copies the directory INTO the destination, so files are at mydir/a.txt
        let fileA = resultURL.appendingPathComponent("mydir").appendingPathComponent("a.txt")
        let fileB = resultURL.appendingPathComponent("mydir").appendingPathComponent("b.txt")

        #expect(FileManager.default.fileExists(atPath: fileA.path))
        #expect(FileManager.default.fileExists(atPath: fileB.path))

        let contentsA = try String(contentsOf: fileA, encoding: .utf8)
        #expect(contentsA.trimmingCharacters(in: .whitespacesAndNewlines) == "file1")

        let contentsB = try String(contentsOf: fileB, encoding: .utf8)
        #expect(contentsB.trimmingCharacters(in: .whitespacesAndNewlines) == "file2")
    }
}

@Test func copyDirectoryFromContainer_createsDestinationDirectory() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand([
            "sh", "-c",
            "mkdir -p /tmp/mydir && echo 'content' > /tmp/mydir/file.txt && sleep 30"
        ])

    try await withContainer(request) { container in
        try await Task.sleep(for: .milliseconds(500))

        // Use a nested path that doesn't exist
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nested-\(UUID().uuidString)")
            .appendingPathComponent("deep")
            .appendingPathComponent("path")
        defer {
            // Clean up parent directory
            try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent().deletingLastPathComponent())
        }

        let resultURL = try await container.copyDirectoryFromContainer(
            "/tmp/mydir",
            to: tempDir.path
        )

        #expect(FileManager.default.fileExists(atPath: resultURL.path))
    }
}

@Test func copyFileToData_returnsFileContentsAsData() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "echo 'Test data content' > /tmp/data.txt && sleep 30"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .milliseconds(500))

        let data = try await container.copyFileToData("/tmp/data.txt")

        #expect(!data.isEmpty)

        let contents = String(data: data, encoding: .utf8)
        #expect(contents?.contains("Test data content") == true)
    }
}

@Test func copyFileToData_handlesBinaryData() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand([
            "sh", "-c",
            "printf '\\x00\\x01\\x02\\x03\\xFF\\xFE' > /tmp/binary.dat && sleep 30"
        ])

    try await withContainer(request) { container in
        try await Task.sleep(for: .milliseconds(500))

        let data = try await container.copyFileToData("/tmp/binary.dat")

        #expect(data.count == 6)
        #expect(data[0] == 0x00)
        #expect(data[1] == 0x01)
        #expect(data[2] == 0x02)
        #expect(data[3] == 0x03)
        #expect(data[4] == 0xFF)
        #expect(data[5] == 0xFE)
    }
}

@Test func copyFileToData_throwsOnMissingFile() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        await #expect(throws: TestContainersError.self) {
            try await container.copyFileToData("/nonexistent/file.txt")
        }
    }
}

@Test func copyFileToData_handlesUnicodeContent() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "printf 'Hello, 世界! 🌍' > /tmp/unicode.txt && sleep 30"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .milliseconds(500))

        let data = try await container.copyFileToData("/tmp/unicode.txt")

        let contents = String(data: data, encoding: .utf8)
        #expect(contents == "Hello, 世界! 🌍")
    }
}

@Test func copyFileFromContainer_handlesEmptyFile() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "touch /tmp/empty.txt && sleep 30"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .milliseconds(500))

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let resultURL = try await container.copyFileFromContainer(
            "/tmp/empty.txt",
            to: tempFile.path
        )

        #expect(FileManager.default.fileExists(atPath: resultURL.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let size = attributes[.size] as? Int
        #expect(size == 0)
    }
}

@Test func copyFileToData_handlesEmptyFile() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sh", "-c", "touch /tmp/empty.txt && sleep 30"])

    try await withContainer(request) { container in
        try await Task.sleep(for: .milliseconds(500))

        let data = try await container.copyFileToData("/tmp/empty.txt")

        #expect(data.isEmpty)
    }
}
