import Foundation
import Subprocess

struct CommandOutput: Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

struct ProcessRunner: Sendable {
    let logger: TCLogger

    init(logger: TCLogger = .null) {
        self.logger = logger
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        stdinData: Data? = nil
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

        logger.trace("Executing command", metadata: [
            "executable": executable,
            "arguments": arguments.joined(separator: " "),
        ])
        let start = ContinuousClock.now

        let output: CommandOutput
        if let stdinData {
            // Use Foundation.Process for stdin piping due to
            // swift-subprocess .data() input issue on macOS
            output = try await Self.runWithStdin(
                executable: executable,
                arguments: arguments,
                environment: environment,
                stdinData: stdinData
            )
        } else {
            let result = try await Subprocess.run(
                .name(executable),
                arguments: Arguments(arguments),
                environment: env,
                output: .string(limit: 1024 * 1024),
                error: .string(limit: 1024 * 1024)
            )
            output = Self.makeOutput(terminationStatus: result.terminationStatus, stdout: result.standardOutput, stderr: result.standardError)
        }

        let duration = ContinuousClock.now - start
        logger.trace("Command completed", metadata: [
            "executable": executable,
            "exitCode": "\(output.exitCode)",
            "duration": "\(duration)",
        ])

        return output
    }

    private static func runWithStdin(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdinData: Data
    ) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                var env = ProcessInfo.processInfo.environment
                for (key, value) in environment {
                    env[key] = value
                }
                process.environment = env

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    stdinPipe.fileHandleForWriting.write(stdinData)
                    stdinPipe.fileHandleForWriting.closeFile()
                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let output = CommandOutput(
                        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8) ?? "",
                        exitCode: process.terminationStatus
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func makeOutput(terminationStatus: Subprocess.TerminationStatus, stdout: String?, stderr: String?) -> CommandOutput {
        let exitCode: Int32
        switch terminationStatus {
        case .exited(let code):
            exitCode = Int32(code)
        case .unhandledException(let code):
            exitCode = Int32(code)
        }
        return CommandOutput(
            stdout: stdout ?? "",
            stderr: stderr ?? "",
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
