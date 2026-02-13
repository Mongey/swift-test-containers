import Foundation
import Testing
@testable import TestContainers

// MARK: - CollectingLogConsumer Tests

@Test func collectingLogConsumer_storesEntries() async {
    let collector = CollectingLogConsumer()
    await collector.accept(stream: .stdout, line: "hello")
    await collector.accept(stream: .stderr, line: "world")

    let entries = await collector.getEntries()
    #expect(entries.count == 2)
    #expect(entries[0].stream == .stdout)
    #expect(entries[0].line == "hello")
    #expect(entries[1].stream == .stderr)
    #expect(entries[1].line == "world")
}

@Test func collectingLogConsumer_getLines_returnsAllLines() async {
    let collector = CollectingLogConsumer()
    await collector.accept(stream: .stdout, line: "line1")
    await collector.accept(stream: .stderr, line: "line2")
    await collector.accept(stream: .stdout, line: "line3")

    let lines = await collector.getLines()
    #expect(lines == ["line1", "line2", "line3"])
}

@Test func collectingLogConsumer_getLines_filtersStdout() async {
    let collector = CollectingLogConsumer()
    await collector.accept(stream: .stdout, line: "out1")
    await collector.accept(stream: .stderr, line: "err1")
    await collector.accept(stream: .stdout, line: "out2")

    let stdoutLines = await collector.getLines(from: .stdout)
    #expect(stdoutLines == ["out1", "out2"])
}

@Test func collectingLogConsumer_getLines_filtersStderr() async {
    let collector = CollectingLogConsumer()
    await collector.accept(stream: .stdout, line: "out1")
    await collector.accept(stream: .stderr, line: "err1")
    await collector.accept(stream: .stderr, line: "err2")

    let stderrLines = await collector.getLines(from: .stderr)
    #expect(stderrLines == ["err1", "err2"])
}

@Test func collectingLogConsumer_startsEmpty() async {
    let collector = CollectingLogConsumer()

    let entries = await collector.getEntries()
    let lines = await collector.getLines()

    #expect(entries.isEmpty)
    #expect(lines.isEmpty)
}

// MARK: - CompositeLogConsumer Tests

@Test func compositeLogConsumer_sendsToAllConsumers() async {
    let collector1 = CollectingLogConsumer()
    let collector2 = CollectingLogConsumer()
    let composite = CompositeLogConsumer([collector1, collector2])

    await composite.accept(stream: .stdout, line: "test")

    let lines1 = await collector1.getLines()
    let lines2 = await collector2.getLines()

    #expect(lines1 == ["test"])
    #expect(lines2 == ["test"])
}

@Test func compositeLogConsumer_preservesStreamInfo() async {
    let collector = CollectingLogConsumer()
    let composite = CompositeLogConsumer([collector])

    await composite.accept(stream: .stderr, line: "error line")

    let entries = await collector.getEntries()
    #expect(entries.count == 1)
    #expect(entries[0].stream == .stderr)
    #expect(entries[0].line == "error line")
}

@Test func compositeLogConsumer_handlesEmptyConsumerList() async {
    let composite = CompositeLogConsumer([])
    // Should not crash
    await composite.accept(stream: .stdout, line: "test")
}

// MARK: - LogStream Tests

@Test func logStream_equatable() {
    #expect(LogStream.stdout == LogStream.stdout)
    #expect(LogStream.stderr == LogStream.stderr)
    #expect(LogStream.stdout != LogStream.stderr)
}

@Test func logStream_hashable() {
    let set: Set<LogStream> = [.stdout, .stderr, .stdout]
    #expect(set.count == 2)
}

// MARK: - ContainerRequest.withLogConsumer Tests

@Test func containerRequest_logConsumers_defaultsToEmpty() {
    let request = ContainerRequest(image: "alpine:3")
    #expect(request.logConsumers.isEmpty)
}

@Test func containerRequest_withLogConsumer_addsConsumer() {
    let collector = CollectingLogConsumer()
    let request = ContainerRequest(image: "alpine:3")
        .withLogConsumer(collector)

    #expect(request.logConsumers.count == 1)
}

@Test func containerRequest_withLogConsumer_multipleConsumers() {
    let collector1 = CollectingLogConsumer()
    let collector2 = CollectingLogConsumer()
    let request = ContainerRequest(image: "alpine:3")
        .withLogConsumer(collector1)
        .withLogConsumer(collector2)

    #expect(request.logConsumers.count == 2)
}

@Test func containerRequest_withLogConsumers_addsArray() {
    let collector1 = CollectingLogConsumer()
    let collector2 = CollectingLogConsumer()
    let request = ContainerRequest(image: "alpine:3")
        .withLogConsumers([collector1, collector2])

    #expect(request.logConsumers.count == 2)
}

@Test func containerRequest_withLogConsumer_returnsNewInstance() {
    let collector = CollectingLogConsumer()
    let original = ContainerRequest(image: "alpine:3")
    let modified = original.withLogConsumer(collector)

    #expect(original.logConsumers.isEmpty)
    #expect(modified.logConsumers.count == 1)
}

@Test func containerRequest_withLogConsumer_preservesHashability() {
    let collector = CollectingLogConsumer()
    let request1 = ContainerRequest(image: "alpine:3")
        .withLogConsumer(collector)
    let request2 = ContainerRequest(image: "alpine:3")
        .withLogConsumer(collector)

    // Requests with different consumer entries (different UUIDs) should not be equal
    #expect(request1 != request2)
}

@Test func containerRequest_withLogConsumer_chainsWithOtherBuilders() {
    let collector = CollectingLogConsumer()
    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .withLogConsumer(collector)
        .waitingFor(.tcpPort(6379))

    #expect(request.logConsumers.count == 1)
    #expect(request.ports.count == 1)
}

@Test func containerRequest_initWithDockerfile_logConsumersDefaultsToEmpty() {
    let dockerfile = ImageFromDockerfile()
    let request = ContainerRequest(imageFromDockerfile: dockerfile)
    #expect(request.logConsumers.isEmpty)
}
