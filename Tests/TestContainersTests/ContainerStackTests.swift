import Foundation
import Testing
@testable import TestContainers

@Test func containerStack_defaultValues() {
    let stack = ContainerStack()

    #expect(stack.containers.isEmpty)
    #expect(stack.dependencies.isEmpty)
    #expect(stack.network?.createIfMissing == true)
    #expect(stack.network?.driver == "bridge")
    #expect(stack.environment.isEmpty)
    #expect(stack.volumes.isEmpty)
    #expect(stack.labels["testcontainers.swift.stack"] == "true")
}

@Test func containerStack_builderMethods_areImmutable() {
    let base = ContainerStack()
    let dbRequest = ContainerRequest(image: "postgres:15")
    let derived = base
        .withContainer("db", dbRequest)
        .withDependency("app", dependsOn: "db")
        .withEnvironment(["STACK_ENV": "1"])
        .withLabel("stack.label", "yes")

    #expect(base.containers.isEmpty)
    #expect(base.dependencies.isEmpty)
    #expect(base.environment.isEmpty)
    #expect(base.labels["stack.label"] == nil)

    #expect(derived.containers["db"]?.image == "postgres:15")
    #expect(derived.dependencies["app"] == ["db"])
    #expect(derived.environment["STACK_ENV"] == "1")
    #expect(derived.labels["stack.label"] == "yes")
}

@Test func containerStack_withDependencies_addsAllDependencies() {
    let stack = ContainerStack()
        .withContainer("db", ContainerRequest(image: "postgres:15"))
        .withContainer("cache", ContainerRequest(image: "redis:7"))
        .withContainer("app", ContainerRequest(image: "example/app:latest"))
        .withDependencies("app", dependsOn: ["db", "cache"])

    #expect(stack.dependencies["app"] == ["db", "cache"])
}

@Test func containerStack_validate_missingDependency_throwsInvalidDependency() {
    let stack = ContainerStack()
        .withContainer("app", ContainerRequest(image: "example/app:latest"))
        .withDependency("app", dependsOn: "db")

    do {
        try stack.validate()
        Issue.record("Expected stack validation to fail for missing dependency")
    } catch let error as TestContainersError {
        if case let .invalidDependency(dependent, dependency, reason) = error {
            #expect(dependent == "app")
            #expect(dependency == "db")
            #expect(reason.contains("not defined"))
        } else {
            Issue.record("Expected invalidDependency error, got: \(error)")
        }
    } catch {
        Issue.record("Expected TestContainersError, got: \(error)")
    }
}

@Test func containerStack_validate_missingDependent_throwsInvalidDependency() {
    let stack = ContainerStack()
        .withContainer("db", ContainerRequest(image: "postgres:15"))
        .withDependency("app", dependsOn: "db")

    do {
        try stack.validate()
        Issue.record("Expected stack validation to fail for missing dependent")
    } catch let error as TestContainersError {
        if case let .invalidDependency(dependent, dependency, reason) = error {
            #expect(dependent == "app")
            #expect(dependency == "db")
            #expect(reason.contains("Dependent"))
        } else {
            Issue.record("Expected invalidDependency error, got: \(error)")
        }
    } catch {
        Issue.record("Expected TestContainersError, got: \(error)")
    }
}

@Test func containerStack_validate_circularDependency_throwsCircularDependency() {
    let stack = ContainerStack()
        .withContainer("a", ContainerRequest(image: "a:latest"))
        .withContainer("b", ContainerRequest(image: "b:latest"))
        .withDependency("a", dependsOn: "b")
        .withDependency("b", dependsOn: "a")

    do {
        try stack.validate()
        Issue.record("Expected stack validation to fail for circular dependency")
    } catch let error as TestContainersError {
        if case let .circularDependency(containers) = error {
            #expect(containers.contains("a"))
            #expect(containers.contains("b"))
        } else {
            Issue.record("Expected circularDependency error, got: \(error)")
        }
    } catch {
        Issue.record("Expected TestContainersError, got: \(error)")
    }
}

@Test func containerStack_startupOrder_simpleChain() throws {
    let stack = ContainerStack()
        .withContainer("db", ContainerRequest(image: "postgres:15"))
        .withContainer("cache", ContainerRequest(image: "redis:7"))
        .withContainer("app", ContainerRequest(image: "example/app:latest"))
        .withDependency("cache", dependsOn: "db")
        .withDependency("app", dependsOn: "cache")

    let order = try stack.startupOrder()

    #expect(order.firstIndex(of: "db")! < order.firstIndex(of: "cache")!)
    #expect(order.firstIndex(of: "cache")! < order.firstIndex(of: "app")!)
}

@Test func containerStack_startupOrder_diamondGraph() throws {
    let stack = ContainerStack()
        .withContainer("db", ContainerRequest(image: "postgres:15"))
        .withContainer("cache", ContainerRequest(image: "redis:7"))
        .withContainer("queue", ContainerRequest(image: "nats:latest"))
        .withContainer("app", ContainerRequest(image: "example/app:latest"))
        .withDependency("cache", dependsOn: "db")
        .withDependency("queue", dependsOn: "db")
        .withDependencies("app", dependsOn: ["cache", "queue"])

    let order = try stack.startupOrder()

    #expect(order.firstIndex(of: "db")! < order.firstIndex(of: "cache")!)
    #expect(order.firstIndex(of: "db")! < order.firstIndex(of: "queue")!)
    #expect(order.firstIndex(of: "cache")! < order.firstIndex(of: "app")!)
    #expect(order.firstIndex(of: "queue")! < order.firstIndex(of: "app")!)
}

@Test func networkConfig_builderMethods() {
    let config = NetworkConfig(name: "stack-net")
        .withDriver("overlay")
        .withInternal(true)

    #expect(config.name == "stack-net")
    #expect(config.driver == "overlay")
    #expect(config.createIfMissing == true)
    #expect(config.internal == true)
}

@Test func volumeConfig_builderMethods() {
    let config = VolumeConfig()
        .withDriver("local")
        .withOption("type", "tmpfs")
        .withOption("device", "tmpfs")

    #expect(config.driver == "local")
    #expect(config.options["type"] == "tmpfs")
    #expect(config.options["device"] == "tmpfs")
}

@Test func containerStack_withVolume_builderAddsConfig() {
    let stack = ContainerStack()
        .withVolume("shared-data", VolumeConfig())
        .withVolume("cache", VolumeConfig(driver: "local").withOption("type", "tmpfs"))

    #expect(stack.volumes.count == 2)
    #expect(stack.volumes["shared-data"]?.driver == "local")
    #expect(stack.volumes["cache"]?.options["type"] == "tmpfs")
}

@Test func runningStack_containerLookup_returnsContainer() async throws {
    let request = ContainerRequest(image: "postgres:15")
    let dbContainer = Container(id: "stack-db-id", request: request, runtime: DockerClient())
    let running = RunningStack(
        stackId: "stack-id",
        containers: ["db": dbContainer],
        network: nil,
        volumes: [],
        shutdownOrder: ["db"],
        runtime: DockerClient()
    )

    let fetched = try await running.container("db")
    #expect(fetched.id == "stack-db-id")
}

@Test func runningStack_volumeNames_returnsStackVolumes() async throws {
    let request = ContainerRequest(image: "postgres:15")
    let dbContainer = Container(id: "stack-db-id", request: request, runtime: DockerClient())
    let running = RunningStack(
        stackId: "stack-id",
        containers: ["db": dbContainer],
        network: nil,
        volumes: [
            StackVolumeInfo(name: "shared-data", removeOnTermination: true),
            StackVolumeInfo(name: "cache-vol", removeOnTermination: true),
        ],
        shutdownOrder: ["db"],
        runtime: DockerClient()
    )

    let names = await running.volumeNames()
    #expect(names.sorted() == ["cache-vol", "shared-data"])
}

@Test func runningStack_missingContainer_throwsContainerNotFound() async {
    let request = ContainerRequest(image: "postgres:15")
    let dbContainer = Container(id: "stack-db-id", request: request, runtime: DockerClient())
    let running = RunningStack(
        stackId: "stack-id",
        containers: ["db": dbContainer],
        network: nil,
        volumes: [],
        shutdownOrder: ["db"],
        runtime: DockerClient()
    )

    do {
        _ = try await running.container("api")
        Issue.record("Expected container lookup to fail")
    } catch let error as TestContainersError {
        if case let .containerNotFound(name, availableContainers) = error {
            #expect(name == "api")
            #expect(availableContainers == ["db"])
        } else {
            Issue.record("Expected containerNotFound error, got: \(error)")
        }
    } catch {
        Issue.record("Expected TestContainersError, got: \(error)")
    }
}
