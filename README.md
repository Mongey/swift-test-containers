# swift-test-containers

A Swift package for running containers in tests, designed to pair nicely with `swift-testing` (`import Testing`).

Supports both **Docker** and **Apple's `container` CLI** (macOS 26+, Apple Silicon) as container runtimes.

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

## Parallel Test Safety

`swift-test-containers` now defaults to parallel-safe container naming and port allocation patterns.

### What happens by default

- Containers get unique names (`tc-swift-<timestamp>-<uuid8>`)
- `withExposedPort(_:)` uses Docker random host ports
- `withContainer` still guarantees cleanup on success, failure, and cancellation

### Recommended pattern

```swift
let request = ContainerRequest(image: "redis:7")
    .withExposedPort(6379) // random host port
    .waitingFor(.tcpPort(6379))
```

### Avoid for parallel runs

```swift
let request = ContainerRequest(image: "redis:7")
    .withFixedName("my-redis")
    .withExposedPort(6379, hostPort: 6379)
```

Fixed names and fixed host ports can collide when tests run concurrently.

## Run as specific user/group

```swift
let request = ContainerRequest(image: "alpine:3")
    .withUser(uid: 1000, gid: 1000)
    .withCommand(["sleep", "30"])
```

## Extra hosts (`--add-host`)

```swift
let request = ContainerRequest(image: "alpine:3")
    .withExtraHost(hostname: "db.local", ip: "192.0.2.10")
    .withExtraHost(.gateway(hostname: "host.internal"))
```

## Container Runtimes

By default, `swift-test-containers` uses the Docker CLI. You can switch to Apple's `container` CLI:

```swift
// Explicit runtime selection
let runtime = AppleContainerClient()
try await withContainer(request, runtime: runtime) { container in ... }

// Or use detectRuntime() with environment variable
// TESTCONTAINERS_RUNTIME=apple swift test
let runtime = detectRuntime()
try await withContainer(request, runtime: runtime) { container in ... }
```

### Docker (default)
- Requires Docker installed and available on `PATH`
- Full feature support

### Apple `container` CLI
- Requires macOS 26+ on Apple Silicon
- Install: `brew install container`
- Start service: `container system start`
- Runs Linux containers as lightweight VMs
- Most features supported; `connectToNetwork` after creation is not supported

## Notes

- Integration tests are opt-in via `TESTCONTAINERS_RUN_DOCKER_TESTS=1` (Docker) or `TESTCONTAINERS_RUN_APPLE_CONTAINER_TESTS=1` (Apple container).
- Feature status and roadmap: `FEATURES.md`.

## Platform Selection

Use `--platform` when you need a specific architecture:

```swift
let request = ContainerRequest(image: "alpine:3")
    .withPlatform("linux/amd64")
    .withCommand(["uname", "-m"])
```

## Reusable containers (experimental)

Container reuse is opt-in per request and gated globally for safety:

```swift
let request = ContainerRequest(image: "redis:7")
    .withReuse()
```

Enable global reuse with either:
- `TESTCONTAINERS_REUSE_ENABLE=true` (or `1`)
- `~/.testcontainers.properties` containing `testcontainers.reuse.enable=true`

Reusable containers are intentionally not terminated at the end of `withContainer` and are not recommended for CI.

Manual cleanup:

```bash
docker rm -f $(docker ps -aq --filter label=testcontainers.swift.reuse=true)
```

## Service Containers

### Kafka

```swift
import Testing
import TestContainers

@Test func kafkaExample() async throws {
    let kafka = KafkaContainer()

    try await withContainer(kafka.build()) { container in
        let bootstrapServers = try await KafkaContainer.bootstrapServers(from: container)
        #expect(bootstrapServers.contains(":"))
    }
}
```

### MySQL

```swift
import Testing
import TestContainers

@Test func mySQLExample() async throws {
    let request = MySQLContainerRequest()
        .withDatabase("myapp")
        .withUsername("app", password: "secret")

    try await withMySQLContainer(request) { mysql in
        let connectionString = try await mysql.connectionString()
        #expect(connectionString.hasPrefix("mysql://"))
    }
}
```

### MariaDB

```swift
import Testing
import TestContainers

@Test func mariaDBExample() async throws {
    let request = MariaDBContainerRequest()
        .withDatabase("myapp")
        .withUsername("app", password: "secret")

    try await withMariaDBContainer(request) { mariadb in
        let connectionString = try await mariadb.connectionString()
        #expect(connectionString.hasPrefix("mysql://"))
    }
}
```

### Elasticsearch

```swift
import Testing
import TestContainers

@Test func elasticsearchExample() async throws {
    let elasticsearch = ElasticsearchContainer()
        .withSecurityDisabled()

    try await withElasticsearchContainer(elasticsearch) { container in
        let address = try await container.httpAddress()
        #expect(address.hasPrefix("http://"))
    }
}
```

### OpenSearch

```swift
import Testing
import TestContainers

@Test func openSearchExample() async throws {
    let openSearch = OpenSearchContainer()
        .withSecurityDisabled()

    try await withOpenSearchContainer(openSearch) { container in
        let settings = try await container.settings()
        #expect(settings.address.hasPrefix("http://"))
    }
}
```
