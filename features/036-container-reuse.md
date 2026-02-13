# Feature 036: Reusable Containers

**Status:** Implemented (v1)  
**Priority:** High (Reliability)  
**Depends on:** none (v1 integrates into existing `withContainer`)  
**Reference studied:** `testcontainers-java` reusable containers

## Summary

Add opt-in reusable containers so repeated local test runs can reuse already-running containers instead of recreating them every time.

The design should follow `testcontainers-java` semantics closely:
- per-container opt-in (`withReuse(true)` equivalent),
- global safety gate (`TESTCONTAINERS_REUSE_ENABLE` / user property),
- hash-based container identity via labels,
- reuse only running containers,
- keep reusable containers alive after test completion.

## Upstream behavior (testcontainers-java)

From docs and source:

1. Reuse is experimental and not recommended for CI.
2. Reuse requires both a container-level flag and environment-level enablement.
3. A deterministic hash of container create config is stored in label `org.testcontainers.hash`.
4. Reuse discovery lists running containers with matching hash label.
5. Reused containers still pass startup/wait checks.
6. If startup fails, container is stopped/removed.
7. Reusable containers bypass normal automatic cleanup registration.

## Current gap in this repo

`withContainer` always terminates containers on success/failure/cancellation. There is no reuse flag or reuse lookup path today.

## Goals

- Keep default behavior unchanged (ephemeral by default).
- Add deterministic, label-based reuse matching.
- Make reuse explicit and safe by default.
- Keep implementation compatible with existing wait strategies and Docker-gated tests.

## Non-goals (v1)

- Automatic TTL eviction for reusable containers.
- Cross-process locking for reuse races.
- Reuse support for `imageFromDockerfile` requests.

## Proposed API

### `ContainerRequest`

Add:

```swift
public var reuse: Bool
public func withReuse(_ enabled: Bool = true) -> Self
```

Default: `reuse = false`.

### Global gate

Add `ReuseConfig` helper:

- env var: `TESTCONTAINERS_REUSE_ENABLE=true|1`
- optional user file: `~/.testcontainers.properties` key `testcontainers.reuse.enable=true`

If request has `reuse = true` but gate is disabled, run normal ephemeral flow.

## Reuse labels and fingerprint

Add labels on reusable containers:

- `testcontainers.swift.reuse=true`
- `testcontainers.swift.reuse.hash=<fingerprint>`
- `testcontainers.swift.reuse.version=1`

Fingerprint source:
- canonical JSON of a `ReuseFingerprintV1` struct + hash (SHA1 for parity with java; SHA256 acceptable if documented).

Fingerprint includes:
- `image`, `command`, `entrypoint`
- `environment` (sorted)
- `ports` (include fixed host port when present)
- `volumes`, `bindMounts`, `tmpfsMounts`
- `workingDirectory`, `privileged`, capability sets
- `waitStrategy`, `healthCheck`, `host`
- stable labels (exclude session/reuse labels)

Fingerprint excludes:
- `name`
- lifecycle hooks
- artifact config
- retry policy

## Lifecycle behavior in Swift

For `reuse=true` + global gate enabled:

1. Compute fingerprint.
2. Query running containers by reuse hash label.
3. If match found:
   - create `Container` handle,
   - run readiness checks (`waitUntilReady()`).
4. If reused container fails readiness/startup checks:
   - remove it,
   - create fresh reusable container.
5. If no match:
   - create fresh reusable container with reuse labels.
6. After operation:
   - do **not** terminate reusable containers.
   - skip terminate hooks when intentionally preserving container.

For all non-reuse paths: existing behavior remains unchanged.

## Docker client additions

Add:

- `findReusableContainer(hash:)` -> `ContainerListItem?`
- (optional) `listReusableContainers()`

Implementation:
- reuse `listContainers(labels:)`
- require `state == "running"`
- if multiple matches, choose newest by `created`

## Test plan

### Unit

- `ReuseConfig` parsing (default false, env true/1 true, invalid false).
- fingerprint determinism and diff behavior.
- volatile label exclusion logic.

### Docker integration (`TESTCONTAINERS_RUN_DOCKER_TESTS=1`)

1. `reuse_disabled_createsFreshContainerEachRun`
2. `reuse_enabled_reusesContainerIdForSameRequest`
3. `reuse_enabled_differentConfigDoesNotReuse`
4. `reuse_ignoresStoppedContainers`
5. `reuse_badReusedContainerIsRemovedAndRecreated`
6. `reuse_path_doesNotTerminateOnSuccess`

## Rollout checklist

1. Add request/config primitives (`reuse` + gate reader).
2. Add fingerprint utility + tests.
3. Add Docker lookup helpers + tests.
4. Integrate reuse flow into `withContainer`.
5. Add integration tests.
6. Update `README.md` with caveats and cleanup command.

## Manual cleanup

```bash
docker rm -f $(docker ps -aq --filter label=testcontainers.swift.reuse=true)
```

## References

- Docs: https://java.testcontainers.org/features/reuse/
- Reuse implementation: https://github.com/testcontainers/testcontainers-java/blob/main/core/src/main/java/org/testcontainers/containers/GenericContainer.java
- Reuse config gate: https://github.com/testcontainers/testcontainers-java/blob/main/core/src/main/java/org/testcontainers/utility/TestcontainersConfiguration.java
- Reuse tests: https://github.com/testcontainers/testcontainers-java/blob/main/core/src/test/java/org/testcontainers/containers/ReusabilityUnitTests.java
- Config tests: https://github.com/testcontainers/testcontainers-java/blob/main/core/src/test/java/org/testcontainers/utility/TestcontainersConfigurationTest.java
