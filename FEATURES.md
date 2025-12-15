# Features

This document tracks what `swift-test-containers` supports today, and what's planned next.

## Implemented

**Core API**
- [x] SwiftPM library target: `TestContainers`
- [x] Fluent `ContainerRequest` builder (`image`, `name`, `command`, env, labels, ports)
- [x] Scoped lifecycle: `withContainer(_:_:)` ensures cleanup on success, error, and cancellation
- [x] `Container` handle: `hostPort(_:)`, `endpoint(for:)`, `logs()`, `terminate()`

**Docker backend**
- [x] Docker CLI runner (shells out to `docker`)
- [x] Start container: `docker run -d ...`
- [x] Stop/remove container: `docker rm -f`
- [x] Port resolution: `docker port <id> <containerPort>`

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
- [ ] Copy files from container (`docker cp` from)
- [ ] Inspect container (state, health, IPs, env, ports, labels)
- [ ] Stream logs / follow logs (requires SDK or background process)

---

### Tier 2: Medium Priority

**Container configuration**
- [ ] Volume mounts (named volumes)
- [ ] Bind mounts (host path → container path)
- [ ] Tmpfs mounts
- [ ] Working directory (`--workdir`)
- [ ] User / groups (`--user`)
- [ ] Entrypoint override (`--entrypoint`)
- [ ] Extra hosts (`--add-host`)
- [ ] Resource limits (CPU/memory)
- [ ] Privileged mode / capabilities
- [ ] Platform/arch selection (`--platform`)
- [ ] Container labels beyond defaults

**Networking**
- [ ] Create/remove networks (`docker network create/rm`)
- [ ] Attach container to network(s) on start
- [ ] Network aliases (container-to-container by name)
- [ ] Container-to-container communication helpers
- [ ] `withNetwork(_:_:)` scoped lifecycle

**Lifecycle & hooks**
- [ ] Explicit `start()` / `stop()` API (in addition to scoped helper)
- [ ] Lifecycle hooks: PreStart, PostStart, PreStop, PostStop, PreTerminate, PostTerminate
- [ ] Log consumers (stream logs to callback during execution)

---

### Tier 3: Advanced Features

**Image workflows**
- [ ] Pull policy (always / if-missing / never)
- [ ] Auth to private registries
- [ ] Build image from Dockerfile (and pass build args)
- [ ] Image preflight checks (inspect, existence)
- [ ] Image substitutors (registry mirrors, custom hubs)

**Reliability & reuse**
- [ ] Reuse containers between tests (opt-in + safety constraints)
- [ ] Global cleanup for leaked containers (Ryuk/Reaper-style or label-based sweeper)
- [ ] Parallel test safety guidance (port collisions, unique naming)

**Developer experience**
- [ ] Better diagnostics on failures (include last N log lines on timeout)
- [ ] Structured logging hooks
- [ ] Per-test artifacts (logs on failure, container metadata)

**Compose / multi-container**
- [ ] Define multi-container stacks
- [ ] Dependency ordering + health/wait graph
- [ ] Shared networks/volumes

---

### Tier 4: Module System (Service-Specific Helpers)

Pre-configured containers with typed APIs, connection strings, and sensible defaults.

**Databases**
- [ ] `PostgresContainer` (connection string, init scripts, config)
- [ ] `MySQLContainer` / `MariaDBContainer`
- [ ] `MongoDBContainer`
- [ ] `RedisContainer` (connection string, TLS support)

**Message queues**
- [ ] `KafkaContainer`
- [ ] `RabbitMQContainer`
- [ ] `NATSContainer`

**Cloud & storage**
- [ ] `LocalStackContainer` (AWS services emulation)
- [ ] `MinioContainer` (S3-compatible storage)

**Other services**
- [ ] `ElasticsearchContainer` / `OpenSearchContainer`
- [ ] `VaultContainer`
- [ ] `NginxContainer`

---

## Implementation Notes

### CLI vs SDK

Features are categorized by implementation approach:

| Approach | Features |
|----------|----------|
| **Docker CLI** (current) | exec, copy, inspect, networks, volumes, mounts, most wait strategies |
| **Docker SDK** (future) | Log streaming, advanced networking, image builds, attach/detach |

The library will continue using Docker CLI for simplicity and zero dependencies. SDK features may be added later for advanced use cases.

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
3. ~~Copy files to container~~ ✓ / Copy files from container
4. Container inspection

**Infrastructure**
5. Bind mounts + volume mounts
6. Network creation + attachment + aliases
7. ~~Composite wait strategies~~ ✓

**Modules (First Set)**
8. `PostgresContainer` with connection string helper
9. `RedisContainer` with connection string helper

**Reliability**
10. Improved diagnostics (logs on timeout)
11. Lifecycle hooks
12. Label-based cleanup sweeper
