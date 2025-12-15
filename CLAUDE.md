# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

swift-test-containers is a Swift package for running Docker containers in tests, designed to work with `swift-testing` (`import Testing`). It uses [swift-subprocess](https://github.com/swiftlang/swift-subprocess) to execute `docker` CLI commands (Docker must be installed and on PATH).

## Build & Test Commands

```bash
# Build
swift build

# Run all tests (unit tests only, no Docker required)
swift test

# Run tests with Docker integration tests enabled
TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test

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
4. **DockerClient** (`DockerClient.swift`) - Sendable struct that executes `docker` CLI commands via swift-subprocess
5. **ProcessRunner** (`ProcessRunner.swift`) - Thin wrapper around swift-subprocess for executing shell commands

### Wait Strategy Pattern

Wait strategies are defined as an enum in `ContainerRequest.swift`:
- `.none` - No waiting
- `.tcpPort(port, timeout, pollInterval)` - Poll TCP connection
- `.logContains(string, timeout, pollInterval)` - Poll container logs for substring
- `.logMatches(pattern, timeout, pollInterval)` - Poll container logs for regex match
- `.http(HTTPWaitConfig)` - Poll HTTP endpoint

Wait logic is executed in `Container.waitUntilReady()` using `Waiter.wait()` which polls until condition is met or timeout.

### Adding New Wait Strategies

1. Add enum case to `WaitStrategy` in `ContainerRequest.swift`
2. Create supporting types if needed (e.g., `HTTPWaitConfig.swift`)
3. Create probe module if needed (e.g., `HTTPProbe.swift`, following `TCPProbe.swift` pattern)
4. Add case handler in `Container.waitUntilReady()`

### Key Patterns

- **Builder pattern**: All configuration uses `func withX() -> Self` methods returning copies
- **Sendable types**: `Container` is an actor; `DockerClient` and `ProcessRunner` are Sendable structs
- **Scoped resources**: `withContainer()` ensures cleanup on success, error, and cancellation

## Test Organization

- Unit tests: Always run, test configuration and logic without Docker
- Docker integration tests: Gated by `TESTCONTAINERS_RUN_DOCKER_TESTS=1` environment variable
- Network-dependent tests: Use `@Test(.disabled(...))` trait to skip by default

## Feature Tracking

- `FEATURES.md` - Tracks implemented features and roadmap
- `features/` directory - Detailed specifications for planned features
