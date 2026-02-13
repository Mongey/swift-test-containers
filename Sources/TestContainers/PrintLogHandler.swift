import Foundation

/// A simple ``LogHandler`` that prints messages to standard output.
///
/// Output format: `[timestamp] [LEVEL] [source] message key=value ...`
public struct PrintLogHandler: LogHandler {
    public let minimumLevel: LogLevel

    public init(minimumLevel: LogLevel = .info) {
        self.minimumLevel = minimumLevel
    }

    public func log(
        level: LogLevel,
        message: String,
        metadata: [String: String],
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let levelStr = level.description.uppercased()
        let metadataStr = metadata.isEmpty
            ? ""
            : " " + metadata.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[\(timestamp)] [\(levelStr)] [\(source)] \(message)\(metadataStr)")
    }
}
