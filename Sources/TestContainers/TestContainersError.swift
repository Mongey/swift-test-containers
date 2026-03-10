import Foundation

/// Diagnostic information collected when a container wait strategy times out.
public struct TimeoutDiagnostics: Sendable {
    /// Description of what was being waited for.
    public let description: String
    /// The container ID.
    public let containerId: String
    /// The image name.
    public let image: String
    /// Container state at time of timeout, if available.
    public let containerState: ContainerStateDiagnostics?
    /// Recent container log output, if available.
    public let recentLogs: String?
    /// Number of log lines requested.
    public let logLineCount: Int

    /// Formats a human-readable error message with all diagnostic information.
    public func formatted() -> String {
        var message = "Timed out: \(description)"
        message += "\n\nContainer: \(containerId.prefix(12))"
        message += "\nImage: \(image)"

        if let state = containerState {
            message += "\n\nContainer State:"
            message += "\n  Status: \(state.status)"
            if !state.running, state.exitCode != 0 {
                message += "\n  Exit Code: \(state.exitCode)"
            }
            if state.oomKilled {
                message += "\n  OOM Killed: true (container ran out of memory)"
            }
        }

        if let logs = recentLogs, !logs.isEmpty {
            message += "\n\nContainer Logs (last \(logLineCount) lines):"
            message += "\n" + String(repeating: "-", count: 60)
            message += "\n\(logs)"
            message += "\n" + String(repeating: "-", count: 60)
        } else {
            message += "\n\nContainer Logs: (empty or unavailable)"
        }

        message += "\n\nTroubleshooting:"
        message += "\n  - Check container logs above for errors"
        message += "\n  - Verify the container starts correctly with: docker run \(image)"
        if let state = containerState, state.status == "exited" {
            message += "\n  - Container exited; check exit code and logs for failure reason"
        }

        return message
    }
}

/// Snapshot of Docker container state for diagnostic purposes.
public struct ContainerStateDiagnostics: Sendable {
    public let status: String
    public let running: Bool
    public let exitCode: Int
    public let oomKilled: Bool

    public init(status: String, running: Bool, exitCode: Int, oomKilled: Bool) {
        self.status = status
        self.running = running
        self.exitCode = exitCode
        self.oomKilled = oomKilled
    }
}

public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    case dockerNotAvailable(String)
    case commandFailed(command: [String], exitCode: Int32, stdout: String, stderr: String)
    case unexpectedDockerOutput(String)
    case timeout(String)
    case invalidRegexPattern(String, underlyingError: String)
    case healthCheckNotConfigured(String)
    /// All wait strategies in an `.any([...])` composite failed
    case allWaitStrategiesFailed([String])
    /// Empty `.any([])` array provided - at least one strategy is required
    case emptyAnyWaitStrategy
    /// Startup failed after exhausting all retry attempts
    case startupRetriesExhausted(attempts: Int, lastError: Error)
    /// Command executed in container failed with non-zero exit code
    case execCommandFailed(command: [String], exitCode: Int32, stdout: String, stderr: String, containerID: String)
    /// Invalid input provided to a function
    case invalidInput(String)
    /// A lifecycle hook failed during execution
    case lifecycleHookFailed(phase: String, hookIndex: Int, underlyingError: Error)
    /// General lifecycle error
    case lifecycleError(String)
    /// Docker image build from Dockerfile failed
    case imageBuildFailed(dockerfile: String, context: String, exitCode: Int32, stdout: String, stderr: String)
    /// Image not found locally and pull policy is set to never
    case imageNotFoundLocally(image: String, message: String)
    /// Failed to pull image from registry
    case imagePullFailed(image: String, exitCode: Int32, stdout: String, stderr: String)
    /// Invalid container state transition
    case invalidStateTransition(from: String, to: String, reason: String)
    /// Timeout with diagnostic information (container logs, state)
    case timeoutWithDiagnostics(TimeoutDiagnostics)
    /// Container is not attached to the requested Docker network
    case networkNotFound(String, id: String)
    /// Named container not found in a running stack.
    case containerNotFound(String, availableContainers: [String])
    /// Invalid stack dependency declaration.
    case invalidDependency(dependent: String, dependency: String, reason: String)
    /// Circular dependency detected in stack graph.
    case circularDependency(containers: [String])
    /// Docker network creation failed for stack startup.
    case networkCreationFailed(String)
    /// Docker Engine API returned a non-success HTTP status code.
    case apiError(statusCode: Int, message: String)
    /// The requested operation is not supported by the current container runtime.
    case unsupportedByRuntime(String)

    public var description: String {
        switch self {
        case let .dockerNotAvailable(message):
            return "Docker not available: \(message)"
        case let .commandFailed(command, exitCode, stdout, stderr):
            return "Command failed (exit \(exitCode)): \(command.joined(separator: " "))\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
        case let .unexpectedDockerOutput(output):
            return "Unexpected Docker output: \(output)"
        case let .timeout(message):
            return "Timed out: \(message)"
        case let .invalidRegexPattern(pattern, underlyingError):
            return "Invalid regex pattern '\(pattern)': \(underlyingError)"
        case let .healthCheckNotConfigured(message):
            return "Health check not configured: \(message)"
        case let .allWaitStrategiesFailed(errors):
            let details = errors.enumerated().map { "  [\($0.offset)] \($0.element)" }.joined(separator: "\n")
            return "All wait strategies in .any([...]) failed:\n\(details)"
        case .emptyAnyWaitStrategy:
            return "No wait strategies provided to .any([]) - at least one strategy is required"
        case let .startupRetriesExhausted(attempts, lastError):
            return "Container startup failed after \(attempts) attempts. Last error: \(lastError)"
        case let .execCommandFailed(command, exitCode, stdout, stderr, containerID):
            return """
            Exec command failed in container \(containerID) (exit \(exitCode)): \
            \(command.joined(separator: " "))
            stdout:
            \(stdout)
            stderr:
            \(stderr)
            """
        case let .invalidInput(message):
            return "Invalid input: \(message)"
        case let .lifecycleHookFailed(phase, hookIndex, underlyingError):
            return "Lifecycle hook failed at phase '\(phase)' (hook index \(hookIndex)): \(underlyingError)"
        case let .lifecycleError(message):
            return "Lifecycle error: \(message)"
        case let .imageBuildFailed(dockerfile, context, exitCode, stdout, stderr):
            return """
            Docker image build failed (exit \(exitCode))
            Dockerfile: \(dockerfile)
            Context: \(context)
            stdout:
            \(stdout)
            stderr:
            \(stderr)
            """
        case let .imageNotFoundLocally(image, message):
            return "Image not found locally: \(image). \(message)"
        case let .imagePullFailed(image, exitCode, stdout, stderr):
            return "Failed to pull image '\(image)' (exit \(exitCode))\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
        case let .invalidStateTransition(from, to, reason):
            return "Invalid state transition from \(from) to \(to): \(reason)"
        case let .timeoutWithDiagnostics(diagnostics):
            return diagnostics.formatted()
        case let .networkNotFound(network, id):
            return "Network '\(network)' not found for container \(id)"
        case let .containerNotFound(name, availableContainers):
            let available = availableContainers.sorted().joined(separator: ", ")
            return "Container '\(name)' not found in stack. Available containers: \(available)"
        case let .invalidDependency(dependent, dependency, reason):
            return "Invalid dependency '\(dependent)' -> '\(dependency)': \(reason)"
        case let .circularDependency(containers):
            return "Circular dependency detected in stack: \(containers.sorted().joined(separator: ", "))"
        case let .networkCreationFailed(message):
            return "Failed to create stack network: \(message)"
        case let .apiError(statusCode, message):
            return "Docker API error (HTTP \(statusCode)): \(message)"
        case let .unsupportedByRuntime(message):
            return "Unsupported by runtime: \(message)"
        }
    }
}
