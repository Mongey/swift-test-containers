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
        }
    }
}

