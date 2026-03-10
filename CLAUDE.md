# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

swift-test-containers is a Swift package for running containers in tests, designed to work with `swift-testing` (`import Testing`). It supports two container runtimes via the `ContainerRuntime` protocol:

- **DockerClient** (default) — shells out to `docker` CLI via [swift-subprocess](https://github.com/swiftlang/swift-subprocess)
- **AppleContainerClient** — shells out to Apple's `container` CLI (macOS 26+, Apple Silicon)

Runtime selection: explicit parameter, `TESTCONTAINERS_RUNTIME=apple` env var, or `detectRuntime()`.

## Build & Test Commands

```bash
# Build
swift build

# Run all tests (unit tests only, no Docker/container CLI required)
swift test

# Run tests with Docker integration tests enabled
TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test

# Run tests with Apple container integration tests enabled
TESTCONTAINERS_RUN_APPLE_CONTAINER_TESTS=1 swift test

# Run a specific test
swift test --filter <TestName>

# Run tests in a specific file
swift test --filter <TestFileName>
```

## Architecture

### Core Flow

1. **ContainerRequest** (`ContainerRequest.swift`) - Builder pattern struct for configuring containers (image, ports, env, labels, wait strategy)
2. **withContainer()** (`WithContainer.swift`) - Scoped lifecycle helper that creates, waits for readiness, runs operation, and cleans up
3. **Container** (`Container.swift`) - Actor providing runtime access (hostPort, endpoint, logs, terminate)
4. **ContainerRuntime** (`ContainerRuntime.swift`) - Protocol abstracting container backends (~25 methods)
5. **DockerClient** (`DockerClient.swift`) - `ContainerRuntime` implementation using `docker` CLI
6. **AppleContainerClient** (`AppleContainerClient.swift`) - `ContainerRuntime` implementation using Apple's `container` CLI
7. **RuntimeDetection** (`RuntimeDetection.swift`) - `detectRuntime()` selects runtime from explicit parameter, env var, or default
8. **ProcessRunner** (`ProcessRunner.swift`) - Thin wrapper around swift-subprocess for executing shell commands

### Wait Strategy Pattern

Wait strategies are defined as an enum in `ContainerRequest.swift`:
- `.none` - No waiting
- `.tcpPort(port, timeout, pollInterval)` - Poll TCP connection
- `.logContains(string, timeout, pollInterval)` - Poll container logs for substring
- `.logMatches(pattern, timeout, pollInterval)` - Poll container logs for regex match
- `.http(HTTPWaitConfig)` - Poll HTTP endpoint
- `.exec(command, timeout, pollInterval)` - Poll by executing command inside container (exit code 0 = ready)

Wait logic is executed in `Container.waitUntilReady()` using `Waiter.wait()` which polls until condition is met or timeout.

### Adding New Wait Strategies

1. Add enum case to `WaitStrategy` in `ContainerRequest.swift`
2. Create supporting types if needed (e.g., `HTTPWaitConfig.swift`)
3. Create probe module if needed (e.g., `HTTPProbe.swift`, following `TCPProbe.swift` pattern)
4. Add case handler in `Container.waitUntilReady()`

### Key Patterns

- **Builder pattern**: All configuration uses `func withX() -> Self` methods returning copies
- **Sendable types**: `Container` is an actor; `DockerClient`, `AppleContainerClient`, and `ProcessRunner` are Sendable structs
- **Runtime abstraction**: All public APIs accept `runtime: any ContainerRuntime` defaulting to `DockerClient()`
- **Scoped resources**: `withContainer()` ensures cleanup on success, error, and cancellation

## Test Organization

- Unit tests: Always run, test configuration and logic without Docker or container CLI
- Docker integration tests: Gated by `TESTCONTAINERS_RUN_DOCKER_TESTS=1` environment variable
- Apple container integration tests: Gated by `TESTCONTAINERS_RUN_APPLE_CONTAINER_TESTS=1` environment variable
- Network-dependent tests: Use `@Test(.disabled(...))` trait to skip by default

## Feature Tracking

- `FEATURES.md` - Tracks implemented features and roadmap
- `features/` directory - Detailed specifications for planned features
