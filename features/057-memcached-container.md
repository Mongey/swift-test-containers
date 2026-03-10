# Feature 057: MemcachedContainer Module

**Status:** Implemented
**Priority:** Tier 4 (Module System - Service-Specific Helpers)
**Category:** Caching

---

## Summary

Pre-configured `MemcachedContainer` module that provides a typed Swift API for running Memcached containers in tests. Includes sensible defaults, memory/connection/thread configuration, connection string helpers, and TCP-based wait strategy.

---

## API

### MemcachedContainer

```swift
let memcached = MemcachedContainer()              // image: "memcached:1.6", port: 11211
let memcached = MemcachedContainer(image: "memcached:1.6-alpine")

// Builder methods
memcached
    .withPort(12345)
    .withMemory(megabytes: 128)       // -m 128
    .withMaxConnections(2048)          // -c 2048
    .withThreads(8)                    // -t 8
    .withVerbose()                     // -v
    .withHost("localhost")
    .waitingFor(.logContains("..."))   // override default TCP wait
```

### RunningMemcachedContainer

```swift
try await withMemcachedContainer(memcached) { container in
    let connStr = try await container.connectionString()  // "127.0.0.1:32768"
    let port = try await container.port()                 // mapped host port
    let host = container.host()                           // "127.0.0.1"
    let logs = try await container.logs()
    let result = try await container.exec(["command"])
    let underlying = container.underlyingContainer        // generic Container
}
```

### Connection String

```swift
MemcachedContainer.buildConnectionString(host: "localhost", port: 11211)
// => "localhost:11211"
```

---

## Configuration Mapping

| Builder Method | Memcached Flag | Default |
|---|---|---|
| `.withMemory(megabytes:)` | `-m <MB>` | 64 (Memcached default) |
| `.withMaxConnections(_:)` | `-c <N>` | 1024 (Memcached default) |
| `.withThreads(_:)` | `-t <N>` | 4 (Memcached default) |
| `.withVerbose()` | `-v` | disabled |

---

## Wait Strategy

Default: `.tcpPort(11211, timeout: 60s, pollInterval: 500ms)`

Memcached accepts TCP connections immediately upon startup, making TCP port check the appropriate default wait strategy.

---

## Testing

- 32 unit tests covering defaults, builder methods, immutability, hashability, `toContainerRequest()` conversion, connection strings, and static constants
- 5 integration tests (gated by `TESTCONTAINERS_RUN_DOCKER_TESTS=1`) covering container startup, port mapping, memory configuration, underlying container access, and exec/stats

---

## Files

- `Sources/TestContainers/MemcachedContainer.swift` - Implementation
- `Tests/TestContainersTests/MemcachedContainerTests.swift` - Tests
