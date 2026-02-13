import Testing
@testable import TestContainers

@Test func logLevel_rawValues_areOrdered() {
    #expect(LogLevel.trace.rawValue == 0)
    #expect(LogLevel.debug.rawValue == 1)
    #expect(LogLevel.info.rawValue == 2)
    #expect(LogLevel.notice.rawValue == 3)
    #expect(LogLevel.warning.rawValue == 4)
    #expect(LogLevel.error.rawValue == 5)
    #expect(LogLevel.critical.rawValue == 6)
}

@Test func logLevel_comparable_operatorsWork() {
    #expect(LogLevel.trace < LogLevel.debug)
    #expect(LogLevel.debug < LogLevel.info)
    #expect(LogLevel.info < LogLevel.notice)
    #expect(LogLevel.notice < LogLevel.warning)
    #expect(LogLevel.warning < LogLevel.error)
    #expect(LogLevel.error < LogLevel.critical)
    #expect(LogLevel.critical > LogLevel.trace)
    #expect(LogLevel.info >= LogLevel.info)
    #expect(LogLevel.info <= LogLevel.info)
}

@Test func logLevel_description_returnsLowercaseStrings() {
    #expect(LogLevel.trace.description == "trace")
    #expect(LogLevel.debug.description == "debug")
    #expect(LogLevel.info.description == "info")
    #expect(LogLevel.notice.description == "notice")
    #expect(LogLevel.warning.description == "warning")
    #expect(LogLevel.error.description == "error")
    #expect(LogLevel.critical.description == "critical")
}

@Test func logLevel_isSendable() {
    let level: any Sendable = LogLevel.info
    #expect(level is LogLevel)
}
