import Foundation

/// Options for streaming container logs.
///
/// Use this to configure how logs are streamed from a container,
/// including whether to follow (tail) logs in real-time, filter by time,
/// or limit the number of lines.
public struct LogStreamOptions: Sendable, Hashable {
    /// Whether to follow the log output (like `docker logs -f`).
    public var follow: Bool

    /// Whether to include stdout in the stream.
    public var stdout: Bool

    /// Whether to include stderr in the stream.
    public var stderr: Bool

    /// Whether to include timestamps in the log output.
    public var timestamps: Bool

    /// Only return logs after this time.
    public var since: Date?

    /// Only return logs before this time.
    public var until: Date?

    /// Number of lines to show from the end of the logs (like `tail -n`).
    public var tail: Int?

    /// Default options: follow enabled, both streams, no timestamps.
    public static let `default` = LogStreamOptions()

    /// Creates log stream options.
    ///
    /// - Parameters:
    ///   - follow: Whether to follow the log output. Default: true
    ///   - stdout: Whether to include stdout. Default: true
    ///   - stderr: Whether to include stderr. Default: true
    ///   - timestamps: Whether to include timestamps. Default: false
    ///   - since: Only return logs after this time. Default: nil
    ///   - until: Only return logs before this time. Default: nil
    ///   - tail: Number of lines to show from the end. Default: nil (all lines)
    public init(
        follow: Bool = true,
        stdout: Bool = true,
        stderr: Bool = true,
        timestamps: Bool = false,
        since: Date? = nil,
        until: Date? = nil,
        tail: Int? = nil
    ) {
        self.follow = follow
        self.stdout = stdout
        self.stderr = stderr
        self.timestamps = timestamps
        self.since = since
        self.until = until
        self.tail = tail
    }

    /// Converts options to Docker CLI arguments.
    ///
    /// - Returns: Array of CLI arguments for `docker logs`
    func toDockerArgs() -> [String] {
        var args: [String] = []

        if follow {
            args.append("-f")
        }

        if timestamps {
            args.append("--timestamps")
        }

        if let tail = tail {
            args.append("--tail")
            args.append("\(tail)")
        }

        if let since = since {
            args.append("--since")
            args.append(Self.formatDate(since))
        }

        if let until = until {
            args.append("--until")
            args.append(Self.formatDate(until))
        }

        return args
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// A single log entry from a container.
public struct LogEntry: Sendable, Hashable {
    /// The stream type (stdout or stderr).
    public enum Stream: Sendable, Hashable {
        case stdout
        case stderr
    }

    /// Which stream this entry came from.
    public var stream: Stream

    /// The log message content.
    public var message: String

    /// Optional timestamp from the log entry.
    public var timestamp: Date?

    /// Creates a log entry.
    ///
    /// - Parameters:
    ///   - stream: The stream type (stdout or stderr)
    ///   - message: The log message content
    ///   - timestamp: Optional timestamp
    public init(stream: Stream, message: String, timestamp: Date? = nil) {
        self.stream = stream
        self.message = message
        self.timestamp = timestamp
    }

    /// Parses a log line from Docker output.
    ///
    /// - Parameters:
    ///   - line: The raw log line
    ///   - hasTimestamps: Whether timestamps are included in the output
    /// - Returns: Parsed LogEntry
    static func parse(line: String, hasTimestamps: Bool) -> LogEntry {
        guard hasTimestamps else {
            return LogEntry(stream: .stdout, message: line, timestamp: nil)
        }

        // Docker timestamp format: 2024-12-15T10:30:45.123456789Z message
        // Try to parse the timestamp from the beginning of the line
        let components = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)

        guard components.count >= 1 else {
            return LogEntry(stream: .stdout, message: line, timestamp: nil)
        }

        let timestampString = String(components[0])

        // Try parsing with fractional seconds (Docker uses nanoseconds)
        if let timestamp = Self.parseTimestamp(timestampString) {
            let message = components.count > 1 ? String(components[1]) : ""
            return LogEntry(stream: .stdout, message: message, timestamp: timestamp)
        }

        // If timestamp parsing fails, return the whole line as message
        return LogEntry(stream: .stdout, message: line, timestamp: nil)
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        // Docker outputs timestamps with nanosecond precision: 2024-12-15T10:30:45.123456789Z
        // ISO8601DateFormatter doesn't handle nanoseconds well, so we truncate to milliseconds

        var truncated = string

        // Find the decimal point and truncate to 3 decimal places
        if let dotIndex = truncated.firstIndex(of: "."),
           let zIndex = truncated.firstIndex(of: "Z") {
            let decimalStart = truncated.index(after: dotIndex)
            let decimalPart = truncated[decimalStart..<zIndex]
            if decimalPart.count > 3 {
                // Truncate to 3 decimal places
                let millisEnd = truncated.index(decimalStart, offsetBy: 3)
                truncated = String(truncated[..<millisEnd]) + "Z"
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: truncated) {
            return date
        }

        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
