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

// MARK: - BindMount Tests

@Test func bindMount_dockerFlag_readWrite() {
    let mount = BindMount(hostPath: "/tmp/data", containerPath: "/mnt/data")
    #expect(mount.dockerFlag == "/tmp/data:/mnt/data")
}

@Test func bindMount_dockerFlag_readOnly() {
    let mount = BindMount(hostPath: "/host/config.yml", containerPath: "/etc/config.yml", readOnly: true)
    #expect(mount.dockerFlag == "/host/config.yml:/etc/config.yml:ro")
}

@Test func bindMount_dockerFlag_cached() {
    let mount = BindMount(
        hostPath: "/Users/dev/src",
        containerPath: "/app/src",
        readOnly: false,
        consistency: .cached
    )
    #expect(mount.dockerFlag == "/Users/dev/src:/app/src:cached")
}

@Test func bindMount_dockerFlag_delegated() {
    let mount = BindMount(
        hostPath: "/tmp/logs",
        containerPath: "/logs",
        readOnly: false,
        consistency: .delegated
    )
    #expect(mount.dockerFlag == "/tmp/logs:/logs:delegated")
}

@Test func bindMount_dockerFlag_consistent() {
    let mount = BindMount(
        hostPath: "/data",
        containerPath: "/mnt/data",
        readOnly: false,
        consistency: .consistent
    )
    #expect(mount.dockerFlag == "/data:/mnt/data:consistent")
}

@Test func bindMount_dockerFlag_readOnlyWithConsistency() {
    let mount = BindMount(
        hostPath: "/host/readonly",
        containerPath: "/readonly",
        readOnly: true,
        consistency: .delegated
    )
    #expect(mount.dockerFlag == "/host/readonly:/readonly:ro,delegated")
}

@Test func bindMount_conformsToHashable() {
    let mount1 = BindMount(hostPath: "/data", containerPath: "/mnt/data")
    let mount2 = BindMount(hostPath: "/data", containerPath: "/mnt/data")
    let mount3 = BindMount(hostPath: "/other", containerPath: "/mnt/data")

    #expect(mount1 == mount2)
    #expect(mount1 != mount3)
}

@Test func bindMount_readOnly_defaultsToFalse() {
    let mount = BindMount(hostPath: "/test", containerPath: "/test")
    #expect(mount.readOnly == false)
}

@Test func bindMount_consistency_defaultsToDefault() {
    let mount = BindMount(hostPath: "/test", containerPath: "/test")
    #expect(mount.consistency == .default)
}

@Test func bindMountConsistency_rawValues() {
    #expect(BindMountConsistency.default.rawValue == "")
    #expect(BindMountConsistency.cached.rawValue == "cached")
    #expect(BindMountConsistency.delegated.rawValue == "delegated")
    #expect(BindMountConsistency.consistent.rawValue == "consistent")
}

// MARK: - ContainerRequest BindMount Tests

@Test func containerRequest_withBindMount_addsMount() {
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(hostPath: "/tmp/test", containerPath: "/test")

    #expect(request.bindMounts.count == 1)
    #expect(request.bindMounts[0].hostPath == "/tmp/test")
    #expect(request.bindMounts[0].containerPath == "/test")
    #expect(request.bindMounts[0].readOnly == false)
}

@Test func containerRequest_withBindMount_readOnly() {
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(hostPath: "/config", containerPath: "/etc/config", readOnly: true)

    #expect(request.bindMounts.count == 1)
    #expect(request.bindMounts[0].readOnly == true)
}

@Test func containerRequest_withBindMount_consistency() {
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(
            hostPath: "/src",
            containerPath: "/app/src",
            readOnly: false,
            consistency: .cached
        )

    #expect(request.bindMounts.count == 1)
    #expect(request.bindMounts[0].consistency == .cached)
}

@Test func containerRequest_withBindMount_multiple() {
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(hostPath: "/config", containerPath: "/etc/config", readOnly: true)
        .withBindMount(hostPath: "/data", containerPath: "/data")
        .withBindMount(hostPath: "/logs", containerPath: "/logs", consistency: .delegated)

    #expect(request.bindMounts.count == 3)
    #expect(request.bindMounts.contains(where: { $0.hostPath == "/config" }))
    #expect(request.bindMounts.contains(where: { $0.hostPath == "/data" }))
    #expect(request.bindMounts.contains(where: { $0.hostPath == "/logs" }))
}

@Test func containerRequest_withBindMount_returnsNewInstance() {
    let original = ContainerRequest(image: "alpine:3")
    let modified = original.withBindMount(hostPath: "/data", containerPath: "/mnt/data")

    #expect(original.bindMounts.isEmpty)
    #expect(modified.bindMounts.count == 1)
}

@Test func containerRequest_withBindMountStruct_addsDirectly() {
    let mount = BindMount(
        hostPath: "/shared",
        containerPath: "/mnt/shared",
        readOnly: true,
        consistency: .cached
    )
    let request = ContainerRequest(image: "alpine:3")
        .withBindMount(mount)

    #expect(request.bindMounts.count == 1)
    #expect(request.bindMounts[0] == mount)
}

@Test func containerRequest_bindMounts_startsEmpty() {
    let request = ContainerRequest(image: "alpine:3")
    #expect(request.bindMounts.isEmpty)
}

// MARK: - Entrypoint Override Tests

@Test func containerRequest_entrypoint_defaultsToNil() {
    let request = ContainerRequest(image: "alpine:3")
    #expect(request.entrypoint == nil)
}

@Test func containerRequest_withEntrypoint_setsEntrypointArray() {
    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint(["/bin/sh", "-c"])

    #expect(request.entrypoint == ["/bin/sh", "-c"])
}

@Test func containerRequest_withEntrypoint_singleString() {
    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint("/bin/bash")

    #expect(request.entrypoint == ["/bin/bash"])
}

@Test func containerRequest_withEntrypoint_emptyArrayDisables() {
    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint([])

    #expect(request.entrypoint == [])
}

@Test func containerRequest_withEntrypoint_returnsNewInstance() {
    let original = ContainerRequest(image: "alpine:3")
    let modified = original.withEntrypoint(["/bin/sh"])

    #expect(original.entrypoint == nil)
    #expect(modified.entrypoint == ["/bin/sh"])
}

@Test func containerRequest_withEntrypoint_chainWithCommand() {
    let request = ContainerRequest(image: "alpine:3")
        .withEntrypoint(["/bin/sh", "-c"])
        .withCommand(["echo hello"])
        .withEnvironment(["KEY": "value"])

    #expect(request.entrypoint == ["/bin/sh", "-c"])
    #expect(request.command == ["echo hello"])
    #expect(request.environment["KEY"] == "value")
}

@Test func containerRequest_withEntrypoint_conformsToHashable() {
    let request1 = ContainerRequest(image: "alpine:3")
        .withEntrypoint(["/bin/sh"])
    let request2 = ContainerRequest(image: "alpine:3")
        .withEntrypoint(["/bin/sh"])
    let request3 = ContainerRequest(image: "alpine:3")
        .withEntrypoint(["/bin/bash"])

    #expect(request1 == request2)
    #expect(request1 != request3)
}

@Test func containerRequest_withEntrypoint_nilVsEmptyArrayAreDifferent() {
    let nilEntrypoint = ContainerRequest(image: "alpine:3")
    let emptyEntrypoint = ContainerRequest(image: "alpine:3")
        .withEntrypoint([])

    #expect(nilEntrypoint.entrypoint == nil)
    #expect(emptyEntrypoint.entrypoint == [])
    #expect(nilEntrypoint != emptyEntrypoint)
}

// MARK: - Extended Labels Tests

@Test func containerRequest_withLabels_addsMultipleLabels() {
    let request = ContainerRequest(image: "alpine:3")
        .withLabels([
            "app.name": "test-app",
            "app.version": "1.0"
        ])

    #expect(request.labels["testcontainers.swift"] == "true")
    #expect(request.labels["app.name"] == "test-app")
    #expect(request.labels["app.version"] == "1.0")
    #expect(request.labels.count == 3)
}

@Test func containerRequest_withLabels_prefixed_addsPrefixedLabels() {
    let request = ContainerRequest(image: "alpine:3")
        .withLabels(prefix: "com.acme", [
            "team": "platform",
            "env": "test"
        ])

    #expect(request.labels["com.acme.team"] == "platform")
    #expect(request.labels["com.acme.env"] == "test")
}

@Test func containerRequest_withLabels_emptyPrefixAddsLabelsWithoutDot() {
    let request = ContainerRequest(image: "alpine:3")
        .withLabels(prefix: "", [
            "key": "value"
        ])

    #expect(request.labels["key"] == "value")
    #expect(request.labels[".key"] == nil)
}

@Test func containerRequest_withLabels_overridesExistingLabels() {
    let request = ContainerRequest(image: "alpine:3")
        .withLabel("version", "1.0")
        .withLabels(["version": "2.0"])

    #expect(request.labels["version"] == "2.0")
}

@Test func containerRequest_withoutLabel_removesLabel() {
    let request = ContainerRequest(image: "alpine:3")
        .withLabel("temp", "value")
        .withoutLabel("temp")

    #expect(request.labels["temp"] == nil)
    #expect(request.labels["testcontainers.swift"] == "true")
}

@Test func containerRequest_withoutLabel_removesDefaultLabel() {
    let request = ContainerRequest(image: "alpine:3")
        .withoutLabel("testcontainers.swift")

    #expect(request.labels["testcontainers.swift"] == nil)
    #expect(request.labels.isEmpty)
}

@Test func containerRequest_withLabels_chainsMultipleLabelOperations() {
    let request = ContainerRequest(image: "redis:7")
        .withLabel("single", "value")
        .withLabels(["bulk1": "v1", "bulk2": "v2"])
        .withLabels(prefix: "prefix", ["key": "val"])
        .withoutLabel("bulk1")

    #expect(request.labels["single"] == "value")
    #expect(request.labels["bulk1"] == nil)
    #expect(request.labels["bulk2"] == "v2")
    #expect(request.labels["prefix.key"] == "val")
    #expect(request.labels["testcontainers.swift"] == "true")
}

@Test func containerRequest_withLabels_returnsNewInstance() {
    let original = ContainerRequest(image: "alpine:3")
    let modified = original.withLabels(["new": "label"])

    #expect(original.labels.count == 1)
    #expect(modified.labels.count == 2)
}

@Test func containerRequest_withoutLabel_returnsNewInstance() {
    let original = ContainerRequest(image: "alpine:3")
        .withLabel("temp", "value")
    let modified = original.withoutLabel("temp")

    #expect(original.labels["temp"] == "value")
    #expect(modified.labels["temp"] == nil)
}

@Test func containerRequest_withoutLabel_nonExistentKeyIsNoop() {
    let request = ContainerRequest(image: "alpine:3")
        .withoutLabel("nonexistent")

    #expect(request.labels["testcontainers.swift"] == "true")
    #expect(request.labels.count == 1)
}

// MARK: - ImageFromDockerfile Integration Tests

@Test func containerRequest_initWithImageFromDockerfile_setsProperty() {
    let dockerfile = ImageFromDockerfile(
        dockerfilePath: "test/Dockerfile",
        buildContext: "test"
    )
    let request = ContainerRequest(imageFromDockerfile: dockerfile)

    #expect(request.imageFromDockerfile != nil)
    #expect(request.imageFromDockerfile?.dockerfilePath == "test/Dockerfile")
    #expect(request.imageFromDockerfile?.buildContext == "test")
}

@Test func containerRequest_initWithImageFromDockerfile_generatesUniqueImageTag() {
    let dockerfile = ImageFromDockerfile()
    let request = ContainerRequest(imageFromDockerfile: dockerfile)

    #expect(request.image.hasPrefix("testcontainers-swift-"))
    #expect(request.image.hasSuffix(":latest"))
}

@Test func containerRequest_initWithImageFromDockerfile_imageTagsAreUnique() {
    let dockerfile = ImageFromDockerfile()
    let request1 = ContainerRequest(imageFromDockerfile: dockerfile)
    let request2 = ContainerRequest(imageFromDockerfile: dockerfile)

    #expect(request1.image != request2.image)
}

@Test func containerRequest_initWithImageFromDockerfile_preservesDefaultLabels() {
    let dockerfile = ImageFromDockerfile()
    let request = ContainerRequest(imageFromDockerfile: dockerfile)

    #expect(request.labels["testcontainers.swift"] == "true")
}

@Test func containerRequest_withImageFromDockerfile_builderMethod() {
    let dockerfile = ImageFromDockerfile(dockerfilePath: "Dockerfile.dev")
    let request = ContainerRequest(image: "ignored")
        .withImageFromDockerfile(dockerfile)

    #expect(request.imageFromDockerfile != nil)
    #expect(request.imageFromDockerfile?.dockerfilePath == "Dockerfile.dev")
    #expect(request.image.hasPrefix("testcontainers-swift-"))
}

@Test func containerRequest_withImageFromDockerfile_returnsNewInstance() {
    let dockerfile = ImageFromDockerfile()
    let original = ContainerRequest(image: "alpine:3")
    let modified = original.withImageFromDockerfile(dockerfile)

    #expect(original.imageFromDockerfile == nil)
    #expect(modified.imageFromDockerfile != nil)
}

@Test func containerRequest_withImageFromDockerfile_chainsWithOtherMethods() {
    let dockerfile = ImageFromDockerfile()
        .withBuildArg("VERSION", "1.0")
    let request = ContainerRequest(imageFromDockerfile: dockerfile)
        .withExposedPort(8080)
        .withEnvironment(["DEBUG": "true"])
        .withLabel("app", "test")
        .waitingFor(.tcpPort(8080))

    #expect(request.imageFromDockerfile != nil)
    #expect(request.ports.count == 1)
    #expect(request.environment["DEBUG"] == "true")
    #expect(request.labels["app"] == "test")
}

@Test func containerRequest_imageFromDockerfile_defaultsToNil() {
    let request = ContainerRequest(image: "alpine:3")

    #expect(request.imageFromDockerfile == nil)
}

@Test func containerRequest_imageFromDockerfile_conformsToHashable() {
    let dockerfile = ImageFromDockerfile(dockerfilePath: "Dockerfile")
        .withBuildArg("A", "1")

    // Two requests with the same dockerfile config should not be equal
    // because they have different generated image tags
    let request1 = ContainerRequest(imageFromDockerfile: dockerfile)
    let request2 = ContainerRequest(imageFromDockerfile: dockerfile)

    // They have different images due to UUID generation
    #expect(request1 != request2)
}

@Test func containerRequest_imageFromDockerfile_sameImageWhenCopied() {
    let dockerfile = ImageFromDockerfile()
    let request1 = ContainerRequest(imageFromDockerfile: dockerfile)
    let request2 = request1.withExposedPort(8080)

    // Same request modified should keep same image tag
    #expect(request1.image == request2.image)
}

// MARK: - TmpfsMount Tests

@Test func tmpfsMount_dockerFlag_pathOnly() {
    let mount = TmpfsMount(containerPath: "/tmp")
    #expect(mount.dockerFlag == "/tmp")
}

@Test func tmpfsMount_dockerFlag_withSizeLimit() {
    let mount = TmpfsMount(containerPath: "/cache", sizeLimit: "100m")
    #expect(mount.dockerFlag == "/cache:size=100m")
}

@Test func tmpfsMount_dockerFlag_withMode() {
    let mount = TmpfsMount(containerPath: "/data", mode: "0755")
    #expect(mount.dockerFlag == "/data:mode=0755")
}

@Test func tmpfsMount_dockerFlag_withSizeAndMode() {
    let mount = TmpfsMount(containerPath: "/work", sizeLimit: "1g", mode: "1777")
    #expect(mount.dockerFlag == "/work:size=1g,mode=1777")
}

@Test func tmpfsMount_conformsToHashable() {
    let mount1 = TmpfsMount(containerPath: "/tmp", sizeLimit: "100m")
    let mount2 = TmpfsMount(containerPath: "/tmp", sizeLimit: "100m")
    let mount3 = TmpfsMount(containerPath: "/tmp", sizeLimit: "200m")

    #expect(mount1 == mount2)
    #expect(mount1 != mount3)
}

@Test func tmpfsMount_defaultsToNilOptions() {
    let mount = TmpfsMount(containerPath: "/test")
    #expect(mount.sizeLimit == nil)
    #expect(mount.mode == nil)
}

// MARK: - ContainerRequest Tmpfs Tests

@Test func containerRequest_withTmpfs_addsMount() {
    let request = ContainerRequest(image: "alpine:3")
        .withTmpfs("/tmp")

    #expect(request.tmpfsMounts.count == 1)
    #expect(request.tmpfsMounts[0].containerPath == "/tmp")
    #expect(request.tmpfsMounts[0].sizeLimit == nil)
    #expect(request.tmpfsMounts[0].mode == nil)
}

@Test func containerRequest_withTmpfs_withOptions() {
    let request = ContainerRequest(image: "alpine:3")
        .withTmpfs("/tmp", sizeLimit: "100m", mode: "1777")

    #expect(request.tmpfsMounts.count == 1)
    #expect(request.tmpfsMounts[0].containerPath == "/tmp")
    #expect(request.tmpfsMounts[0].sizeLimit == "100m")
    #expect(request.tmpfsMounts[0].mode == "1777")
}

@Test func containerRequest_withTmpfs_multipleMounts() {
    let request = ContainerRequest(image: "alpine:3")
        .withTmpfs("/tmp", sizeLimit: "100m", mode: "1777")
        .withTmpfs("/cache", sizeLimit: "500m")
        .withTmpfs("/work")

    #expect(request.tmpfsMounts.count == 3)
    #expect(request.tmpfsMounts[0].containerPath == "/tmp")
    #expect(request.tmpfsMounts[1].containerPath == "/cache")
    #expect(request.tmpfsMounts[2].containerPath == "/work")
}

@Test func containerRequest_withTmpfs_returnsNewInstance() {
    let original = ContainerRequest(image: "alpine:3")
    let modified = original.withTmpfs("/tmp")

    #expect(original.tmpfsMounts.isEmpty)
    #expect(modified.tmpfsMounts.count == 1)
}

@Test func containerRequest_tmpfsMounts_startsEmpty() {
    let request = ContainerRequest(image: "alpine:3")
    #expect(request.tmpfsMounts.isEmpty)
}

@Test func containerRequest_withTmpfsMount_addsDirectly() {
    let mount = TmpfsMount(containerPath: "/data", sizeLimit: "256m", mode: "0755")
    let request = ContainerRequest(image: "alpine:3")
        .withTmpfsMount(mount)

    #expect(request.tmpfsMounts.count == 1)
    #expect(request.tmpfsMounts[0] == mount)
}

// MARK: - Working Directory Tests

@Test func containerRequest_workingDirectory_isNilByDefault() {
    let request = ContainerRequest(image: "alpine:3")
    #expect(request.workingDirectory == nil)
}

@Test func containerRequest_withWorkingDirectory_setsProperty() {
    let request = ContainerRequest(image: "alpine:3")
        .withWorkingDirectory("/app")

    #expect(request.workingDirectory == "/app")
}

@Test func containerRequest_withWorkingDirectory_canBeChained() {
    let request = ContainerRequest(image: "node:20")
        .withWorkingDirectory("/app")
        .withCommand(["node", "index.js"])
        .withExposedPort(3000)

    #expect(request.workingDirectory == "/app")
    #expect(request.command == ["node", "index.js"])
    #expect(request.ports.count == 1)
}

@Test func containerRequest_withWorkingDirectory_returnsNewInstance() {
    let original = ContainerRequest(image: "alpine:3")
    let modified = original.withWorkingDirectory("/app")

    #expect(original.workingDirectory == nil)
    #expect(modified.workingDirectory == "/app")
}

@Test func containerRequest_withWorkingDirectory_conformsToHashable() {
    let request1 = ContainerRequest(image: "alpine:3")
        .withWorkingDirectory("/app")
    let request2 = ContainerRequest(image: "alpine:3")
        .withWorkingDirectory("/app")
    let request3 = ContainerRequest(image: "alpine:3")
        .withWorkingDirectory("/other")

    #expect(request1 == request2)
    #expect(request1 != request3)
}

@Test func containerRequest_withWorkingDirectory_supportsRootDirectory() {
    let request = ContainerRequest(image: "alpine:3")
        .withWorkingDirectory("/")

    #expect(request.workingDirectory == "/")
}

@Test func containerRequest_withWorkingDirectory_supportsPathsWithSpaces() {
    let request = ContainerRequest(image: "alpine:3")
        .withWorkingDirectory("/my app/data")

    #expect(request.workingDirectory == "/my app/data")
}

// MARK: - Privileged Mode & Capabilities Tests

@Test func containerRequest_privileged_defaultsToFalse() {
    let request = ContainerRequest(image: "alpine:3")
    #expect(request.privileged == false)
}

@Test func containerRequest_withPrivileged_setsFlag() {
    let request = ContainerRequest(image: "alpine:3")
        .withPrivileged()

    #expect(request.privileged == true)
}

@Test func containerRequest_withCapabilityAdd_accumulatesCapabilities() {
    let request = ContainerRequest(image: "alpine:3")
        .withCapabilityAdd(.netAdmin)
        .withCapabilityAdd([.netRaw, .sysTime])

    #expect(request.capabilitiesToAdd == [.netAdmin, .netRaw, .sysTime])
}

@Test func containerRequest_withCapabilityDrop_accumulatesCapabilities() {
    let request = ContainerRequest(image: "alpine:3")
        .withCapabilityDrop(.netRaw)
        .withCapabilityDrop([.chown, .setuid])

    #expect(request.capabilitiesToDrop == [.netRaw, .chown, .setuid])
}

@Test func containerRequest_withCapabilityAddAndDrop_canCombine() {
    let request = ContainerRequest(image: "alpine:3")
        .withCapabilityAdd([.netAdmin, .sysTime])
        .withCapabilityDrop([.chown, .setuid])

    #expect(request.capabilitiesToAdd == [.netAdmin, .sysTime])
    #expect(request.capabilitiesToDrop == [.chown, .setuid])
}

@Test func capability_rawValue_matchesExpectedConstant() {
    #expect(Capability.netAdmin.rawValue == "NET_ADMIN")
    #expect(Capability.sysTime.rawValue == "SYS_TIME")
}

@Test func capability_supportsCustomRawValues() {
    let custom = Capability(rawValue: "CUSTOM_CAP")
    #expect(custom.rawValue == "CUSTOM_CAP")
}
