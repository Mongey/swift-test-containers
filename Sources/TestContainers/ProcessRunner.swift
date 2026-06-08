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
        default:
            exitCode = Self.nonExitStatusCode(from: terminationStatus)
        }
        return CommandOutput(
            stdout: stdout ?? "",
            stderr: stderr ?? "",
            exitCode: exitCode
        )
    }

    private static func nonExitStatusCode(from terminationStatus: Subprocess.TerminationStatus) -> Int32 {
        let description = String(describing: terminationStatus)
        let digits = description
            .split { !$0.isNumber }
            .last
            .flatMap { Int32($0) }
        return digits ?? 1
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
            let processState = RunningProcessState()
            let task = Task {
                do {
                    try await Self.streamLinesWithProcess(
                        executable: executable,
                        arguments: arguments,
                        environment: environment,
                        processState: processState,
                        streamContinuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
                processState.terminate()
            }
        }
    }

    private static func streamLinesWithProcess(
        executable: String,
        arguments: [String],
        environment: [String: String],
        processState: RunningProcessState,
        streamContinuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        try await withCheckedThrowingContinuation { (processContinuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                var processEnvironment = ProcessInfo.processInfo.environment
                for (key, value) in environment {
                    processEnvironment[key] = value
                }
                process.environment = processEnvironment

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let lineBuffer = LineBuffer { line in
                    streamContinuation.yield(line)
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    lineBuffer.append(handle.availableData)
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    lineBuffer.append(handle.availableData)
                }

                do {
                    processState.set(process)
                    try process.run()
                    process.waitUntilExit()

                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    lineBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    lineBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    lineBuffer.flush()

                    processState.clear(process)
                    processContinuation.resume(returning: ())
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    processState.clear(process)
                    processContinuation.resume(throwing: error)
                }
            }
        }
    }
}

private final class RunningProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.withLock {
            self.process = process
        }
    }

    func clear(_ process: Process) {
        lock.withLock {
            if self.process === process {
                self.process = nil
            }
        }
    }

    func terminate() {
        lock.withLock {
            process?.terminate()
            process = nil
        }
    }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let yield: @Sendable (String) -> Void
    private var pending = ""

    init(yield: @escaping @Sendable (String) -> Void) {
        self.yield = yield
    }

    func append(_ data: Data) {
        guard !data.isEmpty,
              let chunk = String(data: data, encoding: .utf8) else {
            return
        }

        lock.withLock {
            pending += chunk

            let parts = pending.split(separator: "\n", omittingEmptySubsequences: false)
            guard parts.count > 1 else { return }

            for line in parts.dropLast() {
                yield(String(line).trimmingCharacters(in: .newlines))
            }
            pending = String(parts.last ?? "")
        }
    }

    func flush() {
        lock.withLock {
            guard !pending.isEmpty else { return }
            yield(pending.trimmingCharacters(in: .newlines))
            pending = ""
        }
    }
}
