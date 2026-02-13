#if canImport(os)
import os

/// A ``LogHandler`` that emits messages through Apple's unified logging system.
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public struct OSLogHandler: LogHandler {
    private let logger: os.Logger
    public let minimumLevel: LogLevel

    public init(
        subsystem: String = "com.testcontainers.swift",
        category: String = "TestContainers",
        minimumLevel: LogLevel = .info
    ) {
        self.logger = os.Logger(subsystem: subsystem, category: category)
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
        let osLogType = level.osLogType
        let metadataStr = metadata.isEmpty
            ? ""
            : " " + metadata.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        logger.log(level: osLogType, "\(message, privacy: .public)\(metadataStr, privacy: .public)")
    }
}

extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .trace, .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .error
        case .error, .critical: return .fault
        }
    }
}
#endif
