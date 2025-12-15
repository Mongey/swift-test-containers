import Foundation

/// Options for executing commands in a container.
public struct ExecOptions: Sendable, Hashable {
    /// User to run the command as (username, UID, or UID:GID)
    public var user: String?

    /// Working directory for command execution
    public var workingDirectory: String?

    /// Environment variables to set for the command
    public var environment: [String: String]

    /// Allocate a pseudo-TTY
    public var tty: Bool

    /// Keep STDIN open (for interactive commands)
    public var interactive: Bool

    /// Run in detached mode (don't wait for completion)
    public var detached: Bool

    /// Create a default ExecOptions with sensible defaults
    public init(
        user: String? = nil,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        tty: Bool = false,
        interactive: Bool = false,
        detached: Bool = false
    ) {
        self.user = user
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.tty = tty
        self.interactive = interactive
        self.detached = detached
    }

    /// Set the user to run the command as.
    public func withUser(_ user: String) -> Self {
        var copy = self
        copy.user = user
        return copy
    }

    /// Set the working directory for the command.
    public func withWorkingDirectory(_ workingDirectory: String) -> Self {
        var copy = self
        copy.workingDirectory = workingDirectory
        return copy
    }

    /// Set environment variables for the command.
    public func withEnvironment(_ environment: [String: String]) -> Self {
        var copy = self
        copy.environment = environment
        return copy
    }

    /// Allocate a pseudo-TTY.
    public func withTTY(_ tty: Bool = true) -> Self {
        var copy = self
        copy.tty = tty
        return copy
    }

    /// Keep STDIN open for interactive commands.
    public func withInteractive(_ interactive: Bool = true) -> Self {
        var copy = self
        copy.interactive = interactive
        return copy
    }

    /// Run in detached mode (don't wait for completion).
    public func withDetached(_ detached: Bool = true) -> Self {
        var copy = self
        copy.detached = detached
        return copy
    }
}

/// Result of executing a command in a container.
public struct ExecResult: Sendable, Hashable {
    /// The exit code returned by the command
    public let exitCode: Int32

    /// Standard output from the command
    public let stdout: String

    /// Standard error from the command
    public let stderr: String

    /// Whether the command succeeded (exit code 0)
    public var succeeded: Bool { exitCode == 0 }

    /// Whether the command failed (exit code != 0)
    public var failed: Bool { exitCode != 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}
