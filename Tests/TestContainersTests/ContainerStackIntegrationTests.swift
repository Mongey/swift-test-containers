import Foundation
import Testing
@testable import TestContainers

@Test func withStack_dependencyAndNetworkAliasIntegration() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let stack = ContainerStack()
        .withContainer(
            "redis",
            ContainerRequest(image: "redis:7")
                .withExposedPort(6379)
                .waitingFor(.tcpPort(6379))
        )
        .withContainer(
            "redis-cli",
            ContainerRequest(image: "redis:7")
                .withCommand(["sh", "-c", "redis-cli -h redis ping && sleep 30"])
                .waitingFor(.logContains("PONG", timeout: .seconds(20)))
        )
        .withDependency("redis-cli", dependsOn: "redis")

    try await withStack(stack) { running in
        let redis = try await running.container("redis")
        let redisCli = try await running.container("redis-cli")

        let port = try await redis.hostPort(6379)
        #expect(port > 0)

        let logs = try await redisCli.logs()
        #expect(logs.contains("PONG"))
        #expect(await running.networkName() != nil)
    }
}

@Test func withStack_environmentDefaultsIntegration() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let stack = ContainerStack()
        .withEnvironment(["STACK_ENV": "shared", "OVERRIDE": "stack"])
        .withContainer(
            "env-check",
            ContainerRequest(image: "alpine:3")
                .withEnvironment(["OVERRIDE": "container"])
                .withCommand(["sh", "-c", "echo $STACK_ENV:$OVERRIDE && sleep 30"])
                .waitingFor(.logContains("shared:container", timeout: .seconds(20)))
        )

    try await withStack(stack) { running in
        let envCheck = try await running.container("env-check")
        let logs = try await envCheck.logs()

        #expect(logs.contains("shared:container"))
    }
}

@Test func withContainerGroup_requestDependenciesAndHealthyWaitIntegration() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let db = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "touch /tmp/healthy && sleep 30"])
        .withHealthCheck(command: ["test", "-f", "/tmp/healthy"], interval: .seconds(1))
        .waitingFor(.none)

    let app = ContainerRequest(image: "alpine:3")
        .dependsOn("db", waitFor: .healthy)
        .withCommand(["sh", "-c", "echo app-started && sleep 30"])
        .waitingFor(.logContains("app-started", timeout: .seconds(20)))

    let group = ContainerGroup()
        .withContainer("db", db)
        .withContainer("app", app)

    try await withContainerGroup(group) { running in
        let names = await running.containerNames()
        #expect(names == ["app", "db"])

        let appContainer = try await running.container("app")
        let logs = try await appContainer.logs()
        #expect(logs.contains("app-started"))
    }
}
