import Foundation
import Testing
import TestContainers

private func parallelSafetyDockerTestsEnabled() -> Bool {
    ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
}

@Test func parallelSafety_multipleRedisContainersInParallel_getUniqueEndpoints() async throws {
    guard parallelSafetyDockerTestsEnabled() else { return }

    let results = try await withThrowingTaskGroup(of: String.self) { group in
        for index in 0..<5 {
            group.addTask {
                let request = ContainerRequest(image: "redis:7")
                    .withRandomPort(6379)
                    .withTestLabels(testName: "parallel-redis-\(index)", sessionID: ContainerNameGenerator.generateSessionID())
                    .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

                return try await withContainer(request) { container in
                    try await container.endpoint(for: 6379)
                }
            }
        }

        var endpoints: [String] = []
        for try await endpoint in group {
            endpoints.append(endpoint)
        }
        return endpoints
    }

    #expect(results.count == 5)
    #expect(Set(results).count == 5)
}

@Test func parallelSafety_multipleContainersInParallel_noNameCollisions() async throws {
    guard parallelSafetyDockerTestsEnabled() else { return }

    let results = try await withThrowingTaskGroup(of: String.self) { group in
        for index in 0..<3 {
            group.addTask {
                let request = ContainerRequest(image: "postgres:15-alpine")
                    .withRandomPort(5432)
                    .withEnvironment(["POSTGRES_PASSWORD": "secret-\(index)"])
                    .waitingFor(.tcpPort(5432, timeout: .seconds(60)))

                return try await withContainer(request) { container in
                    container.id
                }
            }
        }

        var ids: [String] = []
        for try await id in group {
            ids.append(id)
        }
        return ids
    }

    #expect(results.count == 3)
    #expect(Set(results).count == 3)
}

@Test func parallelSafety_fixedNameConflictsInParallel() async throws {
    guard parallelSafetyDockerTestsEnabled() else { return }

    let fixedName = "parallel-fixed-\(UUID().uuidString.prefix(8).lowercased())"

    await #expect(throws: TestContainersError.self) {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let request = ContainerRequest(image: "redis:7")
                    .withFixedName(fixedName)
                    .withRandomPort(6379)
                    .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

                try await withContainer(request) { _ in
                    try await Task.sleep(for: .seconds(2))
                }
            }

            group.addTask {
                try await Task.sleep(for: .milliseconds(250))

                let request = ContainerRequest(image: "redis:7")
                    .withFixedName(fixedName)
                    .withRandomPort(6379)
                    .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

                try await withContainer(request) { _ in
                    // Expected to fail during container startup.
                }
            }

            try await group.waitForAll()
        }
    }
}
