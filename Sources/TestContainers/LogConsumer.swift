import Foundation

/// Represents the source stream of a log line.
public enum LogStream: Sendable, Hashable {
    case stdout
    case stderr
}

/// A consumer that receives log output from a running container.
public protocol LogConsumer: Sendable {
    /// Called when a new log line is produced by the container.
    /// - Parameters:
    ///   - stream: The stream that produced the log line (stdout or stderr)
    ///   - line: The log line content (without trailing newline)
    func accept(stream: LogStream, line: String) async
}

/// Wraps a log consumer with a unique ID for Hashable conformance on ContainerRequest.
public struct LogConsumerEntry: Sendable, Hashable {
    let id: UUID
    let consumer: any LogConsumer

    public init(_ consumer: any LogConsumer) {
        self.id = UUID()
        self.consumer = consumer
    }

    public static func == (lhs: LogConsumerEntry, rhs: LogConsumerEntry) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Collects log lines into an array for testing and debugging.
public actor CollectingLogConsumer: LogConsumer {
    /// A single collected log entry.
    public struct Entry: Sendable, Equatable {
        public let stream: LogStream
        public let line: String
    }

    private var entries: [Entry] = []

    public init() {}

    public func accept(stream: LogStream, line: String) async {
        entries.append(Entry(stream: stream, line: line))
    }

    /// Returns all collected entries.
    public func getEntries() -> [Entry] {
        entries
    }

    /// Returns collected lines, optionally filtered by stream.
    public func getLines(from stream: LogStream? = nil) -> [String] {
        if let stream {
            return entries.filter { $0.stream == stream }.map(\.line)
        }
        return entries.map(\.line)
    }
}

/// Prints log lines to standard output with optional prefix.
public struct PrintLogConsumer: LogConsumer {
    private let prefix: String?
    private let includeStream: Bool

    public init(prefix: String? = nil, includeStream: Bool = true) {
        self.prefix = prefix
        self.includeStream = includeStream
    }

    public func accept(stream: LogStream, line: String) async {
        var parts: [String] = []
        if let prefix {
            parts.append("[\(prefix)]")
        }
        if includeStream {
            parts.append("[\(stream)]")
        }
        parts.append(line)
        print(parts.joined(separator: " "))
    }
}

/// Sends log lines to multiple consumers.
public struct CompositeLogConsumer: LogConsumer {
    private let consumers: [any LogConsumer]

    public init(_ consumers: [any LogConsumer]) {
        self.consumers = consumers
    }

    public func accept(stream: LogStream, line: String) async {
        for consumer in consumers {
            await consumer.accept(stream: stream, line: line)
        }
    }
}
