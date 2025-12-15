import Foundation
import Testing
import TestContainers

// MARK: - WaitStrategy.all Tests

@Test func waitStrategy_all_configuresCorrectly() {
    let request = ContainerRequest(image: "test:latest")
        .waitingFor(.all([
            .tcpPort(8080, timeout: .seconds(30)),
            .logContains("ready", timeout: .seconds(45))
        ]))

    if case let .all(strategies, timeout) = request.waitStrategy {
        #expect(strategies.count == 2)
        #expect(timeout == nil)
    } else {
        Issue.record("Expected .all wait strategy")
    }
}

@Test func waitStrategy_all_withCompositeTimeout() {
    let request = ContainerRequest(image: "test:latest")
        .waitingFor(.all([
            .tcpPort(8080),
            .logContains("ready")
        ], timeout: .seconds(90)))

    if case let .all(strategies, timeout) = request.waitStrategy {
        #expect(strategies.count == 2)
        #expect(timeout == .seconds(90))
    } else {
        Issue.record("Expected .all wait strategy")
    }
}

@Test func waitStrategy_all_conformsToHashable() {
    let strategy1 = WaitStrategy.all([.tcpPort(8080), .logContains("ready")])
    let strategy2 = WaitStrategy.all([.tcpPort(8080), .logContains("ready")])
    let strategy3 = WaitStrategy.all([.tcpPort(9090), .logContains("ready")])

    #expect(strategy1 == strategy2)
    #expect(strategy1 != strategy3)
}

@Test func waitStrategy_all_emptyArrayIsValid() {
    let strategy = WaitStrategy.all([])
    if case let .all(strategies, _) = strategy {
        #expect(strategies.isEmpty)
    } else {
        Issue.record("Expected .all wait strategy")
    }
}

@Test func waitStrategy_all_singleStrategy() {
    let strategy = WaitStrategy.all([.tcpPort(8080)])
    if case let .all(strategies, _) = strategy {
        #expect(strategies.count == 1)
    } else {
        Issue.record("Expected .all wait strategy")
    }
}

// MARK: - WaitStrategy.any Tests

@Test func waitStrategy_any_configuresCorrectly() {
    let request = ContainerRequest(image: "test:latest")
        .waitingFor(.any([
            .tcpPort(8080, timeout: .seconds(20)),
            .tcpPort(9090, timeout: .seconds(20))
        ]))

    if case let .any(strategies, timeout) = request.waitStrategy {
        #expect(strategies.count == 2)
        #expect(timeout == nil)
    } else {
        Issue.record("Expected .any wait strategy")
    }
}

@Test func waitStrategy_any_withCompositeTimeout() {
    let request = ContainerRequest(image: "test:latest")
        .waitingFor(.any([
            .logContains("HTTP"),
            .logContains("gRPC")
        ], timeout: .seconds(30)))

    if case let .any(strategies, timeout) = request.waitStrategy {
        #expect(strategies.count == 2)
        #expect(timeout == .seconds(30))
    } else {
        Issue.record("Expected .any wait strategy")
    }
}

@Test func waitStrategy_any_conformsToHashable() {
    let strategy1 = WaitStrategy.any([.tcpPort(8080), .tcpPort(9090)])
    let strategy2 = WaitStrategy.any([.tcpPort(8080), .tcpPort(9090)])
    let strategy3 = WaitStrategy.any([.tcpPort(8080), .tcpPort(8081)])

    #expect(strategy1 == strategy2)
    #expect(strategy1 != strategy3)
}

@Test func waitStrategy_any_emptyArrayIsValid() {
    let strategy = WaitStrategy.any([])
    if case let .any(strategies, _) = strategy {
        #expect(strategies.isEmpty)
    } else {
        Issue.record("Expected .any wait strategy")
    }
}

// MARK: - Nested Composition Tests

@Test func waitStrategy_nestedComposition() {
    let strategy = WaitStrategy.all([
        .any([
            .tcpPort(8080),
            .tcpPort(9090)
        ]),
        .logContains("ready")
    ])

    if case let .all(strategies, _) = strategy {
        #expect(strategies.count == 2)
        if case let .any(innerStrategies, _) = strategies[0] {
            #expect(innerStrategies.count == 2)
        } else {
            Issue.record("Expected nested .any strategy")
        }
    } else {
        Issue.record("Expected .all wait strategy")
    }
}

@Test func waitStrategy_deeplyNestedComposition() {
    let strategy = WaitStrategy.all([
        .any([
            .all([
                .tcpPort(8080),
                .logContains("started")
            ]),
            .tcpPort(9090)
        ]),
        .logContains("ready")
    ])

    // Just verify it compiles and constructs correctly
    if case let .all(strategies, _) = strategy {
        #expect(strategies.count == 2)
    } else {
        Issue.record("Expected .all wait strategy")
    }
}

@Test func waitStrategy_nestedComposition_isHashable() {
    let strategy1 = WaitStrategy.all([
        .any([.tcpPort(8080), .tcpPort(9090)]),
        .logContains("ready")
    ])
    let strategy2 = WaitStrategy.all([
        .any([.tcpPort(8080), .tcpPort(9090)]),
        .logContains("ready")
    ])

    #expect(strategy1 == strategy2)
}

// MARK: - maxTimeout() Tests

@Test func waitStrategy_maxTimeout_simple() {
    let strategy = WaitStrategy.tcpPort(8080, timeout: .seconds(30))
    #expect(strategy.maxTimeout() == .seconds(30))
}

@Test func waitStrategy_maxTimeout_logContains() {
    let strategy = WaitStrategy.logContains("ready", timeout: .seconds(45))
    #expect(strategy.maxTimeout() == .seconds(45))
}

@Test func waitStrategy_maxTimeout_none() {
    let strategy = WaitStrategy.none
    #expect(strategy.maxTimeout() == .seconds(0))
}

@Test func waitStrategy_maxTimeout_all_returnsMaxChild() {
    let strategy = WaitStrategy.all([
        .tcpPort(8080, timeout: .seconds(30)),
        .logContains("ready", timeout: .seconds(60))
    ])
    #expect(strategy.maxTimeout() == .seconds(60))
}

@Test func waitStrategy_maxTimeout_all_withCompositeTimeout() {
    let strategy = WaitStrategy.all([
        .tcpPort(8080, timeout: .seconds(60))
    ], timeout: .seconds(30))
    // Composite timeout overrides child max
    #expect(strategy.maxTimeout() == .seconds(30))
}

@Test func waitStrategy_maxTimeout_any_returnsMaxChild() {
    let strategy = WaitStrategy.any([
        .tcpPort(8080, timeout: .seconds(20)),
        .tcpPort(9090, timeout: .seconds(40))
    ])
    #expect(strategy.maxTimeout() == .seconds(40))
}

@Test func waitStrategy_maxTimeout_nested() {
    let strategy = WaitStrategy.all([
        .any([
            .tcpPort(8080, timeout: .seconds(10)),
            .tcpPort(9090, timeout: .seconds(20))
        ]),
        .logContains("ready", timeout: .seconds(30))
    ])
    // Max of: any(max=20), logContains(30) = 30
    #expect(strategy.maxTimeout() == .seconds(30))
}

@Test func waitStrategy_maxTimeout_empty_all() {
    let strategy = WaitStrategy.all([])
    #expect(strategy.maxTimeout() == .seconds(0))
}

@Test func waitStrategy_maxTimeout_empty_any() {
    let strategy = WaitStrategy.any([])
    #expect(strategy.maxTimeout() == .seconds(0))
}

// MARK: - Integration Tests

@Test func composite_all_withTcpAndLog() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7-alpine")
        .withExposedPort(6379)
        .waitingFor(.all([
            .tcpPort(6379, timeout: .seconds(30)),
            .logContains("Ready to accept connections", timeout: .seconds(30))
        ]))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }
}

@Test func composite_all_withCompositeTimeout() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7-alpine")
        .withExposedPort(6379)
        .waitingFor(.all([
            .tcpPort(6379, timeout: .seconds(60)),
            .logContains("Ready to accept connections", timeout: .seconds(60))
        ], timeout: .seconds(30)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }
}

@Test func composite_any_firstWins() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Redis starts on 6379, not 6380, so tcpPort(6379) should win
    let request = ContainerRequest(image: "redis:7-alpine")
        .withExposedPort(6379)
        .waitingFor(.any([
            .tcpPort(6379, timeout: .seconds(20)),
            .logContains("THIS_WILL_NEVER_APPEAR", timeout: .seconds(20))
        ]))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }
}

@Test func composite_nested_allContainsAny() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7-alpine")
        .withExposedPort(6379)
        .waitingFor(.all([
            .any([
                .tcpPort(6379, timeout: .seconds(15)),
                .logContains("NEVER_APPEARS", timeout: .seconds(15))
            ]),
            .logContains("Ready to accept connections", timeout: .seconds(20))
        ], timeout: .seconds(30)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }
}

@Test func composite_all_emptyArraySucceeds() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .waitingFor(.all([]))

    try await withContainer(request) { container in
        let containerId = await container.id
        #expect(containerId.isEmpty == false)
    }
}

@Test func composite_any_emptyArrayFails() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .waitingFor(.any([]))

    do {
        try await withContainer(request) { _ in
            Issue.record("Expected emptyAnyWaitStrategy error")
        }
    } catch let error as TestContainersError {
        if case .emptyAnyWaitStrategy = error {
            // Expected
        } else {
            Issue.record("Expected emptyAnyWaitStrategy error, got: \(error)")
        }
    }
}

@Test func composite_all_failsOnTimeout() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .waitingFor(.all([
            .logContains("THIS_WILL_NEVER_APPEAR", timeout: .seconds(3))
        ]))

    do {
        try await withContainer(request) { _ in
            Issue.record("Expected timeout error")
        }
    } catch let error as TestContainersError {
        if case let .timeout(message) = error {
            #expect(message.contains("THIS_WILL_NEVER_APPEAR"))
        } else {
            Issue.record("Expected timeout error, got: \(error)")
        }
    }
}

@Test func composite_any_allFailReportsErrors() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "30"])
        .waitingFor(.any([
            .logContains("NEVER1", timeout: .seconds(2)),
            .logContains("NEVER2", timeout: .seconds(2))
        ], timeout: .seconds(5)))

    do {
        try await withContainer(request) { _ in
            Issue.record("Expected allWaitStrategiesFailed or timeout error")
        }
    } catch {
        // Either allWaitStrategiesFailed or timeout is acceptable
        // depending on timing
    }
}

@Test func composite_all_parallelPerformance() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let start = ContinuousClock.now

    let request = ContainerRequest(image: "redis:7-alpine")
        .withExposedPort(6379)
        .waitingFor(.all([
            .tcpPort(6379, timeout: .seconds(30)),
            .logContains("Ready to accept connections", timeout: .seconds(30))
        ]))

    try await withContainer(request) { _ in }

    let elapsed = start.duration(to: ContinuousClock.now)
    // Should complete in parallel, not sum of timeouts
    // Redis typically starts in 1-5 seconds
    #expect(elapsed < .seconds(15))
}
