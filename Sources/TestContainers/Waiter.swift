import Foundation

enum Waiter {
    static func wait(
        timeout: Duration,
        pollInterval: Duration,
        description: String,
        logger: TCLogger = .null,
        _ predicate: @Sendable () async throws -> Bool
    ) async throws {
        logger.debug("Starting wait", metadata: [
            "description": description,
            "timeout": "\(timeout)",
            "pollInterval": "\(pollInterval)",
        ])
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            if try await predicate() {
                let duration = start.duration(to: clock.now)
                logger.debug("Wait condition met", metadata: [
                    "description": description,
                    "duration": "\(duration)",
                ])
                return
            }
            if start.duration(to: clock.now) >= timeout {
                logger.error("Wait timed out", metadata: [
                    "description": description,
                    "timeout": "\(timeout)",
                ])
                throw TestContainersError.timeout(description)
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Poll-based wait that collects diagnostics on timeout.
    ///
    /// Like `wait()` but calls `onTimeout` to gather diagnostic information
    /// before throwing `TestContainersError.timeoutWithDiagnostics`.
    static func waitWithDiagnostics(
        timeout: Duration,
        pollInterval: Duration,
        description: String,
        logger: TCLogger = .null,
        onTimeout: @Sendable () async -> TimeoutDiagnostics,
        _ predicate: @Sendable () async throws -> Bool
    ) async throws {
        logger.debug("Starting wait", metadata: [
            "description": description,
            "timeout": "\(timeout)",
            "pollInterval": "\(pollInterval)",
        ])
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            if try await predicate() {
                let duration = start.duration(to: clock.now)
                logger.debug("Wait condition met", metadata: [
                    "description": description,
                    "duration": "\(duration)",
                ])
                return
            }
            if start.duration(to: clock.now) >= timeout {
                logger.error("Wait timed out", metadata: [
                    "description": description,
                    "timeout": "\(timeout)",
                ])
                let diagnostics = await onTimeout()
                throw TestContainersError.timeoutWithDiagnostics(diagnostics)
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Executes an async operation with a timeout.
    /// - Parameters:
    ///   - timeout: Maximum duration to wait for the operation
    ///   - description: Description for error messages
    ///   - operation: The async operation to execute
    /// - Returns: The result of the operation
    /// - Throws: `TestContainersError.timeout` if the operation takes longer than the timeout
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        description: String,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestContainersError.timeout(description)
            }

            // First task to complete wins
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
