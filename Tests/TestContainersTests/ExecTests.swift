import Testing
@testable import TestContainers

// MARK: - ExecOptions Tests

@Test func execOptions_defaultValues() {
    let options = ExecOptions()

    #expect(options.user == nil)
    #expect(options.workingDirectory == nil)
    #expect(options.environment == [:])
    #expect(options.tty == false)
    #expect(options.interactive == false)
    #expect(options.detached == false)
}

@Test func execOptions_withUser() {
    let options = ExecOptions().withUser("root")

    #expect(options.user == "root")
}

@Test func execOptions_withWorkingDirectory() {
    let options = ExecOptions().withWorkingDirectory("/app")

    #expect(options.workingDirectory == "/app")
}

@Test func execOptions_withEnvironment() {
    let options = ExecOptions().withEnvironment(["FOO": "bar", "BAZ": "qux"])

    #expect(options.environment == ["FOO": "bar", "BAZ": "qux"])
}

@Test func execOptions_withTTY() {
    let options = ExecOptions().withTTY()

    #expect(options.tty == true)
}

@Test func execOptions_withInteractive() {
    let options = ExecOptions().withInteractive()

    #expect(options.interactive == true)
}

@Test func execOptions_withDetached() {
    let options = ExecOptions().withDetached()

    #expect(options.detached == true)
}

@Test func execOptions_builderChaining() {
    let options = ExecOptions()
        .withUser("postgres")
        .withWorkingDirectory("/var/lib/postgresql")
        .withEnvironment(["PGDATA": "/data"])
        .withTTY()

    #expect(options.user == "postgres")
    #expect(options.workingDirectory == "/var/lib/postgresql")
    #expect(options.environment == ["PGDATA": "/data"])
    #expect(options.tty == true)
    #expect(options.interactive == false)
    #expect(options.detached == false)
}

@Test func execOptions_conformsToSendable() {
    let options = ExecOptions().withUser("root")

    // This compiles if ExecOptions is Sendable
    let _: Sendable = options
}

@Test func execOptions_conformsToHashable() {
    let options1 = ExecOptions().withUser("root").withWorkingDirectory("/app")
    let options2 = ExecOptions().withUser("root").withWorkingDirectory("/app")
    let options3 = ExecOptions().withUser("nobody")

    #expect(options1 == options2)
    #expect(options1 != options3)
}

// MARK: - ExecResult Tests

@Test func execResult_succeeded_whenExitCodeZero() {
    let result = ExecResult(exitCode: 0, stdout: "output", stderr: "")

    #expect(result.succeeded == true)
    #expect(result.failed == false)
}

@Test func execResult_failed_whenExitCodeNonZero() {
    let result = ExecResult(exitCode: 1, stdout: "", stderr: "error")

    #expect(result.succeeded == false)
    #expect(result.failed == true)
}

@Test func execResult_failed_withVariousExitCodes() {
    let result1 = ExecResult(exitCode: 1, stdout: "", stderr: "")
    let result42 = ExecResult(exitCode: 42, stdout: "", stderr: "")
    let result127 = ExecResult(exitCode: 127, stdout: "", stderr: "command not found")

    #expect(result1.failed == true)
    #expect(result42.failed == true)
    #expect(result127.failed == true)
}

@Test func execResult_capturesBothOutputs() {
    let result = ExecResult(exitCode: 0, stdout: "standard output", stderr: "standard error")

    #expect(result.stdout == "standard output")
    #expect(result.stderr == "standard error")
}

@Test func execResult_conformsToSendable() {
    let result = ExecResult(exitCode: 0, stdout: "", stderr: "")

    // This compiles if ExecResult is Sendable
    let _: Sendable = result
}

@Test func execResult_conformsToHashable() {
    let result1 = ExecResult(exitCode: 0, stdout: "out", stderr: "err")
    let result2 = ExecResult(exitCode: 0, stdout: "out", stderr: "err")
    let result3 = ExecResult(exitCode: 1, stdout: "out", stderr: "err")

    #expect(result1 == result2)
    #expect(result1 != result3)
}
