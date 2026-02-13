# Feature 031: Image Pull Policy

## Summary

Add support for controlling when and how container images are pulled from registries via an `ImagePullPolicy` enum. This feature allows users to specify whether Docker should always pull the image, only pull if missing locally, or never pull (use only local images). This is essential for:
- Ensuring tests use the latest image versions in CI environments (always pull)
- Improving test performance by reusing local images (pull if missing)
- Running tests in offline/air-gapped environments (never pull)
- Explicit control over image freshness vs. performance trade-offs
- Preventing unexpected image updates during test runs

## Current State

The `ContainerRequest` struct (defined in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`) currently supports:
- Image selection via `image: String` property
- Container naming
- Command execution
- Environment variables
- Labels
- Port mappings
- Wait strategies
- Host configuration

The request is built using a fluent builder pattern with immutable `with*` methods that return modified copies:

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

    public func withName(_ name: String) -> Self
    public func withCommand(_ command: [String]) -> Self
    public func withEnvironment(_ environment: [String: String]) -> Self
    public func withLabel(_ key: String, _ value: String) -> Self
    public func withExposedPort(_ containerPort: Int, hostPort: Int? = nil) -> Self
    public func waitingFor(_ strategy: WaitStrategy) -> Self
    public func withHost(_ host: String) -> Self
}
```

The `DockerClient` actor (in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`) constructs Docker CLI arguments in the `runContainer` method (lines 28-54), which currently:
- Executes `docker run -d` directly with the specified image
- Does NOT check if the image exists locally
- Does NOT explicitly pull images before running
- Relies on Docker's default behavior: pull if missing

**Current Behavior**: Docker's default `docker run` behavior is to pull the image if it's not available locally. This means:
- First run: Image is pulled automatically (can be slow)
- Subsequent runs: Uses cached local image (fast, but may be stale)
- No control over when updates are fetched
- No explicit handling of pull failures

**Missing Capability**: No ability to:
1. Force pull latest image even if cached locally (always pull)
2. Explicitly skip pulling and use only local images (never pull)
3. Check if an image exists locally before attempting to run
4. Provide clear error messages for missing images in "never pull" mode

## Requirements

### Functional Requirements

1. **Three Pull Policy Modes**:
   - **Always**: Always pull the image from the registry, even if it exists locally
   - **IfNotPresent** (default): Pull the image only if it's not available locally
   - **Never**: Never pull the image; fail if not available locally

2. **Image Existence Check**:
   - For "Never" policy: Check if image exists locally before attempting to run
   - Provide clear error message if image is missing

3. **Explicit Pull Command**:
   - For "Always" policy: Execute `docker pull <image>` before `docker run`
   - Handle pull failures with appropriate error messages

4. **Default Behavior**:
   - Default to "IfNotPresent" to maintain backward compatibility
   - Existing code should work without changes

5. **Error Handling**:
   - Clear error when "Never" policy is used but image doesn't exist locally
   - Propagate Docker pull errors with full context (exit code, stderr)
   - Distinguish between pull failures and run failures

### Non-Functional Requirements

1. **API Consistency**: Follow existing builder pattern used in `ContainerRequest`
2. **Type Safety**: Use Swift enum for pull policy (not strings)
3. **Backward Compatibility**: Existing code continues to work unchanged
4. **Performance**: Minimize overhead for "IfNotPresent" mode (current behavior)
5. **Sendable/Hashable**: Conform to protocols used throughout the codebase

## API Design

Add an `ImagePullPolicy` enum and extend `ContainerRequest` with a pull policy property:

```swift
/// Determines when Docker should pull container images from registries
public enum ImagePullPolicy: Sendable, Hashable {
    /// Always pull the image from the registry, even if cached locally.
    /// Ensures you're always running the latest version but may be slower.
    /// Equivalent to running `docker pull <image>` before `docker run`.
    case always

    /// Pull the image only if it doesn't exist locally.
    /// This is the default behavior and balances performance with freshness.
    /// Equivalent to Docker's default `docker run` behavior.
    case ifNotPresent

    /// Never pull the image; only use images already available locally.
    /// Fails with an error if the image doesn't exist locally.
    /// Useful for air-gapped environments or when you want to ensure
    /// no network calls are made during tests.
    case never
}

extension ContainerRequest {
    public var imagePullPolicy: ImagePullPolicy

    /// Specify when the container image should be pulled from the registry
    ///
    /// - Parameter policy: The pull policy to use
    /// - Returns: A new ContainerRequest with the specified pull policy
    ///
    /// Examples:
    /// ```swift
    /// // Always pull latest image (useful in CI)
    /// let request = ContainerRequest(image: "postgres:latest")
    ///     .withImagePullPolicy(.always)
    ///
    /// // Only pull if not already cached (default)
    /// let request = ContainerRequest(image: "redis:7")
    ///     .withImagePullPolicy(.ifNotPresent)
    ///
    /// // Use only local images, fail if missing (offline mode)
    /// let request = ContainerRequest(image: "nginx:1.25")
    ///     .withImagePullPolicy(.never)
    /// ```
    public func withImagePullPolicy(_ policy: ImagePullPolicy) -> Self
}
```

### Usage Examples

```swift
// Example 1: Always pull latest in CI environment
let request = ContainerRequest(image: "postgres:latest")
    .withImagePullPolicy(.always)
    .withEnvironment(["POSTGRES_PASSWORD": "test"])
    .withExposedPort(5432)

// Example 2: Use cached images for faster local development
let request = ContainerRequest(image: "redis:7")
    .withImagePullPolicy(.ifNotPresent)  // This is the default
    .withExposedPort(6379)

// Example 3: Air-gapped/offline testing (fail fast if image missing)
let request = ContainerRequest(image: "nginx:1.25")
    .withImagePullPolicy(.never)
    .withExposedPort(80)

// Example 4: Default behavior (no policy specified)
let request = ContainerRequest(image: "alpine:3")
    .withCommand(["sh", "-c", "echo hello"])
// Uses .ifNotPresent by default

// Example 5: Ensure specific version is always fresh
let request = ContainerRequest(image: "mysql:8.0")
    .withImagePullPolicy(.always)
    .withEnvironment(["MYSQL_ROOT_PASSWORD": "root"])
    .withExposedPort(3306)
```

## Implementation Steps

### Step 1: Add ImagePullPolicy enum to ContainerRequest.swift

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

1. Add the `ImagePullPolicy` enum before the `ContainerRequest` struct definition (before line 26)
2. Add `imagePullPolicy` property to `ContainerRequest` (after line 34)
3. Initialize `imagePullPolicy` to `.ifNotPresent` in `init(image:)` (after line 44)
4. Add `withImagePullPolicy(_:)` builder method (after line 87)

```swift
/// Determines when Docker should pull container images from registries
public enum ImagePullPolicy: Sendable, Hashable {
    /// Always pull the image from the registry, even if cached locally
    case always

    /// Pull the image only if it doesn't exist locally (default)
    case ifNotPresent

    /// Never pull the image; only use images already available locally
    case never
}

public struct ContainerRequest: Sendable, Hashable {
    public var image: String
    public var name: String?
    public var command: [String]
    public var environment: [String: String]
    public var labels: [String: String]
    public var ports: [ContainerPort]
    public var waitStrategy: WaitStrategy
    public var host: String
    public var imagePullPolicy: ImagePullPolicy  // NEW

    public init(image: String) {
        self.image = image
        self.name = nil
        self.command = []
        self.environment = [:]
        self.labels = ["testcontainers.swift": "true"]
        self.ports = []
        self.waitStrategy = .none
        self.host = "127.0.0.1"
        self.imagePullPolicy = .ifNotPresent  // NEW: Default behavior
    }

    // ... existing builder methods ...

    public func withImagePullPolicy(_ policy: ImagePullPolicy) -> Self {
        var copy = self
        copy.imagePullPolicy = policy
        return copy
    }
}
```

### Step 2: Add helper methods to DockerClient

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Add two new helper methods to `DockerClient` actor:

1. **Method to check if image exists locally** (add after line 26, before `runContainer`):

```swift
/// Check if an image exists in the local Docker image cache
func imageExists(_ image: String) async -> Bool {
    do {
        let output = try await runner.run(executable: dockerPath, arguments: ["image", "inspect", image])
        return output.exitCode == 0
    } catch {
        return false
    }
}
```

2. **Method to pull an image** (add after `imageExists`):

```swift
/// Pull an image from a registry
func pullImage(_ image: String) async throws {
    let output = try await runner.run(executable: dockerPath, arguments: ["pull", image])
    if output.exitCode != 0 {
        throw TestContainersError.imagePullFailed(
            image: image,
            exitCode: output.exitCode,
            stdout: output.stdout,
            stderr: output.stderr
        )
    }
}
```

### Step 3: Update runContainer to handle pull policy

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Modify the `runContainer` method (currently lines 28-54) to handle the pull policy before executing `docker run`. Add this logic at the beginning of the method, right after the function declaration:

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    // Handle image pull policy
    switch request.imagePullPolicy {
    case .always:
        // Always pull the image, even if it exists locally
        try await pullImage(request.image)

    case .ifNotPresent:
        // Default Docker behavior: pull if not present
        // We rely on `docker run` to handle this automatically
        // No action needed here
        break

    case .never:
        // Verify image exists locally, fail if not
        let exists = await imageExists(request.image)
        if !exists {
            throw TestContainersError.imageNotFoundLocally(
                image: request.image,
                message: "Image '\(request.image)' not found locally and pull policy is set to 'never'. " +
                         "Either pull the image manually with 'docker pull \(request.image)' or change the pull policy."
            )
        }
    }

    // Existing docker run logic continues unchanged...
    var args: [String] = ["run", "-d"]
    // ... rest of the method
}
```

### Step 4: Add new error cases to TestContainersError

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

Add two new error cases to the `TestContainersError` enum (after line 7):

```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    case dockerNotAvailable(String)
    case commandFailed(command: [String], exitCode: Int32, stdout: String, stderr: String)
    case unexpectedDockerOutput(String)
    case timeout(String)
    case imageNotFoundLocally(image: String, message: String)  // NEW
    case imagePullFailed(image: String, exitCode: Int32, stdout: String, stderr: String)  // NEW

    public var description: String {
        switch self {
        case let .dockerNotAvailable(message):
            return "Docker not available: \(message)"
        case let .commandFailed(command, exitCode, stdout, stderr):
            return "Command failed (exit \(exitCode)): \(command.joined(separator: " "))\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
        case let .unexpectedDockerOutput(output):
            return "Unexpected Docker output: \(output)"
        case let .timeout(message):
            return "Timed out: \(message)"
        case let .imageNotFoundLocally(image, message):
            return "Image not found locally: \(image)\n\(message)"
        case let .imagePullFailed(image, exitCode, stdout, stderr):
            return "Failed to pull image '\(image)' (exit \(exitCode))\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
        }
    }
}
```

### Step 5: Update WithContainer to maintain backward compatibility

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`

No changes needed - the existing `withContainer` function will automatically use the default `.ifNotPresent` policy through `ContainerRequest.init`, maintaining backward compatibility.

## Testing Plan

### Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests for the builder pattern and pull policy:

```swift
@Test func buildsWithAlwaysPullPolicy() {
    let request = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.always)

    #expect(request.imagePullPolicy == .always)
}

@Test func buildsWithIfNotPresentPullPolicy() {
    let request = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.ifNotPresent)

    #expect(request.imagePullPolicy == .ifNotPresent)
}

@Test func buildsWithNeverPullPolicy() {
    let request = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.never)

    #expect(request.imagePullPolicy == .never)
}

@Test func defaultPullPolicyIsIfNotPresent() {
    let request = ContainerRequest(image: "alpine:3")

    #expect(request.imagePullPolicy == .ifNotPresent)
}

@Test func pullPolicyCanBeChainedWithOtherBuilders() {
    let request = ContainerRequest(image: "redis:7")
        .withImagePullPolicy(.always)
        .withExposedPort(6379)
        .withEnvironment(["REDIS_PASSWORD": "test"])

    #expect(request.imagePullPolicy == .always)
    #expect(request.ports.count == 1)
    #expect(request.environment["REDIS_PASSWORD"] == "test")
}

@Test func imagePullPolicyIsHashable() {
    let request1 = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.always)
    let request2 = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.always)
    let request3 = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.never)

    #expect(request1 == request2)
    #expect(request1 != request3)
}
```

### Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

Add Docker integration tests (gated behind `TESTCONTAINERS_RUN_DOCKER_TESTS=1`):

```swift
@Test func canStartContainerWithAlwaysPullPolicy_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // This will pull alpine:3 even if it exists locally
    let request = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.always)
        .withCommand(["sh", "-c", "echo 'test' && sleep 2"])
        .waitingFor(.logContains("test", timeout: .seconds(10)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("test"))
    }
}

@Test func canStartContainerWithIfNotPresentPullPolicy_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // This will use cached alpine:3 if available
    let request = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.ifNotPresent)
        .withCommand(["sh", "-c", "echo 'cached' && sleep 2"])
        .waitingFor(.logContains("cached", timeout: .seconds(10)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("cached"))
    }
}

@Test func canStartContainerWithNeverPullPolicy_whenImageExists() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // First, ensure the image exists by pulling it
    let setupRequest = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.always)
        .withCommand(["echo", "setup"])

    try await withContainer(setupRequest) { _ in
        // Image is now cached
    }

    // Now test with .never policy - should succeed
    let request = ContainerRequest(image: "alpine:3")
        .withImagePullPolicy(.never)
        .withCommand(["sh", "-c", "echo 'offline' && sleep 2"])
        .waitingFor(.logContains("offline", timeout: .seconds(10)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("offline"))
    }
}

@Test func failsWhenNeverPullPolicyAndImageMissing_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Use a tag that definitely doesn't exist locally
    let nonExistentImage = "alpine:this-tag-does-not-exist-12345"

    let request = ContainerRequest(image: nonExistentImage)
        .withImagePullPolicy(.never)
        .withCommand(["echo", "test"])

    do {
        try await withContainer(request) { _ in
            Issue.record("Should have thrown imageNotFoundLocally error")
        }
    } catch let error as TestContainersError {
        switch error {
        case .imageNotFoundLocally(let image, _):
            #expect(image == nonExistentImage)
        default:
            Issue.record("Expected imageNotFoundLocally error, got: \(error)")
        }
    } catch {
        Issue.record("Expected TestContainersError, got: \(error)")
    }
}

@Test func defaultPullPolicyBehavesLikeIfNotPresent_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Don't specify pull policy - should default to .ifNotPresent
    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "echo 'default' && sleep 2"])
        .waitingFor(.logContains("default", timeout: .seconds(10)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("default"))
    }
}
```

### Manual Testing

For validation, manually test the different policies:

```bash
# Set up environment
export TESTCONTAINERS_RUN_DOCKER_TESTS=1

# Test 1: Remove alpine:3 and test .always policy
docker rmi alpine:3 2>/dev/null || true
swift test --filter canStartContainerWithAlwaysPullPolicy_whenOptedIn

# Verify image was pulled
docker images alpine:3

# Test 2: Test .never policy with existing image
swift test --filter canStartContainerWithNeverPullPolicy_whenImageExists

# Test 3: Test .never policy with missing image
docker rmi alpine:this-tag-does-not-exist-12345 2>/dev/null || true
swift test --filter failsWhenNeverPullPolicyAndImageMissing_whenOptedIn

# Test 4: Performance comparison - time with .always vs .ifNotPresent
time swift test --filter canStartContainerWithAlwaysPullPolicy_whenOptedIn
time swift test --filter canStartContainerWithIfNotPresentPullPolicy_whenOptedIn
```

Expected results:
- `.always`: Should see "Pulling from library/alpine" in Docker output
- `.ifNotPresent`: Should start quickly if image is cached
- `.never` with existing image: Should start immediately
- `.never` with missing image: Should fail with clear error message

## Acceptance Criteria

This feature is considered complete when:

### 1. API Implementation
- [x] `ImagePullPolicy` enum is defined with three cases: `.always`, `.ifNotPresent`, `.never`
- [x] `ImagePullPolicy` conforms to `Sendable` and `Hashable`
- [x] `ContainerRequest` has `imagePullPolicy: ImagePullPolicy` property
- [x] `imagePullPolicy` defaults to `.ifNotPresent` in `ContainerRequest.init(image:)`
- [x] `withImagePullPolicy(_:)` builder method is implemented
- [x] Builder method follows existing pattern (copy-and-modify, returns `Self`)

### 2. Docker Integration
- [x] `DockerClient` has `imageExists(_:)` method that checks if image is cached locally
- [x] `DockerClient` has `pullImage(_:)` method that pulls an image from registry
- [x] `DockerClient.runContainer(_:)` handles `.always` policy by calling `pullImage(_:)` before run
- [x] `DockerClient.runContainer(_:)` handles `.ifNotPresent` policy by relying on Docker default behavior
- [x] `DockerClient.runContainer(_:)` handles `.never` policy by checking `imageExists(_:)` and throwing error if missing
- [x] Pull policy logic executes before the `docker run` command is constructed

### 3. Error Handling
- [x] `TestContainersError` has `imageNotFoundLocally(image:message:)` case
- [x] `TestContainersError` has `imagePullFailed(image:exitCode:stdout:stderr:)` case
- [x] Error descriptions are clear and actionable
- [x] `.never` policy with missing image produces helpful error message
- [x] Pull failures are propagated with full Docker error context

### 4. Testing
- [x] Unit tests verify all three pull policy values can be set
- [x] Unit tests verify default policy is `.ifNotPresent`
- [x] Unit tests verify pull policy can be chained with other builders
- [x] Unit tests verify pull policy is hashable
- [x] Integration test verifies `.always` policy pulls image every time
- [x] Integration test verifies `.ifNotPresent` policy uses cached images
- [x] Integration test verifies `.never` policy works with existing images
- [x] Integration test verifies `.never` policy throws error for missing images
- [x] Integration test verifies default behavior matches `.ifNotPresent`

### 5. Documentation
- [x] `ImagePullPolicy` enum has doc comments explaining each case
- [x] Doc comments include when to use each policy
- [x] `withImagePullPolicy(_:)` has doc comments with usage examples
- [x] Error messages clearly explain what went wrong and how to fix it

### 6. Code Quality & Compatibility
- [x] Code follows Swift conventions and existing codebase style
- [x] No breaking changes to existing API
- [x] Backward compatibility: existing code works without specifying pull policy
- [x] All public APIs are properly documented
- [x] Code properly handles actor isolation in `DockerClient`

## References

- Docker CLI documentation: `docker pull` command reference
- Docker CLI documentation: `docker image inspect` command for checking local images
- Docker run behavior: By default pulls image if not present locally
- Kubernetes ImagePullPolicy: Inspired by Kubernetes' approach (Always, IfNotPresent, Never)
- Testcontainers (Java): Similar pull policy implementation
- Existing `ContainerRequest` implementation: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`
- Existing `DockerClient` implementation: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`
- Existing `TestContainersError` definition: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

## Notes

### Design Decisions

1. **Enum vs. String**: Using an enum provides type safety and prevents typos, following the pattern used for `WaitStrategy` in the codebase.

2. **Default to `.ifNotPresent`**: This maintains backward compatibility with the current implicit behavior and matches Docker's default.

3. **Separate pull from run**: For `.always` policy, we execute `docker pull` before `docker run` rather than using `docker run --pull always` to:
   - Support older Docker versions that may not have the `--pull` flag
   - Provide explicit error handling for pull failures
   - Give clearer separation of concerns

4. **Image existence check**: For `.never` policy, we use `docker image inspect` to check if the image exists locally, providing a clear error message before attempting to run.

5. **Error types**: Added specific error cases for image-related failures to distinguish them from general command failures.

### Performance Considerations

- `.always`: Slowest, always hits the registry (network latency)
- `.ifNotPresent`: Balanced, fast after first pull
- `.never`: Fastest, no network calls, but requires pre-populated cache

### Use Cases

- **CI/CD pipelines**: Use `.always` to ensure latest images
- **Local development**: Use `.ifNotPresent` (default) for faster feedback
- **Air-gapped environments**: Use `.never` with pre-pulled images
- **Reproducible tests**: Use `.never` with pinned image tags

### Future Enhancements

Potential future improvements (not in scope for this feature):
- Support for authentication/private registries during pull
- Progress reporting for long pulls
- Parallel image pulling for multiple containers
- Image pre-warming/caching strategies
- Integration with Docker BuildKit for faster pulls
