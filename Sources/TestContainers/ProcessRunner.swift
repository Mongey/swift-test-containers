import Foundation

struct CommandOutput: Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

actor ProcessRunner {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if !environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            process.environment = env
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: CommandOutput(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus))
            }
        }
    }
}

