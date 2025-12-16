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

// MARK: - ContainerRequest.withRetry Tests

@Test func containerRequest_withRetry_setsDefaultPolicy() {
    let request = ContainerRequest(image: "alpine:3")
        .withRetry()

    #expect(request.retryPolicy == RetryPolicy.default)
}

@Test func containerRequest_withRetry_customPolicy() {
    let customPolicy = RetryPolicy(
        maxAttempts: 4,
        initialDelay: .milliseconds(500),
        maxDelay: .seconds(15),
        backoffMultiplier: 1.5,
        jitter: 0.2
    )

    let request = ContainerRequest(image: "alpine:3")
        .withRetry(customPolicy)

    #expect(request.retryPolicy == customPolicy)
}

@Test func containerRequest_withRetry_preservesOtherConfiguration() {
    let request = ContainerRequest(image: "postgres:16")
        .withName("test-db")
        .withExposedPort(5432)
        .withEnvironment(["POSTGRES_PASSWORD": "secret"])
        .waitingFor(.tcpPort(5432))
        .withRetry(.aggressive)

    #expect(request.image == "postgres:16")
    #expect(request.name == "test-db")
    #expect(request.ports == [ContainerPort(containerPort: 5432)])
    #expect(request.environment["POSTGRES_PASSWORD"] == "secret")
    #expect(request.retryPolicy == RetryPolicy.aggressive)
}

@Test func containerRequest_withoutRetry_hasNilPolicy() {
    let request = ContainerRequest(image: "alpine:3")

    #expect(request.retryPolicy == nil)
}

@Test func containerRequest_retryPolicy_conformsToHashable() {
    let request1 = ContainerRequest(image: "alpine:3")
        .withRetry(.default)

    let request2 = ContainerRequest(image: "alpine:3")
        .withRetry(.default)

    let request3 = ContainerRequest(image: "alpine:3")
        .withRetry(.aggressive)

    #expect(request1 == request2)
    #expect(request1 != request3)
}

// MARK: - VolumeMount Tests

@Test func volumeMount_dockerFlag_readWrite() {
    let mount = VolumeMount(volumeName: "data", containerPath: "/mnt/data")
    #expect(mount.dockerFlag == "data:/mnt/data")
}

@Test func volumeMount_dockerFlag_readOnly() {
    let mount = VolumeMount(volumeName: "config", containerPath: "/etc/app", readOnly: true)
    #expect(mount.dockerFlag == "config:/etc/app:ro")
}

@Test func volumeMount_conformsToHashable() {
    let mount1 = VolumeMount(volumeName: "data", containerPath: "/data")
    let mount2 = VolumeMount(volumeName: "data", containerPath: "/data")
    let mount3 = VolumeMount(volumeName: "other", containerPath: "/data")

    #expect(mount1 == mount2)
    #expect(mount1 != mount3)
}

@Test func volumeMount_readOnly_defaultsToFalse() {
    let mount = VolumeMount(volumeName: "test", containerPath: "/test")
    #expect(mount.readOnly == false)
}

// MARK: - ContainerRequest Volume Tests

@Test func containerRequest_withVolume_addsVolumeMount() {
    let request = ContainerRequest(image: "alpine:3")
        .withVolume("data", mountedAt: "/data")

    #expect(request.volumes.count == 1)
    #expect(request.volumes[0].volumeName == "data")
    #expect(request.volumes[0].containerPath == "/data")
    #expect(request.volumes[0].readOnly == false)
}

@Test func containerRequest_withVolume_readOnly() {
    let request = ContainerRequest(image: "alpine:3")
        .withVolume("config", mountedAt: "/etc/config", readOnly: true)

    #expect(request.volumes.count == 1)
    #expect(request.volumes[0].readOnly == true)
}

@Test func containerRequest_withVolume_multipleVolumes() {
    let request = ContainerRequest(image: "alpine:3")
        .withVolume("data", mountedAt: "/data")
        .withVolume("logs", mountedAt: "/logs", readOnly: true)
        .withVolume("cache", mountedAt: "/cache")

    #expect(request.volumes.count == 3)
    #expect(request.volumes.contains(VolumeMount(volumeName: "data", containerPath: "/data")))
    #expect(request.volumes.contains(VolumeMount(volumeName: "logs", containerPath: "/logs", readOnly: true)))
    #expect(request.volumes.contains(VolumeMount(volumeName: "cache", containerPath: "/cache")))
}

@Test func containerRequest_withVolume_returnsNewInstance() {
    let original = ContainerRequest(image: "alpine:3")
    let modified = original.withVolume("data", mountedAt: "/data")

    #expect(original.volumes.isEmpty)
    #expect(modified.volumes.count == 1)
}

@Test func containerRequest_withVolumeMount_addsDirectly() {
    let mount = VolumeMount(volumeName: "shared", containerPath: "/mnt/shared", readOnly: true)
    let request = ContainerRequest(image: "alpine:3")
        .withVolumeMount(mount)

    #expect(request.volumes.count == 1)
    #expect(request.volumes[0] == mount)
}

@Test func containerRequest_volumes_startsEmpty() {
    let request = ContainerRequest(image: "alpine:3")
    #expect(request.volumes.isEmpty)
}
