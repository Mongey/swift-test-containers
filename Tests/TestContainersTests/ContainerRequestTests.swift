import Testing
import TestContainers

@Test func buildsDockerPortFlags() {
    let request = ContainerRequest(image: "alpine:3")
        .withExposedPort(8080)
        .withExposedPort(5432, hostPort: 15432)

    #expect(request.ports == [
        ContainerPort(containerPort: 8080),
        ContainerPort(containerPort: 5432, hostPort: 15432),
    ])
}

// MARK: - WaitStrategy.logMatches Tests

@Test func waitStrategy_logMatches_configuresCorrectly() {
    let request = ContainerRequest(image: "test:latest")
        .waitingFor(.logMatches("ready.*accept", timeout: .seconds(45), pollInterval: .milliseconds(300)))

    if case let .logMatches(pattern, timeout, pollInterval) = request.waitStrategy {
        #expect(pattern == "ready.*accept")
        #expect(timeout == .seconds(45))
        #expect(pollInterval == .milliseconds(300))
    } else {
        Issue.record("Expected .logMatches wait strategy")
    }
}

@Test func waitStrategy_logMatches_defaultValues() {
    let request = ContainerRequest(image: "test:latest")
        .waitingFor(.logMatches("pattern"))

    if case let .logMatches(pattern, timeout, pollInterval) = request.waitStrategy {
        #expect(pattern == "pattern")
        #expect(timeout == .seconds(60))
        #expect(pollInterval == .milliseconds(200))
    } else {
        Issue.record("Expected .logMatches wait strategy")
    }
}

@Test func waitStrategy_logMatches_conformsToHashable() {
    let strategy1 = WaitStrategy.logMatches("pattern", timeout: .seconds(30))
    let strategy2 = WaitStrategy.logMatches("pattern", timeout: .seconds(30))
    let strategy3 = WaitStrategy.logMatches("different", timeout: .seconds(30))

    #expect(strategy1 == strategy2)
    #expect(strategy1 != strategy3)
}
