# Feature: MinioContainer Module

**Status**: IMPLEMENTED

**Implementation Date**: 2026-02-13

## Summary

Implement a pre-configured `MinioContainer` module for swift-test-containers that provides a type-safe, developer-friendly API for running MinIO (S3-compatible object storage) containers in tests. MinIO is a high-performance object storage solution that is API-compatible with Amazon S3, making it ideal for testing applications that interact with S3 without requiring actual AWS infrastructure.

This module will provide:
- Sensible defaults (image, ports, credentials)
- Helper methods for S3 endpoint URLs
- Automatic bucket creation support
- Type-safe credential management
- Proper wait strategies for container readiness
- Console/Web UI port exposure

## Current State

### Generic Container API

Currently, users must manually configure MinIO containers using the generic `ContainerRequest` API:

```swift
let request = ContainerRequest(image: "minio/minio:latest")
    .withExposedPort(9000)  // S3 API port
    .withExposedPort(9001)  // Console port
    .withEnvironment([
        "MINIO_ROOT_USER": "minioadmin",
        "MINIO_ROOT_PASSWORD": "minioadmin"
    ])
    .withCommand(["server", "/data", "--console-address", ":9001"])
    .waitingFor(.tcpPort(9000))

try await withContainer(request) { container in
    let port = try await container.hostPort(9000)
    let endpoint = "http://127.0.0.1:\(port)"
    // Manual S3 client configuration needed
}
```

This approach has several drawbacks:
1. **Boilerplate**: Requires manual configuration of ports, environment variables, and command arguments
2. **Error-prone**: Easy to forget critical settings like console address or proper wait strategy
3. **No helpers**: No built-in methods for S3 endpoint URLs or bucket operations
4. **Credentials scattered**: Access key and secret key management is manual
5. **Suboptimal wait**: TCP port check doesn't verify MinIO is actually ready to accept S3 requests

### Current Architecture

The library's architecture (from `FEATURES.md`, Tier 4) anticipates service-specific modules:
- Generic `Container` actor provides low-level operations
- `ContainerRequest` uses builder pattern for configuration
- Wait strategies are extensible via `WaitStrategy` enum
- The `withContainer(_:_:)` lifecycle helper ensures cleanup

No service-specific modules currently exist, so `MinioContainer` will be a reference implementation for future modules (PostgresContainer, RedisContainer, etc.).

## Requirements

### Core Functionality

1. **Default Configuration**
   - Default image: `minio/minio:latest` (with ability to override version)
   - Default S3 API port: 9000
   - Default Console port: 9001
   - Default credentials: `minioadmin` / `minioadmin` (with ability to customize)
   - Default command: `server /data --console-address :9001`

2. **Credential Management**
   - Type-safe access key (username) configuration
   - Type-safe secret key (password) configuration
   - Environment variable mapping: `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD`
   - Minimum password length validation (MinIO requires non-empty passwords)
   - Credential retrieval methods on container instance

3. **Port Management**
   - Expose S3 API port (9000) by default
   - Expose Console port (9001) optionally
   - Helper methods to get host-mapped ports
   - Helper methods to construct full endpoint URLs

4. **Endpoint Helpers**
   - `s3Endpoint()` -> Returns S3 API endpoint URL (e.g., "http://127.0.0.1:49152")
   - `consoleEndpoint()` -> Returns Console UI URL (e.g., "http://127.0.0.1:49153")
   - `connectionString()` -> Alias for `s3Endpoint()` (matches testcontainers-go API)

5. **Bucket Management** (Optional but valuable)
   - Configuration option to create buckets on startup
   - Support for multiple buckets
   - Use MinIO client (`mc`) via `docker exec` to create buckets after container starts

6. **Wait Strategy**
   - Smart default: HTTP wait on `/minio/health/ready` endpoint (requires Feature 001)
   - Fallback: TCP port wait on 9000 (if HTTP wait not yet implemented)
   - Configurable timeout and poll interval
   - Verify MinIO is ready to accept S3 requests, not just listening

7. **Configuration Options**
   - Custom image/tag override
   - Custom access key/secret key
   - Optional console port exposure
   - Optional initial buckets to create
   - Custom environment variables (for advanced use cases)

### Non-Functional Requirements

1. **Usability**
   - Minimal configuration needed for common cases
   - Builder pattern consistent with `ContainerRequest`
   - Clear, discoverable API
   - Comprehensive documentation and examples

2. **Compatibility**
   - Works with existing `Container` infrastructure
   - Integrates with `withContainer(_:_:)` lifecycle management
   - Compatible with Swift Concurrency (async/await)
   - Cross-platform (macOS, Linux)

3. **Maintainability**
   - Follow existing codebase patterns
   - Reuse `ContainerRequest` internally
   - Clear separation between configuration and runtime
   - Well-tested with unit and integration tests

4. **Feature Parity**
   - Matches capabilities of testcontainers-go MinIO module
   - Reference implementation for future service modules
   - Demonstrates best practices for module development

## API Design

### Proposed Swift API

```swift
// New MinioContainer module
// File: Sources/TestContainers/MinioContainer.swift

public struct MinioContainerRequest: Sendable, Hashable {
    public var image: String
    public var accessKey: String
    public var secretKey: String
    public var consoleEnabled: Bool
    public var buckets: [String]
    public var environment: [String: String]
    public var waitTimeout: Duration
    public var waitPollInterval: Duration

    public init(
        image: String = "minio/minio:latest",
        accessKey: String = "minioadmin",
        secretKey: String = "minioadmin"
    ) {
        self.image = image
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.consoleEnabled = true
        self.buckets = []
        self.environment = [:]
        self.waitTimeout = .seconds(60)
        self.waitPollInterval = .milliseconds(200)
    }

    // Builder methods
    public func withImage(_ image: String) -> Self
    public func withCredentials(accessKey: String, secretKey: String) -> Self
    public func withAccessKey(_ accessKey: String) -> Self
    public func withSecretKey(_ secretKey: String) -> Self
    public func withConsole(_ enabled: Bool) -> Self
    public func withBucket(_ bucket: String) -> Self
    public func withBuckets(_ buckets: [String]) -> Self
    public func withEnvironment(_ environment: [String: String]) -> Self
    public func withWaitTimeout(_ timeout: Duration) -> Self
    public func withWaitPollInterval(_ interval: Duration) -> Self

    // Internal: Convert to ContainerRequest
    func toContainerRequest() -> ContainerRequest
}

// Extension on Container for MinIO-specific helpers
extension Container {
    /// Returns the S3 API endpoint URL (e.g., "http://127.0.0.1:49152")
    public func s3Endpoint() async throws -> String

    /// Returns the Console/Web UI endpoint URL (e.g., "http://127.0.0.1:49153")
    /// Throws if console was not enabled in the request
    public func consoleEndpoint() async throws -> String

    /// Alias for s3Endpoint() for compatibility with testcontainers-go
    public func connectionString() async throws -> String

    /// Returns the access key (username) for this MinIO instance
    public func minioAccessKey() -> String

    /// Returns the secret key (password) for this MinIO instance
    public func minioSecretKey() -> String

    /// Creates a bucket in the running MinIO instance
    /// Requires docker exec capability (Feature 007)
    public func createBucket(_ bucket: String) async throws
}

// Top-level helper function (primary API)
public func withMinioContainer(
    _ request: MinioContainerRequest = MinioContainerRequest(),
    _ body: @Sendable (Container) async throws -> Void
) async throws
```

### Alternative API (Using Custom Container Type)

If a dedicated `MinioContainer` type is preferred over extending `Container`:

```swift
public actor MinioContainer {
    private let container: Container
    private let config: MinioContainerRequest

    // Delegate to underlying container
    public var id: String { container.id }

    // MinIO-specific helpers
    public func s3Endpoint() async throws -> String
    public func consoleEndpoint() async throws -> String
    public func connectionString() async throws -> String
    public var accessKey: String { config.accessKey }
    public var secretKey: String { config.secretKey }
    public func createBucket(_ bucket: String) async throws

    // Pass-through methods
    public func logs() async throws -> String
    public func terminate() async throws
}

public func withMinioContainer(
    _ request: MinioContainerRequest = MinioContainerRequest(),
    _ body: @Sendable (MinioContainer) async throws -> Void
) async throws
```

**Recommendation**: Use the extension-based approach initially for simplicity, migrate to dedicated type if needed.

### Usage Examples

```swift
import Testing
import TestContainers

// Example 1: Simplest usage with defaults
@Test func minioBasicUsage() async throws {
    try await withMinioContainer { container in
        let endpoint = try await container.s3Endpoint()
        let accessKey = container.minioAccessKey()
        let secretKey = container.minioSecretKey()

        // Configure S3 client with endpoint and credentials
        // Test S3 operations...
    }
}

// Example 2: Custom credentials
@Test func minioCustomCredentials() async throws {
    let request = MinioContainerRequest()
        .withCredentials(accessKey: "myuser", secretKey: "mypassword123")

    try await withMinioContainer(request) { container in
        let endpoint = try await container.s3Endpoint()
        #expect(container.minioAccessKey() == "myuser")
        // Test with custom credentials...
    }
}

// Example 3: Specific version and pre-created bucket
@Test func minioWithBucket() async throws {
    let request = MinioContainerRequest(
        image: "minio/minio:RELEASE.2024-01-16T16-07-38Z"
    )
    .withBucket("test-bucket")

    try await withMinioContainer(request) { container in
        let endpoint = try await container.s3Endpoint()
        // Bucket "test-bucket" already exists
        // Test bucket operations...
    }
}

// Example 4: Multiple buckets and console access
@Test func minioFullFeatures() async throws {
    let request = MinioContainerRequest()
        .withBuckets(["uploads", "exports", "backups"])
        .withConsole(true)

    try await withMinioContainer(request) { container in
        let s3 = try await container.s3Endpoint()
        let console = try await container.consoleEndpoint()

        // All three buckets exist
        // Console accessible at `console` URL
        // Test comprehensive S3 operations...
    }
}

// Example 5: Manual bucket creation
@Test func minioManualBucket() async throws {
    try await withMinioContainer { container in
        // Create bucket on-demand
        try await container.createBucket("my-new-bucket")

        let endpoint = try await container.s3Endpoint()
        // Test with dynamically created bucket...
    }
}

// Example 6: Integration with AWS SDK for Swift
@Test func minioWithAWSSDK() async throws {
    try await withMinioContainer { container in
        let endpoint = try await container.s3Endpoint()

        // Configure AWS SDK for Swift
        let config = try await S3Client.S3ClientConfiguration(
            region: "us-east-1",  // MinIO ignores region but SDK requires it
            endpoint: endpoint,
            useDualStack: false
        )

        let client = S3Client(config: config)
        client.config.credentialsProvider = .static(
            accessKey: container.minioAccessKey(),
            secret: container.minioSecretKey()
        )

        // Test S3 operations with AWS SDK
    }
}
```

## Implementation Steps

### 1. Create MinioContainerRequest Configuration

**File**: `/Sources/TestContainers/MinioContainer.swift`

- Define `MinioContainerRequest` struct with default values
- Implement builder pattern methods (`.withCredentials()`, `.withBucket()`, etc.)
- Add validation:
  - Secret key must not be empty (MinIO requirement)
  - Access key must not be empty
  - Bucket names must be valid S3 bucket names (lowercase, 3-63 chars, etc.)
- Implement `Sendable` and `Hashable` conformance
- Add comprehensive inline documentation

**Key considerations**:
- Store credentials in the request for later retrieval
- Validate credentials early (on construction/builder methods)
- Keep configuration immutable (builder returns new instance)

### 2. Implement toContainerRequest() Conversion

**File**: `/Sources/TestContainers/MinioContainer.swift`

- Convert `MinioContainerRequest` to generic `ContainerRequest`
- Set image from config
- Expose port 9000 (always)
- Conditionally expose port 9001 if console enabled
- Set environment variables:
  - `MINIO_ROOT_USER` = accessKey
  - `MINIO_ROOT_PASSWORD` = secretKey
  - Merge any custom environment variables
- Set command: `["server", "/data", "--console-address", ":9001"]`
- Set wait strategy:
  - **Preferred**: `.http(HTTPWaitConfig(port: 9000).withPath("/minio/health/ready"))` if Feature 001 implemented
  - **Fallback**: `.tcpPort(9000)` initially
- Add label: `"testcontainers.service": "minio"`

**Implementation pattern**:
```swift
func toContainerRequest() -> ContainerRequest {
    var env = environment
    env["MINIO_ROOT_USER"] = accessKey
    env["MINIO_ROOT_PASSWORD"] = secretKey

    var request = ContainerRequest(image: image)
        .withExposedPort(9000)
        .withEnvironment(env)
        .withCommand(["server", "/data", "--console-address", ":9001"])
        .withLabel("testcontainers.service", "minio")

    if consoleEnabled {
        request = request.withExposedPort(9001)
    }

    // Wait strategy - use HTTP if available, fallback to TCP
    #if FEATURE_001_HTTP_WAIT_AVAILABLE
    request = request.waitingFor(.http(
        HTTPWaitConfig(port: 9000)
            .withPath("/minio/health/ready")
            .withTimeout(waitTimeout)
            .withPollInterval(waitPollInterval)
    ))
    #else
    request = request.waitingFor(.tcpPort(
        9000,
        timeout: waitTimeout,
        pollInterval: waitPollInterval
    ))
    #endif

    return request
}
```

### 3. Add Container Extension Methods

**File**: `/Sources/TestContainers/MinioContainer.swift` (or separate extension file)

- Implement `s3Endpoint()`:
  - Get host port mapping for 9000
  - Construct URL: `"http://\(host):\(port)"`
  - Return string
- Implement `consoleEndpoint()`:
  - Verify console was enabled (check request metadata)
  - Get host port mapping for 9001
  - Construct URL: `"http://\(host):\(port)"`
  - Return string
- Implement `connectionString()` as alias to `s3Endpoint()`
- Implement credential getters:
  - Extract from container's request metadata
  - Stored during initialization

**Challenge**: Container actor doesn't store MinIO-specific config. Solutions:
1. **Preferred**: Store MinioContainerRequest in container's request via labels/metadata
2. **Alternative**: Return a custom MinioContainer wrapper that stores config
3. **Simple**: Use global/scoped storage keyed by container ID

**Recommended approach**: Store credentials in container labels during request creation, retrieve in helper methods.

### 4. Implement withMinioContainer() Helper

**File**: `/Sources/TestContainers/MinioContainer.swift`

- Create top-level `withMinioContainer(_:_:)` function
- Convert `MinioContainerRequest` to `ContainerRequest`
- Call `withContainer(_:_:)` internally
- After container starts, create initial buckets if specified
- Pass container to user's closure
- Ensure cleanup on success, error, or cancellation

**Implementation pattern**:
```swift
public func withMinioContainer(
    _ minioRequest: MinioContainerRequest = MinioContainerRequest(),
    _ body: @Sendable (Container) async throws -> Void
) async throws {
    let request = minioRequest.toContainerRequest()

    try await withContainer(request) { container in
        // Create initial buckets if specified
        for bucket in minioRequest.buckets {
            try await container.createBucket(bucket)
        }

        // Pass to user's closure
        try await body(container)
    }
}
```

### 5. Implement Bucket Creation (Depends on Feature 007: Container Exec)

**File**: `/Sources/TestContainers/MinioContainer.swift`

- Add `createBucket(_:)` method to Container extension
- Use `docker exec` to run MinIO client commands
- MinIO client (`mc`) is included in the MinIO image
- Command: `mc mb /data/{bucket-name}`

**Implementation pattern**:
```swift
public func createBucket(_ bucket: String) async throws {
    // Validate bucket name (S3 naming rules)
    guard isValidBucketName(bucket) else {
        throw TestContainersError.invalidBucketName(bucket)
    }

    // Use mc (MinIO client) bundled in the image
    // mc mb creates bucket in local filesystem mode
    let result = try await exec(["mc", "mb", "/data/\(bucket)"])

    guard result.exitCode == 0 else {
        throw TestContainersError.bucketCreationFailed(
            bucket: bucket,
            exitCode: result.exitCode,
            stderr: result.stderr
        )
    }
}

private func isValidBucketName(_ name: String) -> Bool {
    // S3 bucket naming rules
    // 3-63 characters, lowercase, numbers, hyphens, dots
    let regex = #"^[a-z0-9][a-z0-9\-\.]{1,61}[a-z0-9]$"#
    return name.range(of: regex, options: .regularExpression) != nil
}
```

**Note**: If Feature 007 (container exec) is not implemented, skip automatic bucket creation or implement a simpler approach using environment variables (if MinIO supports it).

### 6. Store Configuration in Container Metadata

**File**: `/Sources/TestContainers/MinioContainer.swift`

To retrieve MinIO-specific config (credentials, console flag) from the container:

- Store configuration in container labels during request creation
- Labels to add:
  - `"testcontainers.minio.accessKey": "{accessKey}"`
  - `"testcontainers.minio.secretKey": "{secretKey}"`
  - `"testcontainers.minio.consoleEnabled": "true|false"`

**Implementation**:
```swift
func toContainerRequest() -> ContainerRequest {
    // ... existing code ...

    request = request
        .withLabel("testcontainers.minio.accessKey", accessKey)
        .withLabel("testcontainers.minio.secretKey", secretKey)
        .withLabel("testcontainers.minio.consoleEnabled", consoleEnabled ? "true" : "false")

    return request
}

// Retrieval helpers
public func minioAccessKey() -> String {
    request.labels["testcontainers.minio.accessKey"] ?? "minioadmin"
}

public func minioSecretKey() -> String {
    request.labels["testcontainers.minio.secretKey"] ?? "minioadmin"
}

private func isConsoleEnabled() -> Bool {
    request.labels["testcontainers.minio.consoleEnabled"] == "true"
}
```

### 7. Add Unit Tests

**File**: `/Tests/TestContainersTests/MinioContainerRequestTests.swift`

- Test default values
- Test builder pattern methods:
  - `.withImage()`
  - `.withCredentials()`
  - `.withAccessKey()` / `.withSecretKey()`
  - `.withConsole()`
  - `.withBucket()` / `.withBuckets()`
  - `.withEnvironment()`
- Test validation:
  - Empty secret key should fail
  - Empty access key should fail
  - Invalid bucket names should fail
- Test `toContainerRequest()` conversion:
  - Verify image set correctly
  - Verify ports exposed correctly
  - Verify environment variables set correctly
  - Verify command set correctly
  - Verify labels include MinIO metadata
  - Verify wait strategy configured
- Test `Hashable` conformance
- Test immutability (builder returns new instance)

### 8. Add Integration Tests

**File**: `/Tests/TestContainersTests/MinioContainerIntegrationTests.swift`

Guard all tests with opt-in check:
```swift
let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
guard optedIn else { return }
```

**Test cases**:

1. **Basic container lifecycle**
   - Start MinIO with defaults
   - Verify s3Endpoint() returns valid URL
   - Verify minioAccessKey() returns "minioadmin"
   - Verify container terminates cleanly

2. **Custom credentials**
   - Start with custom access key and secret key
   - Verify credentials retrievable
   - (Optional) Verify S3 client can authenticate

3. **Console endpoint**
   - Start with console enabled
   - Verify consoleEndpoint() returns valid URL
   - Verify port is accessible
   - Test with console disabled (should throw error)

4. **Bucket creation** (if exec implemented)
   - Test withBucket() creates bucket on startup
   - Test withBuckets() creates multiple buckets
   - Test createBucket() creates bucket on-demand
   - Verify invalid bucket names fail appropriately

5. **S3 operations** (if S3 client available)
   - Create S3 client with endpoint and credentials
   - Put object to MinIO
   - Get object from MinIO
   - List objects
   - Verify objects exist

6. **Wait strategy**
   - Verify container waits for MinIO to be ready
   - Test timeout scenarios (if possible)

7. **Image version override**
   - Test with specific MinIO version tag
   - Verify correct image is used

**Example test**:
```swift
@Test func minioContainer_basicLifecycle() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withMinioContainer { container in
        let endpoint = try await container.s3Endpoint()
        #expect(endpoint.starts(with: "http://127.0.0.1:"))

        let accessKey = container.minioAccessKey()
        #expect(accessKey == "minioadmin")

        let secretKey = container.minioSecretKey()
        #expect(secretKey == "minioadmin")
    }
}

@Test func minioContainer_customCredentials() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = MinioContainerRequest()
        .withCredentials(accessKey: "testuser", secretKey: "testpass123")

    try await withMinioContainer(request) { container in
        #expect(container.minioAccessKey() == "testuser")
        #expect(container.minioSecretKey() == "testpass123")
    }
}

@Test func minioContainer_consoleEndpoint() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withMinioContainer { container in
        let consoleURL = try await container.consoleEndpoint()
        #expect(consoleURL.starts(with: "http://127.0.0.1:"))
    }
}
```

### 9. Documentation

- Add comprehensive doc comments to all public APIs
- Update README.md with MinIO example in "Modules" section
- Add usage guide in package documentation
- Document common pitfalls:
  - MinIO requires non-empty passwords
  - Bucket names must follow S3 naming rules
  - Console must be enabled to access consoleEndpoint()
- Add troubleshooting section:
  - Container fails to start (check Docker installed)
  - S3 client can't connect (verify endpoint URL)
  - Authentication fails (verify credentials)

**README.md addition**:
```markdown
### Service Modules

#### MinIO (S3-Compatible Storage)

```swift
import Testing
import TestContainers

@Test func s3Operations() async throws {
    try await withMinioContainer { container in
        let endpoint = try await container.s3Endpoint()
        let accessKey = container.minioAccessKey()
        let secretKey = container.minioSecretKey()

        // Configure your S3 client
        // Perform S3 operations...
    }
}

// Custom configuration
let request = MinioContainerRequest()
    .withCredentials(accessKey: "myuser", secretKey: "mypass123")
    .withBucket("test-bucket")

try await withMinioContainer(request) { container in
    // Bucket "test-bucket" already exists
}
```
```

### 10. Update FEATURES.md

- Mark `MinioContainer` as implemented in Tier 4 (Module System)
- Add notes about feature dependencies:
  - Bucket creation requires Feature 007 (container exec)
  - Optimal wait strategy requires Feature 001 (HTTP wait)
- Document as reference implementation for future modules

## Testing Plan

### Unit Tests

1. **MinioContainerRequest Tests**
   - Default values initialization
   - Builder pattern immutability
   - Credential validation (non-empty)
   - Bucket name validation (S3 rules)
   - Environment variable merging
   - Hashable conformance
   - toContainerRequest() correctness

2. **Container Extension Tests** (if mockable)
   - s3Endpoint() URL construction
   - consoleEndpoint() URL construction
   - connectionString() alias behavior
   - Credential retrieval from labels
   - Console enabled/disabled detection

### Integration Tests (Opt-in via TESTCONTAINERS_RUN_DOCKER_TESTS=1)

1. **Lifecycle Tests**
   - Start with defaults
   - Start with custom image version
   - Verify cleanup on normal exit
   - Verify cleanup on error
   - Verify cleanup on cancellation

2. **Endpoint Tests**
   - s3Endpoint() returns valid, accessible URL
   - consoleEndpoint() returns valid URL when enabled
   - consoleEndpoint() throws when disabled
   - connectionString() matches s3Endpoint()

3. **Credential Tests**
   - Default credentials (minioadmin/minioadmin)
   - Custom credentials
   - Credential retrieval from container

4. **Bucket Tests** (requires Feature 007)
   - Single bucket creation on startup
   - Multiple buckets creation on startup
   - On-demand bucket creation
   - Invalid bucket name rejection
   - Duplicate bucket handling

5. **S3 Integration Tests** (if S3 client available)
   - Put object
   - Get object
   - List objects
   - Delete object
   - Head object
   - Multipart upload

6. **Wait Strategy Tests**
   - Verify container waits until ready
   - Verify health endpoint is checked (if HTTP wait implemented)
   - Timeout behavior

### Manual Testing Checklist

- [ ] Test on macOS
- [ ] Test on Linux (if available)
- [ ] Test with AWS SDK for Swift
- [ ] Test with various MinIO versions
- [ ] Test console UI accessibility in browser
- [ ] Test with large file uploads
- [ ] Verify performance (container startup time)
- [ ] Test parallel container creation
- [ ] Verify no port conflicts with multiple containers
- [ ] Check resource cleanup (no leaked containers)

## Acceptance Criteria

### Must Have

- [ ] `MinioContainerRequest` struct with builder pattern
- [ ] Default configuration (image, ports, credentials)
- [ ] `withMinioContainer(_:_:)` lifecycle helper
- [ ] `s3Endpoint()` helper method
- [ ] `consoleEndpoint()` helper method
- [ ] `connectionString()` helper method
- [ ] `minioAccessKey()` and `minioSecretKey()` getters
- [ ] Credential validation (non-empty)
- [ ] Custom credentials support (`.withCredentials()`)
- [ ] Custom image/version support (`.withImage()`)
- [ ] Console port exposure (`.withConsole()`)
- [ ] Proper wait strategy (TCP at minimum, HTTP preferred)
- [ ] Automatic cleanup via `withContainer` integration
- [ ] Unit tests with >80% coverage
- [ ] Integration tests with real MinIO container
- [ ] Documentation in code (doc comments)
- [ ] README.md example
- [ ] FEATURES.md updated

### Should Have

- [ ] Bucket creation on startup (`.withBucket()`, `.withBuckets()`)
- [ ] On-demand bucket creation (`createBucket()`)
- [ ] Bucket name validation (S3 naming rules)
- [ ] HTTP health check wait strategy (if Feature 001 available)
- [ ] Stored credentials in container labels/metadata
- [ ] Custom environment variables support
- [ ] Timeout and poll interval configuration
- [ ] Error handling with descriptive messages
- [ ] Multiple MinIO containers in parallel

### Nice to Have

- [ ] Region configuration (even though MinIO ignores it)
- [ ] TLS/HTTPS support for S3 endpoint
- [ ] Custom domain/virtual host support
- [ ] Versioning configuration
- [ ] Lifecycle policy configuration
- [ ] Integration example with popular S3 clients
- [ ] Performance benchmarks
- [ ] Debug/verbose logging option

### Definition of Done

- All "Must Have" criteria completed
- All "Should Have" criteria completed (or explicitly deferred with reasoning)
- All unit tests passing
- All integration tests passing (when opted in)
- Code review completed
- Documentation reviewed and clear
- Manually tested with at least one S3 client library
- No regressions in existing tests
- Follows existing code style and patterns
- All public APIs have comprehensive doc comments
- README includes clear MinIO example
- FEATURES.md reflects implementation status

## Dependencies

### Hard Dependencies

None - MinioContainer can be implemented with current infrastructure using TCP wait strategy.

### Soft Dependencies (Enhances functionality)

1. **Feature 001: HTTP Wait Strategy**
   - Enables health check on `/minio/health/ready`
   - Ensures MinIO is truly ready to accept S3 requests
   - Without it: Use TCP port wait as fallback

2. **Feature 007: Container Exec**
   - Enables automatic bucket creation
   - Allows running `mc mb` commands
   - Without it: Skip bucket creation feature or use alternative approach

3. **Feature 010: Container Inspect**
   - Could verify MinIO health status
   - Could retrieve additional container metadata
   - Without it: Limited to basic port/endpoint access

### External Dependencies

- MinIO Docker image (minio/minio)
- Docker CLI (already required by testcontainers)
- Optional: S3 client library for integration tests (e.g., AWS SDK for Swift, Soto)

## Implementation Notes

### MinIO Docker Image Details

**Image**: `minio/minio` (or `quay.io/minio/minio`)

**Default ports**:
- 9000: S3 API endpoint
- 9001: Console/Web UI (must be explicitly set via `--console-address`)

**Required environment variables**:
- `MINIO_ROOT_USER`: Access key (minimum 3 characters)
- `MINIO_ROOT_PASSWORD`: Secret key (minimum 8 characters)

**Command**:
- `server /data`: Start MinIO server with data directory
- `--console-address :9001`: Enable web console on port 9001

**Health endpoints**:
- `/minio/health/live`: Liveness probe (always returns 200 if server is running)
- `/minio/health/ready`: Readiness probe (returns 200 if ready for requests)

### Alternative: Using Bitnami MinIO Image

The Bitnami MinIO image (`bitnami/minio`) uses different environment variables:
- `MINIO_ROOT_USER` (same)
- `MINIO_ROOT_PASSWORD` (same)

Could support both images in the future via image detection or explicit configuration.

### Bucket Creation Alternatives

If container exec is not available:

1. **Environment variable approach** (if MinIO supports it):
   - Some MinIO versions support `MINIO_DEFAULT_BUCKETS`
   - Not officially documented, may not be reliable

2. **Init script via bind mount**:
   - Create script that creates buckets
   - Mount script into container
   - Override entrypoint to run script then start server
   - Complex, fragile

3. **Post-startup HTTP API**:
   - Use MinIO's S3 API to create buckets
   - Requires S3 client library
   - Adds external dependency

**Recommendation**: Start without bucket creation, add it when Feature 007 (exec) is available.

### Credentials Storage Strategy

Store credentials in container labels for retrieval:

**Pros**:
- No global state
- No need for custom container type
- Simple implementation
- Works with existing Container actor

**Cons**:
- Credentials visible in labels (not a security issue for tests)
- Slight overhead (minimal)

**Alternative**: Create dedicated `MinioContainer` actor wrapping `Container` and storing config.

## References

### Related Files

- `/Sources/TestContainers/ContainerRequest.swift` - Base request builder
- `/Sources/TestContainers/Container.swift` - Container actor
- `/Sources/TestContainers/WithContainer.swift` - Lifecycle helper
- `/Sources/TestContainers/DockerClient.swift` - Docker CLI interface
- `/Sources/TestContainers/Waiter.swift` - Wait polling mechanism

### Similar Implementations

- **Testcontainers Go**: [MinIO Module](https://golang.testcontainers.org/modules/minio/)
- **Testcontainers Java**: [MinIO Containers](https://java.testcontainers.org/modules/minio/)
- **Testcontainers Python**: [minio.MinioContainer](https://testcontainers-python.readthedocs.io/en/latest/modules/minio/README.html)

### MinIO Documentation

- [MinIO Docker Quickstart](https://min.io/docs/minio/container/index.html)
- [MinIO Healthcheck API](https://min.io/docs/minio/linux/operations/monitoring/healthcheck-probe.html)
- [MinIO Console](https://min.io/docs/minio/linux/administration/minio-console.html)
- [MinIO Root Credentials](https://min.io/docs/minio/linux/reference/minio-server/settings/root-credentials.html)

### S3 Client Libraries for Swift

- [AWS SDK for Swift](https://github.com/awslabs/aws-sdk-swift)
- [Soto (AWS SDK for Swift)](https://github.com/soto-project/soto)
- [MinIO Swift SDK](https://github.com/minio/minio-swift) (if exists)

## Future Enhancements

After initial implementation, consider:

1. **Advanced configuration**:
   - KMS encryption
   - Event notifications
   - Replication
   - Gateway mode

2. **Additional helpers**:
   - Presigned URL generation helpers
   - Bucket policy helpers
   - Lifecycle policy helpers

3. **Performance optimizations**:
   - Container reuse between tests (opt-in)
   - Faster startup via image caching
   - Parallel bucket creation

4. **Enhanced testing**:
   - Stress tests (large files, many objects)
   - Performance benchmarks
   - Multi-container scenarios (MinIO cluster)

5. **Documentation**:
   - Video tutorial
   - Integration guides for popular frameworks
   - Troubleshooting guide
   - Migration guide from manual setup
