# Feature: Private Registry Authentication

## Summary

Implement authentication support for private Docker registries in swift-test-containers, enabling users to pull images from private registries (Docker Hub private repos, GitHub Container Registry, AWS ECR, Google Artifact Registry, Azure Container Registry, etc.) by providing registry credentials.

## Current State

### Image Pulling Behavior

Currently, swift-test-containers relies on Docker CLI's implicit image pulling behavior. Images are pulled automatically when `docker run` is executed if they don't exist locally:

```swift
// DockerClient.runContainer(_:) at /Sources/TestContainers/DockerClient.swift:28-54
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    if let name = request.name {
        args += ["--name", name]
    }

    for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
        args += ["-e", "\(key)=\(value)"]
    }

    for mapping in request.ports {
        args += ["-p", mapping.dockerFlag]
    }

    for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
        args += ["--label", "\(key)=\(value)"]
    }

    args.append(request.image)
    args += request.command

    let output = try await runDocker(args)
    let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { throw TestContainersError.unexpectedDockerOutput(output.stdout) }
    return id
}
```

**Limitations:**
- No explicit authentication mechanism
- Cannot pull from private registries requiring credentials
- Relies on pre-authenticated Docker daemon (via prior `docker login`)
- No per-test or per-container credential isolation
- No programmatic credential management

### Docker CLI Architecture

The library uses Docker CLI exclusively via `ProcessRunner` at `/Sources/TestContainers/ProcessRunner.swift:9-42`:

```swift
actor ProcessRunner {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if !environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            process.environment = env
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: CommandOutput(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus))
            }
        }
    }
}
```

**Key observations:**
- Supports custom environment variables (can be used for Docker config paths)
- All Docker commands flow through `DockerClient.runDocker(_:)` at line 20
- Error handling via `TestContainersError.commandFailed` includes stdout/stderr

### Existing Request Configuration Pattern

`ContainerRequest` at `/Sources/TestContainers/ContainerRequest.swift` follows a builder pattern:

```swift
public struct ContainerRequest: Sendable, Hashable {
    public var image: String
    public var name: String?
    public var command: [String]
    public var environment: [String: String]
    public var labels: [String: String]
    public var ports: [ContainerPort]
    public var waitStrategy: WaitStrategy
    public var host: String

    public func withName(_ name: String) -> Self { ... }
    public func withCommand(_ command: [String]) -> Self { ... }
    public func withEnvironment(_ environment: [String: String]) -> Self { ... }
    public func withLabel(_ key: String, _ value: String) -> Self { ... }
    public func withExposedPort(_ containerPort: Int, hostPort: Int? = nil) -> Self { ... }
    public func waitingFor(_ strategy: WaitStrategy) -> Self { ... }
    public func withHost(_ host: String) -> Self { ... }
}
```

**Pattern to follow:**
- Immutable struct with copy-on-write builder methods
- Methods return `Self` for chaining
- Properties stored on the struct, used later during container lifecycle
- Conforms to `Sendable` and `Hashable` for concurrency safety

## Requirements

### Core Functionality

1. **Username/Password Authentication**
   - Registry URL
   - Username
   - Password (or token)
   - Support for Docker Hub, GHCR, ECR, GCR, ACR, etc.

2. **Docker Config.json Support**
   - Read existing `~/.docker/config.json` credentials
   - Support custom config.json path
   - Respect existing authentication without requiring re-login

3. **Registry-Specific Credentials**
   - Different credentials for different registries
   - Default credentials for unspecified registries
   - Registry URL matching (exact match, domain match)

4. **Credential Lifecycle**
   - Scoped authentication (login before pull, logout after cleanup)
   - Persistent authentication (leave credentials in daemon)
   - No authentication pollution between tests

### API Design Principles

1. **Security by Default**
   - No credential logging or printing
   - Secure credential storage in memory
   - Clear credential lifecycle

2. **Ergonomics**
   - Simple API for common cases
   - Flexible API for advanced scenarios
   - Composable with existing builder pattern

3. **Compatibility**
   - Works with existing Docker daemon authentication
   - Doesn't interfere with user's Docker CLI sessions
   - Cross-platform (macOS, Linux)

## API Design

### Option 1: Inline Credentials (Simple)

```swift
// Add to ContainerRequest
public struct RegistryCredentials: Sendable, Hashable {
    public var registry: String
    public var username: String
    public var password: String

    public init(registry: String = "https://index.docker.io/v1/", username: String, password: String) {
        self.registry = registry
        self.username = username
        self.password = password
    }
}

// Add to ContainerRequest
public var registryAuth: RegistryCredentials?

public func withRegistryAuth(_ credentials: RegistryCredentials) -> Self {
    var copy = self
    copy.registryAuth = credentials
    return copy
}

// Usage
let request = ContainerRequest(image: "ghcr.io/myorg/private-image:latest")
    .withRegistryAuth(RegistryCredentials(
        registry: "ghcr.io",
        username: "myuser",
        password: ProcessInfo.processInfo.environment["GITHUB_TOKEN"]!
    ))
    .withExposedPort(8080)
```

### Option 2: Docker Config Path (Advanced)

```swift
// Add to ContainerRequest
public var dockerConfigPath: String?

public func withDockerConfig(_ path: String) -> Self {
    var copy = self
    copy.dockerConfigPath = path
    return copy
}

// Usage
let request = ContainerRequest(image: "ghcr.io/myorg/private-image:latest")
    .withDockerConfig("/path/to/custom/docker/config.json")
```

### Option 3: Hybrid Approach (Recommended)

```swift
// Add to ContainerRequest.swift
public enum RegistryAuth: Sendable, Hashable {
    case credentials(registry: String, username: String, password: String)
    case configFile(path: String)
    case systemDefault // Use ~/.docker/config.json
}

public var registryAuth: RegistryAuth?

public func withRegistryAuth(_ auth: RegistryAuth) -> Self {
    var copy = self
    copy.registryAuth = auth
    return copy
}

// Usage examples

// 1. Direct credentials
let request1 = ContainerRequest(image: "ghcr.io/myorg/app:v1")
    .withRegistryAuth(.credentials(
        registry: "ghcr.io",
        username: "myuser",
        password: ProcessInfo.processInfo.environment["GITHUB_TOKEN"]!
    ))

// 2. Custom config file
let request2 = ContainerRequest(image: "private.registry.io/app:v1")
    .withRegistryAuth(.configFile(path: "/tmp/test-docker-config.json"))

// 3. System default (explicit)
let request3 = ContainerRequest(image: "myuser/private:latest")
    .withRegistryAuth(.systemDefault)
```

## Implementation Steps

### 1. Update ContainerRequest Model

**File:** `/Sources/TestContainers/ContainerRequest.swift`

```swift
// Add after line 24 (after WaitStrategy enum)
public enum RegistryAuth: Sendable, Hashable {
    case credentials(registry: String, username: String, password: String)
    case configFile(path: String)
    case systemDefault
}

// Add to ContainerRequest struct (after line 34)
public var registryAuth: RegistryAuth?

// Add builder method (after withHost method, line 87)
public func withRegistryAuth(_ auth: RegistryAuth) -> Self {
    var copy = self
    copy.registryAuth = auth
    return copy
}
```

### 2. Implement Authentication Logic in DockerClient

**File:** `/Sources/TestContainers/DockerClient.swift`

Add new methods:

```swift
// After isAvailable() method
func authenticateRegistry(_ auth: RegistryAuth) async throws {
    switch auth {
    case let .credentials(registry, username, password):
        // Execute: docker login <registry> -u <username> --password-stdin
        // Pass password via stdin to avoid shell exposure
        try await loginWithCredentials(registry: registry, username: username, password: password)

    case let .configFile(path):
        // Set DOCKER_CONFIG environment variable to directory containing config.json
        // This affects subsequent docker commands
        // Store path for use in runDocker calls
        setDockerConfigPath(path)

    case .systemDefault:
        // No action needed - Docker CLI will use ~/.docker/config.json automatically
        break
    }
}

private func loginWithCredentials(registry: String, username: String, password: String) async throws {
    // Create stdin pipe for password
    let stdinPipe = Pipe()

    // Write password to stdin pipe
    let passwordData = password.data(using: .utf8)!
    try stdinPipe.fileHandleForWriting.write(contentsOf: passwordData)
    try stdinPipe.fileHandleForWriting.close()

    // Execute docker login with password from stdin
    let args = ["login", registry, "-u", username, "--password-stdin"]

    // Need to modify ProcessRunner to support stdin
    let output = try await runner.run(
        executable: dockerPath,
        arguments: args,
        stdin: stdinPipe
    )

    if output.exitCode != 0 {
        throw TestContainersError.commandFailed(
            command: ["docker", "login", registry, "-u", username, "--password-stdin"],
            exitCode: output.exitCode,
            stdout: output.stdout,
            stderr: output.stderr
        )
    }
}

func logoutRegistry(_ registry: String) async throws {
    // Execute: docker logout <registry>
    _ = try await runDocker(["logout", registry])
}
```

Update `runContainer` method to handle authentication:

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    // Authenticate if credentials provided
    if let auth = request.registryAuth {
        try await authenticateRegistry(auth)
    }

    // Existing runContainer logic...
    var args: [String] = ["run", "-d"]
    // ... rest of implementation
}
```

### 3. Update ProcessRunner to Support Stdin

**File:** `/Sources/TestContainers/ProcessRunner.swift`

```swift
actor ProcessRunner {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        stdin: Pipe? = nil  // Add stdin parameter
    ) async throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if !environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            process.environment = env
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Set stdin if provided
        if let stdin = stdin {
            process.standardInput = stdin
        }

        try process.run()

        // ... rest of implementation
    }
}
```

### 4. Handle Docker Config Path via Environment Variable

For `.configFile(path)` case, use `DOCKER_CONFIG` environment variable:

```swift
func runDocker(_ args: [String]) async throws -> CommandOutput {
    var environment: [String: String] = [:]

    // If custom docker config path is set, use it
    if let configPath = self.dockerConfigPath {
        // DOCKER_CONFIG should point to directory containing config.json
        environment["DOCKER_CONFIG"] = configPath
    }

    let output = try await runner.run(
        executable: dockerPath,
        arguments: args,
        environment: environment
    )

    if output.exitCode != 0 {
        throw TestContainersError.commandFailed(
            command: [dockerPath] + args,
            exitCode: output.exitCode,
            stdout: output.stdout,
            stderr: output.stderr
        )
    }
    return output
}
```

### 5. Add Cleanup/Logout Support (Optional)

Add logout support in `Container.terminate()`:

```swift
// In Container.swift
public func terminate() async throws {
    try await docker.removeContainer(id: id)

    // Logout if credentials were used
    if case let .credentials(registry, _, _) = request.registryAuth {
        try? await docker.logoutRegistry(registry)
    }
}
```

### 6. Update Error Handling

**File:** `/Sources/TestContainers/TestContainersError.swift`

Add new error case:

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    case dockerNotAvailable(String)
    case commandFailed(command: [String], exitCode: Int32, stdout: String, stderr: String)
    case unexpectedDockerOutput(String)
    case timeout(String)
    case authenticationFailed(String)  // New error case

    public var description: String {
        switch self {
        // ... existing cases
        case let .authenticationFailed(message):
            return "Registry authentication failed: \(message)"
        }
    }
}
```

## Security Considerations

### 1. Credential Storage

**Risk:** Credentials stored in memory could leak via debugging, logging, or crash dumps.

**Mitigations:**
- Don't log credentials in any error messages
- Redact passwords in `TestContainersError.commandFailed` output
- Use `--password-stdin` instead of command-line arguments
- Clear password strings from memory after use (if possible in Swift)

```swift
// Example: Redact password in error messages
case let .commandFailed(command, exitCode, stdout, stderr):
    let sanitizedCommand = command.map { arg in
        // If this looks like a password, redact it
        if arg.contains("password") || arg.count > 20 {
            return "[REDACTED]"
        }
        return arg
    }
    return "Command failed (exit \(exitCode)): \(sanitizedCommand.joined(separator: " "))\n..."
```

### 2. Credential Leakage in Logs

**Risk:** Docker CLI output might echo credentials.

**Mitigations:**
- Use `--password-stdin` for login
- Never pass credentials as command-line arguments
- Sanitize stdout/stderr in error messages
- Document that users should use environment variables for credentials

### 3. Credential Persistence

**Risk:** `docker login` persists credentials in `~/.docker/config.json`, potentially affecting user's Docker environment.

**Mitigations:**
- Document logout behavior (automatic vs. manual)
- Provide option to skip logout (`.persistAuth` flag?)
- Consider using temporary config directories per test
- Warn in documentation about credential persistence

```swift
public enum RegistryAuth: Sendable, Hashable {
    case credentials(registry: String, username: String, password: String, persistAuth: Bool = false)
    case configFile(path: String)
    case systemDefault
}
```

### 4. Concurrent Test Isolation

**Risk:** Multiple tests authenticating simultaneously could conflict.

**Mitigations:**
- Use `DockerClient` as an actor (already done)
- Document that authentication is shared across concurrent tests
- Consider per-test temporary config directories for isolation

### 5. Token Exposure in Process Lists

**Risk:** Credentials visible in `ps aux` output.

**Mitigations:**
- Always use `--password-stdin` instead of `-p <password>`
- Never pass credentials as CLI arguments
- Use environment variables or stdin exclusively

### 6. Config File Path Validation

**Risk:** Path traversal or reading sensitive files.

**Mitigations:**
- Validate that config file exists and is readable
- Document expected format (Docker config.json)
- Consider sandboxing in future

## Testing Plan

### Unit Tests

**File:** `/Tests/TestContainersTests/ContainerRequestTests.swift`

```swift
@Test func registryAuth_credentials() {
    let request = ContainerRequest(image: "private/image:v1")
        .withRegistryAuth(.credentials(
            registry: "ghcr.io",
            username: "testuser",
            password: "testpass"
        ))

    #expect(request.registryAuth != nil)
    if case let .credentials(registry, username, password) = request.registryAuth {
        #expect(registry == "ghcr.io")
        #expect(username == "testuser")
        #expect(password == "testpass")
    } else {
        Issue.record("Expected credentials auth")
    }
}

@Test func registryAuth_configFile() {
    let request = ContainerRequest(image: "private/image:v1")
        .withRegistryAuth(.configFile(path: "/tmp/config.json"))

    #expect(request.registryAuth != nil)
    if case let .configFile(path) = request.registryAuth {
        #expect(path == "/tmp/config.json")
    } else {
        Issue.record("Expected config file auth")
    }
}

@Test func registryAuth_systemDefault() {
    let request = ContainerRequest(image: "private/image:v1")
        .withRegistryAuth(.systemDefault)

    #expect(request.registryAuth != nil)
    if case .systemDefault = request.registryAuth {
        // Success
    } else {
        Issue.record("Expected system default auth")
    }
}

@Test func registryAuth_sendsbleAndHashable() {
    let auth1: RegistryAuth = .credentials(registry: "r1", username: "u1", password: "p1")
    let auth2: RegistryAuth = .credentials(registry: "r1", username: "u1", password: "p1")
    let auth3: RegistryAuth = .credentials(registry: "r2", username: "u2", password: "p2")

    #expect(auth1 == auth2)
    #expect(auth1 != auth3)
}
```

### Integration Tests

**File:** `/Tests/TestContainersTests/RegistryAuthIntegrationTests.swift`

```swift
import Foundation
import Testing
import TestContainers

// These tests require a private registry or Docker Hub credentials
@Test func canPullFromPrivateRegistry_withCredentials() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    let username = ProcessInfo.processInfo.environment["DOCKER_USERNAME"]
    let password = ProcessInfo.processInfo.environment["DOCKER_PASSWORD"]

    guard optedIn, let username, let password else { return }

    let request = ContainerRequest(image: "myusername/private-redis:latest")
        .withRegistryAuth(.credentials(
            registry: "https://index.docker.io/v1/",
            username: username,
            password: password
        ))
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }
}

@Test func canPullFromGHCR_withToken() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]

    guard optedIn, let token else { return }

    let request = ContainerRequest(image: "ghcr.io/myorg/private-app:latest")
        .withRegistryAuth(.credentials(
            registry: "ghcr.io",
            username: "oauth",
            password: token
        ))
        .withExposedPort(8080)
        .waitingFor(.tcpPort(8080, timeout: .seconds(30)))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 8080)
        #expect(endpoint.contains(":"))
    }
}

@Test func canUseSystemDefaultAuth() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Assumes user has already run `docker login`
    let request = ContainerRequest(image: "myusername/private-nginx:latest")
        .withRegistryAuth(.systemDefault)
        .withExposedPort(80)
        .waitingFor(.tcpPort(80, timeout: .seconds(30)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(80)
        #expect(port > 0)
    }
}

@Test func authFailure_throwsError() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "ghcr.io/nonexistent/private:latest")
        .withRegistryAuth(.credentials(
            registry: "ghcr.io",
            username: "invalid",
            password: "wrongpassword"
        ))

    await #expect(throws: TestContainersError.self) {
        try await withContainer(request) { _ in }
    }
}
```

### Manual Testing

1. **Docker Hub Private Repository**
   ```bash
   export DOCKER_USERNAME="myusername"
   export DOCKER_PASSWORD="mypassword"
   export TESTCONTAINERS_RUN_DOCKER_TESTS=1
   swift test --filter canPullFromPrivateRegistry
   ```

2. **GitHub Container Registry**
   ```bash
   export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
   export TESTCONTAINERS_RUN_DOCKER_TESTS=1
   swift test --filter canPullFromGHCR
   ```

3. **AWS ECR**
   ```bash
   # Get ECR password
   aws ecr get-login-password --region us-east-1 > /tmp/ecr-password.txt
   export ECR_PASSWORD=$(cat /tmp/ecr-password.txt)
   export TESTCONTAINERS_RUN_DOCKER_TESTS=1
   # Use in test with registry: "123456789012.dkr.ecr.us-east-1.amazonaws.com"
   ```

4. **Custom Docker Config**
   ```bash
   # Create test config
   mkdir -p /tmp/docker-test
   echo '{"auths":{"ghcr.io":{"auth":"dXNlcjpwYXNz"}}}' > /tmp/docker-test/config.json
   # Test with .configFile(path: "/tmp/docker-test")
   ```

## Acceptance Criteria

### Must Have

- [x] `RegistryAuth` enum defined with three cases: `credentials`, `configFile`, `systemDefault`
- [x] `ContainerRequest.withRegistryAuth(_:)` builder method implemented
- [x] `DockerClient.authenticateRegistry(_:)` executes `docker login` with `--password-stdin`
- [x] `ProcessRunner` supports stdin for passing passwords securely
- [x] Credentials never appear in command-line arguments (always use stdin)
- [ ] Error messages redact sensitive information (passwords, tokens)
- [ ] Integration test for Docker Hub private repository authentication
- [ ] Integration test for authentication failure handling
- [ ] Documentation in README with examples for Docker Hub, GHCR, ECR
- [ ] Security documentation about credential handling and cleanup

### Should Have

- [ ] `docker logout` called automatically after container termination
- [x] Support for `DOCKER_CONFIG` environment variable via `.configFile`
- [ ] Integration test for GitHub Container Registry
- [x] Integration test for custom config file (mock-script-based)
- [x] Unit tests for all `RegistryAuth` cases
- [ ] Error handling for invalid registry URLs
- [ ] Example code in README for all major registries (Docker Hub, GHCR, ECR, GCR, ACR)

### Nice to Have

- [ ] Option to persist authentication (`persistAuth: Bool` parameter)
- [ ] Automatic detection of registry from image name (e.g., `ghcr.io/org/image` → registry: `ghcr.io`)
- [ ] Support for credential helpers (e.g., `docker-credential-helper`)
- [ ] Multiple registry credentials (array of auth configs)
- [ ] Logging of authentication attempts (without exposing credentials)
- [ ] Performance optimization: cache successful logins within test session

### Out of Scope (Future Enhancements)

- [ ] OAuth-based authentication flows
- [ ] Integration with system keychains (macOS Keychain, Linux Secret Service)
- [ ] Automatic token refresh for cloud providers (AWS, GCP, Azure)
- [ ] Image pull policies (always, if-missing, never)
- [ ] Registry mirror configuration
- [ ] Multi-architecture image support with auth

## References

### Docker CLI Documentation

- [docker login](https://docs.docker.com/engine/reference/commandline/login/)
- [Docker config.json format](https://docs.docker.com/engine/reference/commandline/cli/#configuration-files)
- [DOCKER_CONFIG environment variable](https://docs.docker.com/engine/reference/commandline/cli/#environment-variables)

### Registry-Specific Documentation

- [Docker Hub](https://docs.docker.com/docker-hub/access-tokens/)
- [GitHub Container Registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [AWS ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/registry_auth.html)
- [Google Artifact Registry](https://cloud.google.com/artifact-registry/docs/docker/authentication)
- [Azure Container Registry](https://docs.microsoft.com/en-us/azure/container-registry/container-registry-authentication)

### Related Code

- `/Sources/TestContainers/DockerClient.swift` - Docker CLI execution
- `/Sources/TestContainers/ProcessRunner.swift` - Process execution with environment
- `/Sources/TestContainers/ContainerRequest.swift` - Request builder pattern
- `/Sources/TestContainers/TestContainersError.swift` - Error handling

### Related Features

- Feature 084: Pull policy (always / if-missing / never)
- Feature 086: Image preflight checks (inspect, existence)
- Feature 087: Image substitutors (registry mirrors, custom hubs)
