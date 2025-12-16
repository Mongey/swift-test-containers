import Foundation

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
        }
    }
}

