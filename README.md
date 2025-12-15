# swift-test-containers

A Swift package for running Docker containers in tests, designed to pair nicely with `swift-testing` (`import Testing`).

## Quick start

```swift
import Testing
import TestContainers

@Test func redisExample() async throws {
    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }
}
```

## Notes

- This library currently shells out to the `docker` CLI (so Docker must be installed and available on `PATH`).
- Integration tests are opt-in via `TESTCONTAINERS_RUN_DOCKER_TESTS=1`.
- Feature status and roadmap: `FEATURES.md`.
