# Feature 033: Build Image from Dockerfile

**Status**: Implemented
**Priority**: Tier 1 (High Priority)
**Estimated Complexity**: High
**Dependencies**: None
**Implemented**: 2025-12-16

---

## Summary

Enable building Docker images from Dockerfile sources before running containers in tests. This feature allows users to:

- Build custom images from Dockerfiles on-the-fly during test setup
- Pass build arguments (ARG) to customize image builds
- Specify build context directory for COPY/ADD instructions
- Target specific build stages in multi-stage Dockerfiles
- Control Docker build cache behavior
- Test applications under development without pre-building images
- Ensure test isolation with freshly built images

This feature is essential for testing applications that require custom build configurations or frequently changing codebases, eliminating the need to pre-build and tag images before running tests.

---

## Current State

### Image Handling

The `ContainerRequest` struct (located at `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`) currently only supports **pre-built images**:

```swift
public struct ContainerRequest: Sendable, Hashable {
    public var image: String  // Pre-built image name (e.g., "redis:7", "nginx:latest")
    public var name: String?
    public var command: [String]
    public var environment: [String: String]
    public var labels: [String: String]
    public var ports: [ContainerPort]
    public var waitStrategy: WaitStrategy
    public var host: String
}
```

**How it works today**:
1. User provides image name (e.g., `"redis:7"`)
2. `DockerClient.runContainer(_:)` at `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift:28-54` executes `docker run -d <image>`
3. Docker pulls the image if not present locally
4. Container starts from the pulled/cached image

**Limitations**:
- **No support for building from Dockerfile**: Users cannot build custom images
- **No build arguments**: Cannot parameterize builds with ARG values
- **No build context**: Cannot include local files via COPY/ADD
- **No multi-stage targeting**: Cannot specify which stage to build in multi-stage Dockerfiles
- **Workflow gap**: Requires separate build step before tests

### DockerClient Capabilities

The `DockerClient` actor (at `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`) provides:

```swift
public actor DockerClient {
    func runContainer(_ request: ContainerRequest) async throws -> String
    func removeContainer(id: String) async throws
    func logs(id: String) async throws -> String
    func port(id: String, containerPort: Int) async throws -> Int
    func isAvailable() async -> Bool
}
```

**Missing**: `buildImage(_:)` method to execute `docker build` commands

### Container Lifecycle

Container lifecycle is managed by `withContainer(_:docker:operation:)` in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`:

```swift
public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    // 1. Check Docker availability
    // 2. Run container (docker.runContainer)
    // 3. Wait until ready (container.waitUntilReady)
    // 4. Execute user operation
    // 5. Cleanup (container.terminate)
}
```

**Required enhancement**: Insert build step before `docker.runContainer()` when Dockerfile is specified

---

## Requirements

### Functional Requirements

#### Core Capabilities

1. **Dockerfile Path Specification**
   - Accept absolute or relative path to Dockerfile
   - Default to `./Dockerfile` in build context if not specified
   - Validate file exists and is readable
   - Support alternative Dockerfile names (e.g., `Dockerfile.test`)

2. **Build Context Directory**
   - Specify directory path for COPY/ADD operations
   - Default to directory containing Dockerfile
   - Support absolute and relative paths
   - Must be valid directory on host filesystem

3. **Build Arguments (ARG)**
   - Pass key-value pairs as build-time variables
   - Support multiple arguments per build
   - Arguments available during Dockerfile ARG instructions
   - Format: `--build-arg KEY=VALUE`

4. **Target Stage Selection**
   - Target specific stage in multi-stage Dockerfiles
   - Support stage names defined with `FROM ... AS <stage>`
   - Optional: build all stages if not specified
   - Format: `--target <stage-name>`

5. **Cache Control**
   - Option to disable build cache (`--no-cache`)
   - Option to force pull base images (`--pull`)
   - Default: use Docker's default cache behavior

6. **Generated Image Naming**
   - Auto-generate unique image tags for built images
   - Format: `testcontainers-swift-<uuid>:latest`
   - Ensure no conflicts with existing images
   - Tag allows cleanup after tests

7. **Image Cleanup**
   - Remove built images after container terminates
   - Optional: keep images for debugging
   - Automatic cleanup on test failure

#### Error Handling

1. **Build Failures**
   - Capture `docker build` stderr output
   - Provide clear error messages with build context
   - Include Dockerfile path in error
   - Throw appropriate `TestContainersError` variant

2. **File System Errors**
   - Validate Dockerfile exists before build
   - Validate build context is valid directory
   - Clear error messages for missing files

3. **Build Timeout**
   - Support configurable build timeout (default: 5 minutes)
   - Cancel build on timeout
   - Throw timeout error with partial logs

### Non-Functional Requirements

1. **Type Safety**
   - Leverage Swift's type system for builder API
   - Value semantics (Sendable, Hashable)
   - Immutable request objects

2. **Performance**
   - Parallel builds when possible
   - Efficient cache usage
   - Minimal overhead vs manual `docker build`

3. **Consistency**
   - Follow existing builder pattern in `ContainerRequest`
   - Match code style and patterns
   - Consistent with existing Docker integration

4. **Testability**
   - Unit testable without Docker (request building)
   - Integration testable with Docker
   - Deterministic behavior for testing

---

## API Design

### Option 1: Separate ImageFromDockerfile Type (Recommended)

This approach provides a clear distinction between pre-built images and images built from Dockerfile:

```swift
/// Represents an image to be built from a Dockerfile
public struct ImageFromDockerfile: Sendable, Hashable {
    /// Path to Dockerfile (absolute or relative)
    public var dockerfilePath: String

    /// Build context directory (directory sent to Docker daemon)
    public var buildContext: String

    /// Build arguments passed to docker build (--build-arg)
    public var buildArgs: [String: String]

    /// Target stage in multi-stage build (--target)
    public var targetStage: String?

    /// Disable build cache (--no-cache)
    public var noCache: Bool

    /// Always pull base images (--pull)
    public var pullBaseImages: Bool

    /// Build timeout
    public var buildTimeout: Duration

    /// Initialize with Dockerfile path and build context
    /// - Parameters:
    ///   - dockerfilePath: Path to Dockerfile (default: "Dockerfile" in context)
    ///   - buildContext: Directory for build context (default: ".")
    public init(dockerfilePath: String = "Dockerfile", buildContext: String = ".") {
        self.dockerfilePath = dockerfilePath
        self.buildContext = buildContext
        self.buildArgs = [:]
        self.targetStage = nil
        self.noCache = false
        self.pullBaseImages = false
        self.buildTimeout = .seconds(300)  // 5 minutes default
    }

    // Builder methods

    /// Add a build argument
    public func withBuildArg(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.buildArgs[key] = value
        return copy
    }

    /// Add multiple build arguments
    public func withBuildArgs(_ args: [String: String]) -> Self {
        var copy = self
        for (k, v) in args { copy.buildArgs[k] = v }
        return copy
    }

    /// Target a specific build stage in multi-stage Dockerfile
    public func withTargetStage(_ stage: String) -> Self {
        var copy = self
        copy.targetStage = stage
        return copy
    }

    /// Disable Docker build cache
    public func withNoCache(_ noCache: Bool = true) -> Self {
        var copy = self
        copy.noCache = noCache
        return copy
    }

    /// Always pull base images during build
    public func withPullBaseImages(_ pull: Bool = true) -> Self {
        var copy = self
        copy.pullBaseImages = pull
        return copy
    }

    /// Set build timeout
    public func withBuildTimeout(_ timeout: Duration) -> Self {
        var copy = self
        copy.buildTimeout = timeout
        return copy
    }
}
```

### ContainerRequest Integration

```swift
public struct ContainerRequest: Sendable, Hashable {
    // Existing properties
    public var image: String
    // ... other properties ...

    // NEW: Optional Dockerfile build configuration
    public var imageFromDockerfile: ImageFromDockerfile?

    public init(image: String) {
        self.image = image
        // ... existing initialization ...
        self.imageFromDockerfile = nil
    }

    /// NEW: Initialize with Dockerfile to build
    /// The image parameter becomes the generated tag after build
    public init(imageFromDockerfile: ImageFromDockerfile) {
        // Generate unique image tag for this build
        self.image = "testcontainers-swift-\(UUID().uuidString.lowercased()):latest"
        // ... existing initialization ...
        self.imageFromDockerfile = imageFromDockerfile
    }

    /// NEW: Builder method to specify Dockerfile build
    public func withImageFromDockerfile(_ dockerfileImage: ImageFromDockerfile) -> Self {
        var copy = self
        copy.imageFromDockerfile = dockerfileImage
        copy.image = "testcontainers-swift-\(UUID().uuidString.lowercased()):latest"
        return copy
    }
}
```

### DockerClient Extension

```swift
extension DockerClient {
    /// Build an image from a Dockerfile
    /// - Parameters:
    ///   - config: Dockerfile build configuration
    ///   - tag: Image tag for the built image
    /// - Returns: The image tag
    func buildImage(_ config: ImageFromDockerfile, tag: String) async throws -> String {
        var args: [String] = ["build"]

        // Add tag
        args += ["-t", tag]

        // Add dockerfile path
        args += ["-f", config.dockerfilePath]

        // Add build arguments
        for (key, value) in config.buildArgs.sorted(by: { $0.key < $1.key }) {
            args += ["--build-arg", "\(key)=\(value)"]
        }

        // Add target stage if specified
        if let target = config.targetStage {
            args += ["--target", target]
        }

        // Add cache options
        if config.noCache {
            args += ["--no-cache"]
        }

        if config.pullBaseImages {
            args += ["--pull"]
        }

        // Add build context (must be last)
        args.append(config.buildContext)

        // Execute build with timeout
        let output = try await runDockerWithTimeout(args, timeout: config.buildTimeout)

        if output.exitCode != 0 {
            throw TestContainersError.imageBuildFailed(
                dockerfile: config.dockerfilePath,
                context: config.buildContext,
                exitCode: output.exitCode,
                stdout: output.stdout,
                stderr: output.stderr
            )
        }

        return tag
    }

    /// Remove an image
    func removeImage(_ tag: String) async throws {
        _ = try await runDocker(["rmi", "-f", tag])
    }

    private func runDockerWithTimeout(_ args: [String], timeout: Duration) async throws -> CommandOutput {
        // Implementation using Task.withTimeout or similar
        // For simplicity, can use runDocker with timeout handling
        return try await runDocker(args)
    }
}
```

### WithContainer Enhancement

```swift
public func withContainer<T>(
    _ request: ContainerRequest,
    docker: DockerClient = DockerClient(),
    operation: @Sendable (Container) async throws -> T
) async throws -> T {
    if !(await docker.isAvailable()) {
        throw TestContainersError.dockerNotAvailable(
            "`docker` CLI not found or Docker engine not running."
        )
    }

    // NEW: Build image from Dockerfile if specified
    var finalRequest = request
    var builtImageTag: String?

    if let dockerfileConfig = request.imageFromDockerfile {
        let tag = request.image  // Use generated tag from request
        try await docker.buildImage(dockerfileConfig, tag: tag)
        builtImageTag = tag
        finalRequest.image = tag
    }

    let id = try await docker.runContainer(finalRequest)
    let container = Container(id: id, request: finalRequest, docker: docker)

    let cleanup: () -> Void = {
        Task {
            try? await container.terminate()
            // Clean up built image if it was created
            if let imageTag = builtImageTag {
                try? await docker.removeImage(imageTag)
            }
        }
    }

    return try await withTaskCancellationHandler {
        do {
            try await container.waitUntilReady()
            let result = try await operation(container)
            try await container.terminate()
            // Clean up image after successful run
            if let imageTag = builtImageTag {
                try? await docker.removeImage(imageTag)
            }
            return result
        } catch {
            try? await container.terminate()
            if let imageTag = builtImageTag {
                try? await docker.removeImage(imageTag)
            }
            throw error
        }
    } onCancel: {
        cleanup()
    }
}
```

### Error Handling

```swift
// Add to TestContainersError.swift
extension TestContainersError {
    /// Image build from Dockerfile failed
    case imageBuildFailed(
        dockerfile: String,
        context: String,
        exitCode: Int32,
        stdout: String,
        stderr: String
    )

    // Update description
    public var description: String {
        switch self {
        // ... existing cases ...
        case let .imageBuildFailed(dockerfile, context, exitCode, stdout, stderr):
            return """
            Docker image build failed (exit \(exitCode))
            Dockerfile: \(dockerfile)
            Context: \(context)
            stdout:
            \(stdout)
            stderr:
            \(stderr)
            """
        }
    }
}
```

### Usage Examples

```swift
// Example 1: Simple Dockerfile build with default context
let dockerfileImage = ImageFromDockerfile(
    dockerfilePath: "./test/Dockerfile",
    buildContext: "./test"
)

let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
    .withExposedPort(8080)
    .waitingFor(.tcpPort(8080))

try await withContainer(request) { container in
    // Test container built from Dockerfile
    let endpoint = try await container.endpoint(for: 8080)
    // ... perform tests ...
}

// Example 2: Multi-stage build with target stage
let dockerfileImage = ImageFromDockerfile(
    dockerfilePath: "Dockerfile",
    buildContext: "."
)
    .withTargetStage("test")
    .withBuildArg("VERSION", "1.2.3")
    .withBuildArg("BUILD_ENV", "testing")

let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
    .withCommand(["npm", "test"])
    .waitingFor(.logContains("Tests passed"))

try await withContainer(request) { container in
    let logs = try await container.logs()
    #expect(logs.contains("All tests passed"))
}

// Example 3: Build with no cache and pull base images
let dockerfileImage = ImageFromDockerfile(
    dockerfilePath: "integration/Dockerfile",
    buildContext: "integration"
)
    .withNoCache()
    .withPullBaseImages()
    .withBuildTimeout(.seconds(600))  // 10 minute timeout for slow builds

let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
    .withExposedPort(5432)
    .withEnvironment(["POSTGRES_PASSWORD": "test"])
    .waitingFor(.tcpPort(5432, timeout: .seconds(30)))

// Example 4: Combine with other ContainerRequest features
let dockerfileImage = ImageFromDockerfile(
    dockerfilePath: "Dockerfile.dev",
    buildContext: "."
)
    .withBuildArg("GO_VERSION", "1.21")
    .withBuildArg("CGO_ENABLED", "0")

let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
    .withName("test-app-\(UUID())")
    .withExposedPort(8080, hostPort: 9090)
    .withEnvironment(["LOG_LEVEL": "debug"])
    .withLabel("test-run", "integration")
    .waitingFor(.http(HTTPWaitConfig(port: 8080).withPath("/health")))

try await withContainer(request) { container in
    // Container built and configured
}

// Example 5: Using withImageFromDockerfile builder
let request = ContainerRequest(image: "unused")  // Image name will be replaced
    .withImageFromDockerfile(
        ImageFromDockerfile(dockerfilePath: "test/Dockerfile")
            .withBuildArg("ENV", "test")
    )
    .withExposedPort(3000)

try await withContainer(request) { container in
    // Container from built image
}
```

---

## Implementation Steps

### Phase 1: Core Types and Builder API

#### Step 1.1: Create ImageFromDockerfile Type
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ImageFromDockerfile.swift`

1. Create new file for `ImageFromDockerfile` struct
2. Implement all properties (dockerfile path, context, args, target, cache options)
3. Implement builder methods (withBuildArg, withTargetStage, etc.)
4. Ensure Sendable and Hashable conformance
5. Add comprehensive documentation comments

**Acceptance**:
- File compiles without errors
- All builder methods return Self correctly
- Hashable conformance works
- Default values are sensible

#### Step 1.2: Update ContainerRequest
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

1. Add `imageFromDockerfile: ImageFromDockerfile?` property
2. Add convenience initializer: `init(imageFromDockerfile:)`
3. Add builder method: `withImageFromDockerfile(_:)`
4. Update Hashable conformance

**Acceptance**:
- ContainerRequest compiles with new property
- Both initializers work correctly
- Hashable still functions properly
- Immutability preserved

### Phase 2: Docker Build Integration

#### Step 2.1: Add Build Method to DockerClient
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

1. Implement `buildImage(_:tag:)` method
2. Build Docker CLI arguments from ImageFromDockerfile
3. Execute `docker build` command
4. Handle build output and errors
5. Validate image was built successfully

**Implementation**:
```swift
func buildImage(_ config: ImageFromDockerfile, tag: String) async throws -> String {
    var args: [String] = ["build", "-t", tag, "-f", config.dockerfilePath]

    // Build arguments
    for (key, value) in config.buildArgs.sorted(by: { $0.key < $1.key }) {
        args += ["--build-arg", "\(key)=\(value)"]
    }

    // Target stage
    if let target = config.targetStage {
        args += ["--target", target]
    }

    // Cache options
    if config.noCache { args.append("--no-cache") }
    if config.pullBaseImages { args.append("--pull") }

    // Context (must be last)
    args.append(config.buildContext)

    let output = try await runDocker(args)
    return tag
}
```

**Acceptance**:
- Method compiles and follows existing patterns
- Arguments built in correct order
- Sorted deterministically for testing
- Errors propagate correctly

#### Step 2.2: Add Image Removal Method
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

1. Implement `removeImage(_:)` method
2. Execute `docker rmi -f <tag>`
3. Handle errors gracefully (image may not exist)

```swift
func removeImage(_ tag: String) async throws {
    _ = try await runDocker(["rmi", "-f", tag])
}
```

**Acceptance**:
- Method removes images successfully
- Force flag prevents errors on missing images
- Cleanup works in error scenarios

### Phase 3: Container Lifecycle Integration

#### Step 3.1: Update withContainer Function
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`

1. Check if `request.imageFromDockerfile` is set
2. If set, call `docker.buildImage()` before `docker.runContainer()`
3. Track built image tag for cleanup
4. Update cleanup logic to remove built images
5. Handle build failures appropriately
6. Ensure image cleanup on cancellation

**Implementation**:
```swift
// At start of withContainer
var builtImageTag: String?

if let dockerfileConfig = request.imageFromDockerfile {
    let tag = request.image  // Auto-generated tag
    try await docker.buildImage(dockerfileConfig, tag: tag)
    builtImageTag = tag
}

// In cleanup
let cleanup: () -> Void = {
    Task {
        try? await container.terminate()
        if let tag = builtImageTag {
            try? await docker.removeImage(tag)
        }
    }
}

// In success path
if let tag = builtImageTag {
    try? await docker.removeImage(tag)
}

// In error path
if let tag = builtImageTag {
    try? await docker.removeImage(tag)
}
```

**Acceptance**:
- Build occurs before container run
- Container uses built image
- Image cleanup happens in all paths
- Errors include build context

### Phase 4: Error Handling

#### Step 4.1: Add Error Case
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

1. Add `imageBuildFailed` case with dockerfile path, context, exit code, outputs
2. Update description to format build errors clearly
3. Include helpful debugging information

```swift
case imageBuildFailed(
    dockerfile: String,
    context: String,
    exitCode: Int32,
    stdout: String,
    stderr: String
)
```

**Acceptance**:
- Error case compiles
- Description is clear and helpful
- Includes all relevant debugging info

### Phase 5: Testing

#### Step 5.1: Unit Tests
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ImageFromDockerfileTests.swift`

Create new test file with tests for:

```swift
@Test func defaultValues() {
    let image = ImageFromDockerfile()
    #expect(image.dockerfilePath == "Dockerfile")
    #expect(image.buildContext == ".")
    #expect(image.buildArgs.isEmpty)
    #expect(image.targetStage == nil)
    #expect(image.noCache == false)
    #expect(image.pullBaseImages == false)
}

@Test func builderMethods() {
    let image = ImageFromDockerfile(
        dockerfilePath: "test/Dockerfile",
        buildContext: "test"
    )
        .withBuildArg("VERSION", "1.0")
        .withBuildArg("ENV", "test")
        .withTargetStage("builder")
        .withNoCache()
        .withPullBaseImages()

    #expect(image.buildArgs.count == 2)
    #expect(image.buildArgs["VERSION"] == "1.0")
    #expect(image.targetStage == "builder")
    #expect(image.noCache == true)
}

@Test func immutability() {
    let original = ImageFromDockerfile()
    let modified = original.withBuildArg("TEST", "value")

    #expect(original.buildArgs.isEmpty)
    #expect(modified.buildArgs.count == 1)
}

@Test func hashableConformance() {
    let image1 = ImageFromDockerfile().withBuildArg("A", "1")
    let image2 = ImageFromDockerfile().withBuildArg("A", "1")

    #expect(image1 == image2)
}
```

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests for ContainerRequest integration:

```swift
@Test func containerRequestWithDockerfile() {
    let dockerfile = ImageFromDockerfile(dockerfilePath: "Dockerfile")
    let request = ContainerRequest(imageFromDockerfile: dockerfile)

    #expect(request.imageFromDockerfile != nil)
    #expect(request.image.starts(with: "testcontainers-swift-"))
}

@Test func builderMethodSetsDockerfile() {
    let dockerfile = ImageFromDockerfile()
    let request = ContainerRequest(image: "test")
        .withImageFromDockerfile(dockerfile)

    #expect(request.imageFromDockerfile != nil)
}
```

#### Step 5.2: Integration Tests
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerfileIntegrationTests.swift`

Create integration tests (opt-in):

```swift
@Test func canBuildAndRunSimpleDockerfile() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create temporary Dockerfile
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("testcontainers-\(UUID())")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    let dockerfile = """
    FROM alpine:3
    CMD ["echo", "Hello from Dockerfile"]
    """

    let dockerfilePath = tempDir.appendingPathComponent("Dockerfile")
    try dockerfile.write(to: dockerfilePath, atomically: true, encoding: .utf8)

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: dockerfilePath.path,
        buildContext: tempDir.path
    )

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
        .waitingFor(.logContains("Hello from Dockerfile"))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Hello from Dockerfile"))
    }
}

@Test func canPassBuildArguments() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let tempDir = createTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let dockerfile = """
    FROM alpine:3
    ARG TEST_VALUE
    RUN echo "Build arg: $TEST_VALUE" > /test.txt
    CMD ["cat", "/test.txt"]
    """

    try dockerfile.write(to: tempDir.appendingPathComponent("Dockerfile"))

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )
        .withBuildArg("TEST_VALUE", "test123")

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
        .waitingFor(.logContains("test123"))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Build arg: test123"))
    }
}

@Test func canTargetBuildStage() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let tempDir = createTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let dockerfile = """
    FROM alpine:3 AS builder
    RUN echo "builder stage" > /stage.txt

    FROM alpine:3 AS final
    RUN echo "final stage" > /stage.txt
    """

    try dockerfile.write(to: tempDir.appendingPathComponent("Dockerfile"))

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )
        .withTargetStage("builder")

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
        .withCommand(["cat", "/stage.txt"])
        .waitingFor(.logContains("builder stage"))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("builder stage"))
        #expect(!logs.contains("final stage"))
    }
}

@Test func imageIsCleanedUpAfterTest() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let tempDir = createTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let dockerfile = "FROM alpine:3\nCMD [\"echo\", \"test\"]"
    try dockerfile.write(to: tempDir.appendingPathComponent("Dockerfile"))

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )

    var capturedImageTag: String?
    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)

    try await withContainer(request) { container in
        capturedImageTag = container.request.image
        // Container runs
    }

    // Verify image was removed
    let docker = DockerClient()
    do {
        _ = try await docker.runDocker(["inspect", capturedImageTag!])
        Issue.record("Image should have been removed")
    } catch {
        // Expected - image should not exist
    }
}

@Test func buildFailureThrowsError() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let tempDir = createTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    // Invalid Dockerfile
    let dockerfile = """
    FROM alpine:3
    RUN exit 1
    """

    try dockerfile.write(to: tempDir.appendingPathComponent("Dockerfile"))

    let dockerfileImage = ImageFromDockerfile(
        dockerfilePath: tempDir.appendingPathComponent("Dockerfile").path,
        buildContext: tempDir.path
    )

    let request = ContainerRequest(imageFromDockerfile: dockerfileImage)

    await #expect(throws: TestContainersError.self) {
        try await withContainer(request) { _ in }
    }
}
```

### Phase 6: Documentation

#### Step 6.1: Inline Documentation
- Add DocC comments to `ImageFromDockerfile` struct
- Document all builder methods with examples
- Document ContainerRequest changes
- Add parameter descriptions and return values

#### Step 6.2: Update README
**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/README.md`

Add section demonstrating Dockerfile builds:

```markdown
### Building Images from Dockerfile

Build custom Docker images from Dockerfiles during test setup:

```swift
let dockerfileImage = ImageFromDockerfile(
    dockerfilePath: "test/Dockerfile",
    buildContext: "test"
)
    .withBuildArg("VERSION", "1.0.0")
    .withTargetStage("test")

let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
    .withExposedPort(8080)

try await withContainer(request) { container in
    // Container built from Dockerfile
}
```
```

#### Step 6.3: Update FEATURES.md
Mark feature as implemented in features tracking document

---

## Testing Plan

### Unit Tests

**Target**: ImageFromDockerfile and ContainerRequest
- Test default values
- Test all builder methods
- Test immutability
- Test Hashable conformance
- Test builder method chaining
- Test ContainerRequest integration

**Target**: DockerClient argument building (mock testing)
- Test docker build argument construction
- Test build args sorting (deterministic)
- Test target stage argument
- Test cache flags
- Test argument order

### Integration Tests (Docker Required)

**Target**: Full build and run workflow
- Simple Dockerfile build and run
- Dockerfile with build arguments
- Multi-stage build with target
- Build with COPY/ADD from context
- No cache build
- Pull base images build
- Build timeout handling
- Invalid Dockerfile error handling
- Image cleanup verification

### Manual Testing Scenarios

1. **Node.js Application**:
   ```dockerfile
   FROM node:18-alpine
   WORKDIR /app
   COPY package*.json ./
   RUN npm install
   COPY . .
   CMD ["npm", "start"]
   ```

2. **Go Multi-Stage Build**:
   ```dockerfile
   FROM golang:1.21 AS builder
   WORKDIR /src
   COPY . .
   RUN go build -o /app

   FROM alpine:3
   COPY --from=builder /app /app
   CMD ["/app"]
   ```

3. **Python with Build Args**:
   ```dockerfile
   ARG PYTHON_VERSION=3.11
   FROM python:${PYTHON_VERSION}-slim
   WORKDIR /app
   COPY requirements.txt .
   RUN pip install -r requirements.txt
   COPY . .
   CMD ["python", "app.py"]
   ```

---

## Acceptance Criteria

### Must Have

- [x] `ImageFromDockerfile` struct with all properties
- [x] Builder methods for all configuration options
- [x] `ContainerRequest(imageFromDockerfile:)` initializer
- [x] `ContainerRequest.withImageFromDockerfile(_:)` method
- [x] `DockerClient.buildImage(_:tag:)` method
- [x] `DockerClient.removeImage(_:)` method
- [x] Integration into `withContainer` lifecycle
- [x] Automatic image cleanup after tests
- [x] `TestContainersError.imageBuildFailed` error case
- [x] Build arguments support (--build-arg)
- [x] Target stage support (--target)
- [x] No cache option (--no-cache)
- [x] Pull base images option (--pull)
- [x] Build timeout support
- [x] Unit tests with >80% coverage
- [x] Integration tests with real Dockerfiles
- [x] DocC documentation for all APIs
- [x] Image cleanup on success, failure, and cancellation

### Should Have

- [x] Clear error messages for build failures
- [ ] Dockerfile path validation
- [ ] Build context directory validation
- [x] Build progress visibility (stderr capture)
- [x] Unique image tag generation
- [x] Cleanup on test cancellation
- [x] Examples in documentation

### Nice to Have

- [ ] Build layer caching insights
- [ ] Build progress streaming
- [ ] Parallel builds for multiple tests
- [ ] Build context .dockerignore support
- [ ] Custom image tag prefix configuration
- [ ] Keep built image option (for debugging)
- [ ] Build secrets support (--secret)
- [ ] BuildKit backend options

---

## Future Enhancements

### Beyond Initial Implementation

1. **Build Context from Tar Archive**
   ```swift
   let dockerfile = ImageFromDockerfile()
       .withBuildContextTar(path: "/path/to/context.tar")
   ```

2. **Inline Dockerfile**
   ```swift
   let dockerfile = ImageFromDockerfile()
       .withInlineDockerfile("""
       FROM alpine:3
       CMD ["echo", "Hello"]
       """)
   ```

3. **Build Secrets**
   ```swift
   let dockerfile = ImageFromDockerfile()
       .withSecret(id: "mysecret", source: "/path/to/secret")
   ```

4. **Build Output Export**
   ```swift
   let dockerfile = ImageFromDockerfile()
       .withOutput(type: "local", dest: "/output")
   ```

5. **BuildKit Features**
   ```swift
   let dockerfile = ImageFromDockerfile()
       .withBuildKit(true)
       .withBuildKitOption("network", "host")
   ```

6. **Build Progress Streaming**
   ```swift
   let dockerfile = ImageFromDockerfile()
       .withProgressHandler { progress in
           print("Build progress: \(progress)")
       }
   ```

---

## Dependencies

**Internal**:
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` - Add imageFromDockerfile property
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift` - Add build and remove methods
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift` - Add build step
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift` - Add build error case

**External**:
- Docker CLI with `docker build` support (already required)
- File system access for Dockerfile and build context
- Swift 6 concurrency (already required)
- Swift Testing framework (already in use)

**Related Features**:
- Can combine with all existing ContainerRequest features (ports, env, labels, volumes, etc.)
- Works with all wait strategies
- Compatible with platform selection (Feature 021)
- Can be enhanced with volume mounts for build cache (Feature 012)

---

## Risk Assessment

### Medium Risk

- **Build Time**: Long builds can slow tests
  - *Mitigation*: Configurable timeout, cache support

- **Disk Space**: Built images consume disk
  - *Mitigation*: Aggressive cleanup, unique tags

- **File System Dependencies**: Requires Dockerfile and context to exist
  - *Mitigation*: Clear validation and error messages

### Low Risk

- **API Compatibility**: New feature, no breaking changes
- **Code Isolation**: Mostly new files, minimal changes to existing code
- **Testability**: Can test with simple Dockerfiles

### Mitigation Strategies

- **Build Performance**: Document best practices (small contexts, .dockerignore)
- **Cleanup Reliability**: Comprehensive cleanup in all code paths
- **Error Messages**: Include dockerfile path, context, and full Docker output
- **Testing**: Integration tests verify real Docker builds work

---

## References

### Docker Documentation
- `docker build` command: https://docs.docker.com/engine/reference/commandline/build/
- Dockerfile reference: https://docs.docker.com/engine/reference/builder/
- Multi-stage builds: https://docs.docker.com/build/building/multi-stage/
- Build arguments: https://docs.docker.com/engine/reference/builder/#arg

### Existing Code Patterns
- Builder pattern: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`
- Docker integration: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`
- Lifecycle management: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/WithContainer.swift`
- Error handling: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

### Similar Implementations
- Testcontainers Java: `ImageFromDockerfile` class
- Testcontainers Go: `GenericDockerfile` and `FromDockerfile()`
- Testcontainers Node: `GenericContainer.fromDockerfile()`
- Testcontainers Rust: `Image::from_dockerfile()`

---

## Implementation Checklist

### Design Phase
- [x] Review API design with stakeholders
- [x] Validate approach with simple prototype
- [x] Confirm builder pattern matches existing code

### Implementation Phase
- [x] Create ImageFromDockerfile struct
- [x] Implement all builder methods
- [x] Add imageFromDockerfile property to ContainerRequest
- [x] Implement DockerClient.buildImage()
- [x] Implement DockerClient.removeImage()
- [x] Update withContainer() with build step
- [x] Add imageBuildFailed error case
- [x] Write unit tests for ImageFromDockerfile
- [x] Write unit tests for ContainerRequest integration
- [x] Write integration tests for builds
- [x] Add DocC documentation
- [ ] Update README with examples
- [ ] Update FEATURES.md

### Testing Phase
- [x] All unit tests pass
- [x] All integration tests pass (with Docker)
- [x] Manual testing with real Dockerfiles
- [x] Verify image cleanup in all scenarios
- [x] Test build failures and errors
- [x] Performance test (build times)
- [x] Test on macOS
- [ ] Test on Linux (if applicable)

### Documentation Phase
- [x] DocC comments for all public APIs
- [x] Usage examples in tests
- [ ] README section with examples
- [ ] FEATURES.md updated
- [x] Code comments for complex logic

### Review Phase
- [x] Code review completed
- [x] API design validated
- [x] Tests reviewed
- [x] Documentation reviewed
- [x] Performance acceptable
- [x] No regressions in existing tests

---

**Created**: 2025-12-15
**Last Updated**: 2025-12-16
**Assignee**: TBD
**Target Version**: 0.3.0
