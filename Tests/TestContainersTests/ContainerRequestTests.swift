import Testing
@testable import TestContainers

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

// MARK: - WaitStrategy.exec Tests

@Test func waitStrategy_exec_configuresCorrectly() {
    let request = ContainerRequest(image: "postgres:16")
        .waitingFor(.exec(["pg_isready", "-U", "postgres"], timeout: .seconds(45), pollInterval: .milliseconds(300)))

    if case let .exec(command, timeout, pollInterval) = request.waitStrategy {
        #expect(command == ["pg_isready", "-U", "postgres"])
        #expect(timeout == .seconds(45))
        #expect(pollInterval == .milliseconds(300))
    } else {
        Issue.record("Expected .exec wait strategy")
    }
}

@Test func waitStrategy_exec_defaultValues() {
    let request = ContainerRequest(image: "alpine:3")
        .waitingFor(.exec(["test", "-f", "/ready"]))

    if case let .exec(command, timeout, pollInterval) = request.waitStrategy {
        #expect(command == ["test", "-f", "/ready"])
        #expect(timeout == .seconds(60))
        #expect(pollInterval == .milliseconds(200))
    } else {
        Issue.record("Expected .exec wait strategy")
    }
}

@Test func waitStrategy_exec_conformsToHashable() {
    let strategy1 = WaitStrategy.exec(["pg_isready"], timeout: .seconds(30))
    let strategy2 = WaitStrategy.exec(["pg_isready"], timeout: .seconds(30))
    let strategy3 = WaitStrategy.exec(["different"], timeout: .seconds(30))

    #expect(strategy1 == strategy2)
    #expect(strategy1 != strategy3)
}

@Test func waitStrategy_exec_singleCommand() {
    let request = ContainerRequest(image: "alpine:3")
        .waitingFor(.exec(["true"]))

    if case let .exec(command, _, _) = request.waitStrategy {
        #expect(command == ["true"])
    } else {
        Issue.record("Expected .exec wait strategy")
    }
}

// MARK: - WaitStrategy.healthCheck Tests

@Test func waitStrategy_healthCheck_configuresCorrectly() {
    let request = ContainerRequest(image: "postgres:16")
        .waitingFor(.healthCheck(timeout: .seconds(120), pollInterval: .milliseconds(500)))

    if case let .healthCheck(timeout, pollInterval) = request.waitStrategy {
        #expect(timeout == .seconds(120))
        #expect(pollInterval == .milliseconds(500))
    } else {
        Issue.record("Expected .healthCheck wait strategy")
    }
}

@Test func waitStrategy_healthCheck_defaultValues() {
    let request = ContainerRequest(image: "postgres:16")
        .waitingFor(.healthCheck())

    if case let .healthCheck(timeout, pollInterval) = request.waitStrategy {
        #expect(timeout == .seconds(60))
        #expect(pollInterval == .milliseconds(200))
    } else {
        Issue.record("Expected .healthCheck wait strategy")
    }
}

@Test func waitStrategy_healthCheck_conformsToHashable() {
    let strategy1 = WaitStrategy.healthCheck(timeout: .seconds(30))
    let strategy2 = WaitStrategy.healthCheck(timeout: .seconds(30))
    let strategy3 = WaitStrategy.healthCheck(timeout: .seconds(60))

    #expect(strategy1 == strategy2)
    #expect(strategy1 != strategy3)
}

// MARK: - DockerClient.parseHealthStatus Tests

@Test func parseHealthStatus_returnsHealthy() throws {
    let json = """
    {"Status": "healthy", "FailingStreak": 0, "Log": []}
    """

    let status = try DockerClient.parseHealthStatus(json)

    #expect(status.hasHealthCheck == true)
    #expect(status.status == ContainerHealthStatus.Status.healthy)
}

@Test func parseHealthStatus_returnsStarting() throws {
    let json = """
    {"Status": "starting", "FailingStreak": 0, "Log": []}
    """

    let status = try DockerClient.parseHealthStatus(json)

    #expect(status.hasHealthCheck == true)
    #expect(status.status == ContainerHealthStatus.Status.starting)
}

@Test func parseHealthStatus_returnsUnhealthy() throws {
    let json = """
    {"Status": "unhealthy", "FailingStreak": 3, "Log": []}
    """

    let status = try DockerClient.parseHealthStatus(json)

    #expect(status.hasHealthCheck == true)
    #expect(status.status == ContainerHealthStatus.Status.unhealthy)
}

@Test func parseHealthStatus_returnsNoHealthCheck_forNull() throws {
    let json = "null"

    let status = try DockerClient.parseHealthStatus(json)

    #expect(status.hasHealthCheck == false)
    #expect(status.status == nil)
}

@Test func parseHealthStatus_handlesWhitespace() throws {
    let json = """

    {"Status": "healthy"}

    """

    let status = try DockerClient.parseHealthStatus(json)

    #expect(status.hasHealthCheck == true)
    #expect(status.status == ContainerHealthStatus.Status.healthy)
}

@Test func parseHealthStatus_returnsNoHealthCheck_forEmptyString() throws {
    let json = ""

    let status = try DockerClient.parseHealthStatus(json)

    #expect(status.hasHealthCheck == false)
    #expect(status.status == nil)
}
