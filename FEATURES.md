# Features

This document tracks what `swift-test-containers` supports today, and what's planned next.

## Implemented

**Core API**
- [x] SwiftPM library target: `TestContainers`
- [x] Fluent `ContainerRequest` builder (`image`, `name`, `command`, env, labels, ports)
- [x] Scoped lifecycle: `withContainer(_:_:)` ensures cleanup on success, error, and cancellation
- [x] Scoped multi-container lifecycle: `withStack(_:_:)` with `ContainerStack` and `RunningStack`
- [x] `Container` handle: `hostPort(_:)`, `endpoint(for:)`, `logs()`, `terminate()`

**Container runtimes**
- [x] `ContainerRuntime` protocol - abstraction over container backends
- [x] Docker CLI runner (shells out to `docker`) - `DockerClient`
- [x] Apple `container` CLI runner (macOS 26+, Apple Silicon) - `AppleContainerClient`
- [x] Runtime detection: `detectRuntime(preferred:)` with `TESTCONTAINERS_RUNTIME` env var support
- [x] Start container: `docker run -d ...` / `container run -d ...`
- [x] Stop/remove container: `docker rm -f` / `container delete --force`
- [x] Port resolution: `docker port` / inspect JSON parsing

**Wait strategies**
- [x] `.none`
- [x] `.tcpPort(port, timeout, pollInterval)`
- [x] `.logContains(string, timeout, pollInterval)`
- [x] `.logMatches(regex, timeout, pollInterval)` - regex pattern matching for logs
- [x] `.http(HTTPWaitConfig)` - HTTP/HTTPS wait with method, path, status, body match
- [x] `.all([...], timeout)` - composite wait for all strategies to succeed
- [x] `.any([...], timeout)` - composite wait for first strategy to succeed

**Runtime operations**
- [x] `exec()` in container (sync/async, exit code + stdout/stderr) with `ExecOptions` support
- [x] Copy files to container (`docker cp` to) - file, directory, string, and Data support
- [x] Copy files from container (`docker cp` from) - file, directory, and Data variants
- [x] `inspect()` - comprehensive container inspection (state, health, IPs, env, ports, labels)
- [x] Container-to-container communication - `internalIP()`, `internalIP(forNetwork:)`, `internalHostname()`, `internalEndpoint(for:)`, `internalHostnameEndpoint(for:)`

**Container configuration**
- [x] Volume mounts (named volumes) - `.withVolume(_:mountedAt:readOnly:)`
- [x] Bind mounts (host path → container path) - `.withBindMount(hostPath:containerPath:readOnly:consistency:)`
- [x] Entrypoint override (`--entrypoint`) - `.withEntrypoint([String])` / `.withEntrypoint(String)`
- [x] Extra hosts (`--add-host`) - `.withExtraHost(...)` / `.withExtraHosts(...)`
- [x] User / groups (`--user`) - `.withUser(...)`, `.withUser(uid:)`, `.withUser(uid:gid:)`, `.withUser(username:group:)`
- [x] Privileged mode / capabilities
- [x] Explicit start/stop API - `createContainer()`, `Container.start()`, `.stop()`, `.restart()`, `.currentState`, `.isRunning`

**Testing**
- [x] Unit tests for request building
- [x] Opt-in Docker integration test via `TESTCONTAINERS_RUN_DOCKER_TESTS=1`

---

## Not Implemented (Planned)

### Tier 1: High Priority (Next Up)

**Wait strategies (richer)**
- [x] HTTP/HTTPS wait (method, path, status code, body match, headers) - implemented as `.http(HTTPWaitConfig)`
- [x] Regex log waits (`.logMatches(regex, ...)`) - implemented
- [x] Exec wait (run command, check exit code) - implemented as `.exec([command], ...)`
- [x] Health check wait (Docker HEALTHCHECK status) - implemented as `.healthCheck(...)`
- [x] Composite/multiple waits (`.all([...])`, `.any([...])`) - implemented
- [x] Startup retries with backoff/jitter - implemented as `.withRetry()` / `.withRetry(RetryPolicy)`

**Runtime operations**
- [x] `exec()` in container (sync/async, exit code + stdout/stderr) - implemented with `ExecOptions` support
- [x] Copy files into container (`docker cp` to) - implemented with file, directory, string, and Data variants
- [x] Copy files from container (`docker cp` from) - implemented with file, directory, and Data variants
- [x] Inspect container (state, health, IPs, env, ports, labels) - implemented as `Container.inspect()`
- [x] Stream logs / follow logs - implemented as `Container.streamLogs(options:)` with `AsyncThrowingStream<LogEntry, Error>`

---

### Tier 2: Medium Priority

**Container configuration**
- [x] Volume mounts (named volumes) - implemented as `.withVolume(_:mountedAt:readOnly:)`
- [x] Bind mounts (host path → container path) - implemented as `.withBindMount(hostPath:containerPath:readOnly:consistency:)`
- [x] Entrypoint override (`--entrypoint`) - implemented as `.withEntrypoint([String])` / `.withEntrypoint(String)`
- [x] Tmpfs mounts - implemented as `.withTmpfs(_:sizeLimit:mode:)` / `.withTmpfsMount(_:)`
- [x] Working directory (`--workdir`) - implemented as `.withWorkingDirectory(_:)`
- [x] Extra hosts (`--add-host`) - implemented as `.withExtraHost(...)` / `.withExtraHosts(...)`
- [x] Resource limits (CPU/memory)
- [x] Privileged mode / capabilities
- [x] Platform/arch selection (`--platform`)
- [x] Extended container labels (`.withLabels(_:)`, `.withLabels(prefix:_:)`, `.withoutLabel(_:)`)

**Networking**
- [x] Create/remove networks (`docker network create/rm`) - implemented as `NetworkRequest` builder, `DockerClient.createNetwork()`/`removeNetwork()`
- [x] Attach container to network(s) on start - implemented as `.withNetwork(_:)`, `.withNetwork(_:aliases:)`, `.withNetwork(NetworkConnection(...))`, `.withNetworkMode(_:)` with multi-network support via `docker network connect`
- [x] Network aliases (container-to-container by name) - implemented via `NetworkConnection.aliases`, `.withNetwork(_:aliases:)`, verified with DNS resolution integration tests
- [x] Container-to-container communication helpers - implemented as `Container.internalIP()`, `.internalIP(forNetwork:)`, `.internalHostname()`, `.internalEndpoint(for:)`, `.internalHostnameEndpoint(for:)`
- [x] `withNetwork(_:_:)` scoped lifecycle - implemented with automatic cleanup on success, error, and cancellation

**Lifecycle & hooks**
- [x] Explicit `start()` / `stop()` API (in addition to scoped helper) - implemented as `createContainer()`, `Container.start()`, `.stop(timeout:)`, `.restart(timeout:)`, `.currentState`, `.isRunning`, `ContainerState` enum
- [x] Lifecycle hooks: PreStart, PostStart, PreStop, PostStop, PreTerminate, PostTerminate - implemented as `.onPreStart()`, `.onPostStart()`, etc.
- [x] Log consumers (stream logs to callback during execution) - implemented as `LogConsumer` protocol, `CollectingLogConsumer`, `PrintLogConsumer`, `CompositeLogConsumer`, `.withLogConsumer()` / `.withLogConsumers()`

---

### Tier 3: Advanced Features

**Image workflows**
- [x] Pull policy (always / if-missing / never) - implemented as `.withImagePullPolicy(.always/.ifNotPresent/.never)`
- [x] Auth to private registries - implemented as `RegistryAuth` enum with `.credentials()`, `.configFile()`, `.systemDefault` cases, `ContainerRequest.withRegistryAuth()` builder, `docker login --password-stdin` for secure credential passing
- [x] Build image from Dockerfile (and pass build args) - implemented as `ImageFromDockerfile` with builder pattern
- [x] Image preflight checks (inspect, existence) - implemented as `DockerClient.inspectImage(_:platform:)`, `imageExists(_:platform:)`, `ImageInspection` type with `ImageConfig` helpers
- [x] Image substitutors (registry mirrors, custom hubs) - implemented as `ImageSubstitutorConfig` with `.registryMirror()`, `.repositoryPrefix()`, `.replaceRegistry()` factories, `.then()` chaining, and `ContainerRequest.withImageSubstitutor()`

**Reliability & reuse**
- [x] Reuse containers between tests (opt-in + safety constraints) - implemented with `ContainerRequest.withReuse()`, `ReuseConfig` gate, hash labels, and running-container lookup
- [x] Global cleanup for leaked containers - implemented as `TestContainersCleanup` actor with label-based filtering, age thresholds, session tracking, dry-run mode, and parallel removal
- [x] Parallel test safety guidance (port collisions, unique naming) - implemented with auto-generated names, random-port helpers, test labels, and parallel-safety request config

**Developer experience**
- [x] Better diagnostics on failures (include last N log lines on timeout) - implemented as `DiagnosticsConfig` with `.default`/`.disabled`/`.verbose` presets, `TimeoutDiagnostics` with container state and log capture, `.withDiagnostics()` / `.withLogTailLines()` builder methods
- [x] Structured logging hooks - `TCLogger`, `LogHandler` protocol, `PrintLogHandler`, `OSLogHandler`, wired into `DockerClient`, `Container`, `Waiter`, `withContainer`, `withStack`, `withNetwork`
- [x] Per-test artifacts (logs on failure, container metadata) - implemented as `ArtifactConfig` with configurable triggers (`.onFailure`, `.always`, `.onTimeout`), retention policies, and automatic collection via `withContainer(..., testName:)`

**Compose / multi-container**
- [x] Define multi-container stacks (`ContainerStack`, `RunningStack`, `withStack`)
- [x] Dependency ordering + wait graph (topological startup with per-container wait strategy)
- [x] Shared networks/volumes - shared `VolumeConfig` in `ContainerStack`, auto-created and cleaned up via `withStack`

---

### Tier 4: Module System (Service-Specific Helpers)

Pre-configured containers with typed APIs, connection strings, and sensible defaults.

**Databases**
- [x] `PostgresContainer` - PostgreSQL with connection string helper, pg_isready wait
- [x] `MySQLContainer` / `MariaDBContainer`
- [x] `MongoDBContainer` - MongoDB with connection string helper, replica set support, auth
- [x] `RedisContainer` - Redis with connection string, password auth, log level, snapshotting

**Message queues**
- [x] `KafkaContainer`
- [x] `RabbitMQContainer` - RabbitMQ with AMQP/management URL helpers, credentials, virtual host, SSL support
- [x] `NATSContainer` - NATS with connection string helper, JetStream support, auth (user/pass and token), cluster config

**Cloud & storage**
- [x] `LocalStackContainer` (AWS services emulation) - LocalStack with service selection, region config, endpoint helpers, HTTP health check wait
- [x] `MinioContainer` (S3-compatible storage) - MinIO with S3/console endpoint helpers, credential management, bucket creation, HTTP health check wait

**Caching**
- [x] `MemcachedContainer` - Memcached with connection string helper, memory/connection/thread configuration

**Other services**
- [x] `ElasticsearchContainer` / `OpenSearchContainer`
- [x] `VaultContainer` - HashiCorp Vault for secrets management
- [x] `NginxContainer` - Nginx web server with static files and custom config support
- [x] `RedisContainer` - Redis with connection string, password auth, log level, snapshotting

---

## Implementation Notes

### Runtime Abstraction

All public APIs accept `runtime: any ContainerRuntime` (defaults to `DockerClient()`). Select a runtime via:

```swift
// Explicit parameter
try await withContainer(request, runtime: AppleContainerClient()) { ... }

// Environment variable: TESTCONTAINERS_RUNTIME=apple
let runtime = detectRuntime()
try await withContainer(request, runtime: runtime) { ... }
```

**Apple `container` CLI limitations** (throws `unsupportedByRuntime`):
- `connectToNetwork` after container creation (attach networks at run time instead)
- Directory copy from container is currently unsupported
- File copy uses CLI emulation and does not preserve ownership/permissions metadata

### CLI vs SDK

Features are categorized by implementation approach:

| Approach | Features |
|----------|----------|
| **Docker CLI** (current) | exec, copy, inspect, networks, volumes, mounts, most wait strategies |
| **Apple container CLI** (current) | Same feature set with CLI translation; some features emulated or unsupported |
| **Docker SDK** (future) | Log streaming, advanced networking, image builds, attach/detach |

The library uses CLI backends for simplicity and zero dependencies. SDK features may be added later for advanced use cases.

### Reference Implementation

Feature design is informed by [testcontainers-go](https://github.com/testcontainers/testcontainers-go), adapting patterns to idiomatic Swift:

| Go Pattern | Swift Equivalent |
|------------|------------------|
| `ContainerRequest` struct | `ContainerRequest` struct with builder methods |
| Functional options | Builder methods returning `Self` |
| Context + error returns | `async throws` |
| Interfaces | Protocols |
| `GenericContainer` | `Container` actor |

---

## Near-term Milestones

**MVP+ (Next)**
1. ~~HTTP wait strategy~~ ✓
2. ~~Exec in container~~ ✓
3. ~~Copy files to container~~ ✓ / ~~Copy files from container~~ ✓
4. ~~Container inspection~~ ✓

**Infrastructure**
5. ~~Bind mounts~~ ✓ + ~~volume mounts~~ ✓
6. Network creation + attachment + aliases
7. ~~Composite wait strategies~~ ✓

**Modules (First Set)**
8. ~~`PostgresContainer` with connection string helper~~ ✓
9. ~~`RedisContainer` with connection string helper~~ ✓

**Runtime Abstraction**
10. ~~`ContainerRuntime` protocol~~ ✓
11. ~~Apple `container` CLI support~~ ✓
12. ~~Runtime detection (`detectRuntime()`)~~ ✓

**Reliability**
13. Improved diagnostics (logs on timeout)
14. ~~Lifecycle hooks~~ ✓
15. Label-based cleanup sweeper
