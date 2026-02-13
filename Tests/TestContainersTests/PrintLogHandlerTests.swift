import Testing
@testable import TestContainers

@Test func printLogHandler_defaultMinimumLevel_isInfo() {
    let handler = PrintLogHandler()
    #expect(handler.minimumLevel == .info)
}

@Test func printLogHandler_customMinimumLevel_isRespected() {
    let handler = PrintLogHandler(minimumLevel: .debug)
    #expect(handler.minimumLevel == .debug)
}

@Test func printLogHandler_isSendable() {
    let handler: any Sendable = PrintLogHandler()
    #expect(handler is PrintLogHandler)
}

@Test func printLogHandler_conformsToLogHandler() {
    let handler: any LogHandler = PrintLogHandler()
    #expect(handler.minimumLevel == .info)
}

@Test func printLogHandler_doesNotCrash_withEmptyMetadata() {
    let handler = PrintLogHandler()
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

@Test func printLogHandler_doesNotCrash_withMetadata() {
    let handler = PrintLogHandler()
    handler.log(
        level: .warning,
        message: "test message",
        metadata: ["key1": "value1", "key2": "value2"],
        source: "TestContainers",
        file: #file,
        function: #function,
        line: #line
    )
}
