import Foundation

/// Represents a unique test session for container tracking.
///
/// Each test process gets a unique session that is used to identify
/// containers belonging to this process. This enables cleanup of
/// only containers from this session, or cleanup of orphaned containers
/// from previous sessions.
///
/// Session labels are automatically applied when using `withSessionLabels()`
/// on a `ContainerRequest`, enabling session-specific cleanup.
public struct TestContainersSession: Sendable {
    /// Unique identifier for this session (UUID)
    public let id: String

    /// Process ID of the current process
    public let processId: Int32

    /// When this session started
    public let startTime: Date

    /// Create a new session with unique ID and current process info.
    public init() {
        self.id = UUID().uuidString
        self.processId = ProcessInfo.processInfo.processIdentifier
        self.startTime = Date()
    }

    /// Labels to apply to containers in this session.
    ///
    /// These labels enable session-specific cleanup and tracking:
    /// - `testcontainers.swift.session.id`: Unique session identifier
    /// - `testcontainers.swift.session.pid`: Process ID
    /// - `testcontainers.swift.session.started`: Unix timestamp of session start
    public var sessionLabels: [String: String] {
        [
            "testcontainers.swift.session.id": id,
            "testcontainers.swift.session.pid": String(processId),
            "testcontainers.swift.session.started": String(Int(startTime.timeIntervalSince1970))
        ]
    }
}

/// The current test session for this process.
///
/// This is lazily initialized once per process and remains constant
/// for the lifetime of the process. Use this to add session labels
/// to containers or to clean up containers from this session.
public let currentTestSession = TestContainersSession()
