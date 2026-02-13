# Feature 021: Platform Selection (--platform)

## Summary

Add support for specifying the target platform/architecture when starting containers via the `--platform` flag. This allows users to explicitly request containers for specific platforms (e.g., `linux/amd64`, `linux/arm64`) which is essential for:
- Running x86_64 containers on Apple Silicon Macs via emulation
- Running ARM64 containers on AMD64 hosts (when supported)
- Ensuring consistent behavior across different host architectures
- Testing multi-architecture images

## Current State

The `ContainerRequest` struct currently supports the following configuration options:

**Location**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

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
}
```

Available builder methods:
- `withName(_:)` - Set container name
- `withCommand(_:)` - Set command to run
- `withEnvironment(_:)` - Add environment variables
- `withLabel(_:_:)` - Add a label
- `withExposedPort(_:hostPort:)` - Add port mappings
- `waitingFor(_:)` - Set wait strategy
- `withHost(_:)` - Set host address

The `DockerClient.runContainer(_:)` method (lines 28-54) builds Docker CLI arguments from the `ContainerRequest` and executes `docker run -d` with flags for name, environment, ports, and labels. Currently, there is **no support for specifying platform**.

## Requirements

### Functional Requirements

1. **Platform String Support**: Accept standard Docker platform strings:
   - `linux/amd64` (x86_64)
   - `linux/arm64` (ARM64/aarch64)
   - `linux/arm/v7` (ARMv7)
   - `linux/arm/v6` (ARMv6)
   - Other platform strings supported by Docker

2. **Optional Configuration**: Platform selection should be optional (nil by default)
   - When nil: Docker uses default platform for the host
   - When set: Docker uses the specified platform

3. **Validation**: Basic validation of platform string format
   - Should follow pattern: `<os>/<architecture>[/variant]`
   - Examples: `linux/amd64`, `linux/arm64`, `linux/arm/v7`

4. **Error Handling**: Provide clear errors when:
   - Requested platform is not available for the image
   - Platform format is invalid
   - Docker daemon doesn't support multi-platform

### Non-Functional Requirements

1. **API Consistency**: Follow existing builder pattern used in `ContainerRequest`
2. **Type Safety**: Use Swift's type system to prevent common errors
3. **Backward Compatibility**: Existing code should continue to work without changes
4. **Documentation**: Include clear examples in code comments

## API Design

### Option 1: String-Based Approach (Recommended)

This approach provides maximum flexibility and mirrors Docker's API directly:

```swift
// In ContainerRequest.swift
public struct ContainerRequest: Sendable, Hashable {
    public var image: String
    public var name: String?
    public var command: [String]
    public var environment: [String: String]
    public var labels: [String: String]
    public var ports: [ContainerPort]
    public var waitStrategy: WaitStrategy
    public var host: String
    public var platform: String?  // NEW: Optional platform string

    public init(image: String) {
        // ... existing initialization
        self.platform = nil
    }

    // NEW: Builder method
    public func withPlatform(_ platform: String) -> Self {
        var copy = self
        copy.platform = platform
        return copy
    }
}
```

**Pros**:
- Simple and flexible
- Directly mirrors Docker CLI API
- Easy to support new platforms without code changes
- Users can pass any platform string Docker supports

**Cons**:
- No compile-time validation
- Typos possible (e.g., "linux/amd46" instead of "linux/amd64")

### Option 2: Enum-Based Approach

This approach provides type safety at the cost of flexibility:

```swift
public enum ContainerPlatform: String, Sendable, Hashable {
    case linuxAMD64 = "linux/amd64"
    case linuxARM64 = "linux/arm64"
    case linuxARMv7 = "linux/arm/v7"
    case linuxARMv6 = "linux/arm/v6"
    case linux386 = "linux/386"
    case linuxPPC64LE = "linux/ppc64le"
    case linuxS390X = "linux/s390x"

    // Allow custom platform strings
    case custom(String)

    var dockerValue: String {
        switch self {
        case .custom(let value):
            return value
        default:
            return self.rawValue
        }
    }
}

public struct ContainerRequest: Sendable, Hashable {
    // ...
    public var platform: ContainerPlatform?

    public func withPlatform(_ platform: ContainerPlatform) -> Self {
        var copy = self
        copy.platform = platform
        return copy
    }
}
```

**Pros**:
- Type-safe for common platforms
- Autocomplete in IDE
- Self-documenting

**Cons**:
- More complex
- Requires updates for new platforms
- `.custom()` case adds complexity

### Recommendation

**Use Option 1 (String-Based)** for the following reasons:
1. Matches the existing codebase's pragmatic approach (similar to how `host` is a plain `String`)
2. Simpler implementation and maintenance
3. Mirrors Docker's API directly
4. Forward-compatible with new platforms
5. Basic validation can be added in tests if needed

### Usage Examples

```swift
// Cross-platform testing: Force ARM64 on Apple Silicon
let request = ContainerRequest(image: "alpine:3")
    .withPlatform("linux/arm64")
    .withCommand(["uname", "-m"])

// Force AMD64 emulation on Apple Silicon
let request = ContainerRequest(image: "redis:7")
    .withPlatform("linux/amd64")
    .withExposedPort(6379)
    .waitingFor(.tcpPort(6379))

// Default behavior (no platform specified)
let request = ContainerRequest(image: "nginx:latest")
    .withExposedPort(80)
```

## Implementation Steps

### Step 1: Add Platform Property to ContainerRequest

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

1. Add `public var platform: String?` property to `ContainerRequest` struct (after line 34)
2. Initialize `platform` to `nil` in the `init(image:)` method (after line 44)
3. Add `withPlatform(_:)` builder method following the pattern of existing builder methods (after line 87)

```swift
public func withPlatform(_ platform: String) -> Self {
    var copy = self
    copy.platform = platform
    return copy
}
```

### Step 2: Update DockerClient to Pass Platform Flag

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Modify the `runContainer(_:)` method (lines 28-54) to include `--platform` flag when platform is set:

1. After the initial `var args: [String] = ["run", "-d"]` declaration (line 29)
2. Add platform check before name check (around line 31):

```swift
if let platform = request.platform {
    args += ["--platform", platform]
}
```

The platform flag should come early in the command (after `run -d` but before other flags) to match typical Docker CLI ordering.

### Step 3: Add Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests following the existing pattern (after line 13):

```swift
@Test func buildsPlatformInRequest() {
    let request = ContainerRequest(image: "alpine:3")
        .withPlatform("linux/amd64")

    #expect(request.platform == "linux/amd64")
}

@Test func defaultsToNoPlatform() {
    let request = ContainerRequest(image: "alpine:3")

    #expect(request.platform == nil)
}

@Test func buildsMultipleConfigOptionsIncludingPlatform() {
    let request = ContainerRequest(image: "alpine:3")
        .withPlatform("linux/arm64")
        .withName("test-container")
        .withExposedPort(8080)

    #expect(request.platform == "linux/arm64")
    #expect(request.name == "test-container")
    #expect(request.ports.count == 1)
}
```

### Step 4: Add Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

Add integration tests to verify Docker receives the platform flag correctly (after line 19):

```swift
@Test func canStartContainer_withPlatformSpecified() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Use a multi-arch image
    let request = ContainerRequest(image: "alpine:3")
        .withPlatform("linux/amd64")
        .withCommand(["sh", "-c", "uname -m && sleep 5"])
        .waitingFor(.logContains("x86_64", timeout: .seconds(10)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("x86_64"))
    }
}

@Test func canStartContainer_withARM64Platform() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withPlatform("linux/arm64")
        .withCommand(["sh", "-c", "uname -m && sleep 5"])
        .waitingFor(.logContains("aarch64", timeout: .seconds(10)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("aarch64"))
    }
}
```

### Step 5: Update Documentation

1. Add inline documentation to the `withPlatform(_:)` method explaining:
   - What platform strings are valid
   - Common examples (`linux/amd64`, `linux/arm64`)
   - When to use this feature
   - Note that invalid platforms will fail at Docker runtime

2. Add example usage to README or package documentation (if exists)

### Step 6: Manual Testing

Test with various scenarios:

```bash
# Test AMD64 on Apple Silicon (if applicable)
TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test

# Verify platform flag is passed correctly
docker ps -a --filter "label=testcontainers.swift=true"

# Check container architecture
docker inspect <container-id> | grep Architecture
```

## Testing Plan

### Unit Tests

1. **Builder Pattern Test**: Verify `withPlatform()` sets the platform property correctly
2. **Default Value Test**: Verify platform defaults to `nil` when not specified
3. **Chaining Test**: Verify platform can be combined with other builder methods
4. **Hashable Test**: Verify two `ContainerRequest` instances with same platform are equal

### Integration Tests

1. **Platform AMD64 Test**: Start container with `linux/amd64` and verify architecture via `uname -m`
2. **Platform ARM64 Test**: Start container with `linux/arm64` and verify architecture
3. **No Platform Test**: Verify existing behavior (no platform specified) continues to work
4. **Multi-Arch Image Test**: Use a known multi-arch image (alpine, redis, nginx) and verify different platforms work
5. **Invalid Platform Test**: Verify appropriate error when invalid platform is requested (should fail at Docker CLI level)

### Manual Testing

1. **Cross-Platform Emulation**: On Apple Silicon, test AMD64 containers run via emulation
2. **Native Platform**: Test containers run on native platform when not specified
3. **Error Cases**: Test with non-existent platforms to verify error messages are clear
4. **Performance**: Verify no performance regression when platform is not specified

## Acceptance Criteria

- [ ] `ContainerRequest` has a `platform: String?` property
- [ ] `withPlatform(_:)` builder method follows existing pattern and returns `Self`
- [ ] `DockerClient.runContainer(_:)` passes `--platform` flag to Docker CLI when platform is set
- [ ] `--platform` flag is NOT passed when platform is `nil` (default behavior)
- [ ] Unit tests verify builder pattern works correctly
- [ ] Integration tests verify platform selection works with Docker
- [ ] Integration test for `linux/amd64` platform passes
- [ ] Integration test for `linux/arm64` platform passes
- [ ] Existing tests continue to pass (backward compatibility)
- [ ] Code follows existing conventions (struct properties, builder methods, Sendable/Hashable conformance)
- [ ] `withPlatform(_:)` has documentation comments explaining usage
- [ ] No breaking changes to existing API

## References

- Docker CLI documentation: `docker run --platform` flag sets platform if server is multi-platform capable
- Platform string format: `<os>/<architecture>[/variant]`
- Common platforms: `linux/amd64`, `linux/arm64`, `linux/arm/v7`, `linux/386`
- Multi-platform images on Docker Hub typically support multiple architectures

## Notes

- Platform selection relies on Docker daemon supporting multi-platform
- Invalid platform strings will result in Docker CLI errors at runtime
- Emulated platforms (e.g., AMD64 on ARM via QEMU) may have performance implications
- Not all images are available for all platforms; users must ensure their image supports the requested platform
