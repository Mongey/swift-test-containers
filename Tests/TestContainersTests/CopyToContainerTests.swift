import Foundation
import Testing
@testable import TestContainers

// MARK: - Docker Integration Test Helper

private var dockerTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
}

// MARK: - Copy to Container Unit Tests

// Test that TestContainersError.invalidInput exists and has correct description
@Test func invalidInput_errorDescription() {
    let error = TestContainersError.invalidInput("test message")

    #expect(error.description.contains("Invalid input"))
    #expect(error.description.contains("test message"))
}

@Test func invalidInput_conformsToSendable() {
    let error = TestContainersError.invalidInput("test")

    // This compiles if TestContainersError is Sendable
    let _: Sendable = error
}

// MARK: - DockerClient Copy Validation Tests

@Test func copyToContainer_throwsForNonExistentSourceFile() async throws {
    let docker = DockerClient()
    let nonExistentPath = "/nonexistent/path/to/file.txt"

    do {
        try await docker.copyToContainer(id: "fake-container", sourcePath: nonExistentPath, destinationPath: "/tmp/dest")
        Issue.record("Expected invalidInput error for non-existent source path")
    } catch let error as TestContainersError {
        if case .invalidInput(let message) = error {
            #expect(message.contains(nonExistentPath))
        } else {
            Issue.record("Wrong error type: \(error)")
        }
    }
}

@Test func copyToContainer_throwsForNonExistentSourceDirectory() async throws {
    let docker = DockerClient()
    let nonExistentPath = "/nonexistent/directory/that/does/not/exist"

    do {
        try await docker.copyToContainer(id: "fake-container", sourcePath: nonExistentPath, destinationPath: "/tmp/dest")
        Issue.record("Expected invalidInput error for non-existent source directory")
    } catch let error as TestContainersError {
        if case .invalidInput(let message) = error {
            #expect(message.contains(nonExistentPath))
        } else {
            Issue.record("Wrong error type: \(error)")
        }
    }
}

// MARK: - String Encoding Tests

@Test func copyToContainer_stringEncodesAsUTF8() {
    let testString = "Hello, 世界! 🌍"
    let data = testString.data(using: .utf8)

    #expect(data != nil)

    // Verify round-trip encoding
    if let data = data {
        let decoded = String(data: data, encoding: .utf8)
        #expect(decoded == testString)
    }
}

@Test func copyToContainer_stringWithSpecialCharacters() {
    let testString = "#!/bin/bash\necho 'test'\nexit 0"
    let data = testString.data(using: .utf8)

    #expect(data != nil)

    if let data = data {
        let decoded = String(data: data, encoding: .utf8)
        #expect(decoded == testString)
    }
}

// MARK: - Copy to Container Integration Tests
// These tests require Docker and are gated by TESTCONTAINERS_RUN_DOCKER_TESTS=1

@Test func copyFileToContainer_copiesSingleFile() async throws {
    guard dockerTestsEnabled else { return }

    // Create temp file on host
    let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-copy-\(UUID().uuidString).txt")
    let content = "Hello from host!"
    try content.write(to: tempFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        // Copy file to container
        try await container.copyFileToContainer(from: tempFile.path, to: "/tmp/test.txt")

        // Verify file content using exec
        let result = try await container.exec(["cat", "/tmp/test.txt"])
        #expect(result.succeeded)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == content)
    }
}

@Test func copyStringToContainer_writesStringContent() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let content = "#!/bin/sh\necho 'test script'\nexit 0"
        try await container.copyToContainer(content, to: "/tmp/script.sh")

        // Verify content
        let result = try await container.exec(["cat", "/tmp/script.sh"])
        #expect(result.succeeded)
        #expect(result.stdout == content)
    }
}

@Test func copyStringToContainer_handlesUnicodeAndEmoji() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        let content = "Hello, 世界! 🌍🎉"
        try await container.copyToContainer(content, to: "/tmp/unicode.txt")

        // Verify content
        let result = try await container.exec(["cat", "/tmp/unicode.txt"])
        #expect(result.succeeded)
        #expect(result.stdout == content)
    }
}

@Test func copyDataToContainer_writesBinaryData() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        // Create binary data (a simple pattern)
        let data = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD])
        try await container.copyDataToContainer(data, to: "/tmp/binary.dat")

        // Verify file size
        let result = try await container.exec(["stat", "-c", "%s", "/tmp/binary.dat"])
        #expect(result.succeeded)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "7")
    }
}

@Test func copyDirectoryToContainer_copiesDirectoryTree() async throws {
    guard dockerTestsEnabled else { return }

    // Create temp directory with files
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-dir-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try "file1 content".write(to: tempDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
    try "file2 content".write(to: tempDir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

    // Create subdirectory
    let subDir = tempDir.appendingPathComponent("subdir")
    try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
    try "nested content".write(to: subDir.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)

    defer { try? FileManager.default.removeItem(at: tempDir) }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        // Copy directory to container - when destination doesn't exist,
        // docker cp copies the source directory AS the destination
        try await container.copyDirectoryToContainer(from: tempDir.path, to: "/tmp/testdir")

        // Files are directly under /tmp/testdir (not nested in source dir name)
        let file1Result = try await container.exec(["cat", "/tmp/testdir/file1.txt"])
        #expect(file1Result.succeeded)
        #expect(file1Result.stdout == "file1 content")

        let file2Result = try await container.exec(["cat", "/tmp/testdir/file2.txt"])
        #expect(file2Result.succeeded)
        #expect(file2Result.stdout == "file2 content")

        let nestedResult = try await container.exec(["cat", "/tmp/testdir/subdir/nested.txt"])
        #expect(nestedResult.succeeded)
        #expect(nestedResult.stdout == "nested content")
    }
}

@Test func copyToContainer_emptyFile() async throws {
    guard dockerTestsEnabled else { return }

    // Create empty temp file
    let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("empty-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: tempFile.path, contents: nil, attributes: nil)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        // Copy empty file
        try await container.copyFileToContainer(from: tempFile.path, to: "/tmp/empty.txt")

        // Verify file exists and is empty
        let result = try await container.exec(["stat", "-c", "%s", "/tmp/empty.txt"])
        #expect(result.succeeded)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }
}

@Test func copyToContainer_largeFile() async throws {
    guard dockerTestsEnabled else { return }

    // Create a larger file (1MB)
    let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("large-\(UUID().uuidString).txt")
    let largeContent = String(repeating: "A", count: 1024 * 1024)  // 1MB
    try largeContent.write(to: tempFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "60"])

    try await withContainer(request) { container in
        // Copy large file
        try await container.copyFileToContainer(from: tempFile.path, to: "/tmp/large.txt")

        // Verify file size
        let result = try await container.exec(["stat", "-c", "%s", "/tmp/large.txt"])
        #expect(result.succeeded)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1048576")
    }
}

@Test func copyToContainer_overwritesExistingFile() async throws {
    guard dockerTestsEnabled else { return }

    let request = ContainerRequest(image: "alpine:3.19")
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        // Write initial content
        try await container.copyToContainer("original", to: "/tmp/overwrite.txt")

        // Verify initial content
        let result1 = try await container.exec(["cat", "/tmp/overwrite.txt"])
        #expect(result1.stdout == "original")

        // Overwrite with new content
        try await container.copyToContainer("updated", to: "/tmp/overwrite.txt")

        // Verify new content
        let result2 = try await container.exec(["cat", "/tmp/overwrite.txt"])
        #expect(result2.stdout == "updated")
    }
}
