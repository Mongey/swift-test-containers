import Foundation

enum Waiter {
    static func wait(
        timeout: Duration,
        pollInterval: Duration,
        description: String,
        _ predicate: @Sendable () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            if try await predicate() { return }
            if start.duration(to: clock.now) >= timeout {
                throw TestContainersError.timeout(description)
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}
