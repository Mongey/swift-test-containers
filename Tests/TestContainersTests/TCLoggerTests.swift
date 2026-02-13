import Foundation
import Testing
@testable import TestContainers

// MARK: - MockLogHandler

/// A test-only log handler that captures all entries for assertions.
final class MockLogHandler: LogHandler, @unchecked Sendable {
    struct Entry: Sendable {
        let level: LogLevel
        let message: String
        let metadata: [String: String]
        let source: String
        let file: String
        let function: String
        let line: UInt
    }

    let minimumLevel: LogLevel
    private let lock = NSLock()
    private var _entries: [Entry] = []

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    init(minimumLevel: LogLevel = .trace) {
        self.minimumLevel = minimumLevel
    }

    func log(
        level: LogLevel,
        message: String,
        metadata: [String: String],
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        lock.lock()
        defer { lock.unlock() }
        _entries.append(Entry(
            level: level,
            message: message,
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        ))
    }
}

// MARK: - TCLogger Tests

@Test func tcLogger_null_discardsAllMessages() {
    let logger = TCLogger.null
    logger.trace("msg")
    logger.debug("msg")
    logger.info("msg")
    logger.notice("msg")
    logger.warning("msg")
    logger.error("msg")
    logger.critical("msg")
    // No crash, no output — that's the assertion
}

@Test func tcLogger_handlerReceivesMessage() {
    let mock = MockLogHandler()
    let logger = TCLogger(handler: mock)

    logger.info("hello world", metadata: ["key": "value"])

    #expect(mock.entries.count == 1)
    #expect(mock.entries[0].level == .info)
    #expect(mock.entries[0].message == "hello world")
    #expect(mock.entries[0].metadata == ["key": "value"])
    #expect(mock.entries[0].source == "TestContainers")
}

@Test func tcLogger_levelFiltering_belowMinimumIsDiscarded() {
    let mock = MockLogHandler(minimumLevel: .warning)
    let logger = TCLogger(handler: mock)

    logger.trace("t")
    logger.debug("d")
    logger.info("i")
    logger.notice("n")
    logger.warning("w")
    logger.error("e")
    logger.critical("c")

    #expect(mock.entries.count == 3)
    #expect(mock.entries[0].level == .warning)
    #expect(mock.entries[1].level == .error)
    #expect(mock.entries[2].level == .critical)
}

@Test func tcLogger_allConvenienceMethods_emitCorrectLevel() {
    let mock = MockLogHandler()
    let logger = TCLogger(handler: mock)

    logger.trace("t")
    logger.debug("d")
    logger.info("i")
    logger.notice("n")
    logger.warning("w")
    logger.error("e")
    logger.critical("c")

    #expect(mock.entries.count == 7)
    let levels = mock.entries.map(\.level)
    #expect(levels == [.trace, .debug, .info, .notice, .warning, .error, .critical])
}

@Test func tcLogger_defaultSource_isTestContainers() {
    let mock = MockLogHandler()
    let logger = TCLogger(handler: mock)

    logger.info("msg")

    #expect(mock.entries[0].source == "TestContainers")
}

@Test func tcLogger_customSource_isPassedThrough() {
    let mock = MockLogHandler()
    let logger = TCLogger(handler: mock)

    logger.info("msg", source: "CustomSource")

    #expect(mock.entries[0].source == "CustomSource")
}

@Test func tcLogger_defaultMetadata_isEmpty() {
    let mock = MockLogHandler()
    let logger = TCLogger(handler: mock)

    logger.info("msg")

    #expect(mock.entries[0].metadata.isEmpty)
}

@Test func tcLogger_isSendable() {
    let logger: any Sendable = TCLogger.null
    #expect(logger is TCLogger)
}
