import Testing
import Foundation
@testable import TestContainers

// MARK: - DiagnosticsConfig Tests

@Test func diagnosticsConfig_defaultValues() {
    let config = DiagnosticsConfig.default

    #expect(config.captureLogsOnFailure == true)
    #expect(config.logTailLines == 50)
    #expect(config.captureStateOnFailure == true)
}

@Test func diagnosticsConfig_disabled_allFalse() {
    let config = DiagnosticsConfig.disabled

    #expect(config.captureLogsOnFailure == false)
    #expect(config.logTailLines == 0)
    #expect(config.captureStateOnFailure == false)
}

@Test func diagnosticsConfig_verbose_moreLines() {
    let config = DiagnosticsConfig.verbose

    #expect(config.captureLogsOnFailure == true)
    #expect(config.logTailLines == 200)
    #expect(config.captureStateOnFailure == true)
}

@Test func diagnosticsConfig_customInit() {
    let config = DiagnosticsConfig(
        captureLogsOnFailure: true,
        logTailLines: 100,
        captureStateOnFailure: false
    )

    #expect(config.captureLogsOnFailure == true)
    #expect(config.logTailLines == 100)
    #expect(config.captureStateOnFailure == false)
}

@Test func diagnosticsConfig_negativeLinesClampedToZero() {
    let config = DiagnosticsConfig(logTailLines: -5)

    #expect(config.logTailLines == 0)
}

@Test func diagnosticsConfig_conformsToHashable() {
    let config1 = DiagnosticsConfig.default
    let config2 = DiagnosticsConfig.default
    let config3 = DiagnosticsConfig.verbose

    #expect(config1 == config2)
    #expect(config1 != config3)
}

// MARK: - ContainerRequest Diagnostics Builder Tests

@Test func containerRequest_diagnostics_defaultIsDefault() {
    let request = ContainerRequest(image: "alpine:3")
    #expect(request.diagnostics == .default)
}

@Test func containerRequest_initImageFromDockerfile_diagnosticsDefault() {
    let request = ContainerRequest(imageFromDockerfile: ImageFromDockerfile())
    #expect(request.diagnostics == .default)
}

@Test func containerRequest_withDiagnostics_setsConfig() {
    let request = ContainerRequest(image: "alpine:3")
        .withDiagnostics(.verbose)

    #expect(request.diagnostics == .verbose)
}

@Test func containerRequest_withDiagnostics_disabled() {
    let request = ContainerRequest(image: "alpine:3")
        .withDiagnostics(.disabled)

    #expect(request.diagnostics == .disabled)
}

@Test func containerRequest_withLogTailLines_setsLines() {
    let request = ContainerRequest(image: "alpine:3")
        .withLogTailLines(100)

    #expect(request.diagnostics.logTailLines == 100)
}

@Test func containerRequest_withDiagnostics_returnsNewInstance() {
    let original = ContainerRequest(image: "alpine:3")
    let modified = original.withDiagnostics(.verbose)

    #expect(original.diagnostics == .default)
    #expect(modified.diagnostics == .verbose)
}

@Test func containerRequest_withDiagnostics_canBeChained() {
    let request = ContainerRequest(image: "postgres:16")
        .withExposedPort(5432)
        .withDiagnostics(.verbose)
        .withEnvironment(["POSTGRES_PASSWORD": "secret"])

    #expect(request.diagnostics == .verbose)
    #expect(request.ports.count == 1)
    #expect(request.environment["POSTGRES_PASSWORD"] == "secret")
}

@Test func containerRequest_withDiagnostics_conformsToHashable() {
    let request1 = ContainerRequest(image: "alpine:3")
        .withDiagnostics(.verbose)
    let request2 = ContainerRequest(image: "alpine:3")
        .withDiagnostics(.verbose)
    let request3 = ContainerRequest(image: "alpine:3")
        .withDiagnostics(.disabled)

    #expect(request1 == request2)
    #expect(request1 != request3)
}

// MARK: - TimeoutDiagnostics Formatting Tests

@Test func timeoutDiagnostics_formatIncludesDescription() {
    let diag = TimeoutDiagnostics(
        description: "container logs to contain 'ready'",
        containerId: "abc123def456",
        image: "postgres:16",
        containerState: nil,
        recentLogs: nil,
        logLineCount: 50
    )

    let message = diag.formatted()
    #expect(message.contains("container logs to contain 'ready'"))
    #expect(message.contains("abc123def456"))
    #expect(message.contains("postgres:16"))
}

@Test func timeoutDiagnostics_formatIncludesContainerState() {
    let diag = TimeoutDiagnostics(
        description: "TCP port",
        containerId: "abc123def456",
        image: "myapp:latest",
        containerState: .init(status: "exited", running: false, exitCode: 1, oomKilled: false),
        recentLogs: nil,
        logLineCount: 50
    )

    let message = diag.formatted()
    #expect(message.contains("exited"))
    #expect(message.contains("Exit Code: 1"))
}

@Test func timeoutDiagnostics_formatIncludesOOMKilled() {
    let diag = TimeoutDiagnostics(
        description: "TCP port",
        containerId: "abc123def456",
        image: "myapp:latest",
        containerState: .init(status: "exited", running: false, exitCode: 137, oomKilled: true),
        recentLogs: nil,
        logLineCount: 50
    )

    let message = diag.formatted()
    #expect(message.contains("OOM Killed"))
}

@Test func timeoutDiagnostics_formatIncludesLogs() {
    let diag = TimeoutDiagnostics(
        description: "waiting",
        containerId: "abc123def456",
        image: "myapp:latest",
        containerState: nil,
        recentLogs: "ERROR: database connection refused\nFATAL: startup failed",
        logLineCount: 50
    )

    let message = diag.formatted()
    #expect(message.contains("Container Logs (last 50 lines)"))
    #expect(message.contains("database connection refused"))
    #expect(message.contains("startup failed"))
}

@Test func timeoutDiagnostics_formatHandlesNilLogs() {
    let diag = TimeoutDiagnostics(
        description: "waiting",
        containerId: "abc123def456",
        image: "myapp:latest",
        containerState: nil,
        recentLogs: nil,
        logLineCount: 50
    )

    let message = diag.formatted()
    #expect(message.contains("empty or unavailable"))
}

@Test func timeoutDiagnostics_formatHandlesEmptyLogs() {
    let diag = TimeoutDiagnostics(
        description: "waiting",
        containerId: "abc123def456",
        image: "myapp:latest",
        containerState: nil,
        recentLogs: "",
        logLineCount: 50
    )

    let message = diag.formatted()
    #expect(message.contains("empty or unavailable"))
}

@Test func timeoutDiagnostics_formatIncludesTroubleshooting() {
    let diag = TimeoutDiagnostics(
        description: "waiting",
        containerId: "abc123def456",
        image: "myapp:latest",
        containerState: .init(status: "exited", running: false, exitCode: 1, oomKilled: false),
        recentLogs: nil,
        logLineCount: 50
    )

    let message = diag.formatted()
    #expect(message.contains("Troubleshooting"))
    #expect(message.contains("Container exited"))
}

@Test func timeoutDiagnostics_formatRunningContainerNoExitHint() {
    let diag = TimeoutDiagnostics(
        description: "waiting",
        containerId: "abc123def456",
        image: "myapp:latest",
        containerState: .init(status: "running", running: true, exitCode: 0, oomKilled: false),
        recentLogs: nil,
        logLineCount: 50
    )

    let message = diag.formatted()
    #expect(!message.contains("Container exited"))
}

// MARK: - TestContainersError.timeoutWithDiagnostics Tests

@Test func testContainersError_timeoutWithDiagnostics_includesFormattedMessage() {
    let diag = TimeoutDiagnostics(
        description: "container logs to contain 'ready'",
        containerId: "abc123def456",
        image: "postgres:16",
        containerState: .init(status: "running", running: true, exitCode: 0, oomKilled: false),
        recentLogs: "Starting up...\nLoading config...",
        logLineCount: 50
    )

    let error = TestContainersError.timeoutWithDiagnostics(diag)
    let description = error.description

    #expect(description.contains("container logs to contain 'ready'"))
    #expect(description.contains("postgres:16"))
    #expect(description.contains("Starting up..."))
}

// MARK: - DockerClient.logsTail Argument Tests

@Test func dockerClient_logsTailArgs() {
    let args = DockerClient.logsTailArgs(id: "abc123", lines: 50)
    #expect(args == ["logs", "--tail", "50", "abc123"])
}

@Test func dockerClient_logsTailArgs_oneLine() {
    let args = DockerClient.logsTailArgs(id: "xyz", lines: 1)
    #expect(args == ["logs", "--tail", "1", "xyz"])
}

// MARK: - Waiter.waitWithDiagnostics Tests

@Test func waiterWithDiagnostics_throwsDiagnosticsOnTimeout() async {
    do {
        try await Waiter.waitWithDiagnostics(
            timeout: .milliseconds(50),
            pollInterval: .milliseconds(10),
            description: "test condition",
            onTimeout: {
                TimeoutDiagnostics(
                    description: "test condition",
                    containerId: "test-id",
                    image: "test-image",
                    containerState: .init(status: "running", running: true, exitCode: 0, oomKilled: false),
                    recentLogs: "some log output",
                    logLineCount: 50
                )
            }
        ) {
            false // never succeeds
        }
        Issue.record("Should have thrown")
    } catch let TestContainersError.timeoutWithDiagnostics(diag) {
        #expect(diag.description == "test condition")
        #expect(diag.containerId == "test-id")
        #expect(diag.image == "test-image")
        #expect(diag.recentLogs == "some log output")
        #expect(diag.containerState?.status == "running")
    } catch {
        Issue.record("Expected timeoutWithDiagnostics, got: \(error)")
    }
}

@Test func waiterWithDiagnostics_succeedsWhenPredicatePasses() async throws {
    let counter = CallCounter()
    try await Waiter.waitWithDiagnostics(
        timeout: .seconds(1),
        pollInterval: .milliseconds(10),
        description: "test",
        onTimeout: {
            TimeoutDiagnostics(
                description: "test",
                containerId: "id",
                image: "img",
                containerState: nil,
                recentLogs: nil,
                logLineCount: 0
            )
        }
    ) {
        await counter.increment()
        return await counter.count >= 2
    }
    // Should succeed without throwing
    let finalCount = await counter.count
    #expect(finalCount >= 2)
}

private actor CallCounter {
    var count = 0
    func increment() { count += 1 }
}

// MARK: - ContainerStateDiagnostics Tests

@Test func containerStateDiagnostics_initSetsAllFields() {
    let state = ContainerStateDiagnostics(
        status: "exited",
        running: false,
        exitCode: 1,
        oomKilled: true
    )

    #expect(state.status == "exited")
    #expect(state.running == false)
    #expect(state.exitCode == 1)
    #expect(state.oomKilled == true)
}

@Test func timeoutDiagnostics_exitCodeZeroNotShown() {
    let diag = TimeoutDiagnostics(
        description: "waiting",
        containerId: "abc123",
        image: "test",
        containerState: .init(status: "running", running: true, exitCode: 0, oomKilled: false),
        recentLogs: nil,
        logLineCount: 50
    )

    let message = diag.formatted()
    // Running containers with exit code 0 should not show "Exit Code: 0"
    #expect(!message.contains("Exit Code:"))
}
