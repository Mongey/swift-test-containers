# 058: Apple Container Runtime Support

## Summary

Adds Apple's open-source `container` CLI as a first-class alternative to Docker, abstracted behind a `ContainerRuntime` protocol.

## Motivation

Apple released an open-source `container` CLI ([github.com/apple/container](https://github.com/apple/container)) that runs Linux containers as lightweight VMs on Apple Silicon Macs (macOS 26+). Supporting it as an alternative runtime allows developers to run container-based tests without Docker Desktop.

## Design

### ContainerRuntime Protocol

A new `ContainerRuntime` protocol (`ContainerRuntime.swift`) extracts ~25 methods from `DockerClient`'s public surface:

- Availability, registry auth
- Image operations (exists, pull, inspect, build, remove)
- Container lifecycle (run, create, start, stop, remove)
- Container info (logs, port, inspect, health, exec)
- File copy (to/from container)
- Networks (create, remove, connect, exists)
- Volumes (create, remove)
- Listing (list, find reusable)

Both `DockerClient` and `AppleContainerClient` conform to this protocol.

### Runtime Selection

```swift
// Explicit
let runtime = AppleContainerClient()
try await withContainer(request, runtime: runtime) { ... }

// Via detectRuntime()
let runtime = detectRuntime(preferred: .appleContainer)

// Via environment variable
// TESTCONTAINERS_RUNTIME=apple swift test
let runtime = detectRuntime()
```

Priority: explicit parameter > `TESTCONTAINERS_RUNTIME` env var > `DockerClient()` default.

### CLI Command Translation

| Operation | Docker | Apple Container |
|---|---|---|
| Run | `docker run -d` | `container run -d` |
| Stop | `docker stop --time N` | `container stop --time N` |
| Remove | `docker rm -f` | `container delete --force` |
| Logs | `docker logs --tail N` | `container logs -n N` |
| Pull | `docker pull` | `container image pull` |
| Build | `docker build` | `container build` |
| Remove image | `docker rmi` | `container image delete` |
| Network create | `docker network create` | `container network create` |
| Network remove | `docker network rm` | `container network delete` |
| Volume create | `docker volume create` | `container volume create` |
| Volume remove | `docker volume rm` | `container volume delete` |

### JSON Format Differences

Apple's `container inspect` returns a completely different JSON structure from Docker's `docker inspect`. The `AppleContainerClient` includes its own JSON parser (`AppleInspectItem`) that maps the Apple format into the shared `ContainerInspection` type.

Key differences:
- Apple uses `configuration.id` vs Docker's `Id`
- Apple uses `configuration.initProcess` vs Docker's `Config`
- Apple uses `configuration.publishedPorts` array vs Docker's `NetworkSettings.Ports` dict
- Apple uses `startedDate` (TimeIntervalSinceReferenceDate) vs Docker's `Created` (ISO8601 string)
- Apple uses `configuration.labels` (dict) vs Docker's labels in `Config.Labels`

### Unsupported Operations

`connectToNetwork` after container creation throws `TestContainersError.unsupportedByRuntime`. Networks must be attached at container creation time.

File copy (`copyToContainer`, `copyFromContainer`) uses `exec tar` emulation since the Apple CLI has no `cp` command.

## Files

### New
- `Sources/TestContainers/ContainerRuntime.swift` - Protocol definition
- `Sources/TestContainers/AppleContainerClient.swift` - Apple runtime implementation + JSON parsing
- `Sources/TestContainers/RuntimeDetection.swift` - `detectRuntime()` helper
- `Tests/TestContainersTests/AppleContainerArgumentTests.swift` - Unit tests for arg building
- `Tests/TestContainersTests/AppleContainerIntegrationTests.swift` - Integration tests (gated)

### Modified
- All files accepting `docker: DockerClient` renamed to `runtime: any ContainerRuntime`
- `ContainerInspection.swift` - Added internal memberwise initializers
- `TestContainersError.swift` - Added `unsupportedByRuntime` case

## Testing

```bash
# Unit tests (no CLI required)
swift test --filter appleContainer_build

# Integration tests (requires container CLI + container system start)
TESTCONTAINERS_RUN_APPLE_CONTAINER_TESTS=1 swift test --filter appleContainer_

# All tests still pass
swift test
```

## Status

Implemented and tested. All 1436 tests pass.
