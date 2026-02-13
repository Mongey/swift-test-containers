/// A pluggable handler for log messages emitted by TestContainers.
///
/// Implement this protocol to route log messages to your preferred logging
/// backend (console, OSLog, swift-log, a custom service, etc.).
public protocol LogHandler: Sendable {
    /// Called for every log message that passes the minimum level filter.
    func log(
        level: LogLevel,
        message: String,
        metadata: [String: String],
        source: String,
        file: String,
        function: String,
        line: UInt
    )

    /// The minimum severity level this handler will accept.
    var minimumLevel: LogLevel { get }
}
