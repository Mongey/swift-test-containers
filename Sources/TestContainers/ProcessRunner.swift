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
}
