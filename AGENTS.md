# Repository Guidelines

## Project Structure & Module Organization
`swift-test-containers` is a SwiftPM library. Keep production code in `Sources/TestContainers/` and tests in `Tests/TestContainersTests/`.

- `Sources/TestContainers/`: core API (`ContainerRequest`, `Container`, `ContainerRuntime` protocol, `DockerClient`, `AppleContainerClient`, wait/probe helpers, service-specific containers).
- `Tests/TestContainersTests/`: unit tests and Docker-backed integration tests.
- `features/`: detailed feature specs and implementation notes.
- `FEATURES.md`: high-level feature status.
- `Package.swift`: package manifest and dependencies.

## Build, Test, and Development Commands
- `swift build`: compile the package.
- `swift test`: run default test suite (unit-first, no Docker opt-in).
- `TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test`: run Docker integration tests.
- `TESTCONTAINERS_RUN_APPLE_CONTAINER_TESTS=1 swift test`: run Apple container integration tests.
- `swift test --filter ContainerRequestTests`: run a specific test file/suite.
- `swift test --filter waitStrategy_exec_defaultValues`: run one test case.

Docker CLI or Apple's `container` CLI must be installed and available on `PATH` for runtime and integration tests.

## Coding Style & Naming Conventions
Use idiomatic Swift with 4-space indentation.

- Types/protocols: `UpperCamelCase`; methods/properties: `lowerCamelCase`.
- Prefer `async throws`, `Sendable`, and `actor` for concurrency safety.
- Keep fluent builder APIs in `ContainerRequest` style (`withX(...) -> Self`).
- Add doc comments for public API surface and use `// MARK:` to organize larger files.

## Testing Guidelines
This repo uses `swift-testing` (`import Testing`, `@Test`, `#expect`).

- Keep unit tests deterministic and Docker-independent by default.
- Gate Docker scenarios with `TESTCONTAINERS_RUN_DOCKER_TESTS=1`.
- Gate Apple container scenarios with `TESTCONTAINERS_RUN_APPLE_CONTAINER_TESTS=1`.
- Name tests by behavior, e.g. `waitStrategy_logMatches_defaultValues`.
- Place Docker-heavy scenarios in `*IntegrationTests.swift` files.
- No strict coverage threshold is enforced; new behavior should ship with tests (unit + integration when Docker behavior changes).

## Commit & Pull Request Guidelines
Follow the existing commit style: short, imperative subjects such as `Add ...`, `Update ...`, `Document ...`.

- Keep commits focused and include related test/doc updates.
- In PRs, include purpose, API/behavior changes, and test evidence (`swift test`, plus Docker-enabled run when relevant).
- Link related issue/spec files (for example, `features/056-nginx-container.md`) and update `README.md`/`FEATURES.md` for user-facing changes.
