# Feature 035: Image Substitutors (Registry Mirrors & Custom Hubs)

**Status**: Implemented
**Priority**: Tier 2 (Medium Priority)
**Estimated Complexity**: Medium
**Dependencies**: None

---

## Summary

Implement image substitutors to transform Docker image references before containers are started. This feature enables:

- **Registry mirroring**: Redirect pulls from Docker Hub to private mirrors/caches (e.g., `redis:7` → `mirror.company.com/redis:7`)
- **Custom hub prefixes**: Add organization prefixes to images (e.g., `nginx:latest` → `myorg/nginx:latest`)
- **Air-gapped environments**: Support fully offline development by rewriting all image references to point to local registries
- **Testing multi-tenancy**: Simulate different registry configurations in tests
- **CI/CD optimization**: Route pulls through build cache registries to improve performance

Image substitutors act as a transformation layer between the image string specified in `ContainerRequest` and the actual image reference passed to Docker CLI, similar to how Testcontainers Java's `ImageNameSubstitutor` works.

---

## Current State

### Image Specification Architecture

The current image handling is straightforward and direct:

**Location**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

```swift
public struct ContainerRequest: Sendable, Hashable {
    public var image: String  // Line 27: Direct image reference
    // ... other properties

    public init(image: String) {
        self.image = image  // Line 37: Stored as-is
        // ...
    }
}
```

**Location**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]
    // ... build arguments
    args.append(request.image)  // Line 47: Used directly without transformation
    args += request.command

    let output = try await runDocker(args)
    // ...
}
```

### How Images Are Used Today

1. **Direct specification**: Users provide image name as string: `ContainerRequest(image: "redis:7")`
2. **No transformation**: Image is stored and used exactly as provided
3. **Docker Hub default**: Unqualified images pull from Docker Hub (Docker's default behavior)
4. **Manual qualification**: Users must manually specify full registry paths: `ContainerRequest(image: "gcr.io/my-project/redis:7")`

### Current Limitations

- **No global registry configuration**: Cannot redirect all pulls to a mirror
- **Repetitive qualification**: Must manually prefix every image in every test
- **No environment-based routing**: Cannot easily switch registries based on CI/CD environment
- **No air-gap support**: Cannot transparently rewrite images for offline use

---

## Requirements

### Functional Requirements

1. **Global Image Substitution**
   - Apply transformations to all container requests automatically
   - Configure once, affects all `withContainer()` calls
   - Thread-safe for concurrent test execution

2. **Per-Request Image Substitution**
   - Override global substitutor for specific containers
   - Useful for mixed environments (some from mirror, some from Docker Hub)

3. **Transformation Types**
   - **Registry prefix substitution**: Replace or add registry host
   - **Tag substitution**: Modify or add tags
   - **Repository substitution**: Change repository paths
   - **Custom functions**: Support arbitrary transformation logic

4. **Common Use Cases**
   - **Mirror Docker Hub**: `redis:7` → `mirror.company.com/library/redis:7`
   - **Add organization prefix**: `postgres:16` → `myorg/postgres:16`
   - **Rewrite to local registry**: Any image → `localhost:5000/<original-name>`
   - **Version pinning**: `nginx:latest` → `nginx:1.25.3` (for reproducibility)
   - **Multi-registry routing**: Route by image name pattern

5. **Passthrough & Conditionals**
   - Support conditional substitution (only rewrite if image matches pattern)
   - Allow explicit "no substitution" for specific images
   - Preserve fully-qualified images unless explicitly overridden

6. **Error Handling**
   - Invalid transformations should fail fast
   - Clear error messages for misconfigured substitutors
   - Validation of output image references

### Non-Functional Requirements

1. **Performance**
   - Minimal overhead (string transformation only)
   - No network calls during substitution
   - Efficient for high-volume test suites

2. **Type Safety**
   - Use Swift's type system to prevent invalid configurations
   - Leverage protocols for extensibility
   - Maintain Sendable conformance for Swift Concurrency

3. **Backward Compatibility**
   - Existing code works without changes (substitution is opt-in)
   - Default behavior: no substitution (current behavior)

4. **Observability**
   - Log or expose what transformations were applied
   - Useful for debugging registry issues

---

## API Design

### Proposed Types

```swift
/// Protocol for transforming image references before container creation
public protocol ImageSubstitutor: Sendable {
    /// Transforms an image reference
    /// - Parameter image: Original image string (e.g., "redis:7", "nginx:latest")
    /// - Returns: Transformed image string (e.g., "mirror.company.com/redis:7")
    func substitute(_ image: String) -> String
}

/// Configuration for image substitution at global or request level
public struct ImageSubstitutorConfig: Sendable, Hashable {
    internal let substitute: @Sendable (String) -> String
    private let identifier: String  // For Hashable conformance

    /// Creates a substitutor from a closure
    /// - Parameters:
    ///   - identifier: Unique identifier for this substitutor (used for Hashable)
    ///   - substitute: Transformation function
    public init(identifier: String, substitute: @escaping @Sendable (String) -> String) {
        self.identifier = identifier
        self.substitute = substitute
    }

    /// Creates a substitutor that prefixes all images with a registry host
    /// - Parameter registryHost: Registry host (e.g., "mirror.company.com", "localhost:5000")
    /// - Returns: Substitutor that adds registry prefix
    public static func registryMirror(_ registryHost: String) -> Self {
        Self(identifier: "registry-mirror:\(registryHost)") { image in
            // If image already has a registry (contains '/'), leave as-is
            if image.contains("/") && !image.starts(with: "library/") {
                return image
            }
            // Add registry prefix
            let imageName = image.starts(with: "library/") ? String(image.dropFirst(8)) : image
            return "\(registryHost)/\(imageName)"
        }
    }

    /// Creates a substitutor that adds a prefix to repository names
    /// - Parameter prefix: Repository prefix (e.g., "myorg", "mirrors/dockerhub")
    /// - Returns: Substitutor that adds repository prefix
    public static func repositoryPrefix(_ prefix: String) -> Self {
        Self(identifier: "repo-prefix:\(prefix)") { image in
            if let slashIndex = image.firstIndex(of: "/") {
                // Image has registry or repo (e.g., "gcr.io/project/app" or "myrepo/image")
                let beforeSlash = image[..<slashIndex]
                // Check if it looks like a registry (contains '.' or ':')
                if beforeSlash.contains(".") || beforeSlash.contains(":") {
                    return image  // Already has registry, don't modify
                }
                // Add prefix to repository
                return "\(prefix)/\(image)"
            }
            // Simple image name, add prefix
            return "\(prefix)/\(image)"
        }
    }

    /// Creates a substitutor that replaces the registry portion
    /// - Parameters:
    ///   - from: Registry to replace (e.g., "docker.io")
    ///   - to: Replacement registry (e.g., "mirror.company.com")
    /// - Returns: Substitutor that replaces registry
    public static func replaceRegistry(from: String, to: String) -> Self {
        Self(identifier: "replace-registry:\(from)->\(to)") { image in
            if image.hasPrefix("\(from)/") {
                return "\(to)/\(image.dropFirst(from.count + 1))"
            }
            // If no registry specified, default Docker Hub
            if !image.contains("/") || image.starts(with: "library/") {
                let imageName = image.starts(with: "library/") ? String(image.dropFirst(8)) : image
                if from == "docker.io" || from == "registry-1.docker.io" {
                    return "\(to)/\(imageName)"
                }
            }
            return image
        }
    }

    /// Chains multiple substitutors (applied left-to-right)
    /// - Parameter other: Next substitutor to apply
    /// - Returns: Chained substitutor
    public func then(_ other: ImageSubstitutorConfig) -> Self {
        Self(identifier: "\(identifier) | \(other.identifier)") { image in
            other.substitute(self.substitute(image))
        }
    }

    // Hashable conformance based on identifier
    public static func == (lhs: ImageSubstitutorConfig, rhs: ImageSubstitutorConfig) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}
```

### ContainerRequest Extension

```swift
// In ContainerRequest.swift
public struct ContainerRequest: Sendable, Hashable {
    public var image: String
    // ... existing properties ...
    public var imageSubstitutor: ImageSubstitutorConfig?  // NEW: Per-request substitutor

    public init(image: String) {
        self.image = image
        // ... existing initialization ...
        self.imageSubstitutor = nil
    }

    /// Sets an image substitutor for this specific container request
    /// - Parameter substitutor: Image transformation configuration
    /// - Returns: Updated ContainerRequest
    public func withImageSubstitutor(_ substitutor: ImageSubstitutorConfig) -> Self {
        var copy = self
        copy.imageSubstitutor = substitutor
        return copy
    }
}
```

### Global Configuration

```swift
// New file: Sources/TestContainers/TestContainersConfiguration.swift

/// Global configuration for TestContainers behavior
public actor TestContainersConfiguration {
    /// Shared configuration instance
    public static let shared = TestContainersConfiguration()

    private var globalImageSubstitutor: ImageSubstitutorConfig?

    private init() {}

    /// Sets the global image substitutor applied to all container requests
    /// - Parameter substitutor: Image transformation configuration, or nil to disable
    public func setGlobalImageSubstitutor(_ substitutor: ImageSubstitutorConfig?) {
        globalImageSubstitutor = substitutor
    }

    /// Gets the current global image substitutor
    /// - Returns: Active global substitutor, or nil if none set
    public func getGlobalImageSubstitutor() -> ImageSubstitutorConfig? {
        globalImageSubstitutor
    }
}
```

### DockerClient Integration

```swift
// In DockerClient.swift, modify runContainer(_:)
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    // ... existing argument building ...

    // NEW: Apply image substitution
    let finalImage = await resolveImage(for: request)
    args.append(finalImage)
    args += request.command

    let output = try await runDocker(args)
    // ...
}

private func resolveImage(for request: ContainerRequest) async -> String {
    // Per-request substitutor takes precedence
    if let requestSubstitutor = request.imageSubstitutor {
        return requestSubstitutor.substitute(request.image)
    }

    // Fall back to global substitutor
    if let globalSubstitutor = await TestContainersConfiguration.shared.getGlobalImageSubstitutor() {
        return globalSubstitutor.substitute(request.image)
    }

    // No substitution
    return request.image
}
```

### Usage Examples

```swift
// Example 1: Global registry mirror (applies to all containers)
await TestContainersConfiguration.shared.setGlobalImageSubstitutor(
    .registryMirror("mirror.company.com")
)

let request = ContainerRequest(image: "redis:7")
    .withExposedPort(6379)
// Will pull from: mirror.company.com/redis:7


// Example 2: Organization prefix for all images
await TestContainersConfiguration.shared.setGlobalImageSubstitutor(
    .repositoryPrefix("myorg")
)

let request = ContainerRequest(image: "postgres:16")
    .withExposedPort(5432)
// Will pull from: myorg/postgres:16


// Example 3: Replace Docker Hub registry with local mirror
await TestContainersConfiguration.shared.setGlobalImageSubstitutor(
    .replaceRegistry(from: "docker.io", to: "localhost:5000")
)

let request = ContainerRequest(image: "nginx:latest")
    .withExposedPort(80)
// Will pull from: localhost:5000/nginx:latest


// Example 4: Custom transformation with closure
await TestContainersConfiguration.shared.setGlobalImageSubstitutor(
    ImageSubstitutorConfig(identifier: "custom-env") { image in
        // Add CI environment prefix
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            return "ci-cache.company.com/\(image)"
        }
        return image
    }
)


// Example 5: Per-request override (bypass global substitutor)
await TestContainersConfiguration.shared.setGlobalImageSubstitutor(
    .registryMirror("mirror.company.com")
)

let mirroredRequest = ContainerRequest(image: "redis:7")
    .withExposedPort(6379)
// Uses global: mirror.company.com/redis:7

let directRequest = ContainerRequest(image: "special-image:1.0")
    .withImageSubstitutor(
        ImageSubstitutorConfig(identifier: "passthrough") { $0 }  // No transformation
    )
// Uses Docker Hub directly: special-image:1.0


// Example 6: Chain multiple transformations
let chainedSubstitutor = ImageSubstitutorConfig
    .repositoryPrefix("mirrors")
    .then(.registryMirror("registry.internal.company.com"))

await TestContainersConfiguration.shared.setGlobalImageSubstitutor(chainedSubstitutor)

let request = ContainerRequest(image: "redis:7")
// Will pull from: registry.internal.company.com/mirrors/redis:7


// Example 7: Environment-based configuration (typical CI setup)
func configureImageRegistry() async {
    let registryHost = ProcessInfo.processInfo.environment["TESTCONTAINERS_REGISTRY_MIRROR"]

    if let host = registryHost, !host.isEmpty {
        await TestContainersConfiguration.shared.setGlobalImageSubstitutor(
            .registryMirror(host)
        )
        print("Using image registry mirror: \(host)")
    }
}

// In test setup:
await configureImageRegistry()


// Example 8: Conditional substitution based on image pattern
let substitutor = ImageSubstitutorConfig(identifier: "conditional") { image in
    // Only mirror common databases
    if image.starts(with: "postgres:") || image.starts(with: "redis:") || image.starts(with: "mysql:") {
        return "cache.company.com/\(image)"
    }
    return image  // Leave others unchanged
}

await TestContainersConfiguration.shared.setGlobalImageSubstitutor(substitutor)
```

---

## Implementation Steps

### Step 1: Create ImageSubstitutorConfig Type

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ImageSubstitutorConfig.swift` (NEW)

1. Define `ImageSubstitutorConfig` struct with closure-based substitution
2. Implement static factory methods:
   - `.registryMirror(_:)`
   - `.repositoryPrefix(_:)`
   - `.replaceRegistry(from:to:)`
3. Implement `.then(_:)` for chaining
4. Implement `Hashable` and `Sendable` conformance
5. Add comprehensive documentation

**Key considerations**:
- Use `@Sendable` closure type for Swift Concurrency safety
- Store `identifier` string for `Hashable` conformance (closures aren't Hashable)
- Parse image references correctly (handle registry, repository, tag components)
- Handle edge cases: already-qualified images, missing tags, library/ prefix

**Acceptance**:
- `ImageSubstitutorConfig` compiles
- Factory methods produce correct transformations
- Hashable works based on identifier

### Step 2: Create TestContainersConfiguration Actor

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersConfiguration.swift` (NEW)

1. Define `TestContainersConfiguration` actor (for thread-safe global state)
2. Implement `.shared` singleton
3. Add `setGlobalImageSubstitutor(_:)` method
4. Add `getGlobalImageSubstitutor()` method
5. Document thread-safety guarantees

**Key considerations**:
- Use `actor` for thread-safe mutable state
- Singleton pattern for global configuration
- Allow nil to disable global substitution

**Acceptance**:
- Configuration can be set/get from async contexts
- Thread-safe for concurrent tests
- Nil clears global substitutor

### Step 3: Update ContainerRequest

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

1. Add `imageSubstitutor: ImageSubstitutorConfig?` property (after line 34)
2. Initialize to `nil` in `init(image:)` (after line 44)
3. Add `withImageSubstitutor(_:)` builder method (after line 87)

**Key considerations**:
- Maintain `Hashable` conformance (ImageSubstitutorConfig is Hashable)
- Follow existing builder pattern

**Acceptance**:
- `ContainerRequest` compiles with new property
- Builder method works correctly
- Hashable still works

### Step 4: Implement Image Resolution in DockerClient

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

1. Add private `resolveImage(for:)` method
2. Implement precedence logic:
   - Check per-request substitutor first
   - Fall back to global substitutor
   - Use original image if no substitutors
3. Update `runContainer(_:)` to call `resolveImage(for:)` before appending image to args (replace line 47)

**Implementation**:
```swift
private func resolveImage(for request: ContainerRequest) async -> String {
    if let requestSubstitutor = request.imageSubstitutor {
        return requestSubstitutor.substitute(request.image)
    }

    if let globalSubstitutor = await TestContainersConfiguration.shared.getGlobalImageSubstitutor() {
        return globalSubstitutor.substitute(request.image)
    }

    return request.image
}

func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    // ... existing code ...

    // MODIFIED: Apply image substitution
    let finalImage = await resolveImage(for: request)
    args.append(finalImage)
    args += request.command

    // ...
}
```

**Acceptance**:
- Image resolution applies substitutors in correct order
- Original behavior preserved when no substitutors configured
- Async context handled correctly

### Step 5: Add Unit Tests for Image Parsing & Substitution

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ImageSubstitutorConfigTests.swift` (NEW)

Test coverage:
- Basic image name substitution
- Image with tag substitution
- Image with registry substitution
- Registry mirror factory method
- Repository prefix factory method
- Replace registry factory method
- Chaining multiple substitutors
- Edge cases:
  - Already-qualified images
  - Images with ports (localhost:5000)
  - Images with library/ prefix
  - Images with digests (@sha256:...)
  - Multi-level repository paths (org/team/image)

Example tests:
```swift
@Test func registryMirror_addsRegistryToSimpleImage() {
    let substitutor = ImageSubstitutorConfig.registryMirror("mirror.company.com")
    let result = substitutor.substitute("redis:7")
    #expect(result == "mirror.company.com/redis:7")
}

@Test func registryMirror_preservesQualifiedImage() {
    let substitutor = ImageSubstitutorConfig.registryMirror("mirror.company.com")
    let result = substitutor.substitute("gcr.io/project/image:1.0")
    #expect(result == "gcr.io/project/image:1.0")
}

@Test func repositoryPrefix_addsPrefix() {
    let substitutor = ImageSubstitutorConfig.repositoryPrefix("myorg")
    let result = substitutor.substitute("nginx:latest")
    #expect(result == "myorg/nginx:latest")
}

@Test func replaceRegistry_replacesDockerHub() {
    let substitutor = ImageSubstitutorConfig.replaceRegistry(from: "docker.io", to: "local.registry")
    let result = substitutor.substitute("redis:7")
    #expect(result == "local.registry/redis:7")
}

@Test func chainedSubstitutors_applyInOrder() {
    let substitutor = ImageSubstitutorConfig
        .repositoryPrefix("mirrors")
        .then(.registryMirror("registry.company.com"))

    let result = substitutor.substitute("postgres:16")
    #expect(result == "registry.company.com/mirrors/postgres:16")
}

@Test func customSubstitutor_appliesClosureLogic() {
    let substitutor = ImageSubstitutorConfig(identifier: "test") { image in
        return image.replacingOccurrences(of: "latest", with: "1.0.0")
    }
    let result = substitutor.substitute("nginx:latest")
    #expect(result == "nginx:1.0.0")
}
```

**Acceptance**: All unit tests pass

### Step 6: Add Unit Tests for ContainerRequest

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests (after existing tests):
```swift
@Test func withImageSubstitutor_setsSubstitutor() {
    let substitutor = ImageSubstitutorConfig.registryMirror("mirror.test")
    let request = ContainerRequest(image: "redis:7")
        .withImageSubstitutor(substitutor)

    #expect(request.imageSubstitutor == substitutor)
}

@Test func defaultImageSubstitutor_isNil() {
    let request = ContainerRequest(image: "redis:7")
    #expect(request.imageSubstitutor == nil)
}

@Test func imageSubstitutor_worksWithOtherBuilders() {
    let substitutor = ImageSubstitutorConfig.registryMirror("mirror.test")
    let request = ContainerRequest(image: "redis:7")
        .withImageSubstitutor(substitutor)
        .withExposedPort(6379)
        .withName("test-redis")

    #expect(request.imageSubstitutor == substitutor)
    #expect(request.ports.count == 1)
    #expect(request.name == "test-redis")
}
```

**Acceptance**: All tests pass

### Step 7: Add Unit Tests for Configuration

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/TestContainersConfigurationTests.swift` (NEW)

```swift
@Test func globalImageSubstitutor_defaultsToNil() async {
    let config = TestContainersConfiguration.shared
    let substitutor = await config.getGlobalImageSubstitutor()
    #expect(substitutor == nil)
}

@Test func globalImageSubstitutor_canBeSet() async {
    let config = TestContainersConfiguration.shared
    let substitutor = ImageSubstitutorConfig.registryMirror("test.registry")

    await config.setGlobalImageSubstitutor(substitutor)
    let retrieved = await config.getGlobalImageSubstitutor()

    #expect(retrieved == substitutor)

    // Cleanup
    await config.setGlobalImageSubstitutor(nil)
}

@Test func globalImageSubstitutor_canBeCleared() async {
    let config = TestContainersConfiguration.shared
    let substitutor = ImageSubstitutorConfig.registryMirror("test.registry")

    await config.setGlobalImageSubstitutor(substitutor)
    await config.setGlobalImageSubstitutor(nil)
    let retrieved = await config.getGlobalImageSubstitutor()

    #expect(retrieved == nil)
}
```

**Acceptance**: Configuration actor works correctly

### Step 8: Add Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ImageSubstitutorIntegrationTests.swift` (NEW)

Test with real Docker (opt-in via environment variable):

```swift
@Test func imageSubstitutor_globalMirror_startsContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Setup: Use passthrough substitutor (no actual mirror required for test)
    let substitutor = ImageSubstitutorConfig(identifier: "test-passthrough") { $0 }
    await TestContainersConfiguration.shared.setGlobalImageSubstitutor(substitutor)

    defer {
        Task {
            await TestContainersConfiguration.shared.setGlobalImageSubstitutor(nil)
        }
    }

    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }
}

@Test func imageSubstitutor_perRequestOverride_startsContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Setup global substitutor
    let globalSubstitutor = ImageSubstitutorConfig(identifier: "global") { _ in "should-not-be-used:latest" }
    await TestContainersConfiguration.shared.setGlobalImageSubstitutor(globalSubstitutor)

    defer {
        Task {
            await TestContainersConfiguration.shared.setGlobalImageSubstitutor(nil)
        }
    }

    // Per-request override with passthrough
    let requestSubstitutor = ImageSubstitutorConfig(identifier: "override") { $0 }
    let request = ContainerRequest(image: "redis:7")
        .withImageSubstitutor(requestSubstitutor)
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }
}

// NOTE: Testing actual registry mirroring requires:
// 1. Local registry running (docker run -d -p 5000:5000 registry:2)
// 2. Images pre-pushed to local registry
// Document this in test comments but don't require for CI
```

**Acceptance**: Integration tests verify end-to-end workflow

### Step 9: Documentation

1. **Inline documentation**: Add doc comments to all public APIs
2. **README update**: Add section on image substitutors with common use cases
3. **Feature file**: This document serves as comprehensive spec
4. **Migration guide**: Document how to configure for common scenarios:
   - Corporate registry mirror
   - Air-gapped environments
   - CI/CD optimization

**Example README section**:
```markdown
## Image Substitutors (Registry Mirrors)

Configure global or per-request image transformations to route pulls through registry mirrors:

### Global Configuration
swift
// Route all pulls through corporate mirror
await TestContainersConfiguration.shared.setGlobalImageSubstitutor(
    .registryMirror("mirror.company.com")
)

// Now all containers use the mirror
let request = ContainerRequest(image: "redis:7")  // Pulls from mirror.company.com/redis:7


### Per-Request Override
swift
let request = ContainerRequest(image: "special-image:1.0")
    .withImageSubstitutor(
        ImageSubstitutorConfig(identifier: "direct") { $0 }  // Bypass mirror
    )


### Common Patterns
swift
// Environment-based configuration
if let mirror = ProcessInfo.processInfo.environment["DOCKER_REGISTRY_MIRROR"] {
    await TestContainersConfiguration.shared.setGlobalImageSubstitutor(
        .registryMirror(mirror)
    )
}
```

**Acceptance**: Clear, comprehensive documentation

---

## Testing Plan

### Unit Tests

**ImageSubstitutorConfigTests.swift**:
1. Factory method correctness (registryMirror, repositoryPrefix, replaceRegistry)
2. Custom closure substitution
3. Chaining with `.then()`
4. Edge cases:
   - Empty image strings
   - Images with digests
   - Images with multi-level paths
   - Already-qualified images
5. Hashable conformance

**ContainerRequestTests.swift**:
1. `withImageSubstitutor()` builder method
2. Default value (nil)
3. Chaining with other builders
4. Hashable with substitutors

**TestContainersConfigurationTests.swift**:
1. Singleton access
2. Set/get global substitutor
3. Clear global substitutor (set to nil)
4. Thread-safety (actor isolation)

### Integration Tests

**ImageSubstitutorIntegrationTests.swift**:
1. Global substitutor with real container
2. Per-request override with real container
3. No substitutor (baseline behavior)
4. Document local registry mirror test setup

### Manual Testing Scenarios

1. **Corporate mirror setup**:
   - Configure global mirror
   - Run test suite
   - Verify all images pulled from mirror (check Docker logs)

2. **Air-gapped simulation**:
   - Push images to local registry
   - Configure replaceRegistry substitutor
   - Disconnect from internet
   - Run tests (should work)

3. **Conditional substitution**:
   - Create complex conditional substitutor
   - Run mixed workload (some mirrored, some direct)
   - Verify correct routing

4. **Performance baseline**:
   - Run suite without substitutor
   - Run suite with substitutor
   - Verify minimal overhead (<1% difference)

---

## Acceptance Criteria

### Definition of Done

- [x] `ImageSubstitutorConfig` struct with closure-based substitution
- [x] Static factory methods: `.registryMirror()`, `.repositoryPrefix()`, `.replaceRegistry()`
- [x] `.then()` chaining support
- [ ] `TestContainersConfiguration` actor with global substitutor (deferred)
- [x] `ContainerRequest.imageSubstitutor` property and builder method
- [x] `ContainerRequest.resolvedImage` computed property
- [x] `DockerClient.buildContainerArgs` uses resolved image
- [x] `DockerClient.handleImagePullPolicy` uses resolved image
- [x] Unit tests for all substitution logic (33 tests)
- [ ] Integration tests with real containers
- [x] Documentation in code (doc comments)
- [ ] README examples for common use cases
- [x] Backward compatible (opt-in feature)
- [x] Sendable conformance throughout

### Success Metrics

1. **API Usability**: One-line global configuration for common cases
2. **Flexibility**: Support arbitrary transformation logic via closures
3. **Performance**: <1ms overhead per container start
4. **Observability**: Clear what transformation was applied (via identifier)
5. **Reliability**: All tests pass, no regressions

---

## Future Enhancements

### 1. Image Pull Policies
- Control when images are pulled (always, if-not-present, never)
- API: `.withImagePullPolicy(.always)`

### 2. Image Name Parsing Library
- Structured parsing of image references (registry/repository:tag@digest)
- Type-safe manipulation of image components
- API: `ImageReference` struct

### 3. Logging/Observability
- Log image transformations for debugging
- API: `TestContainersConfiguration.shared.enableSubstitutionLogging()`

### 4. Predefined Substitutor Patterns
- Common patterns as static properties
- Examples: `.dockerHubToGCR`, `.addOrgPrefix("myorg")`

### 5. Image Caching Strategies
- Automatic prefixing for CI cache layers
- Integration with BuildKit cache backends

### 6. Validation Hooks
- Validate transformed images before container creation
- API: `withImageValidator(_ validator: (String) throws -> Void)`

### 7. Multi-Registry Routing
- Route different images to different registries
- API: Pattern matching with multiple substitutors

### 8. Environment Variable Expansion
- Expand env vars in registry URLs
- Example: `${DOCKER_REGISTRY}/image:tag`

---

## References

### Similar Implementations

- **Testcontainers Java**: `ImageNameSubstitutor` interface
  - Allows pluggable image name transformation
  - Used for Docker Hub rate limiting mitigation
  - Configured via ServiceLoader or manually

- **Testcontainers Go**: `ImageSubstitutor` interface
  - Similar pattern with global and per-request config

- **Testcontainers Node**: Registry configuration in config file

### Docker Image Reference Format

Standard format: `[registry/]repository[:tag|@digest]`

Examples:
- `nginx:latest` → Docker Hub (implicit: `docker.io/library/nginx:latest`)
- `myorg/app:1.0` → Docker Hub with custom org
- `gcr.io/project/image:v2` → Google Container Registry
- `localhost:5000/myapp:dev` → Local registry with port

### Related Files

- `/Sources/TestContainers/ContainerRequest.swift` - Container configuration
- `/Sources/TestContainers/DockerClient.swift` - Docker CLI interaction
- `/Sources/TestContainers/TestContainersError.swift` - Error types

### External Documentation

- Docker registry configuration: https://docs.docker.com/registry/
- Image naming conventions: https://docs.docker.com/engine/reference/commandline/tag/
- Container registry mirrors: https://docs.docker.com/registry/recipes/mirror/

---

## Implementation Checklist

- [x] Create `ImageSubstitutorConfig` struct
- [x] Implement `.registryMirror()` factory method
- [x] Implement `.repositoryPrefix()` factory method
- [x] Implement `.replaceRegistry()` factory method
- [x] Implement `.then()` chaining method
- [ ] Create `TestContainersConfiguration` actor (deferred - global config not yet needed)
- [ ] Implement global substitutor storage (deferred - global config not yet needed)
- [x] Add `imageSubstitutor` property to `ContainerRequest`
- [x] Implement `withImageSubstitutor()` builder method
- [x] Add `resolvedImage` computed property to `ContainerRequest`
- [x] Update `buildContainerArgs()` to use resolved image
- [x] Update `handleImagePullPolicy()` to use resolved image
- [x] Write unit tests for ImageSubstitutorConfig (21 tests)
- [x] Write unit tests for ContainerRequest integration (8 tests)
- [x] Write unit tests for DockerClient argument generation (4 tests)
- [x] Add inline documentation (doc comments)
- [ ] Update README with examples
- [ ] Write integration tests with Docker
- [ ] Manual testing with local registry
- [ ] Performance validation
- [ ] Code review
- [ ] Merge to main branch

---

**Created**: 2025-12-15
**Last Updated**: 2025-12-15
**Assignee**: TBD
**Target Version**: 0.3.0
