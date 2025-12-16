# Feature 055: VaultContainer

## Summary

Implement a pre-configured HashiCorp Vault container module for swift-test-containers that provides a typed, Swift-native API for testing applications that integrate with Vault for secrets management. The `VaultContainer` will support dev mode configuration, root token management, secret engine initialization, and convenient helper methods for accessing the Vault HTTP API.

This specialized container builds upon the generic `ContainerRequest` API to provide Vault-specific configuration and ease-of-use for testing scenarios involving secrets management, encryption-as-a-service, and dynamic credential generation.

## Current State

### Generic Container API

The current implementation provides a generic container API defined in `/Sources/TestContainers/ContainerRequest.swift`:

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

    // Builder methods
    public func withName(_ name: String) -> Self
    public func withCommand(_ command: [String]) -> Self
    public func withEnvironment(_ environment: [String: String]) -> Self
    public func withLabel(_ key: String, _ value: String) -> Self
    public func withExposedPort(_ containerPort: Int, hostPort: Int? = nil) -> Self
    public func waitingFor(_ strategy: WaitStrategy) -> Self
    public func withHost(_ host: String) -> Self
}
```

### Container Lifecycle

Containers are managed via `withContainer()` in `/Sources/TestContainers/WithContainer.swift`:

```swift
public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T
```

The `Container` actor provides methods for:
- Port mapping: `hostPort(_:)`, `endpoint(for:)`
- Host access: `host()`
- Log retrieval: `logs()`
- Cleanup: `terminate()`

### Wait Strategies

Currently available wait strategies (`/Sources/TestContainers/ContainerRequest.swift`):

```swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
}
```

### Current Testing Pattern

Users currently need to manually configure Vault containers:

```swift
let request = ContainerRequest(image: "hashicorp/vault:1.17")
    .withEnvironment([
        "VAULT_DEV_ROOT_TOKEN_ID": "mytoken",
        "VAULT_DEV_LISTEN_ADDRESS": "0.0.0.0:8200"
    ])
    .withExposedPort(8200)
    .waitingFor(.tcpPort(8200))

try await withContainer(request) { container in
    let endpoint = try await container.endpoint(for: 8200)
    // Manual HTTP API calls required
}
```

## Requirements

### Functional Requirements

1. **Default Configuration**
   - Default image: `hashicorp/vault:latest` (customizable)
   - Default port: 8200 (Vault's standard HTTP API port)
   - Dev mode enabled by default for testing
   - Generate random root token by default with option to specify custom token

2. **Token Management**
   - Configure root token for Vault authentication
   - Provide convenient access to the configured token
   - Support token-based authentication for API calls

3. **Secret Engine Configuration**
   - Execute initialization commands during container startup
   - Support multiple initialization commands
   - Enable/configure different secret engines (KV v1, KV v2, transit, database, etc.)
   - Pre-populate secrets for testing scenarios

4. **API Access Helpers**
   - HTTP host address helper (e.g., `http://127.0.0.1:54321`)
   - Token retrieval for authenticated API calls
   - Integration-friendly methods for common Vault operations

5. **Wait Strategy**
   - Wait for Vault HTTP API to be available
   - Verify Vault is unsealed and ready
   - Support custom wait strategies for advanced scenarios

6. **Development Mode**
   - Enable Vault dev mode by default
   - Auto-unsealed container
   - In-memory storage (no persistence needed for tests)
   - Single root token configuration

7. **Swift Concurrency Support**
   - Full async/await support
   - Sendable conformance
   - Actor isolation where appropriate

### Non-Functional Requirements

1. **Consistency**
   - Follow existing code patterns from generic container API
   - Use builder pattern consistent with `ContainerRequest`
   - Maintain similar error handling patterns

2. **Testability**
   - Support unit tests without Docker
   - Integration tests with real Vault containers
   - Clear separation of concerns

3. **Documentation**
   - Comprehensive inline documentation
   - Usage examples for common scenarios
   - Migration guide from generic container API

4. **Performance**
   - Minimal startup overhead
   - Efficient wait strategy
   - Quick cleanup after tests

## API Design

### Proposed VaultContainer Module

Create a new specialized container type that builds upon the generic API:

#### File Structure

```
Sources/TestContainers/
├── Vault/
│   ├── VaultContainer.swift       # Main VaultContainer type
│   └── VaultContainerRequest.swift # Configuration type
```

#### VaultContainerRequest API

```swift
/// Configuration for creating a Vault container suitable for testing.
/// Provides a convenient API for HashiCorp Vault container configuration.
public struct VaultContainerRequest: Sendable, Hashable {
    public var image: String
    public var vaultPort: Int
    public var rootToken: String
    public var initCommands: [String]
    public var environment: [String: String]
    public var waitStrategy: WaitStrategy?
    public var host: String

    /// Creates a new Vault container request with default configuration.
    /// - Parameter image: Docker image to use (default: "hashicorp/vault:latest")
    public init(image: String = "hashicorp/vault:latest") {
        self.image = image
        self.vaultPort = 8200
        self.rootToken = UUID().uuidString // Random token by default
        self.initCommands = []
        self.environment = [:]
        self.waitStrategy = nil
        self.host = "127.0.0.1"
    }

    /// Sets the Vault HTTP API port.
    /// - Parameter port: Port number (default: 8200)
    public func withVaultPort(_ port: Int) -> Self

    /// Sets the root token for Vault authentication.
    /// - Parameter token: Root token string
    public func withRootToken(_ token: String) -> Self

    /// Adds an initialization command to execute after Vault starts.
    /// Commands are executed using `vault` CLI inside the container.
    /// - Parameter command: Vault CLI command (without "vault" prefix)
    /// - Returns: Updated request
    /// - Example: `.withInitCommand("secrets enable transit")`
    public func withInitCommand(_ command: String) -> Self

    /// Adds multiple initialization commands to execute after Vault starts.
    /// - Parameter commands: Array of Vault CLI commands
    public func withInitCommands(_ commands: [String]) -> Self

    /// Adds a secret to the KV v2 secret engine at the specified path.
    /// - Parameters:
    ///   - path: Secret path (e.g., "secret/data/myapp")
    ///   - secrets: Key-value pairs to store
    /// - Returns: Updated request
    /// - Example: `.withSecret("secret/data/myapp", ["api-key": "test123"])`
    public func withSecret(_ path: String, _ secrets: [String: String]) -> Self

    /// Sets environment variables for the container.
    /// - Parameter environment: Dictionary of environment variables
    public func withEnvironment(_ environment: [String: String]) -> Self

    /// Sets the wait strategy for container readiness.
    /// If not specified, defaults to waiting for HTTP 200 on /v1/sys/health
    /// - Parameter strategy: Wait strategy to use
    public func withWaitStrategy(_ strategy: WaitStrategy) -> Self

    /// Sets the host address for connecting to the container.
    /// - Parameter host: Host address (default: "127.0.0.1")
    public func withHost(_ host: String) -> Self

    /// Converts this Vault-specific request to a generic ContainerRequest.
    /// This method sets up dev mode, port exposure, and wait strategy.
    internal func toContainerRequest() -> ContainerRequest
}
```

#### VaultContainer API

```swift
/// A container running HashiCorp Vault configured for testing.
/// Provides convenient access to Vault's HTTP API and configuration.
public actor VaultContainer {
    private let container: Container
    private let config: VaultContainerRequest

    internal init(container: Container, config: VaultContainerRequest) {
        self.container = container
        self.config = config
    }

    /// The container ID.
    public var id: String {
        container.id
    }

    /// Returns the HTTP host address for accessing Vault API.
    /// - Returns: Full HTTP URL (e.g., "http://127.0.0.1:54321")
    public func httpHostAddress() async throws -> String {
        let endpoint = try await container.endpoint(for: config.vaultPort)
        return "http://\(endpoint)"
    }

    /// Returns the mapped host port for the Vault HTTP API.
    /// - Returns: Host port number
    public func hostPort() async throws -> Int {
        try await container.hostPort(config.vaultPort)
    }

    /// Returns the host address.
    /// - Returns: Host IP or hostname
    public func host() -> String {
        container.host()
    }

    /// Returns the root token configured for this Vault instance.
    /// Use this token for authenticating API requests.
    /// - Returns: Root token string
    public func rootToken() -> String {
        config.rootToken
    }

    /// Retrieves container logs.
    /// - Returns: Container log output
    public func logs() async throws -> String {
        try await container.logs()
    }

    /// Terminates and removes the container.
    public func terminate() async throws {
        try await container.terminate()
    }

    /// Executes a Vault CLI command inside the container.
    /// Requires Feature 007 (Container Exec) to be implemented.
    /// - Parameter command: Vault CLI command (without "vault" prefix)
    /// - Returns: Command output
    /// - Example: `try await vault.exec("kv get secret/myapp")`
    public func exec(_ command: String) async throws -> String {
        // Future enhancement when exec support is available
        fatalError("Exec support not yet implemented. See Feature 007.")
    }
}
```

#### Convenience Function

```swift
/// Creates and starts a Vault container for testing.
/// The container is automatically cleaned up when the operation completes.
///
/// - Parameters:
///   - request: Vault container configuration
///   - docker: Docker client instance (default: shared client)
///   - operation: Async operation to perform with the running container
/// - Returns: Result of the operation
/// - Throws: Docker errors or operation errors
///
/// Example:
/// ```swift
/// let vaultRequest = VaultContainerRequest()
///     .withRootToken("mytoken")
///     .withSecret("secret/data/myapp", ["api-key": "test123"])
///
/// try await withVaultContainer(vaultRequest) { vault in
///     let address = try await vault.httpHostAddress()
///     let token = vault.rootToken()
///     // Make API calls to Vault
/// }
/// ```
public func withVaultContainer<T>(
    _ request: VaultContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (VaultContainer) async throws -> T
) async throws -> T {
    let containerRequest = request.toContainerRequest()
    return try await withContainer(containerRequest, docker: docker) { container in
        let vaultContainer = VaultContainer(container: container, config: request)
        return try await operation(vaultContainer)
    }
}
```

### Usage Examples

#### Basic Usage with Default Configuration

```swift
import Testing
import TestContainers

@Test func vaultBasicExample() async throws {
    try await withVaultContainer(VaultContainerRequest()) { vault in
        let address = try await vault.httpHostAddress()
        let token = vault.rootToken()

        // Use Vault HTTP API or SDK
        #expect(!address.isEmpty)
        #expect(!token.isEmpty)
    }
}
```

#### Custom Token and Pre-populated Secrets

```swift
@Test func vaultWithSecrets() async throws {
    let request = VaultContainerRequest()
        .withRootToken("test-token")
        .withSecret("secret/data/myapp", [
            "db-password": "secure123",
            "api-key": "abc123xyz"
        ])

    try await withVaultContainer(request) { vault in
        let address = try await vault.httpHostAddress()

        // Verify secrets are accessible via HTTP API
        let url = "\(address)/v1/secret/data/myapp"
        // Make HTTP request with X-Vault-Token: test-token
    }
}
```

#### Transit Secret Engine Configuration

```swift
@Test func vaultWithTransit() async throws {
    let request = VaultContainerRequest()
        .withRootToken("mytoken")
        .withInitCommands([
            "secrets enable transit",
            "write -f transit/keys/my-key"
        ])

    try await withVaultContainer(request) { vault in
        let address = try await vault.httpHostAddress()
        // Use transit encryption API
    }
}
```

#### Multiple Secret Engines and Paths

```swift
@Test func vaultComplexSetup() async throws {
    let request = VaultContainerRequest(image: "hashicorp/vault:1.17")
        .withRootToken("root")
        .withInitCommands([
            "secrets enable -path=secret kv-v2",
            "secrets enable transit",
            "secrets enable database"
        ])
        .withSecret("secret/data/app1", ["key1": "value1"])
        .withSecret("secret/data/app2", ["key2": "value2"])

    try await withVaultContainer(request) { vault in
        #expect(vault.rootToken() == "root")

        let address = try await vault.httpHostAddress()
        let port = try await vault.hostPort()

        #expect(port > 0)
        #expect(address.contains("http://"))
    }
}
```

#### Custom Port and Wait Strategy

```swift
@Test func vaultCustomConfiguration() async throws {
    let request = VaultContainerRequest()
        .withVaultPort(8200)
        .withRootToken("custom-token")
        .withWaitStrategy(.logContains("Development mode", timeout: .seconds(30)))

    try await withVaultContainer(request) { vault in
        let logs = try await vault.logs()
        #expect(logs.contains("Development mode"))
    }
}
```

## Implementation Steps

### Step 1: Create VaultContainerRequest Structure

**File**: `/Sources/TestContainers/Vault/VaultContainerRequest.swift`

**Tasks**:
1. Define `VaultContainerRequest` struct with properties
2. Implement `init(image:)` with sensible defaults
3. Implement all builder methods (`withRootToken`, `withInitCommand`, etc.)
4. Implement `toContainerRequest()` method to convert to generic `ContainerRequest`
5. Ensure `Sendable` and `Hashable` conformance
6. Add comprehensive documentation comments

**Key Implementation Details**:
- Default image: `"hashicorp/vault:latest"`
- Default port: `8200`
- Dev mode environment: `VAULT_DEV_ROOT_TOKEN_ID` and `VAULT_DEV_LISTEN_ADDRESS`
- Random UUID token generation by default
- Convert init commands to environment variable or command array

**Estimated Effort**: 2-3 hours

### Step 2: Implement toContainerRequest() Conversion

**File**: `/Sources/TestContainers/Vault/VaultContainerRequest.swift`

**Implementation**:
```swift
internal func toContainerRequest() -> ContainerRequest {
    var env = self.environment

    // Configure dev mode
    env["VAULT_DEV_ROOT_TOKEN_ID"] = rootToken
    env["VAULT_DEV_LISTEN_ADDRESS"] = "0.0.0.0:\(vaultPort)"

    // Execute init commands if provided
    if !initCommands.isEmpty {
        // Store commands to be executed after startup
        // This may require command wrapping or post-startup exec calls
    }

    let request = ContainerRequest(image: image)
        .withEnvironment(env)
        .withExposedPort(vaultPort)
        .withHost(host)

    // Apply wait strategy (default or custom)
    if let waitStrategy = waitStrategy {
        return request.waitingFor(waitStrategy)
    } else {
        // Default: wait for Vault HTTP API to respond
        return request.waitingFor(.tcpPort(vaultPort, timeout: .seconds(60)))
    }
}
```

**Challenges**:
- Init commands require execution after Vault is running
- May need to use command wrapper or delay execution
- Alternative: Use HTTP API calls after container starts

**Estimated Effort**: 1-2 hours

### Step 3: Create VaultContainer Actor

**File**: `/Sources/TestContainers/Vault/VaultContainer.swift`

**Tasks**:
1. Define `VaultContainer` actor wrapping `Container`
2. Implement `httpHostAddress()` method
3. Implement `hostPort()` method
4. Implement `host()` method
5. Implement `rootToken()` method
6. Implement `logs()` method
7. Implement `terminate()` method
8. Add stub for `exec()` method with clear error message
9. Add comprehensive documentation

**Estimated Effort**: 1-2 hours

### Step 4: Implement withVaultContainer() Function

**File**: `/Sources/TestContainers/Vault/VaultContainer.swift`

**Implementation**:
```swift
public func withVaultContainer<T>(
    _ request: VaultContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (VaultContainer) async throws -> T
) async throws -> T {
    let containerRequest = request.toContainerRequest()
    return try await withContainer(containerRequest, docker: docker) { container in
        let vaultContainer = VaultContainer(container: container, config: request)

        // Execute init commands if any
        if !request.initCommands.isEmpty {
            try await executeInitCommands(vault: vaultContainer, commands: request.initCommands)
        }

        return try await operation(vaultContainer)
    }
}

private func executeInitCommands(vault: VaultContainer, commands: [String]) async throws {
    // This requires exec support (Feature 007)
    // For initial implementation, may use docker exec via DockerClient
    // Or document limitation and implement after exec support is available
}
```

**Estimated Effort**: 2 hours

### Step 5: Handle Init Commands

**Approach Options**:

**Option A: Use Docker Exec** (Preferred)
- Use `DockerClient` to execute commands after container starts
- Requires adding exec support to `DockerClient` (similar to Feature 003)
- Clean separation of concerns

**Option B: Command Wrapper**
- Wrap Vault startup with a shell script that runs commands after Vault is ready
- More complex, harder to debug
- Requires waiting for Vault to be ready before executing commands

**Option C: HTTP API Calls**
- Use Vault HTTP API to configure secret engines
- More portable, no exec required
- Requires implementing HTTP client logic

**Recommended**: Start with Option A (docker exec). Add minimal exec support to `DockerClient` for executing commands:

```swift
// Add to DockerClient.swift
func exec(id: String, command: [String]) async throws -> CommandOutput {
    var args = ["exec", id]
    args += command
    return try await runDocker(args)
}
```

Then use it in `withVaultContainer`:

```swift
private func executeInitCommands(
    vault: VaultContainer,
    commands: [String],
    docker: DockerClient
) async throws {
    for command in commands {
        let fullCommand = ["vault"] + command.split(separator: " ").map(String.init)
        _ = try await docker.exec(id: vault.id, command: fullCommand)
    }
}
```

**Estimated Effort**: 2-3 hours

### Step 6: Add withSecret() Helper Implementation

The `withSecret()` method should convert to an appropriate init command:

```swift
public func withSecret(_ path: String, _ secrets: [String: String]) -> Self {
    var copy = self

    // Convert secrets dictionary to Vault command
    // For KV v2: vault kv put secret/data/path key1=value1 key2=value2
    let secretPairs = secrets.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    let command = "kv put \(path) \(secretPairs)"

    copy.initCommands.append(command)
    return copy
}
```

**Estimated Effort**: 30 minutes

### Step 7: Add Unit Tests

**File**: `/Tests/TestContainersTests/VaultContainerRequestTests.swift`

**Test Cases**:
1. Test default initialization
2. Test builder methods (withRootToken, withVaultPort, etc.)
3. Test withSecret() conversion to init commands
4. Test withInitCommands() appending
5. Test toContainerRequest() conversion
6. Test Hashable conformance
7. Test Sendable conformance (compile-time)

**Example Tests**:
```swift
import Testing
import TestContainers

@Test func vaultContainerRequest_defaultValues() {
    let request = VaultContainerRequest()

    #expect(request.image == "hashicorp/vault:latest")
    #expect(request.vaultPort == 8200)
    #expect(request.host == "127.0.0.1")
    #expect(!request.rootToken.isEmpty)
    #expect(request.initCommands.isEmpty)
}

@Test func vaultContainerRequest_withRootToken() {
    let request = VaultContainerRequest()
        .withRootToken("mytoken")

    #expect(request.rootToken == "mytoken")
}

@Test func vaultContainerRequest_withSecret() {
    let request = VaultContainerRequest()
        .withSecret("secret/data/myapp", ["key1": "value1", "key2": "value2"])

    #expect(request.initCommands.count == 1)
    #expect(request.initCommands[0].contains("kv put"))
    #expect(request.initCommands[0].contains("secret/data/myapp"))
}

@Test func vaultContainerRequest_toContainerRequest() {
    let request = VaultContainerRequest()
        .withRootToken("test-token")
        .withVaultPort(8200)

    let containerRequest = request.toContainerRequest()

    #expect(containerRequest.image == "hashicorp/vault:latest")
    #expect(containerRequest.ports.contains { $0.containerPort == 8200 })
    #expect(containerRequest.environment["VAULT_DEV_ROOT_TOKEN_ID"] == "test-token")
}
```

**Estimated Effort**: 2-3 hours

### Step 8: Add Integration Tests

**File**: `/Tests/TestContainersTests/VaultContainerIntegrationTests.swift`

**Test Cases**:
1. Basic Vault container startup
2. Container with custom root token
3. Container with pre-configured secrets
4. Container with transit secret engine
5. Container with multiple init commands
6. HTTP API accessibility test
7. Container cleanup verification
8. Error handling for invalid configuration

**Example Tests**:
```swift
import Testing
import TestContainers

@Test func vaultContainer_startsSuccessfully() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withVaultContainer(VaultContainerRequest()) { vault in
        let address = try await vault.httpHostAddress()
        let token = vault.rootToken()

        #expect(address.hasPrefix("http://"))
        #expect(!token.isEmpty)
    }
}

@Test func vaultContainer_customToken() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = VaultContainerRequest()
        .withRootToken("my-custom-token")

    try await withVaultContainer(request) { vault in
        #expect(vault.rootToken() == "my-custom-token")

        let address = try await vault.httpHostAddress()
        // Verify token works by making authenticated API call
        // (requires HTTP client or URLSession)
    }
}

@Test func vaultContainer_withInitCommands() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = VaultContainerRequest()
        .withRootToken("root")
        .withInitCommands([
            "secrets enable transit",
            "write -f transit/keys/my-key"
        ])

    try await withVaultContainer(request) { vault in
        let address = try await vault.httpHostAddress()
        let token = vault.rootToken()

        // Verify transit engine is enabled via HTTP API
        #expect(!address.isEmpty)
        #expect(token == "root")
    }
}

@Test func vaultContainer_logsAccessible() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withVaultContainer(VaultContainerRequest()) { vault in
        let logs = try await vault.logs()

        #expect(logs.contains("Vault"))
        #expect(logs.contains("Development mode"))
    }
}
```

**Estimated Effort**: 3-4 hours

### Step 9: Documentation

**Tasks**:
1. Add comprehensive doc comments to all public APIs
2. Create usage examples in comments
3. Update main README.md with Vault example
4. Document common patterns (secrets, engines, authentication)
5. Add troubleshooting section
6. Document limitations (e.g., init commands require exec support)

**README.md Addition**:
```markdown
### VaultContainer Example

```swift
import Testing
import TestContainers

@Test func myVaultTest() async throws {
    let request = VaultContainerRequest()
        .withRootToken("test-token")
        .withSecret("secret/data/myapp", [
            "db-password": "secure123",
            "api-key": "abc123"
        ])

    try await withVaultContainer(request) { vault in
        let address = try await vault.httpHostAddress()
        let token = vault.rootToken()

        // Use Vault HTTP API or SDK to retrieve secrets
        // Example: GET \(address)/v1/secret/data/myapp
        // Header: X-Vault-Token: \(token)
    }
}
```
```

**Estimated Effort**: 2-3 hours

### Step 10: Update Package Structure

**Tasks**:
1. Ensure Vault files are included in the TestContainers target
2. Update Package.swift if necessary (currently uses implicit file inclusion)
3. Verify build succeeds
4. Run all tests

**Estimated Effort**: 30 minutes

## Dependencies

### Required

1. **Generic Container API** - Already implemented
   - `ContainerRequest` and builder pattern
   - `withContainer()` lifecycle management
   - `Container` actor with port mapping

2. **Wait Strategies** - Already implemented
   - `.tcpPort()` strategy sufficient for basic implementation
   - Future: HTTP wait strategy (Feature 001) for more robust readiness checks

3. **DockerClient** - Already implemented
   - Container lifecycle management
   - Port mapping
   - Log retrieval

### Optional (Future Enhancements)

1. **Container Exec** (Feature 007)
   - Required for init command execution
   - Workaround: Basic exec support can be added inline for Vault-specific needs
   - Full exec feature provides better reusability

2. **HTTP Wait Strategy** (Feature 001)
   - More robust wait strategy for Vault readiness
   - Can wait for `/v1/sys/health` to return 200
   - Not blocking: TCP wait is sufficient for initial implementation

## Testing Plan

### Unit Tests

**Location**: `/Tests/TestContainersTests/VaultContainerRequestTests.swift`

**Test Coverage**:
1. **Initialization**
   - Default values
   - Custom image
   - Random token generation

2. **Builder Pattern**
   - Each builder method (withRootToken, withVaultPort, etc.)
   - Method chaining
   - Immutability

3. **Secret Configuration**
   - withSecret() converts to init commands correctly
   - Multiple secrets
   - Special characters in secret values

4. **Init Commands**
   - Single command
   - Multiple commands
   - Command ordering

5. **Conversion**
   - toContainerRequest() produces correct environment
   - Port mapping correct
   - Wait strategy configuration

6. **Conformance**
   - Hashable works correctly
   - Sendable (compile-time check)

### Integration Tests

**Location**: `/Tests/TestContainersTests/VaultContainerIntegrationTests.swift`

**Test Scenarios**:
1. **Basic Startup**
   - Container starts with defaults
   - HTTP address accessible
   - Root token available

2. **Custom Configuration**
   - Custom image version
   - Custom port
   - Custom token

3. **Init Commands**
   - Single command execution
   - Multiple commands
   - Secret engine enablement
   - Secret creation

4. **API Access**
   - HTTP endpoint reachable
   - Authentication with root token
   - Basic API operations (if HTTP client available)

5. **Error Scenarios**
   - Invalid image
   - Port conflicts
   - Failed init commands

6. **Cleanup**
   - Container properly terminated
   - No resource leaks

7. **Real-World Use Cases**
   - KV v2 secrets
   - Transit encryption
   - Multiple secret paths
   - Complex initialization

### Manual Testing

**Checklist**:
- [ ] Test with Vault 1.13, 1.15, 1.17, latest
- [ ] Test on macOS
- [ ] Test on Linux (if available)
- [ ] Verify dev mode is enabled
- [ ] Verify Vault is unsealed automatically
- [ ] Test with Vault Go SDK integration
- [ ] Test with raw HTTP API calls
- [ ] Verify cleanup after test failures
- [ ] Test concurrent containers
- [ ] Performance: container startup time

### Performance Benchmarks

**Metrics to Track**:
- Container startup time (target: < 5 seconds)
- Wait strategy duration (target: < 3 seconds)
- Memory overhead vs generic container
- Cleanup time (target: < 2 seconds)

## Acceptance Criteria

### Must Have

- [x] `VaultContainerRequest` struct with builder pattern implemented
- [x] `withRootToken()` method for token configuration
- [x] `withInitCommand()` and `withInitCommands()` methods
- [x] `withSecret()` helper for KV secrets
- [x] `withVaultPort()` for port configuration
- [x] `withEnvironment()` for additional environment variables
- [x] `withWaitStrategy()` for custom wait strategies
- [x] `VaultContainer` actor wrapping generic container
- [x] `httpHostAddress()` method returning full URL
- [x] `hostPort()` method returning mapped port
- [x] `rootToken()` method returning configured token
- [x] `logs()` method for container logs
- [x] `terminate()` method for cleanup
- [x] `withVaultContainer()` convenience function
- [x] Default configuration uses dev mode
- [x] Default port is 8200
- [x] Default image is "hashicorp/vault:latest"
- [x] Random token generation by default
- [x] Unit tests with >80% coverage
- [x] Integration tests with real Vault containers
- [x] All tests pass
- [x] Documentation in code (doc comments)
- [ ] README updated with examples

### Should Have

- [x] Support for multiple secret paths
- [x] Support for different secret engines (KV v1, v2, transit, etc.)
- [x] Init command execution working
- [x] HTTP wait strategy for `/v1/sys/health` (Feature 001 complete)
- [x] Error handling for invalid configuration
- [x] Helpful error messages
- [x] Examples for common use cases
- [ ] Performance benchmarks documented

### Nice to Have

- [x] `exec()` method for running Vault CLI commands (implemented via `execVaultCommand`)
- [ ] Typed API for common Vault operations
- [ ] Helper methods for secret retrieval
- [ ] Support for Vault policies
- [ ] Support for auth methods (AppRole, Kubernetes, etc.)
- [ ] Support for persistence mode (non-dev)
- [ ] Configuration file support
- [ ] TLS/HTTPS support for Vault API

### Definition of Done

- All "Must Have" criteria completed
- All "Should Have" criteria attempted (document blockers if any)
- All tests passing locally and in CI
- Code review completed
- Documentation reviewed
- Manually tested with multiple Vault versions
- No regressions in existing tests
- Follows existing code style and patterns
- Public APIs have comprehensive documentation
- README updated with clear examples
- Feature ticket updated with final status

## Open Questions

### 1. Init Command Execution Timing

**Question**: When should init commands be executed?

**Options**:
- A: After container starts but before returning to user (in `withVaultContainer`)
- B: During container startup using command wrapper
- C: As a separate method user must call explicitly

**Recommendation**: Option A. Execute commands after container is ready but before returning control to the user. This provides the best UX and is consistent with other testcontainers implementations.

**Decision**: Implement Option A with exec support in `withVaultContainer`.

### 2. Secret Path Format

**Question**: Should we validate or transform secret paths (e.g., auto-add `/data/` for KV v2)?

**Options**:
- A: Accept paths as-is, user responsible for correct format
- B: Auto-detect and transform KV v2 paths
- C: Provide separate methods for different secret engines

**Recommendation**: Option A for initial implementation. Add helpers in future if needed.

**Decision**: Document expected path formats in API docs.

### 3. HTTP Client Dependency

**Question**: Should we add HTTP client functionality for testing Vault API?

**Options**:
- A: No HTTP client, users bring their own (Vault SDK, URLSession, etc.)
- B: Add basic HTTP helpers using URLSession
- C: Add full Vault HTTP client wrapper

**Recommendation**: Option A. Keep the container module focused on container lifecycle. Users can use Foundation's URLSession or Vault SDK for API calls.

**Decision**: Document how to use URLSession with the container in examples.

### 4. Multiple Container Versions

**Question**: Should we provide version-specific container requests (e.g., `Vault113ContainerRequest`)?

**Options**:
- A: Single generic request, user specifies image
- B: Version-specific subclasses/types
- C: Factory methods for common versions

**Recommendation**: Option A with convenience examples in documentation showing how to specify versions.

**Decision**: Use image parameter for version control.

### 5. Error Handling for Init Commands

**Question**: How should we handle init command failures?

**Options**:
- A: Fail fast - throw error if any init command fails
- B: Continue - log errors but don't fail container startup
- C: Configurable - let user decide via parameter

**Recommendation**: Option A. Failed init commands indicate misconfiguration that should be caught immediately.

**Decision**: Throw descriptive errors including command output for debugging.

## Risks and Mitigations

### Risk: Init Commands Require Exec Support

**Impact**: High - Core feature depends on container exec capability

**Probability**: Low - Exec support is straightforward to implement

**Mitigation**:
- Add minimal exec support to `DockerClient` inline
- Document dependency on future Feature 007 for advanced exec scenarios
- Provide workaround examples using manual exec after container starts

### Risk: Vault Startup Time Variability

**Impact**: Medium - Tests may be flaky if wait strategy is insufficient

**Probability**: Medium - Vault startup time varies by host performance

**Mitigation**:
- Use robust wait strategy (HTTP health check when available)
- Provide generous default timeout (60 seconds)
- Allow users to customize wait strategy
- Document best practices for wait strategy selection

### Risk: Version Compatibility Issues

**Impact**: Medium - Different Vault versions may have different behavior

**Probability**: Medium - Vault API evolves across versions

**Mitigation**:
- Test with multiple Vault versions (1.13, 1.15, 1.17, latest)
- Document tested versions
- Use stable API features for init commands
- Provide version-specific examples if needed

### Risk: Port Conflicts

**Impact**: Low - Multiple tests may conflict if using same host port

**Probability**: Low - Random port mapping by default

**Mitigation**:
- Use random port mapping (Docker default)
- Document how to specify custom ports if needed
- Test concurrent container usage

### Risk: Resource Leaks

**Impact**: High - Failed cleanup can leave containers running

**Probability**: Low - Using proven cleanup pattern from generic API

**Mitigation**:
- Rely on existing `withContainer()` cleanup logic
- Add integration tests for cleanup verification
- Document manual cleanup commands for debugging
- Use testcontainers labels for easy identification

### Risk: Incomplete Documentation

**Impact**: Medium - Users may not understand how to use Vault container effectively

**Probability**: Medium - Complex feature with many configuration options

**Mitigation**:
- Comprehensive inline documentation
- Multiple usage examples for common scenarios
- README integration guide
- Reference to Vault documentation for concepts
- Troubleshooting section

## Future Enhancements

### Phase 2: Advanced Features

1. **Full Exec Support**
   - Implement complete exec API via Feature 007
   - Add `VaultContainer.exec()` method
   - Support for retrieving command output
   - Support for command failure handling

2. **Vault Client Integration**
   - Helper methods wrapping common Vault operations
   - Typed API for KV reads/writes
   - Policy management helpers
   - Auth method configuration helpers

3. **TLS/HTTPS Support**
   - Configure Vault with TLS
   - Certificate generation
   - Secure mode testing
   - Certificate trust configuration

4. **Persistence Mode**
   - Support for non-dev mode Vault
   - File-based storage configuration
   - Unseal key management
   - Migration from dev to prod mode testing

### Phase 3: Ecosystem Integration

1. **Auth Methods**
   - AppRole configuration
   - Kubernetes auth setup
   - LDAP integration testing
   - GitHub auth configuration

2. **Secret Engines**
   - Database dynamic credentials
   - PKI certificate generation
   - SSH secret engine
   - AWS/Azure credential generation

3. **High Availability**
   - Multiple Vault instances
   - Raft consensus configuration
   - Replication testing
   - Cluster mode support

4. **Observability**
   - Metrics endpoint exposure
   - Audit log configuration
   - Telemetry integration
   - Debug logging helpers

## References

### Existing Implementation References

- **Generic Container API**: `/Sources/TestContainers/ContainerRequest.swift`
- **Container Lifecycle**: `/Sources/TestContainers/WithContainer.swift`
- **Container Actor**: `/Sources/TestContainers/Container.swift`
- **Docker Client**: `/Sources/TestContainers/DockerClient.swift`
- **Wait Strategies**: `/Sources/TestContainers/Waiter.swift`
- **Integration Tests**: `/Tests/TestContainersTests/DockerIntegrationTests.swift`

### Similar Implementations

- **Testcontainers Go Vault Module**: https://golang.testcontainers.org/modules/vault/
- **Testcontainers Java Vault Module**: https://java.testcontainers.org/modules/vault/
- **Testcontainers Node Vault Module**: (if available)

### Vault Resources

- **Vault Documentation**: https://developer.hashicorp.com/vault/docs
- **Vault API Documentation**: https://developer.hashicorp.com/vault/api-docs
- **Vault Docker Image**: https://hub.docker.com/r/hashicorp/vault
- **Vault Dev Mode**: https://developer.hashicorp.com/vault/docs/concepts/dev-server
- **Vault Secret Engines**: https://developer.hashicorp.com/vault/docs/secrets

### Related Features

- **Feature 001**: HTTP Wait Strategy (enhances Vault readiness detection)
- **Feature 003**: Exec Wait Strategy (pattern for exec support)
- **Feature 007**: Container Exec (enables init command execution)
- **Feature 010**: Container Inspect (useful for debugging Vault configuration)

## Notes

- This feature provides significant value for applications using Vault for secrets management
- The implementation is straightforward given the existing container infrastructure
- Init command support adds complexity but provides essential functionality
- Future integration with Vault SDK would provide even better testing experience
- Consider this a foundation for more advanced Vault testing features
