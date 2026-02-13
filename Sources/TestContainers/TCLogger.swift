/// A lightweight, Sendable logger that dispatches to an optional ``LogHandler``.
///
/// Use ``TCLogger/null`` (the default everywhere in the library) to discard all
/// messages with zero overhead. Supply a handler to opt in to logging.
public struct TCLogger: Sendable {
    private let handler: (any LogHandler)?

    public init(handler: (any LogHandler)?) {
        self.handler = handler
    }

    /// A logger that silently discards every message.
    public static let null = TCLogger(handler: nil)

    // MARK: - Convenience methods

    public func trace(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .trace, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    public func debug(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .debug, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    public func info(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .info, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    public func notice(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .notice, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    public func warning(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .warning, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    public func error(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .error, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    public func critical(
        _ message: String,
        metadata: [String: String] = [:],
        source: String = "TestContainers",
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(level: .critical, message: message, metadata: metadata, source: source, file: file, function: function, line: line)
    }

    // MARK: - Internal

    private func log(
        level: LogLevel,
        message: String,
        metadata: [String: String],
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        guard let handler = handler else { return }
        guard level >= handler.minimumLevel else { return }
        handler.log(
            level: level,
            message: message,
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }
}
