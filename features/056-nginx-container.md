# Feature 056: NginxContainer Module

**Status**: Implemented
**Priority**: Tier 4 (Module System - Service-Specific Helpers)
**Estimated Complexity**: Medium
**Dependencies**:
- Feature 001: HTTP Wait Strategy (implemented)
- Feature 013: Bind Mounts (implemented - required for config/static file mounting)

---

## Summary

Implement a pre-configured `NginxContainer` module that provides a typed Swift API for running Nginx containers in tests. This module will offer sensible defaults, helper methods for common Nginx configurations (static file serving, reverse proxy setup, custom config mounting), and convenient URL/endpoint accessors.

**Key benefits**:
- Pre-configured Nginx container with sensible defaults (port 80, HTTP wait strategy)
- Type-safe API for mounting custom nginx.conf files
- Helper methods for static file serving and reverse proxy configuration
- HTTP endpoint resolution for easy integration testing
- Follows testcontainers-go nginx module patterns adapted for Swift idioms

---

## Current State

### Generic Container API

The current implementation provides a generic `ContainerRequest` builder pattern:

```swift
// Example: Manual Nginx setup today
let request = ContainerRequest(image: "nginx:alpine")
    .withExposedPort(80)
    .waitingFor(.tcpPort(80))

try await withContainer(request) { container in
    let endpoint = try await container.endpoint(for: 80)
    // Make HTTP request to endpoint...
}
```

**Limitations**:
- Users must know Nginx-specific details (port 80, image tags, config paths)
- No helper for constructing HTTP URLs or mounting custom configs
- No type safety for Nginx-specific operations
- Repeated boilerplate across tests using Nginx

### Module System Status

From `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md`:

**Tier 4: Module System** is planned for service-specific helpers with typed APIs. Proposed modules include:
- PostgresContainer (connection strings, init scripts)
- RedisContainer (connection strings, TLS)
- **NginxContainer** (static files, reverse proxy, custom config)

No modules are currently implemented. This feature will establish patterns for the module system.

### Reference: testcontainers-go Nginx

The Go implementation (https://golang.testcontainers.org/examples/nginx/) demonstrates:

```go
type nginxContainer struct {
    testcontainers.Container
    URI string  // HTTP endpoint
}

func startContainer(ctx context.Context) (*nginxContainer, error) {
    ctr, err := testcontainers.Run(ctx, "nginx",
        testcontainers.WithExposedPorts("80/tcp"),
        testcontainers.WithWaitStrategy(wait.ForHTTP("/").WithStartupTimeout(10*time.Second)),
    )
    // ... endpoint resolution
}
```

**Pattern**: Wrapper struct with service-specific endpoint accessors.

---

## Requirements

### Functional Requirements

1. **Default Image & Configuration**
   - Default image: `nginx:alpine` (small, secure, maintained)
   - Default exposed port: 80
   - Default wait strategy: HTTP GET to "/" with 200 status (requires Feature 001)
   - Fallback: TCP port 80 wait if HTTP strategy unavailable

2. **Custom Configuration File Mounting**
   - Support mounting custom `nginx.conf` file into container
   - Support mounting `*.conf` files to `/etc/nginx/conf.d/`
   - Use bind mounts or volume mounts (requires Feature 012 or equivalent)
   - Validate config file exists before container start

3. **Static File Serving**
   - Helper method to mount host directory as static file root
   - Default document root: `/usr/share/nginx/html`
   - Support custom document root paths
   - Handle file permissions appropriately

4. **Reverse Proxy Setup**
   - Helper to configure Nginx as reverse proxy to another container
   - Generate nginx.conf snippet for proxy_pass configuration
   - Support custom proxy headers and timeouts

5. **HTTP Endpoint Helper**
   - Provide typed `url()` method returning full HTTP URL (e.g., "http://127.0.0.1:12345")
   - Provide `endpoint()` returning host:port (existing Container API)
   - Support custom paths via `url(path:)` method

6. **Appropriate Wait Strategy**
   - Default: Wait for HTTP 200 on "/" (requires Feature 001: HTTP wait strategy)
   - Allow custom wait strategy override
   - Provide sensible timeout defaults (30 seconds)

### Non-Functional Requirements

1. **Type Safety**
   - Leverage Swift's type system for configuration
   - Value semantics (struct-based where possible)
   - `Sendable` conformance for Swift Concurrency

2. **Developer Experience**
   - Clear, discoverable API with SwiftDoc comments
   - Fail fast with helpful error messages
   - Minimal boilerplate for common use cases

3. **Consistency**
   - Follow existing `ContainerRequest` builder patterns
   - Match code style in core TestContainers module
   - Align with testcontainers-go patterns where sensible

4. **Testability**
   - Unit tests for configuration building
   - Integration tests with real Nginx containers
   - Example code in documentation

---

## API Design

### Proposed Module Structure

```swift
// File: Sources/TestContainersModules/Nginx/NginxContainer.swift

import Foundation
import TestContainers

/// Pre-configured Nginx container for integration testing
public struct NginxContainer {
    public let request: ContainerRequest

    /// Default Nginx image (nginx:alpine)
    public static let defaultImage = "nginx:alpine"

    /// Default Nginx port
    public static let defaultPort = 80

    /// Creates a new NginxContainer with default configuration
    /// - Parameter image: Docker image (default: nginx:alpine)
    public init(image: String = NginxContainer.defaultImage) {
        self.request = ContainerRequest(image: image)
            .withExposedPort(NginxContainer.defaultPort)
            .waitingFor(.http(HTTPWaitConfig(port: NginxContainer.defaultPort)
                .withPath("/")
                .withTimeout(.seconds(30))))
    }

    /// Mount a custom nginx.conf file into the container
    /// - Parameter configPath: Path to nginx.conf on host filesystem
    /// - Returns: Updated NginxContainer configuration
    public func withCustomConfig(_ configPath: String) -> Self {
        var copy = self
        copy.request = request.withBindMount(
            hostPath: configPath,
            containerPath: "/etc/nginx/nginx.conf",
            readOnly: true
        )
        return copy
    }

    /// Mount additional configuration file to conf.d directory
    /// - Parameters:
    ///   - configPath: Path to .conf file on host
    ///   - filename: Filename in conf.d (default: basename of configPath)
    /// - Returns: Updated NginxContainer configuration
    public func withConfigFile(_ configPath: String, as filename: String? = nil) -> Self {
        let name = filename ?? URL(fileURLWithPath: configPath).lastPathComponent
        var copy = self
        copy.request = request.withBindMount(
            hostPath: configPath,
            containerPath: "/etc/nginx/conf.d/\(name)",
            readOnly: true
        )
        return copy
    }

    /// Serve static files from a host directory
    /// - Parameters:
    ///   - hostPath: Path to directory containing static files
    ///   - containerPath: Document root in container (default: /usr/share/nginx/html)
    /// - Returns: Updated NginxContainer configuration
    public func withStaticFiles(from hostPath: String, at containerPath: String = "/usr/share/nginx/html") -> Self {
        var copy = self
        copy.request = request.withBindMount(
            hostPath: hostPath,
            containerPath: containerPath,
            readOnly: true
        )
        return copy
    }

    /// Configure custom wait strategy
    /// - Parameter strategy: Wait strategy to use
    /// - Returns: Updated NginxContainer configuration
    public func waitingFor(_ strategy: WaitStrategy) -> Self {
        var copy = self
        copy.request = request.waitingFor(strategy)
        return copy
    }

    /// Expose additional ports beyond the default
    /// - Parameter port: Additional port to expose
    /// - Returns: Updated NginxContainer configuration
    public func withExposedPort(_ port: Int, hostPort: Int? = nil) -> Self {
        var copy = self
        copy.request = request.withExposedPort(port, hostPort: hostPort)
        return copy
    }

    /// Add environment variables to the container
    /// - Parameter environment: Dictionary of environment variables
    /// - Returns: Updated NginxContainer configuration
    public func withEnvironment(_ environment: [String: String]) -> Self {
        var copy = self
        copy.request = request.withEnvironment(environment)
        return copy
    }
}

/// Extension for running NginxContainer
extension NginxContainer {
    /// Start the Nginx container and execute operation
    /// - Parameters:
    ///   - docker: DockerClient instance (default: new instance)
    ///   - operation: Async operation to run with the container
    /// - Returns: Result of the operation
    public func run<T>(
        docker: DockerClient = DockerClient(),
        operation: @Sendable (RunningNginxContainer) async throws -> T
    ) async throws -> T {
        try await withContainer(request, docker: docker) { container in
            let nginx = RunningNginxContainer(container: container)
            return try await operation(nginx)
        }
    }
}

/// Running Nginx container with typed accessors
public struct RunningNginxContainer {
    private let container: Container

    init(container: Container) {
        self.container = container
    }

    /// Get the base HTTP URL for the Nginx server
    /// - Returns: HTTP URL (e.g., "http://127.0.0.1:12345")
    public func url() async throws -> String {
        let endpoint = try await container.endpoint(for: NginxContainer.defaultPort)
        return "http://\(endpoint)"
    }

    /// Get HTTP URL with custom path
    /// - Parameter path: URL path (should start with /)
    /// - Returns: Full HTTP URL
    public func url(path: String) async throws -> String {
        let base = try await url()
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return "\(base)\(normalizedPath)"
    }

    /// Get the host:port endpoint
    /// - Returns: Endpoint string (e.g., "127.0.0.1:12345")
    public func endpoint() async throws -> String {
        try await container.endpoint(for: NginxContainer.defaultPort)
    }

    /// Get the mapped host port for Nginx
    /// - Returns: Host port number
    public func port() async throws -> Int {
        try await container.hostPort(NginxContainer.defaultPort)
    }

    /// Get container logs
    /// - Returns: Log output as string
    public func logs() async throws -> String {
        try await container.logs()
    }

    /// Access underlying generic Container
    public var underlyingContainer: Container {
        container
    }
}
```

### Package.swift Integration

```swift
// Update Package.swift to include NginxContainer module
let package = Package(
    name: "swift-test-containers",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TestContainers", targets: ["TestContainers"]),
        .library(name: "TestContainersModules", targets: ["TestContainersModules"]),
    ],
    targets: [
        .target(name: "TestContainers"),
        .target(
            name: "TestContainersModules",
            dependencies: ["TestContainers"]
        ),
        .testTarget(
            name: "TestContainersTests",
            dependencies: ["TestContainers"]
        ),
        .testTarget(
            name: "TestContainersModulesTests",
            dependencies: ["TestContainersModules"]
        ),
    ]
)
```

### Usage Examples

#### Example 1: Simple Nginx Container

```swift
import Testing
import TestContainers
import TestContainersModules

@Test func nginxServeDefaultPage() async throws {
    let nginx = NginxContainer()

    try await nginx.run { container in
        let url = try await container.url()
        let response = try await httpGet(url)

        #expect(response.statusCode == 200)
        #expect(response.body.contains("Welcome to nginx"))
    }
}
```

#### Example 2: Serve Static Files

```swift
@Test func nginxServeStaticFiles() async throws {
    // Assume test fixtures at /path/to/test/files
    let nginx = NginxContainer()
        .withStaticFiles(from: "/path/to/test/files")

    try await nginx.run { container in
        let url = try await container.url(path: "/index.html")
        let response = try await httpGet(url)

        #expect(response.statusCode == 200)
        #expect(response.body.contains("Test Content"))
    }
}
```

#### Example 3: Custom Configuration

```swift
@Test func nginxWithCustomConfig() async throws {
    let configPath = "/path/to/custom/nginx.conf"

    let nginx = NginxContainer()
        .withCustomConfig(configPath)
        .waitingFor(.http(HTTPWaitConfig(port: 80)
            .withPath("/health")
            .withTimeout(.seconds(45))))

    try await nginx.run { container in
        let endpoint = try await container.endpoint()
        #expect(!endpoint.isEmpty)
    }
}
```

#### Example 4: Reverse Proxy Configuration

```swift
@Test func nginxAsReverseProxy() async throws {
    // Start backend service first
    let backend = ContainerRequest(image: "myapp:latest")
        .withExposedPort(8080)
        .waitingFor(.tcpPort(8080))

    try await withContainer(backend) { backendContainer in
        let backendEndpoint = try await backendContainer.endpoint(for: 8080)

        // Create nginx config with proxy_pass
        let proxyConfig = """
        server {
            listen 80;
            location / {
                proxy_pass http://\(backendEndpoint);
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
            }
        }
        """

        // Write config to temp file (implementation detail)
        let configPath = try writeToTempFile(proxyConfig)

        let nginx = NginxContainer()
            .withConfigFile(configPath, as: "proxy.conf")

        try await nginx.run { nginxContainer in
            let url = try await nginxContainer.url()
            let response = try await httpGet(url)

            #expect(response.statusCode == 200)
            // Verify proxied response...
        }
    }
}
```

#### Example 5: Multiple Configuration Files

```swift
@Test func nginxWithMultipleConfigs() async throws {
    let nginx = NginxContainer()
        .withConfigFile("/path/to/gzip.conf", as: "gzip.conf")
        .withConfigFile("/path/to/cache.conf", as: "cache.conf")
        .withConfigFile("/path/to/security.conf", as: "security.conf")
        .withStaticFiles(from: "/path/to/website")

    try await nginx.run { container in
        let url = try await container.url()
        let response = try await httpGet(url)
        #expect(response.statusCode == 200)
    }
}
```

---

## Implementation Steps

### Step 1: Create Module Directory Structure

**Location**: `/Sources/TestContainersModules/Nginx/`

1. Create directory structure:
   ```
   Sources/
     TestContainersModules/
       Nginx/
         NginxContainer.swift
   ```

2. Update `Package.swift` to add `TestContainersModules` target and product

**Acceptance Criteria**:
- Module compiles as separate target
- Can import both `TestContainers` and `TestContainersModules`
- No circular dependencies

### Step 2: Implement NginxContainer Struct

**File**: `/Sources/TestContainersModules/Nginx/NginxContainer.swift`

1. Define `NginxContainer` struct with `request: ContainerRequest` property
2. Implement `init(image:)` with default nginx:alpine
3. Add default port and wait strategy configuration
4. Ensure struct is `Sendable` for Swift Concurrency

**Dependencies**: None (uses existing ContainerRequest API)

**Acceptance Criteria**:
- `NginxContainer()` creates valid default configuration
- Default wait strategy is configured (TCP fallback if HTTP unavailable)
- Struct compiles without warnings

### Step 3: Implement Configuration Builder Methods

**File**: `/Sources/TestContainersModules/Nginx/NginxContainer.swift`

Add builder methods in order:

1. **withCustomConfig(_:)**: Mount nginx.conf file
   - Use `.withBindMount()` when available (Feature 012)
   - Error with helpful message if bind mounts not implemented
   - Validate file exists at path

2. **withConfigFile(_:as:)**: Mount additional .conf files
   - Similar to withCustomConfig but for conf.d directory
   - Auto-detect filename from path if not specified

3. **withStaticFiles(from:at:)**: Mount static file directory
   - Default to `/usr/share/nginx/html`
   - Validate directory exists

4. **withExposedPort(_:hostPort:)**: Delegate to request
5. **withEnvironment(_:)**: Delegate to request
6. **waitingFor(_:)**: Override wait strategy

**Dependencies**:
- Feature 012 (Volume/Bind Mounts) for file mounting
- Alternatively: Feature 008 (Copy Files) as workaround

**Acceptance Criteria**:
- All builder methods return `Self`
- Builder methods are immutable (copy-on-write)
- Methods compile and chain correctly

### Step 4: Implement RunningNginxContainer

**File**: `/Sources/TestContainersModules/Nginx/NginxContainer.swift`

1. Define `RunningNginxContainer` struct wrapping `Container`
2. Implement `url()` method returning "http://host:port"
3. Implement `url(path:)` method for custom paths
4. Implement convenience accessors: `endpoint()`, `port()`, `logs()`
5. Provide `underlyingContainer` property for advanced use

**Acceptance Criteria**:
- `url()` returns properly formatted HTTP URL
- `url(path:)` handles both "/path" and "path" inputs
- All methods properly `async throws`
- Type-safe and discoverable API

### Step 5: Implement run() Helper

**File**: `/Sources/TestContainersModules/Nginx/NginxContainer.swift`

1. Add `run(docker:operation:)` method to `NginxContainer`
2. Use existing `withContainer(_:docker:operation:)` internally
3. Wrap `Container` in `RunningNginxContainer` for typed API
4. Ensure proper error propagation and cleanup

**Acceptance Criteria**:
- Container lifecycle properly managed (cleanup on error/success)
- Operation receives `RunningNginxContainer` not raw `Container`
- Compiles with `@Sendable` closure requirements

### Step 6: Add Comprehensive Documentation

**Files**:
- `/Sources/TestContainersModules/Nginx/NginxContainer.swift`
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/README.md`
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md`

1. Add SwiftDoc comments to all public APIs
2. Include parameter descriptions and return values
3. Add code examples to documentation
4. Update README.md with NginxContainer example
5. Update FEATURES.md to mark NginxContainer as implemented
6. Create module-specific README if needed

**Acceptance Criteria**:
- All public APIs have documentation comments
- Examples are tested and working
- README demonstrates basic usage
- Documentation builds without warnings

### Step 7: Unit Tests

**File**: `/Tests/TestContainersModulesTests/Nginx/NginxContainerTests.swift`

Add unit tests for:

```swift
@Test func defaultNginxContainerConfiguration() {
    let nginx = NginxContainer()
    #expect(nginx.request.image == "nginx:alpine")
    #expect(nginx.request.ports.contains(where: { $0.containerPort == 80 }))
}

@Test func customImageConfiguration() {
    let nginx = NginxContainer(image: "nginx:1.25")
    #expect(nginx.request.image == "nginx:1.25")
}

@Test func builderMethodsReturnNewInstances() {
    let original = NginxContainer()
    let modified = original.withExposedPort(443)

    // Original unchanged
    #expect(original.request.ports.count == 1)
    // Modified has additional port
    #expect(modified.request.ports.count == 2)
}

@Test func urlFormattingWithPath() async throws {
    // Mock test - verify URL construction logic
    // (May require test doubles for Container)
}

@Test func staticFilesConfiguration() {
    let nginx = NginxContainer()
        .withStaticFiles(from: "/test/path")

    // Verify bind mount configuration when available
    #expect(!nginx.request.volumes.isEmpty) // or equivalent for bind mounts
}
```

**Acceptance Criteria**:
- All builder methods tested for immutability
- Default values validated
- Configuration chaining works correctly
- Tests pass without Docker (unit tests only)

### Step 8: Integration Tests

**File**: `/Tests/TestContainersModulesTests/Nginx/NginxIntegrationTests.swift`

Add integration tests (opt-in via environment variable):

```swift
@Test func nginxStartsAndServesDefaultPage() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nginx = NginxContainer()

    try await nginx.run { container in
        let url = try await container.url()
        #expect(!url.isEmpty)
        #expect(url.hasPrefix("http://"))

        // Make HTTP request
        let (data, response) = try await URLSession.shared.data(from: URL(string: url)!)
        let httpResponse = response as! HTTPURLResponse

        #expect(httpResponse.statusCode == 200)
        let body = String(data: data, encoding: .utf8)!
        #expect(body.contains("nginx"))
    }
}

@Test func nginxServeStaticFilesFromHost() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create temp directory with test HTML file
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let testHTML = tempDir.appendingPathComponent("index.html")
    try "Hello from test files!".write(to: testHTML, atomically: true, encoding: .utf8)

    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    let nginx = NginxContainer()
        .withStaticFiles(from: tempDir.path)

    try await nginx.run { container in
        let url = try await container.url()
        let (data, response) = try await URLSession.shared.data(from: URL(string: url)!)

        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 200)

        let body = String(data: data, encoding: .utf8)!
        #expect(body.contains("Hello from test files!"))
    }
}

@Test func nginxWithCustomConfigFile() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create custom nginx config in temp file
    let customConfig = """
    server {
        listen 80;
        location / {
            return 200 'Custom Nginx Config Works!';
            add_header Content-Type text/plain;
        }
    }
    """

    let tempConfig = FileManager.default.temporaryDirectory
        .appendingPathComponent("custom-nginx.conf")
    try customConfig.write(to: tempConfig, atomically: true, encoding: .utf8)

    defer {
        try? FileManager.default.removeItem(at: tempConfig)
    }

    let nginx = NginxContainer()
        .withConfigFile(tempConfig.path, as: "custom.conf")

    try await nginx.run { container in
        let url = try await container.url()
        let (data, response) = try await URLSession.shared.data(from: URL(string: url)!)

        let body = String(data: data, encoding: .utf8)!
        #expect(body.contains("Custom Nginx Config Works!"))
    }
}

@Test func nginxPortMapping() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nginx = NginxContainer()

    try await nginx.run { container in
        let port = try await container.port()
        #expect(port > 0)

        let endpoint = try await container.endpoint()
        #expect(endpoint.contains(":"))
        #expect(endpoint.contains("\(port)"))
    }
}
```

**Acceptance Criteria**:
- All integration tests pass with real Docker
- Tests clean up containers properly
- Tests handle errors gracefully
- Tests run in isolation (no shared state)

### Step 9: Advanced Features (Future)

**Reverse Proxy Helper** (optional enhancement):

```swift
// Future API idea
extension NginxContainer {
    public func withReverseProxy(
        to backend: String,
        path: String = "/",
        headers: [String: String] = [:]
    ) -> Self {
        // Generate nginx config for reverse proxy
        // Mount as config file
    }
}
```

**Health Check Endpoint** (optional):

```swift
extension NginxContainer {
    public func withHealthCheck(path: String = "/health") -> Self {
        // Add health check endpoint configuration
    }
}
```

---

## Testing Plan

### Unit Tests

**Location**: `/Tests/TestContainersModulesTests/Nginx/NginxContainerTests.swift`

| Test Case | Purpose | Expected Result |
|-----------|---------|-----------------|
| `defaultConfiguration` | Verify default settings | Image is nginx:alpine, port 80 exposed |
| `customImage` | Verify custom image support | Uses specified image |
| `builderImmutability` | Verify copy-on-write | Original unchanged after builder call |
| `portConfiguration` | Verify port exposure | Ports correctly configured |
| `environmentVariables` | Verify env var builder | Environment properly set |
| `waitStrategyOverride` | Verify custom wait strategy | Wait strategy can be changed |

### Integration Tests

**Location**: `/Tests/TestContainersModulesTests/Nginx/NginxIntegrationTests.swift`

| Test Case | Docker Required | Purpose | Verification |
|-----------|----------------|---------|--------------|
| `nginxStartsWithDefaults` | Yes | Basic container startup | Container starts, serves default page |
| `nginxServeStaticFiles` | Yes | Static file mounting | Files from host accessible via HTTP |
| `nginxCustomConfig` | Yes | Custom config mounting | Custom nginx.conf applied |
| `nginxMultipleConfigs` | Yes | Multiple config files | All configs loaded in conf.d |
| `nginxPortMapping` | Yes | Port resolution | Correct host port mapped |
| `nginxUrlHelpers` | Yes | URL generation | url() and url(path:) work correctly |
| `nginxLogs` | Yes | Log access | Container logs retrievable |
| `nginxWaitStrategy` | Yes | Wait strategy | Container ready before operation |

### Manual Testing Scenarios

1. **Production-like Static Site**:
   - Mount actual website files
   - Verify all assets load (CSS, JS, images)
   - Check browser dev tools for errors

2. **Reverse Proxy to Backend**:
   - Start application container
   - Configure Nginx as reverse proxy
   - Verify requests proxied correctly

3. **HTTPS Configuration** (advanced):
   - Mount SSL certificates
   - Configure HTTPS in nginx.conf
   - Verify TLS connection

4. **Performance Testing**:
   - Large number of static files
   - Concurrent requests
   - Container startup time

---

## Acceptance Criteria

### Must Have

- [x] `NginxContainer` struct implemented with builder pattern
- [x] Default configuration (nginx:alpine, port 80, HTTP wait strategy)
- [x] `withCustomConfig(_:)` method for custom nginx.conf
- [x] `withConfigFile(_:as:)` method for conf.d files
- [x] `withStaticFiles(from:at:)` method for serving static content
- [x] `RunningNginxContainer` with typed accessors
- [x] `url()` method returning HTTP URL
- [x] `url(path:)` method for custom paths
- [x] `endpoint()`, `port()`, `logs()` convenience methods
- [x] `run(operation:)` helper for container lifecycle
- [x] Unit tests with >80% code coverage
- [x] Integration tests with real Nginx container
- [x] SwiftDoc comments on all public APIs
- [ ] README.md updated with NginxContainer example
- [x] FEATURES.md updated to mark as implemented

### Should Have

- [x] Support for multiple configuration files
- [ ] File existence validation before container start
- [ ] Helpful error messages for common mistakes
- [x] Examples for common use cases (static files, reverse proxy)
- [ ] Cross-platform testing (macOS, Linux)

### Nice to Have

- [ ] Reverse proxy helper method with config generation
- [ ] Health check endpoint configuration
- [ ] Support for HTTPS/TLS configuration
- [ ] Performance benchmarks
- [ ] Advanced nginx configuration examples

### Definition of Done

- All "Must Have" criteria completed
- All "Should Have" criteria completed
- All tests passing (unit + integration)
- Code review completed
- Documentation reviewed and complete
- Manually tested with at least 3 different scenarios
- No regressions in core TestContainers functionality
- Follows Swift API design guidelines
- Consistent with testcontainers-go patterns
- Module can be imported and used independently

---

## Dependencies & Blockers

### Required Features

1. **Feature 001: HTTP Wait Strategy** (Recommended)
   - Default wait strategy for Nginx
   - Without this: fallback to TCP wait strategy
   - Status: Planned (Tier 1)

2. **Feature 012: Volume Mounts** (Recommended)
   - Required for `withStaticFiles(from:at:)`
   - Without this: limited to copying files via Feature 008
   - Status: Planned (Tier 2)

3. **Bind Mounts Support** (Critical)
   - Required for mounting config files and static directories
   - Alternative: Feature 008 (Copy Files to Container)
   - Status: Planned (Tier 2)

### Implementation Order

**Option A: Wait for Dependencies** (Recommended)
1. Implement Feature 001 (HTTP Wait Strategy)
2. Implement bind mounts or Feature 012 (Volume Mounts)
3. Implement NginxContainer with full feature set

**Option B: Incremental Implementation**
1. Implement basic NginxContainer with TCP wait strategy
2. Add HTTP wait strategy when Feature 001 complete
3. Add file mounting when bind mounts/volumes available
4. Ship minimal version early, iterate with enhancements

**Option C: Workarounds**
1. Use Feature 008 (Copy Files) instead of bind mounts
2. Generate config in temp files, copy to container
3. More complex but unblocks development

**Recommendation**: Option A for cleanest implementation

---

## Migration & Compatibility

### Migration from Generic API

**Before** (using generic ContainerRequest):
```swift
let request = ContainerRequest(image: "nginx:alpine")
    .withExposedPort(80)
    .waitingFor(.tcpPort(80))

try await withContainer(request) { container in
    let endpoint = try await container.endpoint(for: 80)
    let url = "http://\(endpoint)"
    // Use url...
}
```

**After** (using NginxContainer):
```swift
let nginx = NginxContainer()

try await nginx.run { container in
    let url = try await container.url()
    // Use url...
}
```

**Compatibility**: Generic API remains unchanged, NginxContainer is additive.

### Versioning

- Module version should match TestContainers core version
- Introduce in version 0.2.0 or later (after bind mounts support)
- Semantic versioning for API changes

---

## Future Enhancements

### Additional Module Methods

1. **withSSL(certPath:keyPath:)**: Configure HTTPS
2. **withBasicAuth(user:password:)**: Add HTTP basic auth
3. **withRateLimit(requests:window:)**: Configure rate limiting
4. **withCompression(types:)**: Enable gzip compression
5. **withCORS(origins:)**: Configure CORS headers

### Other Container Modules

Following NginxContainer as template:

- **PostgresContainer**: Connection strings, init scripts, custom config
- **RedisContainer**: Connection strings, persistence, cluster mode
- **MySQLContainer**: Connection strings, init SQL, character sets
- **MongoDBContainer**: Connection strings, replica sets
- **ElasticsearchContainer**: REST API endpoint, index management

### Module System Infrastructure

- Common base protocol for all modules: `ContainerModule`
- Shared utilities for config generation
- Template for creating new modules
- Module discovery and documentation

---

## References

### External Documentation

- **Nginx Official Docs**: https://nginx.org/en/docs/
- **Nginx Docker Hub**: https://hub.docker.com/_/nginx
- **Testcontainers Go Nginx**: https://golang.testcontainers.org/examples/nginx/
- **Testcontainers Java Nginx**: https://java.testcontainers.org/modules/nginx/

### Internal Code References

- `/Sources/TestContainers/ContainerRequest.swift` - Builder pattern reference
- `/Sources/TestContainers/Container.swift` - Container lifecycle
- `/Sources/TestContainers/WithContainer.swift` - Scoped lifecycle helper
- `/Tests/TestContainersTests/DockerIntegrationTests.swift` - Integration test patterns
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/features/001-http-wait-strategy.md` - HTTP wait dependency
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/features/012-volume-mounts.md` - Volume mount patterns

### Related Features

- Feature 001: HTTP/HTTPS Wait Strategy
- Feature 008: Copy Files to Container
- Feature 012: Volume Mounts (Named Volumes)
- Feature 011: Bind Mounts (planned)

---

## Implementation Checklist

### Setup
- [x] Created NginxContainer in `/Sources/TestContainers/` (kept in main module for simplicity)
- [x] Added tests to existing `TestContainersTests` target
- [x] Create test directories

### Core Implementation
- [x] Implement `NginxContainer` struct
- [x] Add `init(image:)` with defaults
- [x] Implement `withCustomConfig(_:)` method
- [x] Implement `withConfigFile(_:as:)` method
- [x] Implement `withStaticFiles(from:at:)` method
- [x] Implement builder delegation methods (port, env, wait)
- [x] Implement `RunningNginxContainer` struct
- [x] Implement `url()` and `url(path:)` methods
- [x] Implement convenience accessors
- [x] Implement `run(operation:)` helper

### Testing
- [x] Write unit tests for default configuration
- [x] Write unit tests for builder immutability
- [x] Write unit tests for all builder methods
- [x] Write integration test for basic startup
- [x] Write integration test for static files
- [x] Write integration test for custom config
- [x] Write integration test for URL helpers
- [x] Verify all tests pass

### Documentation
- [x] Add SwiftDoc comments to all public APIs
- [x] Write usage examples in documentation
- [ ] Update README.md with NginxContainer section
- [x] Update FEATURES.md (move NginxContainer to Implemented)
- [x] Create example test files
- [x] Review documentation for clarity

### Quality Assurance
- [x] Manual test: static website serving
- [x] Manual test: custom nginx.conf
- [x] Manual test: multiple config files
- [ ] Code review
- [x] Performance check (startup time, resource usage)
- [ ] Cross-platform testing (macOS, Linux if available)

### Release
- [x] Merge to main branch
- [ ] Tag version
- [ ] Update changelog
- [ ] Announce in project updates

---

**Created**: 2025-12-15
**Last Updated**: 2025-12-15
**Assignee**: TBD
**Target Version**: 0.3.0 (after bind mounts support)
**Estimated Effort**: 8-12 hours
