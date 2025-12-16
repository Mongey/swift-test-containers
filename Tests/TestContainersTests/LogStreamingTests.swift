import Foundation
import Testing
@testable import TestContainers

// MARK: - LogStreamOptions Tests

@Test func logStreamOptions_defaultValues() {
    let options = LogStreamOptions()

    #expect(options.follow == true)
    #expect(options.stdout == true)
    #expect(options.stderr == true)
    #expect(options.timestamps == false)
    #expect(options.since == nil)
    #expect(options.until == nil)
    #expect(options.tail == nil)
}

@Test func logStreamOptions_staticDefault() {
    let options = LogStreamOptions.default

    #expect(options.follow == true)
    #expect(options.stdout == true)
    #expect(options.stderr == true)
    #expect(options.timestamps == false)
}

@Test func logStreamOptions_withFollow() {
    let options = LogStreamOptions(follow: false)

    #expect(options.follow == false)
}

@Test func logStreamOptions_withTimestamps() {
    let options = LogStreamOptions(timestamps: true)

    #expect(options.timestamps == true)
}

@Test func logStreamOptions_withTail() {
    let options = LogStreamOptions(tail: 100)

    #expect(options.tail == 100)
}

@Test func logStreamOptions_withSinceAndUntil() {
    let since = Date(timeIntervalSince1970: 1000)
    let until = Date(timeIntervalSince1970: 2000)
    let options = LogStreamOptions(since: since, until: until)

    #expect(options.since == since)
    #expect(options.until == until)
}

@Test func logStreamOptions_withStdoutOnly() {
    let options = LogStreamOptions(stdout: true, stderr: false)

    #expect(options.stdout == true)
    #expect(options.stderr == false)
}

@Test func logStreamOptions_withStderrOnly() {
    let options = LogStreamOptions(stdout: false, stderr: true)

    #expect(options.stdout == false)
    #expect(options.stderr == true)
}

@Test func logStreamOptions_conformsToSendable() {
    let options = LogStreamOptions()

    // This compiles if LogStreamOptions is Sendable
    let _: Sendable = options
}

@Test func logStreamOptions_conformsToHashable() {
    let options1 = LogStreamOptions(follow: true, timestamps: true)
    let options2 = LogStreamOptions(follow: true, timestamps: true)
    let options3 = LogStreamOptions(follow: false, timestamps: true)

    #expect(options1 == options2)
    #expect(options1 != options3)
}

@Test func logStreamOptions_toDockerArgs_default() {
    let options = LogStreamOptions()
    let args = options.toDockerArgs()

    #expect(args.contains("-f"))
    #expect(!args.contains("--timestamps"))
    #expect(!args.contains("--tail"))
    #expect(!args.contains("--since"))
    #expect(!args.contains("--until"))
}

@Test func logStreamOptions_toDockerArgs_noFollow() {
    let options = LogStreamOptions(follow: false)
    let args = options.toDockerArgs()

    #expect(!args.contains("-f"))
}

@Test func logStreamOptions_toDockerArgs_withTimestamps() {
    let options = LogStreamOptions(timestamps: true)
    let args = options.toDockerArgs()

    #expect(args.contains("--timestamps"))
}

@Test func logStreamOptions_toDockerArgs_withTail() {
    let options = LogStreamOptions(tail: 50)
    let args = options.toDockerArgs()

    let tailIndex = args.firstIndex(of: "--tail")
    #expect(tailIndex != nil)
    if let idx = tailIndex {
        #expect(args[idx + 1] == "50")
    }
}

@Test func logStreamOptions_toDockerArgs_withSince() {
    let since = Date(timeIntervalSince1970: 1734278400) // 2024-12-15T16:00:00Z
    let options = LogStreamOptions(since: since)
    let args = options.toDockerArgs()

    let sinceIndex = args.firstIndex(of: "--since")
    #expect(sinceIndex != nil)
    // Check that a date string follows
    if let idx = sinceIndex {
        #expect(args[idx + 1].contains("2024-12-15"))
    }
}

@Test func logStreamOptions_toDockerArgs_withUntil() {
    let until = Date(timeIntervalSince1970: 1734278400) // 2024-12-15T16:00:00Z
    let options = LogStreamOptions(until: until)
    let args = options.toDockerArgs()

    let untilIndex = args.firstIndex(of: "--until")
    #expect(untilIndex != nil)
}

// MARK: - LogEntry Tests

@Test func logEntry_creation() {
    let entry = LogEntry(stream: .stdout, message: "Hello, world!")

    #expect(entry.stream == .stdout)
    #expect(entry.message == "Hello, world!")
    #expect(entry.timestamp == nil)
}

@Test func logEntry_withTimestamp() {
    let timestamp = Date()
    let entry = LogEntry(stream: .stderr, message: "Error occurred", timestamp: timestamp)

    #expect(entry.stream == .stderr)
    #expect(entry.message == "Error occurred")
    #expect(entry.timestamp == timestamp)
}

@Test func logEntry_streamTypes() {
    let stdoutEntry = LogEntry(stream: .stdout, message: "out")
    let stderrEntry = LogEntry(stream: .stderr, message: "err")

    #expect(stdoutEntry.stream == .stdout)
    #expect(stderrEntry.stream == .stderr)
}

@Test func logEntry_conformsToSendable() {
    let entry = LogEntry(stream: .stdout, message: "test")

    // This compiles if LogEntry is Sendable
    let _: Sendable = entry
}

@Test func logEntry_conformsToHashable() {
    let entry1 = LogEntry(stream: .stdout, message: "test")
    let entry2 = LogEntry(stream: .stdout, message: "test")
    let entry3 = LogEntry(stream: .stderr, message: "test")

    #expect(entry1 == entry2)
    #expect(entry1 != entry3)
}

@Test func logEntryStream_conformsToSendable() {
    let stream: LogEntry.Stream = .stdout

    // This compiles if LogEntry.Stream is Sendable
    let _: Sendable = stream
}

// MARK: - Log Parsing Tests

@Test func parseLogLine_plainMessage() {
    let line = "Hello, world!"
    let entry = LogEntry.parse(line: line, hasTimestamps: false)

    #expect(entry.message == "Hello, world!")
    #expect(entry.timestamp == nil)
    #expect(entry.stream == .stdout) // Default when we can't determine
}

@Test func parseLogLine_withTimestamp() {
    let line = "2024-12-15T16:00:00.123456789Z Hello, world!"
    let entry = LogEntry.parse(line: line, hasTimestamps: true)

    #expect(entry.message == "Hello, world!")
    #expect(entry.timestamp != nil)
}

@Test func parseLogLine_withTimestamp_noMessage() {
    let line = "2024-12-15T16:00:00.123456789Z "
    let entry = LogEntry.parse(line: line, hasTimestamps: true)

    #expect(entry.message == "")
    #expect(entry.timestamp != nil)
}

@Test func parseLogLine_emptyLine() {
    let line = ""
    let entry = LogEntry.parse(line: line, hasTimestamps: false)

    #expect(entry.message == "")
}

@Test func parseLogLine_withTimestampFlag_butNoTimestamp() {
    // When timestamps flag is set but line doesn't have timestamp format
    let line = "Plain message without timestamp"
    let entry = LogEntry.parse(line: line, hasTimestamps: true)

    // Should still work - treat whole line as message
    #expect(entry.message == "Plain message without timestamp")
}
