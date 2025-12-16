import Foundation
import Subprocess

struct CommandOutput: Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

struct ProcessRunner: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> CommandOutput {
        // Convert environment to Subprocess.Environment format
        let env: Subprocess.Environment
        if environment.isEmpty {
            env = .inherit
        } else {
            var updates: [Subprocess.Environment.Key: String?] = [:]
            for (key, value) in environment {
                updates[Subprocess.Environment.Key(rawValue: key)!] = value
            }
            env = .inherit.updating(updates)
        }

        let result = try await Subprocess.run(
            .name(executable),
            arguments: Arguments(arguments),
            environment: env,
            output: .string(limit: 1024 * 1024),  // 1MB limit
            error: .string(limit: 1024 * 1024)    // 1MB limit
        )

        let exitCode: Int32
        switch result.terminationStatus {
        case .exited(let code):
            exitCode = Int32(code)
        case .unhandledException(let code):
            exitCode = Int32(code)
        }

        return CommandOutput(
            stdout: result.standardOutput ?? "",
            stderr: result.standardError ?? "",
            exitCode: exitCode
        )
    }

    /// Streams output from a process line by line.
    ///
    /// - Parameters:
    ///   - executable: Path or name of the executable
    ///   - arguments: Command line arguments
    ///   - environment: Additional environment variables
    /// - Returns: AsyncThrowingStream that yields each line of output
    func streamLines(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Convert environment
                    let env: Subprocess.Environment
                    if environment.isEmpty {
                        env = .inherit
                    } else {
                        var updates: [Subprocess.Environment.Key: String?] = [:]
                        for (key, value) in environment {
                            updates[Subprocess.Environment.Key(rawValue: key)!] = value
                        }
                        env = .inherit.updating(updates)
                    }

                    // Use Subprocess.run with streaming body closure
                    // The body receives AsyncBufferSequence for stdout
                    let _ = try await Subprocess.run(
                        .name(executable),
                        arguments: Arguments(arguments),
                        environment: env,
                        error: .combineWithOutput  // Combine stderr with stdout
                    ) { execution, standardOutput in
                        // Use built-in lines() method for line-by-line parsing
                        for try await line in standardOutput.lines() {
                            // Check for cancellation
                            if Task.isCancelled {
                                break
                            }
                            // Trim trailing whitespace (lines include line endings)
                            let trimmed = line.trimmingCharacters(in: .newlines)
                            continuation.yield(trimmed)
                        }
                        return 0 // Return value for the body closure
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
