#if canImport(os)
import Testing
@testable import TestContainers

@Test func osLogHandler_defaultMinimumLevel_isInfo() {
    if #available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *) {
        let handler = OSLogHandler()
        #expect(handler.minimumLevel == .info)
    }
}

@Test func osLogHandler_customMinimumLevel_isRespected() {
    if #available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *) {
        let handler = OSLogHandler(minimumLevel: .trace)
        #expect(handler.minimumLevel == .trace)
    }
}

@Test func osLogHandler_isSendable() {
    if #available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *) {
        let handler: any Sendable = OSLogHandler()
        #expect(handler is OSLogHandler)
    }
}

@Test func osLogHandler_conformsToLogHandler() {
    if #available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *) {
        let handler: any LogHandler = OSLogHandler()
        #expect(handler.minimumLevel == .info)
    }
}

@Test func osLogHandler_doesNotCrash_withEmptyMetadata() {
    if #available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *) {
        let handler = OSLogHandler()
        handler.log(
            level: .info,
            message: "test",
            metadata: [:],
            source: "TestContainers",
            file: #file,
            function: #function,
            line: #line
        )
    }
}

@Test func osLogHandler_doesNotCrash_withMetadata() {
    if #available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *) {
        let handler = OSLogHandler()
        handler.log(
            level: .warning,
            message: "test message",
            metadata: ["key": "value"],
            source: "TestContainers",
            file: #file,
            function: #function,
            line: #line
        )
    }
}

@Test func logLevel_osLogType_mapping() {
    #expect(LogLevel.trace.osLogType == .debug)
    #expect(LogLevel.debug.osLogType == .debug)
    #expect(LogLevel.info.osLogType == .info)
    #expect(LogLevel.notice.osLogType == .default)
    #expect(LogLevel.warning.osLogType == .error)
    #expect(LogLevel.error.osLogType == .fault)
    #expect(LogLevel.critical.osLogType == .fault)
}
#endif
