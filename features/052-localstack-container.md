# Feature 052: LocalStackContainer (AWS Services Emulation)

**Status**: Implemented
**Priority**: Tier 4 (Module System - Service-Specific Helpers)
**Estimated Complexity**: Medium-High
**Dependencies**: HTTP Wait Strategy (Feature 001)

---

## Summary

Implement a pre-configured `LocalStackContainer` module for swift-test-containers that provides a typed, ergonomic API for running LocalStack containers. LocalStack is a fully functional local AWS cloud stack that enables developers to test cloud and serverless applications locally without incurring AWS costs or requiring cloud connectivity.

This module will:
- Provide sensible defaults for LocalStack configuration (image, port, region)
- Support selective AWS service enablement (S3, SQS, DynamoDB, Lambda, etc.)
- Generate service-specific endpoint URLs for AWS SDK configuration
- Include appropriate wait strategies for container readiness
- Follow the builder pattern established in `ContainerRequest`
- Enable seamless integration with AWS SDK for Swift

---

## Current State

### Generic Container API

The current swift-test-containers architecture (as of v0.1.0) provides a generic container API:

**Located at**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/`

```swift
// Current usage for LocalStack (without module)
let request = ContainerRequest(image: "localstack/localstack:3.4")
    .withExposedPort(4566)
    .withEnvironment(["SERVICES": "s3,sqs,dynamodb"])
    .withEnvironment(["DEFAULT_REGION": "us-east-1"])
    .waitingFor(.tcpPort(4566))

try await withContainer(request) { container in
    let endpoint = try await container.endpoint(for: 4566)
    // Manual AWS SDK configuration with endpoint
    // http://localhost:<port>
}
```

**Pain points**:
1. Users must know LocalStack's image name and version
2. Port number (4566) is magic number
3. Environment variable names must be memorized (`SERVICES`, `DEFAULT_REGION`, etc.)
4. No type-safe service selection
5. Endpoint URL construction is manual and error-prone
6. No service-specific helpers for AWS SDK configuration
7. TCP wait strategy doesn't guarantee LocalStack initialization is complete
8. No hostname configuration for service-to-service communication

### Existing Architecture Patterns

**Builder Pattern** (`ContainerRequest.swift`):
```swift
public struct ContainerRequest: Sendable, Hashable {
    public init(image: String)
    public func withExposedPort(_ containerPort: Int, hostPort: Int? = nil) -> Self
    public func withEnvironment(_ environment: [String: String]) -> Self
    public func waitingFor(_ strategy: WaitStrategy) -> Self
}
```

**Scoped Lifecycle** (`WithContainer.swift`):
```swift
public func withContainer<T>(
    _ request: ContainerRequest,
    operation: @Sendable (Container) async throws -> T
) async throws -> T
```

**Container Handle** (`Container.swift`):
```swift
public actor Container {
    public func hostPort(_ containerPort: Int) async throws -> Int
    public func host() -> String
    public func endpoint(for containerPort: Int) async throws -> String
    public func logs() async throws -> String
}
```

---

## Requirements

### Functional Requirements

#### 1. Default Configuration
- **Default Image**: `localstack/localstack:3.4` (latest stable as of 2025)
- **Default Port**: 4566 (LocalStack edge port)
- **Default Region**: `us-east-1`
- **Default Wait Strategy**: HTTP health check on `/_localstack/health` endpoint
- **Automatic Hostname Configuration**: Set `LOCALSTACK_HOST` for v2.0+ compatibility

#### 2. Service Selection
Support selective enablement of AWS services via environment variable:
- S3 (Simple Storage Service)
- SQS (Simple Queue Service)
- DynamoDB (NoSQL Database)
- SNS (Simple Notification Service)
- Lambda (Serverless Functions)
- CloudWatch (Monitoring)
- CloudFormation (Infrastructure as Code)
- API Gateway
- Kinesis (Data Streaming)
- Secrets Manager
- SSM (Systems Manager)
- StepFunctions
- EventBridge
- And others supported by LocalStack

**Default behavior**: All services enabled (LocalStack default)
**Custom selection**: Specify array of services to enable

#### 3. Endpoint URL Helpers
Provide convenience methods for generating AWS SDK endpoint URLs:
- `endpointURL()` - Base LocalStack endpoint (http://host:port)
- `serviceEndpoint(for:)` - Service-specific endpoint URL
- Support for AWS SDK for Swift configuration

#### 4. Region Configuration
- Default region: `us-east-1`
- Allow custom region specification
- Automatically set `DEFAULT_REGION` environment variable

#### 5. Wait Strategy
- Use HTTP wait strategy (requires Feature 001)
- Poll `/_localstack/health` endpoint
- Wait for HTTP 200 response
- Configurable timeout (default: 60 seconds)
- Fallback: TCP port wait if HTTP strategy not implemented yet

#### 6. Hostname Configuration
- Automatically set `LOCALSTACK_HOST` environment variable
- Support for container-to-container communication
- Use container hostname for network aliases

### Non-Functional Requirements

#### 1. Type Safety
- Swift enums for service names (avoid string literals)
- Builder pattern for configuration
- Sendable and Hashable conformance

#### 2. Compatibility
- Work with AWS SDK for Swift
- Support LocalStack versions 2.0+
- Cross-platform (macOS, Linux)

#### 3. Consistency
- Follow existing swift-test-containers patterns
- Maintain builder method naming conventions
- Use async/await for all I/O operations

#### 4. Testability
- Unit tests without Docker
- Integration tests with real LocalStack container
- Example tests for S3, SQS, DynamoDB

---

## API Design

### Proposed Swift API

#### Core Types

```swift
/// Represents AWS services supported by LocalStack
public enum AWSService: String, Sendable, Hashable, CaseIterable {
    case s3
    case sqs
    case dynamodb
    case sns
    case lambda
    case cloudwatch
    case cloudformation
    case apigateway
    case kinesis
    case secretsmanager
    case ssm
    case stepfunctions
    case eventbridge
    case ec2
    case iam
    case sts
    case kms
    case firehose
    case logs
    case athena
    case rds
    case redshift
    case elasticache
    case elasticsearch
    case opensearch

    var serviceName: String {
        rawValue
    }
}

/// Configuration for LocalStack container
public struct LocalStackConfig: Sendable, Hashable {
    /// LocalStack Docker image (default: "localstack/localstack:3.4")
    public var image: String

    /// AWS services to enable (nil = all services)
    public var services: Set<AWSService>?

    /// AWS region (default: "us-east-1")
    public var region: String

    /// LocalStack edge port (default: 4566)
    public var port: Int

    /// Additional environment variables
    public var environment: [String: String]

    /// Wait strategy timeout
    public var timeout: Duration

    /// Whether to enable LocalStack persistence (requires volume mount)
    public var enablePersistence: Bool

    public init(
        image: String = "localstack/localstack:3.4",
        services: Set<AWSService>? = nil,
        region: String = "us-east-1",
        port: Int = 4566,
        environment: [String: String] = [:],
        timeout: Duration = .seconds(60),
        enablePersistence: Bool = false
    ) {
        self.image = image
        self.services = services
        self.region = region
        self.port = port
        self.environment = environment
        self.timeout = timeout
        self.enablePersistence = enablePersistence
    }

    // Builder methods
    public func withImage(_ image: String) -> Self
    public func withServices(_ services: Set<AWSService>) -> Self
    public func withService(_ service: AWSService) -> Self
    public func withRegion(_ region: String) -> Self
    public func withPort(_ port: Int) -> Self
    public func withEnvironment(_ env: [String: String]) -> Self
    public func withTimeout(_ timeout: Duration) -> Self
    public func withPersistence(_ enabled: Bool) -> Self
}

/// LocalStack container wrapper with AWS-specific helpers
public actor LocalStackContainer {
    private let container: Container
    private let config: LocalStackConfig

    init(container: Container, config: LocalStackConfig) {
        self.container = container
        self.config = config
    }

    /// Get the base LocalStack endpoint URL
    /// Example: "http://127.0.0.1:4566"
    public func endpointURL() async throws -> String {
        let endpoint = try await container.endpoint(for: config.port)
        return "http://\(endpoint)"
    }

    /// Get service-specific endpoint URL for AWS SDK configuration
    /// - Parameter service: The AWS service
    /// - Returns: Service endpoint URL (same as base for LocalStack)
    public func serviceEndpoint(for service: AWSService) async throws -> String {
        try await endpointURL()
    }

    /// Get the configured AWS region
    public func region() -> String {
        config.region
    }

    /// Get the host for AWS SDK configuration
    public func host() -> String {
        container.host()
    }

    /// Get the mapped port for AWS SDK configuration
    public func hostPort() async throws -> Int {
        try await container.hostPort(config.port)
    }

    /// Access the underlying generic Container
    public var underlying: Container {
        container
    }

    /// Get container logs
    public func logs() async throws -> String {
        try await container.logs()
    }

    /// Manually terminate the container (usually handled by withLocalStack)
    public func terminate() async throws {
        try await container.terminate()
    }
}
```

#### Top-Level API

```swift
/// Start a LocalStack container with scoped lifetime
/// - Parameters:
///   - config: LocalStack configuration
///   - operation: Async operation to perform with the container
/// - Returns: Result of the operation
/// - Throws: Container startup errors or operation errors
public func withLocalStack<T>(
    _ config: LocalStackConfig = LocalStackConfig(),
    docker: DockerClient = DockerClient(),
    operation: @Sendable (LocalStackContainer) async throws -> T
) async throws -> T {
    let request = buildContainerRequest(from: config)

    return try await withContainer(request, docker: docker) { container in
        let localstack = LocalStackContainer(container: container, config: config)
        return try await operation(localstack)
    }
}

// Internal helper to build ContainerRequest from LocalStackConfig
func buildContainerRequest(from config: LocalStackConfig) -> ContainerRequest {
    var env = config.environment

    // Set AWS region
    env["DEFAULT_REGION"] = config.region

    // Set services if specified
    if let services = config.services {
        let serviceList = services.map { $0.serviceName }.sorted().joined(separator: ",")
        env["SERVICES"] = serviceList
    }

    // Set hostname for LocalStack v2.0+
    env["LOCALSTACK_HOST"] = "localhost.localstack.cloud:\(config.port)"

    var request = ContainerRequest(image: config.image)
        .withExposedPort(config.port)
        .withEnvironment(env)
        .withLabel("testcontainers.module", "localstack")

    // Use HTTP wait strategy if available, fallback to TCP
    #if HTTP_WAIT_AVAILABLE
    request = request.waitingFor(.http(
        HTTPWaitConfig(port: config.port)
            .withPath("/_localstack/health")
            .withStatusCode(200)
            .withTimeout(config.timeout)
    ))
    #else
    request = request.waitingFor(.tcpPort(config.port, timeout: config.timeout))
    #endif

    // Add persistence if enabled (requires volume mount feature)
    if config.enablePersistence {
        request = request.withVolume("localstack-data", mountedAt: "/var/lib/localstack")
    }

    return request
}
```

### Usage Examples

#### Example 1: Basic S3 Testing

```swift
import Testing
import TestContainers
import LocalStackModule
import AWSS3 // AWS SDK for Swift

@Test func testS3Operations() async throws {
    // Start LocalStack with only S3 service
    let config = LocalStackConfig()
        .withServices([.s3])

    try await withLocalStack(config) { localstack in
        let endpoint = try await localstack.endpointURL()

        // Configure AWS SDK
        let s3Client = try await S3Client(
            config: S3ClientConfiguration(
                region: localstack.region(),
                endpoint: endpoint,
                credentials: StaticCredentialsProvider(
                    accessKeyId: "test",
                    secretAccessKey: "test"
                )
            )
        )

        // Create bucket
        _ = try await s3Client.createBucket(input: CreateBucketInput(
            bucket: "test-bucket"
        ))

        // Verify bucket exists
        let buckets = try await s3Client.listBuckets()
        #expect(buckets.buckets?.contains { $0.name == "test-bucket" } == true)
    }
}
```

#### Example 2: Multiple Services (SQS + DynamoDB)

```swift
@Test func testMultipleServices() async throws {
    let config = LocalStackConfig()
        .withServices([.sqs, .dynamodb])
        .withRegion("us-west-2")

    try await withLocalStack(config) { localstack in
        let endpoint = try await localstack.endpointURL()
        let region = localstack.region()

        // Configure SQS client
        let sqsClient = try await SQSClient(
            config: SQSClientConfiguration(
                region: region,
                endpoint: endpoint,
                credentials: testCredentials()
            )
        )

        // Configure DynamoDB client
        let dynamoClient = try await DynamoDBClient(
            config: DynamoDBClientConfiguration(
                region: region,
                endpoint: endpoint,
                credentials: testCredentials()
            )
        )

        // Test SQS
        let queueResponse = try await sqsClient.createQueue(input: CreateQueueInput(
            queueName: "test-queue"
        ))
        #expect(queueResponse.queueUrl != nil)

        // Test DynamoDB
        let tableResponse = try await dynamoClient.createTable(input: CreateTableInput(
            tableName: "test-table",
            keySchema: [/* ... */],
            attributeDefinitions: [/* ... */]
        ))
        #expect(tableResponse.tableDescription?.tableName == "test-table")
    }
}

func testCredentials() -> StaticCredentialsProvider {
    StaticCredentialsProvider(accessKeyId: "test", secretAccessKey: "test")
}
```

#### Example 3: All Services with Default Config

```swift
@Test func testDefaultLocalStack() async throws {
    // Use all defaults: image 3.4, all services, us-east-1
    try await withLocalStack() { localstack in
        let endpoint = try await localstack.endpointURL()
        #expect(endpoint.hasPrefix("http://"))

        let region = localstack.region()
        #expect(region == "us-east-1")

        // Can use any AWS service
        // ...
    }
}
```

#### Example 4: Custom Image Version

```swift
@Test func testCustomLocalStackVersion() async throws {
    let config = LocalStackConfig()
        .withImage("localstack/localstack:2.3.0")
        .withServices([.lambda, .apigateway])

    try await withLocalStack(config) { localstack in
        // Test Lambda and API Gateway
        // ...
    }
}
```

#### Example 5: With Persistence

```swift
@Test func testLocalStackPersistence() async throws {
    let config = LocalStackConfig()
        .withServices([.s3])
        .withPersistence(true)

    try await withLocalStack(config) { localstack in
        // Data will persist to localstack-data volume
        // Useful for testing data persistence across restarts
    }
}
```

---

## Implementation Steps

### Step 1: Create LocalStackModule Directory Structure

**Action**: Set up module organization
```
Sources/
  TestContainers/        (existing core module)
  LocalStackModule/      (new module)
    LocalStackContainer.swift
    LocalStackConfig.swift
    AWSService.swift
```

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Package.swift`

Update Package.swift to include new module:
```swift
.target(
    name: "LocalStackModule",
    dependencies: ["TestContainers"]
),
.testTarget(
    name: "LocalStackModuleTests",
    dependencies: ["LocalStackModule", "TestContainers"]
)
```

**Acceptance**: Module compiles independently, imports TestContainers

### Step 2: Define AWSService Enum

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/LocalStackModule/AWSService.swift`

**Implementation**:
```swift
import Foundation

/// AWS services supported by LocalStack
public enum AWSService: String, Sendable, Hashable, CaseIterable {
    // Storage
    case s3
    case dynamodb
    case rds
    case redshift
    case elasticache
    case elasticsearch
    case opensearch

    // Compute
    case lambda
    case ec2
    case ecs
    case eks

    // Messaging
    case sqs
    case sns
    case kinesis
    case firehose
    case eventbridge

    // API & Integration
    case apigateway
    case appsync
    case stepfunctions

    // Security
    case iam
    case sts
    case kms
    case secretsmanager
    case cognito

    // Monitoring & Management
    case cloudwatch
    case logs
    case cloudformation
    case ssm
    case xray

    // Analytics
    case athena
    case glue

    public var serviceName: String {
        rawValue
    }
}
```

**Acceptance**:
- Enum compiles with all common AWS services
- Sendable and Hashable conformance
- serviceName returns correct string

### Step 3: Implement LocalStackConfig

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/LocalStackModule/LocalStackConfig.swift`

**Implementation**:
```swift
import Foundation
import TestContainers

public struct LocalStackConfig: Sendable, Hashable {
    public var image: String
    public var services: Set<AWSService>?
    public var region: String
    public var port: Int
    public var environment: [String: String]
    public var timeout: Duration
    public var enablePersistence: Bool

    public init(
        image: String = "localstack/localstack:3.4",
        services: Set<AWSService>? = nil,
        region: String = "us-east-1",
        port: Int = 4566,
        environment: [String: String] = [:],
        timeout: Duration = .seconds(60),
        enablePersistence: Bool = false
    ) {
        self.image = image
        self.services = services
        self.region = region
        self.port = port
        self.environment = environment
        self.timeout = timeout
        self.enablePersistence = enablePersistence
    }

    public func withImage(_ image: String) -> Self {
        var copy = self
        copy.image = image
        return copy
    }

    public func withServices(_ services: Set<AWSService>) -> Self {
        var copy = self
        copy.services = services
        return copy
    }

    public func withService(_ service: AWSService) -> Self {
        var copy = self
        if copy.services == nil {
            copy.services = []
        }
        copy.services?.insert(service)
        return copy
    }

    public func withRegion(_ region: String) -> Self {
        var copy = self
        copy.region = region
        return copy
    }

    public func withPort(_ port: Int) -> Self {
        var copy = self
        copy.port = port
        return copy
    }

    public func withEnvironment(_ env: [String: String]) -> Self {
        var copy = self
        for (k, v) in env {
            copy.environment[k] = v
        }
        return copy
    }

    public func withTimeout(_ timeout: Duration) -> Self {
        var copy = self
        copy.timeout = timeout
        return copy
    }

    public func withPersistence(_ enabled: Bool) -> Self {
        var copy = self
        copy.enablePersistence = enabled
        return copy
    }
}
```

**Acceptance**:
- Builder pattern works correctly
- Default values are sensible
- Hashable and Sendable conformance

### Step 4: Implement LocalStackContainer Actor

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/LocalStackModule/LocalStackContainer.swift`

**Implementation**:
```swift
import Foundation
import TestContainers

/// LocalStack container wrapper with AWS-specific helpers
public actor LocalStackContainer {
    private let container: Container
    private let config: LocalStackConfig

    init(container: Container, config: LocalStackConfig) {
        self.container = container
        self.config = config
    }

    /// Get the base LocalStack endpoint URL
    public func endpointURL() async throws -> String {
        let endpoint = try await container.endpoint(for: config.port)
        return "http://\(endpoint)"
    }

    /// Get service-specific endpoint URL for AWS SDK configuration
    public func serviceEndpoint(for service: AWSService) async throws -> String {
        // LocalStack uses same endpoint for all services
        try await endpointURL()
    }

    /// Get the configured AWS region
    public func region() -> String {
        config.region
    }

    /// Get the host for AWS SDK configuration
    public func host() -> String {
        container.host()
    }

    /// Get the mapped port for AWS SDK configuration
    public func hostPort() async throws -> Int {
        try await container.hostPort(config.port)
    }

    /// Access the underlying generic Container
    public var underlying: Container {
        container
    }

    /// Get container logs
    public func logs() async throws -> String {
        try await container.logs()
    }

    /// Manually terminate the container
    public func terminate() async throws {
        try await container.terminate()
    }
}

/// Build ContainerRequest from LocalStackConfig
func buildContainerRequest(from config: LocalStackConfig) -> ContainerRequest {
    var env = config.environment

    // Set AWS region
    env["DEFAULT_REGION"] = config.region

    // Set services if specified (nil = all services enabled)
    if let services = config.services {
        let serviceList = services
            .map { $0.serviceName }
            .sorted()
            .joined(separator: ",")
        env["SERVICES"] = serviceList
    }

    // Set hostname for LocalStack v2.0+ compatibility
    // This allows LocalStack to be aware of its externally accessible hostname
    env["LOCALSTACK_HOST"] = "localhost.localstack.cloud:\(config.port)"

    var request = ContainerRequest(image: config.image)
        .withExposedPort(config.port)
        .withEnvironment(env)
        .withLabel("testcontainers.module", "localstack")
        .waitingFor(.tcpPort(config.port, timeout: config.timeout))

    // TODO: When HTTP wait strategy is available (Feature 001), use:
    // .waitingFor(.http(
    //     HTTPWaitConfig(port: config.port)
    //         .withPath("/_localstack/health")
    //         .withStatusCode(200)
    //         .withTimeout(config.timeout)
    // ))

    // TODO: When volume mounts are available (Feature 012), use:
    // if config.enablePersistence {
    //     request = request.withVolume("localstack-data", mountedAt: "/var/lib/localstack")
    // }

    return request
}

/// Start a LocalStack container with scoped lifetime
public func withLocalStack<T>(
    _ config: LocalStackConfig = LocalStackConfig(),
    docker: DockerClient = DockerClient(),
    operation: @Sendable (LocalStackContainer) async throws -> T
) async throws -> T {
    let request = buildContainerRequest(from: config)

    return try await withContainer(request, docker: docker) { container in
        let localstack = LocalStackContainer(container: container, config: config)
        return try await operation(localstack)
    }
}
```

**Acceptance**:
- withLocalStack function creates container
- LocalStackContainer provides endpoint helpers
- Environment variables are correctly set
- Container lifecycle is managed properly

### Step 5: Unit Tests for Configuration

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/LocalStackModuleTests/LocalStackConfigTests.swift`

**Tests**:
```swift
import Testing
import LocalStackModule

@Test func defaultConfiguration() {
    let config = LocalStackConfig()

    #expect(config.image == "localstack/localstack:3.4")
    #expect(config.services == nil) // All services
    #expect(config.region == "us-east-1")
    #expect(config.port == 4566)
    #expect(config.environment.isEmpty)
    #expect(config.timeout == .seconds(60))
    #expect(config.enablePersistence == false)
}

@Test func builderPattern() {
    let config = LocalStackConfig()
        .withImage("localstack/localstack:2.0")
        .withServices([.s3, .sqs])
        .withRegion("eu-west-1")
        .withPort(5000)
        .withTimeout(.seconds(90))

    #expect(config.image == "localstack/localstack:2.0")
    #expect(config.services == [.s3, .sqs])
    #expect(config.region == "eu-west-1")
    #expect(config.port == 5000)
    #expect(config.timeout == .seconds(90))
}

@Test func builderImmutability() {
    let original = LocalStackConfig()
    let modified = original.withRegion("ap-south-1")

    #expect(original.region == "us-east-1")
    #expect(modified.region == "ap-south-1")
}

@Test func serviceNames() {
    #expect(AWSService.s3.serviceName == "s3")
    #expect(AWSService.dynamodb.serviceName == "dynamodb")
    #expect(AWSService.sqs.serviceName == "sqs")
}

@Test func hashableConformance() {
    let config1 = LocalStackConfig().withServices([.s3])
    let config2 = LocalStackConfig().withServices([.s3])

    #expect(config1 == config2)
}
```

**Acceptance**: All unit tests pass

### Step 6: Unit Tests for Container Request Building

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/LocalStackModuleTests/LocalStackContainerTests.swift`

**Tests**:
```swift
import Testing
import LocalStackModule
import TestContainers

@Test func buildsCorrectContainerRequest() {
    let config = LocalStackConfig()
        .withServices([.s3, .sqs])
        .withRegion("us-west-2")

    let request = buildContainerRequest(from: config)

    #expect(request.image == "localstack/localstack:3.4")
    #expect(request.ports.contains { $0.containerPort == 4566 })
    #expect(request.environment["DEFAULT_REGION"] == "us-west-2")
    #expect(request.environment["SERVICES"]?.contains("s3") == true)
    #expect(request.environment["SERVICES"]?.contains("sqs") == true)
    #expect(request.environment["LOCALSTACK_HOST"] != nil)
    #expect(request.labels["testcontainers.module"] == "localstack")
}

@Test func allServicesWhenNil() {
    let config = LocalStackConfig() // services = nil
    let request = buildContainerRequest(from: config)

    // SERVICES env var should not be set (LocalStack default = all)
    #expect(request.environment["SERVICES"] == nil)
}

@Test func servicesSortedAlphabetically() {
    let config = LocalStackConfig()
        .withServices([.sqs, .dynamodb, .s3]) // Unordered

    let request = buildContainerRequest(from: config)

    // Should be sorted: dynamodb,s3,sqs
    #expect(request.environment["SERVICES"] == "dynamodb,s3,sqs")
}

@Test func customEnvironmentVariables() {
    let config = LocalStackConfig()
        .withEnvironment(["DEBUG": "1", "CUSTOM_VAR": "value"])

    let request = buildContainerRequest(from: config)

    #expect(request.environment["DEBUG"] == "1")
    #expect(request.environment["CUSTOM_VAR"] == "value")
    #expect(request.environment["DEFAULT_REGION"] == "us-east-1")
}
```

**Acceptance**: All tests pass, container request is built correctly

### Step 7: Integration Tests with Real LocalStack

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/LocalStackModuleTests/LocalStackIntegrationTests.swift`

**Tests**:
```swift
import Testing
import LocalStackModule

@Test func canStartLocalStackContainer_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withLocalStack() { localstack in
        let endpoint = try await localstack.endpointURL()
        #expect(endpoint.hasPrefix("http://"))
        #expect(endpoint.contains(":"))

        let region = localstack.region()
        #expect(region == "us-east-1")
    }
}

@Test func canConfigureCustomServices_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let config = LocalStackConfig()
        .withServices([.s3, .sqs])
        .withRegion("eu-west-1")

    try await withLocalStack(config) { localstack in
        let endpoint = try await localstack.endpointURL()
        #expect(!endpoint.isEmpty)

        let region = localstack.region()
        #expect(region == "eu-west-1")

        let port = try await localstack.hostPort()
        #expect(port > 0)
    }
}

@Test func canAccessContainerLogs_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    try await withLocalStack() { localstack in
        let logs = try await localstack.logs()
        // LocalStack should log initialization messages
        #expect(!logs.isEmpty)
    }
}

// TODO: Add AWS SDK integration test when Feature 001 (HTTP wait) is available
// This will ensure LocalStack is fully initialized before testing
@Test func canInteractWithS3_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Skip for now - requires HTTP wait strategy to ensure full initialization
    // Will implement when Feature 001 is complete
}
```

**Acceptance**:
- Integration tests pass with Docker available
- Container starts successfully
- Endpoint URLs are correctly formed
- Configuration is applied correctly

### Step 8: Documentation and Examples

**Files to Update**:
1. `/Users/conor.mongey/workspace/Mongey/swift-test-containers/README.md`
2. `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md`
3. Create `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Examples/LocalStackExample.swift`

**README.md additions**:
```markdown
### LocalStack Module (AWS Services Emulation)

Test AWS service integrations locally without cloud connectivity:

```swift
import Testing
import TestContainers
import LocalStackModule

@Test func testS3Operations() async throws {
    let config = LocalStackConfig()
        .withServices([.s3])

    try await withLocalStack(config) { localstack in
        let endpoint = try await localstack.endpointURL()
        // Configure AWS SDK with endpoint
        // ...
    }
}
```

See [LocalStack documentation](https://docs.localstack.cloud) for service details.
```

**FEATURES.md update**: Move LocalStackContainer from Tier 4 to Implemented section

**Acceptance**: Documentation is clear, examples are runnable

---

## Testing Plan

### Unit Tests

**Location**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/LocalStackModuleTests/`

| Test Suite | Test Cases | Coverage |
|------------|------------|----------|
| `LocalStackConfigTests` | Default config, builder pattern, immutability, Hashable | Configuration API |
| `AWSServiceTests` | Enum cases, service names, CaseIterable | Service enumeration |
| `LocalStackContainerTests` | Request building, environment vars, service sorting | Container creation |

**Test Coverage Goals**: >85% for LocalStackModule code

### Integration Tests

**Location**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/LocalStackModuleTests/LocalStackIntegrationTests.swift`

**Opt-in**: `TESTCONTAINERS_RUN_DOCKER_TESTS=1`

| Test Case | Scenario | Verification |
|-----------|----------|--------------|
| `canStartLocalStackContainer_whenOptedIn` | Basic container start | Endpoint URL, region |
| `canConfigureCustomServices_whenOptedIn` | Custom services and region | Config applied |
| `canAccessContainerLogs_whenOptedIn` | Container logging | Logs accessible |
| `canInteractWithS3_whenOptedIn` (future) | AWS SDK S3 operations | Bucket creation, listing |
| `canInteractWithSQS_whenOptedIn` (future) | AWS SDK SQS operations | Queue creation, send/receive |
| `canInteractWithDynamoDB_whenOptedIn` (future) | AWS SDK DynamoDB operations | Table creation, items |

**AWS SDK Integration Tests** (requires AWS SDK for Swift dependency):
- Will be added after HTTP wait strategy is available (Feature 001)
- Test S3 bucket operations (create, list, delete)
- Test SQS queue operations (create, send, receive, delete)
- Test DynamoDB table operations (create, put, get, delete)

### Manual Testing Scenarios

1. **S3 File Upload/Download**:
   ```bash
   # Start container with LocalStack module
   # Use AWS CLI to test S3 operations
   aws --endpoint-url=http://localhost:<port> s3 mb s3://test-bucket
   aws --endpoint-url=http://localhost:<port> s3 ls
   ```

2. **SQS Message Queue**:
   ```bash
   # Create queue and send message
   aws --endpoint-url=http://localhost:<port> sqs create-queue --queue-name test-queue
   aws --endpoint-url=http://localhost:<port> sqs send-message --queue-url <url> --message-body "test"
   ```

3. **DynamoDB Table Operations**:
   ```bash
   # Create table
   aws --endpoint-url=http://localhost:<port> dynamodb create-table --table-name test-table ...
   aws --endpoint-url=http://localhost:<port> dynamodb list-tables
   ```

4. **Multiple Services**:
   - Start LocalStack with S3, SQS, DynamoDB
   - Verify all services are accessible
   - Test service-to-service interactions (e.g., S3 event → SQS)

5. **Version Compatibility**:
   - Test with LocalStack 2.x images
   - Test with LocalStack 3.x images
   - Verify backwards compatibility

---

## Acceptance Criteria

### Must Have

- [ ] `AWSService` enum with common AWS services (S3, SQS, DynamoDB, Lambda, etc.)
- [ ] `LocalStackConfig` struct with builder pattern
- [ ] `LocalStackContainer` actor with endpoint helpers
- [ ] `withLocalStack()` scoped lifecycle function
- [ ] Default configuration (image 3.4, port 4566, region us-east-1)
- [ ] Service selection via Set<AWSService>
- [ ] Region configuration support
- [ ] Automatic environment variable setup (SERVICES, DEFAULT_REGION, LOCALSTACK_HOST)
- [ ] endpointURL() method for AWS SDK configuration
- [ ] region() method for AWS SDK configuration
- [ ] TCP port wait strategy (until HTTP wait available)
- [ ] Unit tests for configuration and request building
- [ ] Integration tests with real LocalStack container
- [ ] Documentation in README.md and FEATURES.md
- [ ] Code follows existing swift-test-containers patterns
- [ ] Sendable and Hashable conformance throughout

### Should Have

- [ ] HTTP wait strategy on `/_localstack/health` endpoint (when Feature 001 available)
- [ ] Persistence support via volume mounts (when Feature 012 available)
- [ ] Service-specific endpoint helpers (serviceEndpoint(for:))
- [ ] AWS SDK for Swift integration examples
- [ ] Example test for S3 bucket operations
- [ ] Example test for SQS queue operations
- [ ] Example test for DynamoDB table operations
- [ ] Custom environment variable support
- [ ] Timeout configuration

### Nice to Have

- [ ] LocalStack Pro features support (advanced services)
- [ ] Init scripts support (via bind mount)
- [ ] Custom LocalStack configuration files
- [ ] CloudFormation stack deployment helpers
- [ ] Lambda function deployment helpers
- [ ] Multi-region support (though LocalStack is single-region)
- [ ] Network mode configuration for container-to-container communication
- [ ] Automatic credential generation
- [ ] Service health check helpers per service
- [ ] Migration guide from generic ContainerRequest to LocalStackContainer

### Definition of Done

- All "Must Have" criteria completed
- All "Should Have" criteria completed (or marked for future enhancement)
- All unit tests passing (>85% coverage)
- All integration tests passing (opt-in with Docker)
- Documentation complete with working examples
- Code review completed
- No regressions in existing swift-test-containers functionality
- Manually tested with at least 3 AWS services (S3, SQS, DynamoDB)
- Package.swift updated with new module target
- Module can be imported and used independently
- Follows Swift API design guidelines
- All public APIs have documentation comments

---

## Future Enhancements

### Phase 2: Advanced Features

1. **LocalStack Pro Support**:
   - API key configuration
   - Advanced services (RDS, Lambda layers, etc.)
   - Multi-account support

2. **Init Scripts**:
   - Support for initialization scripts
   - Seed data loading
   - Pre-configured resources

3. **CloudFormation Integration**:
   - Deploy CloudFormation stacks on startup
   - Template validation
   - Stack lifecycle management

4. **Lambda Helpers**:
   - Deploy Lambda functions
   - Invoke functions
   - Test event triggers

5. **Network Configuration**:
   - Container-to-container communication
   - Custom network aliases
   - Service discovery

6. **Advanced Wait Strategies**:
   - Wait for specific services to be ready
   - Custom health check predicates
   - Service-specific readiness probes

### Phase 3: Additional Modules

Following the LocalStack pattern, create similar modules for:
- PostgresContainer
- RedisContainer
- MongoDBContainer
- MinioContainer (S3-compatible)
- KafkaContainer
- ElasticsearchContainer

---

## References

### External Documentation

- **LocalStack Official**: https://docs.localstack.cloud
- **LocalStack Docker Hub**: https://hub.docker.com/r/localstack/localstack
- **Testcontainers LocalStack (Java)**: https://java.testcontainers.org/modules/localstack/
- **Testcontainers LocalStack (Go)**: https://golang.testcontainers.org/modules/localstack/
- **Testcontainers LocalStack (Node)**: https://node.testcontainers.org/modules/localstack/
- **AWS SDK for Swift**: https://github.com/awslabs/aws-sdk-swift

### Related Files

**Core TestContainers**:
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` - Base container API
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift` - Container actor
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift` - Scoped lifecycle
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift` - Docker CLI integration

**Related Features**:
- Feature 001: HTTP Wait Strategy (/_localstack/health endpoint)
- Feature 012: Volume Mounts (persistence support)
- Feature 023: Network Creation (container-to-container communication)

### LocalStack Environment Variables Reference

| Variable | Purpose | Default | Version |
|----------|---------|---------|---------|
| `SERVICES` | Comma-separated list of services to enable | All services | All |
| `DEFAULT_REGION` | AWS region | us-east-1 | All |
| `LOCALSTACK_HOST` | External hostname for service communication | localhost.localstack.cloud:4566 | 2.0+ |
| `HOSTNAME_EXTERNAL` | Legacy external hostname | - | 0.10+ |
| `DEBUG` | Enable debug logging | 0 | All |
| `PERSISTENCE` | Enable state persistence | 0 | All |
| `LAMBDA_EXECUTOR` | Lambda execution mode (docker/local) | docker | All |
| `DATA_DIR` | Persistence directory | /var/lib/localstack | All |

### LocalStack Supported Services (v3.4)

**Tier 1 (Fully Supported)**:
- S3, SQS, DynamoDB, Lambda, API Gateway, CloudWatch, SNS, Kinesis, CloudFormation, IAM, STS, SSM, Secrets Manager, EventBridge, StepFunctions

**Tier 2 (Community Support)**:
- EC2, RDS, Redshift, ElastiCache, Elasticsearch, OpenSearch, ECS, EKS, KMS, Athena, Glue, Firehose, CloudWatch Logs, Cognito, AppSync, X-Ray

**Pro-Only Services**:
- RDS (advanced features), Lambda (layers, container images), EC2 (advanced networking), ECS (full support), EKS (full support)

---

## Implementation Checklist

### Setup
- [ ] Create `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/LocalStackModule/` directory
- [ ] Update `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Package.swift` with new target
- [ ] Create test directory structure

### Core Implementation
- [ ] Implement `AWSService` enum (all common services)
- [ ] Implement `LocalStackConfig` struct with builder methods
- [ ] Implement `LocalStackContainer` actor with endpoint helpers
- [ ] Implement `buildContainerRequest()` function
- [ ] Implement `withLocalStack()` scoped function
- [ ] Add proper documentation comments to all public APIs

### Testing
- [ ] Write unit tests for `AWSService` enum
- [ ] Write unit tests for `LocalStackConfig` builder pattern
- [ ] Write unit tests for `buildContainerRequest()` logic
- [ ] Write unit tests for environment variable generation
- [ ] Write integration test: basic container startup
- [ ] Write integration test: custom service selection
- [ ] Write integration test: custom region configuration
- [ ] Write integration test: log access

### Documentation
- [ ] Update README.md with LocalStack module section
- [ ] Add usage examples to README.md
- [ ] Update FEATURES.md (move to Implemented)
- [ ] Create example file with common scenarios
- [ ] Document AWS SDK integration pattern
- [ ] Add troubleshooting section

### Quality Assurance
- [ ] Run unit tests (all pass)
- [ ] Run integration tests with Docker (opt-in, all pass)
- [ ] Test with LocalStack 3.4 image
- [ ] Test with LocalStack 2.3 image (backwards compatibility)
- [ ] Manual test: S3 bucket operations
- [ ] Manual test: SQS queue operations
- [ ] Manual test: DynamoDB table operations
- [ ] Code review
- [ ] Performance check (startup time < 10s for simple config)

### Finalization
- [ ] Ensure all public APIs have doc comments
- [ ] Verify Sendable/Hashable conformance
- [ ] Check code style consistency
- [ ] Update this feature ticket with completion notes
- [ ] Mark as implemented in FEATURES.md

---

## Notes

### Design Decisions

1. **Module Separation**: LocalStack is a separate module (LocalStackModule) rather than part of core TestContainers to:
   - Keep core library lightweight
   - Allow optional dependency management
   - Enable versioning independence
   - Follow testcontainers-go module pattern

2. **Service Selection**: Using `Set<AWSService>?` where `nil` means "all services":
   - Matches LocalStack's default behavior
   - Type-safe service selection
   - Prevents typos in service names
   - Explicit vs implicit service enablement

3. **Wait Strategy**: Initially use TCP wait, upgrade to HTTP when available:
   - TCP wait is sufficient for basic functionality
   - HTTP `/_localstack/health` endpoint is more reliable
   - Graceful degradation if Feature 001 not implemented yet

4. **Endpoint Helpers**: Same endpoint for all services because LocalStack uses a single edge port:
   - `endpointURL()` returns base endpoint
   - `serviceEndpoint(for:)` exists for API consistency (may differ in future LocalStack versions)

5. **Actor Pattern**: LocalStackContainer is an actor to:
   - Match Container actor pattern
   - Thread-safe access to container state
   - Async methods for I/O operations

### Implementation Complexity

**Medium-High** because:
- New module setup required (Package.swift updates)
- Extensive enum definition (25+ AWS services)
- Integration with AWS SDK patterns
- Documentation for AWS-specific use cases
- Testing with multiple AWS services

**Mitigating Factors**:
- Follows established ContainerRequest patterns
- Most complexity is in configuration, not logic
- Docker client integration already exists
- Can leverage existing wait strategies

### Dependencies

**Blocking**:
- None (can implement with current TCP wait strategy)

**Enhanced By**:
- Feature 001 (HTTP Wait Strategy) - Better readiness detection
- Feature 012 (Volume Mounts) - Persistence support

**Enables**:
- AWS service integration testing
- Serverless application testing
- Multi-service orchestration tests
- Cloud migration validation

---

**Created**: 2025-12-15
**Last Updated**: 2025-12-15
**Assignee**: TBD
**Target Version**: 0.3.0
**Estimated Effort**: 3-5 days
