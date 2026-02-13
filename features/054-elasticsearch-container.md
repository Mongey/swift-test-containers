# Feature #054: ElasticsearchContainer / OpenSearchContainer

## Summary

Implement pre-configured container modules for Elasticsearch and OpenSearch in swift-test-containers. These specialized containers will provide typed Swift APIs with sensible defaults, security configuration helpers, connection URL generation, and appropriate wait strategies for cluster health readiness.

Both containers share common patterns but differ in authentication defaults, TLS support, and cluster configuration. This feature provides first-class support for testing applications that depend on Elasticsearch or OpenSearch search engines.

## Current State

### Generic Container API

Currently, users must manually configure Elasticsearch/OpenSearch containers using the generic `ContainerRequest` API:

```swift
// Current approach - verbose and error-prone
let request = ContainerRequest(image: "elasticsearch:8.11.0")
    .withExposedPort(9200)
    .withEnvironment([
        "discovery.type": "single-node",
        "xpack.security.enabled": "false",
        "ES_JAVA_OPTS": "-Xms512m -Xmx512m"
    ])
    .waitingFor(.tcpPort(9200))

try await withContainer(request) { container in
    let port = try await container.hostPort(9200)
    let url = "http://localhost:\(port)"
    // Must manually construct connection details
}
```

### Current Limitations

- **No typed API**: Users must remember environment variables and configuration keys
- **No default security setup**: Requires manual configuration of security settings
- **Manual URL construction**: No helper to get connection endpoints
- **Inadequate wait strategy**: TCP port doesn't guarantee cluster is ready for queries
- **No certificate handling**: No support for Elasticsearch 8+ TLS certificates
- **No cluster health checks**: Cannot verify cluster status before running tests
- **Version-specific quirks**: Users must handle differences between ES versions manually

### Architecture Context

The swift-test-containers library currently has:

- **Fluent builder pattern**: `ContainerRequest` with chainable `withX()` methods (see `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`)
- **Actor-based containers**: `Container` actor providing async-safe operations (see `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`)
- **Wait strategies**: Enum-based wait strategy pattern with `.none`, `.tcpPort`, `.logContains` (lines 20-24 in `ContainerRequest.swift`)
- **Scoped lifecycle**: `withContainer(_:_:)` ensures cleanup (see `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`)

## Requirements

### Functional Requirements

#### ElasticsearchContainer

1. **Default Image Support**:
   - Support Elasticsearch 7.x and 8.x images
   - Default to stable version (e.g., `"elasticsearch:8.11.0"`)
   - Allow custom image override

2. **Security Configuration**:
   - **Version-aware defaults**:
     - ES 8.x: Security enabled by default, requires password
     - ES 7.x: Security disabled by default
   - **Password configuration**: Allow setting custom password (default: `"changeme"`)
   - **Username configuration**: Fixed username `"elastic"` for ES 8+
   - **TLS/Certificate handling**:
     - ES 8+: Automatically expose CA certificate for HTTPS connections
     - Provide method to retrieve CA certificate bytes
   - **Security disabling**: Option to disable security for development

3. **Cluster Configuration**:
   - Set `discovery.type=single-node` by default
   - Configure JVM heap size defaults (`-Xms512m -Xmx512m`)
   - Allow overriding cluster settings

4. **Connection Helpers**:
   - `httpAddress() async throws -> String`: Returns `http://host:port` or `https://host:port`
   - `settings() async throws -> ElasticsearchSettings`: Returns structured connection details
   - Settings should include: address, username, password, caCert (optional)

5. **Wait Strategy**:
   - Wait for cluster health endpoint: `GET /_cluster/health`
   - Verify status is `green` or `yellow` before returning
   - Default timeout: 60 seconds
   - HTTP wait strategy (depends on Feature #001)

#### OpenSearchContainer

1. **Default Image Support**:
   - Support OpenSearch 2.x images
   - Default to stable version (e.g., `"opensearchproject/opensearch:2.11.1"`)
   - Allow custom image override

2. **Security Configuration**:
   - **Default credentials**: Username `"admin"`, password `"admin"`
   - **Custom credentials**: Allow override via `withUsername()` and `withPassword()`
   - **Security plugin**: Default security plugin enabled
   - **TLS**: Currently not supported (HTTP only per testcontainers-go docs)
   - **Version awareness**: OpenSearch 2.12+ requires `OPENSEARCH_INITIAL_ADMIN_PASSWORD`

3. **Cluster Configuration**:
   - Set `discovery.type=single-node` by default
   - Disable security demo configuration: `DISABLE_INSTALL_DEMO_CONFIG=true`
   - Configure JVM heap size defaults (`-Xms512m -Xmx512m`)

4. **Connection Helpers**:
   - `httpAddress() async throws -> String`: Returns `http://host:port`
   - Settings structure with username, password, address

5. **Wait Strategy**:
   - Wait for cluster health endpoint: `GET /_cluster/health`
   - Verify cluster is responding before returning
   - Default timeout: 60 seconds

### Non-Functional Requirements

1. **Type Safety**: Leverage Swift's type system for configuration validation
2. **Sendable Conformance**: All types must be `Sendable` for actor safety
3. **Backward Compatibility**: Build on existing `ContainerRequest` and `Container` APIs
4. **Documentation**: Comprehensive inline documentation with usage examples
5. **Testing**: Both unit tests and Docker integration tests
6. **Performance**: Minimal overhead compared to generic container approach

### Dependencies

- **Feature #001 (HTTP Wait Strategy)**: Required for cluster health endpoint checks
- **Alternative**: Use log-based wait strategy as interim solution (wait for "started" log message)

## API Design

### ElasticsearchContainer

```swift
/// Pre-configured Elasticsearch container with security, cluster settings, and health checks.
///
/// Example usage:
/// ```swift
/// let container = try await ElasticsearchContainer()
///     .withPassword("testpass")
///     .start()
///
/// let settings = try await container.settings()
/// let client = ElasticsearchClient(url: settings.address,
///                                    username: settings.username,
///                                    password: settings.password,
///                                    caCert: settings.caCert)
/// ```
public struct ElasticsearchContainer: Sendable {
    /// The underlying container request
    private let request: ContainerRequest

    /// Default Elasticsearch image
    public static let defaultImage = "elasticsearch:8.11.0"

    /// Default HTTP port
    public static let defaultPort = 9200

    /// Creates a new Elasticsearch container with default configuration.
    /// - Parameter image: Docker image to use (default: "elasticsearch:8.11.0")
    public init(image: String = defaultImage) {
        self.request = ContainerRequest(image: image)
            .withExposedPort(Self.defaultPort)
            .withEnvironment([
                "discovery.type": "single-node",
                "ES_JAVA_OPTS": "-Xms512m -Xmx512m"
            ])
    }

    /// Sets a custom password for the 'elastic' user (Elasticsearch 8+).
    /// - Parameter password: Password for authentication
    /// - Returns: Modified container configuration
    public func withPassword(_ password: String) -> Self {
        var copy = self
        copy.request = copy.request.withEnvironment([
            "ELASTIC_PASSWORD": password,
            "xpack.security.enabled": "true"
        ])
        return copy
    }

    /// Disables security features (not recommended for production-like tests).
    /// - Returns: Modified container configuration
    public func withSecurityDisabled() -> Self {
        var copy = self
        copy.request = copy.request.withEnvironment([
            "xpack.security.enabled": "false"
        ])
        return copy
    }

    /// Overrides default JVM heap size.
    /// - Parameters:
    ///   - min: Minimum heap size (e.g., "512m", "1g")
    ///   - max: Maximum heap size (e.g., "512m", "1g")
    /// - Returns: Modified container configuration
    public func withJvmHeap(min: String, max: String) -> Self {
        var copy = self
        copy.request = copy.request.withEnvironment([
            "ES_JAVA_OPTS": "-Xms\(min) -Xmx\(max)"
        ])
        return copy
    }

    /// Adds custom Elasticsearch configuration.
    /// - Parameter config: Dictionary of Elasticsearch settings
    /// - Returns: Modified container configuration
    public func withConfiguration(_ config: [String: String]) -> Self {
        var copy = self
        copy.request = copy.request.withEnvironment(config)
        return copy
    }

    /// Accesses the underlying container request for advanced customization.
    /// - Parameter modifier: Closure to modify the request
    /// - Returns: Modified container configuration
    public func withRequest(_ modifier: (ContainerRequest) -> ContainerRequest) -> Self {
        var copy = self
        copy.request = modifier(copy.request)
        return copy
    }

    /// Starts the container and waits for it to be ready.
    /// - Returns: Running Elasticsearch container
    public func start() async throws -> RunningElasticsearchContainer {
        let request = self.request
            .waitingFor(.logContains("started", timeout: .seconds(90))) // Interim until HTTP wait available

        return try await withContainer(request) { container in
            RunningElasticsearchContainer(
                container: container,
                password: extractPassword(from: request),
                securityEnabled: isSecurityEnabled(request)
            )
        }
    }

    // Helper methods
    private func extractPassword(from request: ContainerRequest) -> String {
        request.environment["ELASTIC_PASSWORD"] ?? "changeme"
    }

    private func isSecurityEnabled(_ request: ContainerRequest) -> Bool {
        request.environment["xpack.security.enabled"] != "false"
    }
}

/// A running Elasticsearch container with connection methods.
public actor RunningElasticsearchContainer {
    private let container: Container
    private let password: String
    private let securityEnabled: Bool

    init(container: Container, password: String, securityEnabled: Bool) {
        self.container = container
        self.password = password
        self.securityEnabled = securityEnabled
    }

    /// Returns the HTTP(S) address to connect to Elasticsearch.
    /// - Returns: URL string in format "http://host:port" or "https://host:port"
    public func httpAddress() async throws -> String {
        let endpoint = try await container.endpoint(for: ElasticsearchContainer.defaultPort)
        let scheme = securityEnabled ? "https" : "http"
        return "\(scheme)://\(endpoint)"
    }

    /// Returns structured connection settings for Elasticsearch.
    /// - Returns: Settings with address, credentials, and certificate (if security enabled)
    public func settings() async throws -> ElasticsearchSettings {
        let address = try await httpAddress()
        let caCert = securityEnabled ? try await extractCACertificate() : nil

        return ElasticsearchSettings(
            address: address,
            username: "elastic",
            password: password,
            caCert: caCert
        )
    }

    /// Retrieves container logs.
    /// - Returns: Container log output
    public func logs() async throws -> String {
        try await container.logs()
    }

    /// Terminates the container.
    public func terminate() async throws {
        try await container.terminate()
    }

    // Private helpers
    private func extractCACertificate() async throws -> Data? {
        // This would require exec() feature to extract cert from container
        // For now, return nil - to be implemented with Feature #007
        return nil
    }
}

/// Connection settings for Elasticsearch.
public struct ElasticsearchSettings: Sendable {
    /// The HTTP(S) address (e.g., "https://localhost:32768")
    public let address: String

    /// Username for authentication (always "elastic")
    public let username: String

    /// Password for authentication
    public let password: String

    /// CA certificate for TLS connections (Elasticsearch 8+ with security enabled)
    public let caCert: Data?
}
```

### OpenSearchContainer

```swift
/// Pre-configured OpenSearch container with security and cluster settings.
///
/// Example usage:
/// ```swift
/// let container = try await OpenSearchContainer()
///     .withUsername("testuser")
///     .withPassword("testpass")
///     .start()
///
/// let address = try await container.httpAddress()
/// let client = OpenSearchClient(url: address, username: "testuser", password: "testpass")
/// ```
public struct OpenSearchContainer: Sendable {
    /// The underlying container request
    private let request: ContainerRequest
    private let username: String
    private let password: String

    /// Default OpenSearch image
    public static let defaultImage = "opensearchproject/opensearch:2.11.1"

    /// Default HTTP port
    public static let defaultPort = 9200

    /// Creates a new OpenSearch container with default configuration.
    /// - Parameter image: Docker image to use (default: "opensearchproject/opensearch:2.11.1")
    public init(image: String = defaultImage) {
        self.username = "admin"
        self.password = "admin"
        self.request = ContainerRequest(image: image)
            .withExposedPort(Self.defaultPort)
            .withEnvironment([
                "discovery.type": "single-node",
                "OPENSEARCH_JAVA_OPTS": "-Xms512m -Xmx512m",
                "DISABLE_INSTALL_DEMO_CONFIG": "true",
                "OPENSEARCH_INITIAL_ADMIN_PASSWORD": "admin" // Required for 2.12+
            ])
    }

    /// Sets custom username for OpenSearch authentication.
    /// - Parameter username: Username for authentication
    /// - Returns: Modified container configuration
    public func withUsername(_ username: String) -> Self {
        var copy = self
        copy.username = username
        return copy
    }

    /// Sets custom password for OpenSearch authentication.
    /// - Parameter password: Password for authentication
    /// - Returns: Modified container configuration
    public func withPassword(_ password: String) -> Self {
        var copy = self
        copy.password = password
        copy.request = copy.request.withEnvironment([
            "OPENSEARCH_INITIAL_ADMIN_PASSWORD": password
        ])
        return copy
    }

    /// Disables the security plugin (not recommended).
    /// - Returns: Modified container configuration
    public func withSecurityDisabled() -> Self {
        var copy = self
        copy.request = copy.request.withEnvironment([
            "DISABLE_SECURITY_PLUGIN": "true"
        ])
        return copy
    }

    /// Overrides default JVM heap size.
    /// - Parameters:
    ///   - min: Minimum heap size (e.g., "512m", "1g")
    ///   - max: Maximum heap size (e.g., "512m", "1g")
    /// - Returns: Modified container configuration
    public func withJvmHeap(min: String, max: String) -> Self {
        var copy = self
        copy.request = copy.request.withEnvironment([
            "OPENSEARCH_JAVA_OPTS": "-Xms\(min) -Xmx\(max)"
        ])
        return copy
    }

    /// Adds custom OpenSearch configuration.
    /// - Parameter config: Dictionary of OpenSearch settings
    /// - Returns: Modified container configuration
    public func withConfiguration(_ config: [String: String]) -> Self {
        var copy = self
        copy.request = copy.request.withEnvironment(config)
        return copy
    }

    /// Accesses the underlying container request for advanced customization.
    /// - Parameter modifier: Closure to modify the request
    /// - Returns: Modified container configuration
    public func withRequest(_ modifier: (ContainerRequest) -> ContainerRequest) -> Self {
        var copy = self
        copy.request = modifier(copy.request)
        return copy
    }

    /// Starts the container and waits for it to be ready.
    /// - Returns: Running OpenSearch container
    public func start() async throws -> RunningOpenSearchContainer {
        let request = self.request
            .waitingFor(.logContains("started", timeout: .seconds(90))) // Interim until HTTP wait available

        return try await withContainer(request) { container in
            RunningOpenSearchContainer(
                container: container,
                username: username,
                password: password
            )
        }
    }
}

/// A running OpenSearch container with connection methods.
public actor RunningOpenSearchContainer {
    private let container: Container
    private let username: String
    private let password: String

    init(container: Container, username: String, password: String) {
        self.container = container
        self.username = username
        self.password = password
    }

    /// Returns the HTTP address to connect to OpenSearch.
    /// - Returns: URL string in format "http://host:port"
    public func httpAddress() async throws -> String {
        let endpoint = try await container.endpoint(for: OpenSearchContainer.defaultPort)
        return "http://\(endpoint)"
    }

    /// Returns structured connection settings for OpenSearch.
    /// - Returns: Settings with address and credentials
    public func settings() async throws -> OpenSearchSettings {
        let address = try await httpAddress()
        return OpenSearchSettings(
            address: address,
            username: username,
            password: password
        )
    }

    /// Retrieves container logs.
    /// - Returns: Container log output
    public func logs() async throws -> String {
        try await container.logs()
    }

    /// Terminates the container.
    public func terminate() async throws {
        try await container.terminate()
    }
}

/// Connection settings for OpenSearch.
public struct OpenSearchSettings: Sendable {
    /// The HTTP address (e.g., "http://localhost:32768")
    public let address: String

    /// Username for authentication
    public let username: String

    /// Password for authentication
    public let password: String
}
```

## Implementation Steps

### Step 1: Create Module Directory Structure

**Action**: Set up the modules directory and file structure

- Create `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Modules/` directory
- Create `ElasticsearchContainer.swift` in modules directory
- Create `OpenSearchContainer.swift` in modules directory

**Rationale**: Separate modules from core library for maintainability and future expansion

### Step 2: Implement ElasticsearchContainer

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Modules/ElasticsearchContainer.swift`

1. Define `ElasticsearchContainer` struct with builder pattern
2. Implement configuration methods:
   - `withPassword(_:)`
   - `withSecurityDisabled()`
   - `withJvmHeap(min:max:)`
   - `withConfiguration(_:)`
   - `withRequest(_:)`
3. Implement `start()` method that creates and returns `RunningElasticsearchContainer`
4. Define `RunningElasticsearchContainer` actor
5. Implement connection methods:
   - `httpAddress()`
   - `settings()`
   - `logs()`
   - `terminate()`
6. Define `ElasticsearchSettings` struct with address, username, password, caCert

**Key Decisions**:
- Use `Sendable` struct for configuration, actor for running instance
- Store security state and password for later connection string generation
- Use log-based wait strategy initially (can upgrade to HTTP wait once Feature #001 is implemented)
- CA certificate extraction deferred until Feature #007 (exec) is available

### Step 3: Implement OpenSearchContainer

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Modules/OpenSearchContainer.swift`

1. Define `OpenSearchContainer` struct with builder pattern
2. Implement configuration methods:
   - `withUsername(_:)`
   - `withPassword(_:)`
   - `withSecurityDisabled()`
   - `withJvmHeap(min:max:)`
   - `withConfiguration(_:)`
   - `withRequest(_:)`
3. Implement `start()` method that creates and returns `RunningOpenSearchContainer`
4. Define `RunningOpenSearchContainer` actor
5. Implement connection methods:
   - `httpAddress()`
   - `settings()`
   - `logs()`
   - `terminate()`
6. Define `OpenSearchSettings` struct with address, username, password

**Key Decisions**:
- Track username and password as separate properties (not just in environment)
- Default to HTTP only (no TLS support)
- Handle OpenSearch 2.12+ requirement for `OPENSEARCH_INITIAL_ADMIN_PASSWORD`

### Step 4: Add Comprehensive Documentation

**Files**: All module files

- Add module-level documentation explaining purpose and use cases
- Document all public methods with parameter descriptions and return values
- Include usage examples in doc comments
- Add warnings for security-disabled modes
- Document version-specific behavior (ES 7 vs 8, OpenSearch 2.12+)

### Step 5: Create Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ElasticsearchContainerTests.swift` (new)

1. **Configuration Tests**:
   - Test default initialization
   - Test password configuration
   - Test security disabled mode
   - Test JVM heap customization
   - Test custom configuration merging
   - Test builder pattern chaining

2. **Settings Tests**:
   - Test `ElasticsearchSettings` structure
   - Test `OpenSearchSettings` structure
   - Verify Sendable conformance

3. **Request Generation Tests**:
   - Verify correct environment variables set
   - Verify correct ports exposed
   - Verify correct image used

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/OpenSearchContainerTests.swift` (new)

Similar test structure for OpenSearchContainer.

### Step 6: Create Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ElasticsearchIntegrationTests.swift` (new)

**Important**: Gate all integration tests with `TESTCONTAINERS_RUN_DOCKER_TESTS=1` environment check

1. **Basic Startup Test**:
   ```swift
   @Test func elasticsearchContainerStarts() async throws {
       guard ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1" else { return }

       let container = try await ElasticsearchContainer()
           .withSecurityDisabled()
           .start()

       let address = try await container.httpAddress()
       #expect(address.starts(with: "http://"))

       try await container.terminate()
   }
   ```

2. **Connection Test**:
   ```swift
   @Test func elasticsearchAcceptsConnections() async throws {
       guard ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1" else { return }

       let container = try await ElasticsearchContainer()
           .withSecurityDisabled()
           .start()

       let settings = try await container.settings()

       // Verify we can connect and get cluster info
       let url = URL(string: "\(settings.address)/")!
       let (data, _) = try await URLSession.shared.data(from: url)
       let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
       #expect(json?["cluster_name"] != nil)

       try await container.terminate()
   }
   ```

3. **Custom Password Test** (Elasticsearch 8+):
   ```swift
   @Test func elasticsearchWithCustomPassword() async throws {
       guard ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1" else { return }

       let container = try await ElasticsearchContainer(image: "elasticsearch:8.11.0")
           .withPassword("custom-test-password")
           .start()

       let settings = try await container.settings()
       #expect(settings.password == "custom-test-password")
       #expect(settings.username == "elastic")

       try await container.terminate()
   }
   ```

4. **Custom Configuration Test**:
   ```swift
   @Test func elasticsearchWithCustomConfig() async throws {
       guard ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1" else { return }

       let container = try await ElasticsearchContainer()
           .withSecurityDisabled()
           .withJvmHeap(min: "256m", max: "256m")
           .withConfiguration(["cluster.name": "test-cluster"])
           .start()

       let settings = try await container.settings()
       let url = URL(string: "\(settings.address)/")!
       let (data, _) = try await URLSession.shared.data(from: url)
       let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
       #expect(json?["cluster_name"] as? String == "test-cluster")

       try await container.terminate()
   }
   ```

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/OpenSearchIntegrationTests.swift` (new)

Similar integration tests for OpenSearchContainer:

1. **Basic Startup Test**: Verify container starts and returns valid HTTP address
2. **Connection Test**: Verify HTTP requests succeed to cluster info endpoint
3. **Custom Credentials Test**: Verify custom username/password configuration
4. **Version 2.12+ Test**: Verify `OPENSEARCH_INITIAL_ADMIN_PASSWORD` is set correctly

### Step 7: Update Package Exports

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Package.swift`

No changes needed - Swift automatically exports all public types from target.

### Step 8: Update Documentation

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/README.md`

Add examples showing ElasticsearchContainer and OpenSearchContainer usage:

```markdown
## Pre-configured Modules

### Elasticsearch

swift
import Testing
import TestContainers

@Test func testWithElasticsearch() async throws {
    let container = try await ElasticsearchContainer()
        .withSecurityDisabled()
        .start()

    let settings = try await container.settings()
    // Use settings.address, settings.username, settings.password
}


### OpenSearch

swift
import Testing
import TestContainers

@Test func testWithOpenSearch() async throws {
    let container = try await OpenSearchContainer()
        .withPassword("custom-password")
        .start()

    let address = try await container.httpAddress()
    // Connect to OpenSearch at address
}

```

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md`

Update the "Tier 4: Module System" section:
- Change `[ ] ElasticsearchContainer / OpenSearchContainer` to `[x] ElasticsearchContainer / OpenSearchContainer`

## Testing Plan

### Unit Tests

**Location**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ElasticsearchContainerTests.swift` and `OpenSearchContainerTests.swift`

1. **Builder Pattern Tests**:
   - Verify all `withX()` methods return modified copy
   - Verify method chaining works correctly
   - Verify configuration accumulates properly

2. **Default Value Tests**:
   - Verify default image names
   - Verify default ports
   - Verify default credentials (ES: "elastic"/"changeme", OS: "admin"/"admin")
   - Verify default environment variables

3. **Configuration Tests**:
   - Test password configuration sets correct environment variable
   - Test security disabled mode
   - Test JVM heap configuration
   - Test custom configuration merging
   - Test that custom config doesn't override critical settings

4. **Type Safety Tests**:
   - Verify `Sendable` conformance
   - Verify types are thread-safe

### Integration Tests (Docker Required)

**Location**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ElasticsearchIntegrationTests.swift` and `OpenSearchIntegrationTests.swift`

**Prerequisite**: Set `TESTCONTAINERS_RUN_DOCKER_TESTS=1`

#### Elasticsearch Integration Tests

1. **ES 7.x Tests**:
   - Test container starts with security disabled (default for 7.x)
   - Test cluster info endpoint responds
   - Test index creation and query
   - Test logs are accessible

2. **ES 8.x Tests**:
   - Test container starts with security enabled
   - Test custom password configuration
   - Test HTTPS endpoint returns valid address
   - Test connection with authentication
   - Test that settings include password

3. **Configuration Tests**:
   - Test custom cluster name
   - Test custom JVM heap sizes
   - Test custom environment variables

4. **Wait Strategy Tests**:
   - Verify container doesn't return until cluster is ready
   - Verify logs contain "started" message before completion

#### OpenSearch Integration Tests

1. **Basic Functionality**:
   - Test OpenSearch 2.x container starts
   - Test default credentials work
   - Test custom username/password
   - Test cluster health endpoint responds

2. **Version-Specific Tests**:
   - Test OpenSearch 2.12+ with required admin password
   - Verify `OPENSEARCH_INITIAL_ADMIN_PASSWORD` is set

3. **Security Tests**:
   - Test with security enabled (default)
   - Test with security disabled
   - Test authentication works with custom credentials

4. **Connection Tests**:
   - Test `httpAddress()` returns valid HTTP URL
   - Test `settings()` returns correct credentials
   - Test actual HTTP request succeeds

### Performance Tests

1. **Startup Time**:
   - Measure time from `start()` to ready state
   - Compare with raw `ContainerRequest` approach
   - Target: <10% overhead vs raw approach

2. **Memory Overhead**:
   - Verify module types don't significantly increase memory usage
   - Verify actor isolation doesn't cause contention

## Acceptance Criteria

### Must Have

- [x] `ElasticsearchContainer` struct with fluent API
- [x] `OpenSearchContainer` struct with fluent API
- [x] Default images for both containers
- [x] Security configuration methods (password, disable, etc.)
- [x] JVM heap configuration
- [x] Custom configuration support
- [x] `httpAddress()` method returning connection URL
- [x] `settings()` method returning structured connection details
- [x] Cluster name and single-node configuration by default
- [x] Appropriate wait strategy (log-based interim, HTTP when available)
- [x] All types are `Sendable`
- [x] Comprehensive inline documentation
- [x] Unit tests for configuration and builder pattern
- [x] Integration tests for both ES and OpenSearch
- [x] Version-aware defaults (ES 7 vs 8, OpenSearch 2.12+)
- [x] README examples
- [x] FEATURES.md updated

### Should Have

- [ ] HTTP wait strategy for cluster health (blocked by Feature #001)
- [ ] CA certificate extraction for ES 8+ TLS (blocked by Feature #007 - exec)
- [ ] Cluster health status verification (green/yellow)
- [ ] Support for multiple Elasticsearch versions (7.10+, 8.x)
- [ ] Support for multiple OpenSearch versions (2.x)
- [ ] Performance benchmarks vs raw ContainerRequest

### Nice to Have

- [ ] Index initialization helpers (create indices in hooks)
- [ ] Data loading helpers (bulk insert test data)
- [ ] Plugin installation support
- [ ] Snapshot/restore helpers for test data
- [ ] Multi-node cluster support (future)
- [ ] Network alias helpers for inter-container communication

## Dependencies

### Required Features

1. **Feature #001 (HTTP Wait Strategy)**:
   - **Status**: Planned (Tier 1)
   - **Impact**: Currently using log-based wait strategy as workaround
   - **Benefit**: Proper cluster health endpoint checking

2. **Feature #007 (Container Exec)**:
   - **Status**: Planned (Tier 1)
   - **Impact**: Cannot extract CA certificates from ES 8+ containers
   - **Benefit**: Enable full TLS support for Elasticsearch 8+

### Optional Enhancements

- **Feature #029 (Lifecycle Hooks)**: Could enable pre/post-start data loading
- **Feature #010 (Container Inspect)**: Could enable advanced configuration validation
- **Networking features**: Required for multi-node cluster support

## Risks and Mitigations

### Risk 1: Version-Specific Behavior Complexity

**Impact**: High
**Probability**: High

Different Elasticsearch and OpenSearch versions have different defaults and requirements:
- ES 7: Security disabled by default
- ES 8: Security enabled, requires password
- OpenSearch 2.12+: Requires `OPENSEARCH_INITIAL_ADMIN_PASSWORD`

**Mitigation**:
- Clearly document version-specific behavior in inline docs
- Provide sensible defaults that work across versions where possible
- Test against multiple versions in integration tests
- Consider version detection logic if needed

### Risk 2: Wait Strategy Inadequacy

**Impact**: Medium
**Probability**: Medium

Log-based wait strategy may not accurately reflect when cluster is ready for queries. The cluster might be "started" but not yet accepting requests or healthy.

**Mitigation**:
- Use conservative log patterns that indicate late-stage startup
- Set generous timeouts (90 seconds default)
- Document that HTTP wait strategy will improve reliability once available
- Add clear TODO comments for HTTP wait upgrade path

### Risk 3: TLS Certificate Handling

**Impact**: Medium
**Probability**: Low

Elasticsearch 8+ generates self-signed certificates on startup. Without exec() support, we cannot extract these certificates for client configuration.

**Mitigation**:
- Document that TLS support requires Feature #007
- Provide `withSecurityDisabled()` option for testing scenarios
- Return `nil` for `caCert` in `ElasticsearchSettings` until exec is available
- Add clear upgrade path in code comments

### Risk 4: Breaking Changes in Future Versions

**Impact**: Medium
**Probability**: Medium

Elasticsearch and OpenSearch may change default configurations or requirements in future versions.

**Mitigation**:
- Pin default images to known-stable versions
- Allow users to specify custom images
- Comprehensive integration tests that will catch breaking changes
- Document supported version ranges

### Risk 5: Memory and Resource Usage

**Impact**: Low
**Probability**: Low

Elasticsearch and OpenSearch are memory-intensive. Tests may fail on resource-constrained systems.

**Mitigation**:
- Set conservative JVM heap defaults (512m min/max)
- Allow heap size customization
- Document minimum system requirements
- Consider adding heap size helpers for CI/local environments

## Future Enhancements

### Enhanced Wait Strategies

Once Feature #001 is complete:
- Wait for cluster health endpoint: `GET /_cluster/health`
- Wait for specific health status (green/yellow/red)
- Wait for specific number of nodes
- Wait for all shards to be assigned

```swift
public func waitForClusterHealth(_ status: ClusterHealthStatus = .yellow) -> Self {
    var copy = self
    copy.request = copy.request.waitingFor(
        .http(
            port: Self.defaultPort,
            path: "/_cluster/health",
            statusCode: 200,
            responseMatches: { body in
                // Parse JSON and check status field
                return body.contains("\"status\":\"\(status.rawValue)\"")
            }
        )
    )
    return copy
}
```

### TLS Support

Once Feature #007 (exec) is complete:
- Extract CA certificate from container
- Return certificate in `ElasticsearchSettings`
- Provide helper to create SSL context
- Support custom certificates

```swift
private func extractCACertificate() async throws -> Data? {
    let certPath = "/usr/share/elasticsearch/config/certs/http_ca.crt"
    let result = try await container.exec(["cat", certPath])
    return result.stdout.data(using: .utf8)
}
```

### Index Management Helpers

```swift
public func withIndexTemplate(_ name: String, _ template: [String: Any]) -> Self {
    // Use lifecycle hooks to create index template after startup
}

public func withInitialData(_ indexName: String, _ documents: [[String: Any]]) -> Self {
    // Use lifecycle hooks to bulk insert documents after startup
}
```

### Plugin Support

```swift
public func withPlugin(_ pluginName: String) -> Self {
    // Install plugin during container build/startup
}
```

### Snapshot/Restore Helpers

```swift
public func exportSnapshot(to path: String) async throws {
    // Create snapshot and copy to host
}

public func importSnapshot(from path: String) async throws {
    // Copy snapshot from host and restore
}
```

### Multi-Node Cluster

```swift
public struct ElasticsearchCluster {
    public func withNodes(_ count: Int) -> Self
    public func start() async throws -> [RunningElasticsearchContainer]
}
```

## References

### Testcontainers Implementations

- **Testcontainers-go Elasticsearch**: [https://golang.testcontainers.org/modules/elasticsearch/](https://golang.testcontainers.org/modules/elasticsearch/)
- **Testcontainers-go OpenSearch**: [https://golang.testcontainers.org/modules/opensearch/](https://golang.testcontainers.org/modules/opensearch/)
- **Testcontainers Java Elasticsearch**: [https://java.testcontainers.org/modules/elasticsearch/](https://java.testcontainers.org/modules/elasticsearch/)
- **OpenSearch Testcontainers (Java)**: [https://github.com/opensearch-project/opensearch-testcontainers](https://github.com/opensearch-project/opensearch-testcontainers)

### Elasticsearch Documentation

- **Elasticsearch Docker**: https://www.elastic.co/guide/en/elasticsearch/reference/current/docker.html
- **Elasticsearch Configuration**: https://www.elastic.co/guide/en/elasticsearch/reference/current/settings.html
- **Elasticsearch Security**: https://www.elastic.co/guide/en/elasticsearch/reference/current/security-settings.html
- **Cluster Health API**: https://www.elastic.co/guide/en/elasticsearch/reference/current/cluster-health.html

### OpenSearch Documentation

- **OpenSearch Docker**: https://opensearch.org/docs/latest/install-and-configure/install-opensearch/docker/
- **OpenSearch Configuration**: https://opensearch.org/docs/latest/install-and-configure/configuration/
- **OpenSearch Security Plugin**: https://opensearch.org/docs/latest/security/
- **Cluster Health API**: https://opensearch.org/docs/latest/api-reference/cluster-api/cluster-health/

### Codebase References

- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` - Fluent builder pattern
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift` - Container actor API
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift` - Scoped lifecycle
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Waiter.swift` - Wait strategy execution
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/features/029-lifecycle-hooks.md` - Lifecycle hooks design
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/features/001-http-wait-strategy.md` - HTTP wait strategy design
