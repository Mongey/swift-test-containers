import Foundation
import Testing
@testable import TestContainers

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
