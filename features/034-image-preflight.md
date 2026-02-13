# Feature 034: Image Preflight Checks

## Summary

Implement image preflight checks to verify image existence and inspect image metadata before attempting to run containers. This feature adds the ability to:
- Check if an image exists locally (without pulling)
- Inspect image metadata (labels, environment variables, exposed ports, entrypoint, command, working directory)
- Validate image availability before container creation to provide better error messages
- Access image configuration to inform container request building

This enables better error handling, validation, and dynamic container configuration based on image metadata.

## Current State

### Image Handling Today

Currently, `swift-test-containers` does not perform any image-level operations. The flow is:

1. **Container Request Building** (`ContainerRequest.swift`):
   - User specifies image name as a string: `ContainerRequest(image: "redis:7")`
   - No validation that the image exists or is valid
   - No access to image metadata

2. **Container Creation** (`DockerClient.swift:28-54`):
   - `runContainer(_:)` directly executes `docker run -d <image>` with configured flags
   - If image doesn't exist locally, Docker automatically pulls it (can be slow)
   - If image doesn't exist in registry, Docker fails with error at runtime
   - No way to distinguish "image not found" from other Docker errors

3. **Error Handling** (`TestContainersError.swift`):
   ```swift
   case commandFailed(command: [String], exitCode: Int32, stdout: String, stderr: String)
   ```
   - Generic error for all Docker command failures
   - No specific error case for missing images
   - Error messages include raw Docker CLI output

### Limitations

- **No Image Validation**: Can't check if image exists before attempting to run container
- **No Pull Control**: Can't distinguish between "pull then run" vs "image must exist locally"
- **No Metadata Access**: Can't inspect image to discover exposed ports, environment variables, or labels
- **Poor Error Messages**: Image-not-found errors are buried in generic command failure messages
- **No Pull Feedback**: Long image pulls happen silently during container start
- **No Multi-Platform Awareness**: Can't check if image supports requested platform before running

### Related Code

**Container Request**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`
```swift
public struct ContainerRequest: Sendable, Hashable {
    public var image: String  // Plain string, no validation
    // ... other fields
}
```

**Docker Client**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`
```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]
    // ... build arguments
    args.append(request.image)  // Image used directly, no preflight check
    let output = try await runDocker(args)
    // ...
}
```

## Requirements

### Functional Requirements

1. **Image Existence Check**
   - Check if image exists locally by name or ID
   - Check if image exists for specific platform (if platform specified)
   - Return boolean result without throwing for non-existent images
   - Should NOT pull images (check local cache only)

2. **Image Inspection**
   - Retrieve comprehensive image metadata:
     - Image ID (SHA256 digest)
     - Created timestamp
     - Size
     - Architecture and OS
     - Author
     - Labels (key-value pairs)
     - Environment variables from image
     - Exposed ports from EXPOSE directive
     - Entrypoint (default entry command)
     - Command (default CMD)
     - Working directory (WORKDIR)
     - User (default USER)
     - Volumes (VOLUME directives)
   - Parse Docker's JSON format into Swift types
   - Handle multi-platform images (inspect specific platform variant)

3. **Pull Policy Enum** (foundation for future features)
   - Define enum to control image pulling behavior:
     - `.alwaysPull` - Always pull before running
     - `.ifMissing` - Pull only if not local (Docker default)
     - `.neverPull` - Fail if image not local
   - Store in `ContainerRequest` (default: `.ifMissing`)
   - Add builder method `withPullPolicy(_:)`

4. **Error Handling**
   - Add specific error case: `TestContainersError.imageNotFound(image: String, message: String)`
   - Improve error messages to distinguish image problems from other failures
   - Provide helpful suggestions (e.g., "Image 'redis:8' not found. Did you mean 'redis:7'?")

### Non-Functional Requirements

1. **Performance**
   - Image inspection should be fast (< 100ms for cached images)
   - Existence check should be faster than inspection (< 50ms)
   - Should not impact existing container start time if not used

2. **API Consistency**
   - Follow existing patterns (actor-based DockerClient, builder pattern)
   - Use `async throws` for operations that may fail
   - Return structured Swift types, not raw JSON strings

3. **Compatibility**
   - Work with local images and registry images (by name)
   - Support image references: name, name:tag, digest (sha256:...)
   - Handle multi-platform images (inspect specific architecture)

4. **Type Safety**
   - Use Swift enums for known values (architecture, OS, pull policy)
   - Use `Codable` for JSON parsing
   - Make all types `Sendable` for Swift Concurrency

## API Design

### Image Inspection Types

```swift
// New file: ImageInspection.swift

/// Comprehensive image metadata from `docker image inspect`
public struct ImageInspection: Sendable, Codable {
    public let id: String              // Full SHA256 ID
    public let repoTags: [String]      // e.g., ["redis:7", "redis:latest"]
    public let repoDigests: [String]   // Registry digests
    public let created: Date
    public let size: Int64             // Bytes
    public let architecture: String    // "amd64", "arm64", etc.
    public let os: String              // "linux", "windows", etc.
    public let author: String
    public let config: ImageConfig
    public let rootFS: RootFS
}

/// Image configuration (default settings)
public struct ImageConfig: Sendable, Codable {
    public let env: [String]           // Format: "KEY=VALUE"
    public let cmd: [String]?          // Default command
    public let entrypoint: [String]?   // Entrypoint override
    public let workingDir: String      // Default WORKDIR
    public let user: String            // Default USER
    public let exposedPorts: [String: ExposedPort]  // e.g., "6379/tcp": {}
    public let labels: [String: String]
    public let volumes: [String: Volume]  // Volume mount points
    public let onBuild: [String]?      // ONBUILD instructions
}

public struct ExposedPort: Sendable, Codable {
    // Empty struct, Docker uses object as set: {"6379/tcp": {}}
    public init() {}
}

public struct Volume: Sendable, Codable {
    // Empty struct, Docker uses object as set: {"/data": {}}
    public init() {}
}

public struct RootFS: Sendable, Codable {
    public let type: String            // "layers"
    public let layers: [String]        // Layer SHA256 digests
}

/// Image pull policy
public enum ImagePullPolicy: String, Sendable, Hashable {
    case alwaysPull   // Always pull latest from registry
    case ifMissing    // Pull only if not found locally (Docker default)
    case neverPull    // Fail if image not found locally
}
```

### DockerClient API

```swift
// Extension to DockerClient.swift

extension DockerClient {
    /// Check if an image exists locally
    ///
    /// - Parameters:
    ///   - image: Image reference (name, name:tag, or digest)
    ///   - platform: Optional platform (e.g., "linux/amd64")
    /// - Returns: `true` if image exists locally, `false` otherwise
    /// - Note: Does not pull images; checks local cache only
    public func imageExists(_ image: String, platform: String? = nil) async -> Bool {
        // Use: docker images <image> --quiet --no-trunc
        // Returns image ID if exists, empty if not
        // Fast check without full inspection
    }

    /// Inspect an image to retrieve metadata
    ///
    /// - Parameters:
    ///   - image: Image reference (name, name:tag, or digest)
    ///   - platform: Optional platform for multi-platform images
    /// - Returns: Detailed image metadata
    /// - Throws: `TestContainersError.imageNotFound` if image doesn't exist
    /// - Throws: `TestContainersError.unexpectedDockerOutput` if JSON parsing fails
    public func inspectImage(_ image: String, platform: String? = nil) async throws -> ImageInspection {
        // Use: docker image inspect <image> [--platform <platform>]
        // Returns JSON array, parse first element
    }

    /// Pull an image from registry
    ///
    /// - Parameters:
    ///   - image: Image reference to pull
    ///   - platform: Optional platform for multi-platform images
    /// - Throws: `TestContainersError.commandFailed` if pull fails
    /// - Note: Future enhancement - could report progress
    func pullImage(_ image: String, platform: String? = nil) async throws {
        // Use: docker pull <image> [--platform <platform>]
        // Future: could parse progress output for feedback
    }
}
```

### Container API (Optional Convenience)

```swift
// Extension to Container.swift

extension Container {
    /// Retrieve the image inspection that was used to create this container
    ///
    /// - Returns: Image metadata for the container's image
    /// - Throws: `TestContainersError` if inspection fails
    public func imageInspection() async throws -> ImageInspection {
        try await docker.inspectImage(request.image)
    }
}
```

### ContainerRequest Extension

```swift
// Extension to ContainerRequest.swift

extension ContainerRequest {
    /// Set the image pull policy
    ///
    /// - Parameter policy: When to pull the image
    /// - Returns: Modified request
    public func withPullPolicy(_ policy: ImagePullPolicy) -> Self {
        var copy = self
        copy.pullPolicy = policy
        return copy
    }
}

// Add to ContainerRequest struct:
public var pullPolicy: ImagePullPolicy = .ifMissing
```

### Error Handling

```swift
// Add to TestContainersError.swift

extension TestContainersError {
    case imageNotFound(image: String, message: String)

    public var description: String {
        switch self {
        // ... existing cases
        case let .imageNotFound(image, message):
            return "Image not found: \(image)\n\(message)"
        }
    }
}
```

### Usage Examples

```swift
// Example 1: Check if image exists before running
let docker = DockerClient()
if await docker.imageExists("redis:7") {
    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
    try await withContainer(request) { container in
        // Use container
    }
} else {
    print("Redis image not available locally")
}

// Example 2: Inspect image to discover exposed ports
let docker = DockerClient()
let inspection = try await docker.inspectImage("redis:7-alpine")

print("Image ID: \(inspection.id)")
print("Architecture: \(inspection.architecture)")
print("Exposed ports: \(inspection.config.exposedPorts.keys)")
// Output: ["6379/tcp"]

// Build request based on image metadata
let request = ContainerRequest(image: "redis:7-alpine")
for portKey in inspection.config.exposedPorts.keys {
    if let port = parsePort(portKey) {  // Helper to extract port number
        request = request.withExposedPort(port)
    }
}

// Example 3: Never pull policy (fail if not local)
let request = ContainerRequest(image: "custom-app:local")
    .withPullPolicy(.neverPull)
    .withExposedPort(8080)

try await withContainer(request) { container in
    // If image doesn't exist locally, fails immediately
}

// Example 4: Check platform support
let docker = DockerClient()
let inspection = try await docker.inspectImage("redis:7", platform: "linux/arm64")
if inspection.architecture == "arm64" {
    print("ARM64 variant available")
}

// Example 5: Access image labels
let inspection = try await docker.inspectImage("postgres:15")
if let version = inspection.config.labels["org.opencontainers.image.version"] {
    print("PostgreSQL version: \(version)")
}

// Example 6: Environment variables from image
let inspection = try await docker.inspectImage("postgres:15")
for envVar in inspection.config.env {
    print("Image env: \(envVar)")
}
// Could parse to discover default passwords, ports, etc.
```

## Implementation Steps

### Step 1: Define Image Inspection Types

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ImageInspection.swift` (new)

1. Define `ImageInspection` struct with `Codable` conformance
2. Define nested types: `ImageConfig`, `ExposedPort`, `Volume`, `RootFS`
3. Add `CodingKeys` to map Swift names to Docker's JSON format (PascalCase)
4. Implement custom date decoding (Docker uses RFC3339 format)
5. Make all types `Sendable` for concurrency safety
6. Add documentation comments explaining each field

**Key Docker JSON Fields to Map**:
```json
{
  "Id": "sha256:...",
  "RepoTags": ["redis:7"],
  "Created": "2024-12-10T15:30:00.123456789Z",
  "Size": 123456789,
  "Architecture": "amd64",
  "Os": "linux",
  "Config": {
    "Env": ["PATH=/usr/bin", "REDIS_VERSION=7.0"],
    "Cmd": ["redis-server"],
    "Entrypoint": ["docker-entrypoint.sh"],
    "WorkingDir": "/data",
    "User": "redis",
    "ExposedPorts": { "6379/tcp": {} },
    "Labels": { "maintainer": "..." },
    "Volumes": { "/data": {} }
  },
  "RootFS": {
    "Type": "layers",
    "Layers": ["sha256:...", ...]
  }
}
```

### Step 2: Add Image Pull Policy Types

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

1. Define `ImagePullPolicy` enum with cases: `.alwaysPull`, `.ifMissing`, `.neverPull`
2. Add `pullPolicy` property to `ContainerRequest` struct (default: `.ifMissing`)
3. Add `withPullPolicy(_:)` builder method following existing pattern
4. Update `init(image:)` to initialize `pullPolicy = .ifMissing`

```swift
public enum ImagePullPolicy: String, Sendable, Hashable {
    case alwaysPull
    case ifMissing
    case neverPull
}

// Add to ContainerRequest:
public var pullPolicy: ImagePullPolicy

// In init:
self.pullPolicy = .ifMissing

// Add builder:
public func withPullPolicy(_ policy: ImagePullPolicy) -> Self {
    var copy = self
    copy.pullPolicy = policy
    return copy
}
```

### Step 3: Implement Image Exists Check

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Add method after existing methods (around line 95):

```swift
public func imageExists(_ image: String, platform: String? = nil) async -> Bool {
    do {
        var args = ["images", image, "--quiet", "--no-trunc"]
        if let platform = platform {
            args += ["--filter", "platform=\(platform)"]
        }
        let output = try await runner.run(executable: dockerPath, arguments: args)

        // Exit code 0 and non-empty output means image exists
        if output.exitCode == 0 {
            let imageID = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return !imageID.isEmpty
        }
        return false
    } catch {
        return false
    }
}
```

**Why This Approach**:
- `docker images <name>` is faster than `docker image inspect`
- `--quiet` returns only image ID, minimal parsing needed
- `--no-trunc` returns full SHA256 ID for uniqueness
- Non-throwing: returns false on any error (API decision for existence checks)
- Platform filter ensures multi-platform correctness

### Step 4: Implement Image Inspection

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Add method after `imageExists`:

```swift
public func inspectImage(_ image: String, platform: String? = nil) async throws -> ImageInspection {
    var args = ["image", "inspect", image]
    if let platform = platform {
        args += ["--platform", platform]
    }

    let output = try await runDocker(args)
    let jsonData = output.stdout.data(using: .utf8) ?? Data()

    // Docker returns array of image objects
    let decoder = JSONDecoder()

    // Configure date decoding for ISO8601/RFC3339
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let dateString = try container.decode(String.self)
        guard let date = formatter.date(from: dateString) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid date format: \(dateString)"
            )
        }
        return date
    }

    let inspections = try decoder.decode([ImageInspection].self, from: jsonData)
    guard let inspection = inspections.first else {
        throw TestContainersError.imageNotFound(
            image: image,
            message: "Image '\(image)' not found locally. Pull the image first or use a different pull policy."
        )
    }

    return inspection
}
```

**Error Handling Pattern**:
- Use `runDocker()` which throws `commandFailed` on non-zero exit
- Empty array means image not found → throw `imageNotFound` (new error type)
- JSON decode errors propagate as-is (or wrap in `unexpectedDockerOutput`)

### Step 5: Implement Image Pull (Foundation for Future)

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Add method (internal for now, can be made public later):

```swift
func pullImage(_ image: String, platform: String? = nil) async throws {
    var args = ["pull", image]
    if let platform = platform {
        args += ["--platform", platform]
    }
    _ = try await runDocker(args)
    // Future: Could parse progress output for user feedback
}
```

**Note**: This is a foundation method. Full pull progress reporting would require parsing streaming output, which is a more complex feature for the future.

### Step 6: Add Image Not Found Error

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`

Add new case after existing cases:

```swift
case imageNotFound(image: String, message: String)
```

Update `description` property:

```swift
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
    case let .imageNotFound(image, message):
        return "Image not found: \(image)\n\(message)"
    }
}
```

### Step 7: Add Optional Container Convenience Method

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`

Add method after existing methods:

```swift
public func imageInspection() async throws -> ImageInspection {
    try await docker.inspectImage(request.image, platform: request.platform)
}
```

**Note**: Assumes `request.platform` exists (from Feature 021). If not yet implemented, omit platform parameter.

### Step 8: Add Unit Tests for JSON Parsing

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ImageInspectionTests.swift` (new)

Test JSON deserialization without requiring Docker:

```swift
import Testing
import Foundation
@testable import TestContainers

@Test func parsesImageInspection() throws {
    let json = """
    [{
        "Id": "sha256:1234567890abcdef",
        "RepoTags": ["redis:7-alpine", "redis:latest"],
        "RepoDigests": ["redis@sha256:abcd..."],
        "Created": "2024-12-10T15:30:45.123456789Z",
        "Size": 31457280,
        "Architecture": "amd64",
        "Os": "linux",
        "Author": "",
        "Config": {
            "Hostname": "",
            "Domainname": "",
            "User": "redis",
            "Env": [
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "REDIS_VERSION=7.2.3",
                "REDIS_DOWNLOAD_URL=https://download.redis.io/releases/redis-7.2.3.tar.gz"
            ],
            "Cmd": ["redis-server"],
            "Image": "",
            "Volumes": {
                "/data": {}
            },
            "WorkingDir": "/data",
            "Entrypoint": ["docker-entrypoint.sh"],
            "OnBuild": null,
            "Labels": {
                "maintainer": "Redis Docker Team <redis-docker@example.com>",
                "org.opencontainers.image.version": "7.2.3"
            },
            "ExposedPorts": {
                "6379/tcp": {}
            }
        },
        "RootFS": {
            "Type": "layers",
            "Layers": [
                "sha256:layer1...",
                "sha256:layer2..."
            ]
        }
    }]
    """

    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()

    // Configure same date decoding as production code
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let dateString = try container.decode(String.self)
        guard let date = formatter.date(from: dateString) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid date"
            )
        }
        return date
    }

    let inspections = try decoder.decode([ImageInspection].self, from: data)
    let inspection = try #require(inspections.first)

    #expect(inspection.id.hasPrefix("sha256:"))
    #expect(inspection.repoTags.contains("redis:7-alpine"))
    #expect(inspection.architecture == "amd64")
    #expect(inspection.os == "linux")
    #expect(inspection.size == 31457280)
    #expect(inspection.config.user == "redis")
    #expect(inspection.config.workingDir == "/data")
    #expect(inspection.config.cmd == ["redis-server"])
    #expect(inspection.config.entrypoint == ["docker-entrypoint.sh"])
    #expect(inspection.config.exposedPorts.keys.contains("6379/tcp"))
    #expect(inspection.config.env.contains("REDIS_VERSION=7.2.3"))
    #expect(inspection.config.labels["org.opencontainers.image.version"] == "7.2.3")
    #expect(inspection.config.volumes.keys.contains("/data"))
    #expect(inspection.rootFS.layers.count == 2)
}

@Test func parsesImageWithMinimalConfig() throws {
    let json = """
    [{
        "Id": "sha256:minimal",
        "RepoTags": ["alpine:3"],
        "RepoDigests": [],
        "Created": "2024-12-15T00:00:00Z",
        "Size": 7123456,
        "Architecture": "arm64",
        "Os": "linux",
        "Author": "",
        "Config": {
            "Env": ["PATH=/bin"],
            "Cmd": ["/bin/sh"],
            "WorkingDir": "/",
            "User": "",
            "Labels": {},
            "ExposedPorts": null,
            "Volumes": null,
            "Entrypoint": null,
            "OnBuild": null
        },
        "RootFS": {
            "Type": "layers",
            "Layers": ["sha256:singlelayer"]
        }
    }]
    """

    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    // ... configure decoder

    let inspections = try decoder.decode([ImageInspection].self, from: data)
    let inspection = try #require(inspections.first)

    #expect(inspection.architecture == "arm64")
    #expect(inspection.config.cmd == ["/bin/sh"])
    #expect(inspection.config.entrypoint == nil)
    #expect(inspection.config.exposedPorts.isEmpty)
    #expect(inspection.config.volumes.isEmpty)
}
```

### Step 9: Add Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ImageInspectionIntegrationTests.swift` (new)

```swift
import Testing
import TestContainers

@Test func imageExists_returnsTrue_forLocalImage() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()

    // Pull a known image first
    try await docker.pullImage("alpine:3")

    // Check existence
    let exists = await docker.imageExists("alpine:3")
    #expect(exists == true)
}

@Test func imageExists_returnsFalse_forNonExistentImage() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()
    let exists = await docker.imageExists("nonexistent-image-12345:99")
    #expect(exists == false)
}

@Test func inspectImage_returnsMetadata_forRedis() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()

    // Ensure image exists
    try await docker.pullImage("redis:7-alpine")

    let inspection = try await docker.inspectImage("redis:7-alpine")

    // Verify basic metadata
    #expect(inspection.id.hasPrefix("sha256:"))
    #expect(inspection.repoTags.contains(where: { $0.contains("redis") }))
    #expect(inspection.architecture == "amd64" || inspection.architecture == "arm64")
    #expect(inspection.os == "linux")
    #expect(inspection.size > 0)

    // Verify config
    #expect(inspection.config.exposedPorts.keys.contains("6379/tcp"))
    #expect(inspection.config.cmd?.contains("redis-server") == true)
    #expect(inspection.config.workingDir == "/data")
    #expect(inspection.config.volumes.keys.contains("/data"))

    // Verify environment
    let hasRedisVersion = inspection.config.env.contains { $0.hasPrefix("REDIS_VERSION=") }
    #expect(hasRedisVersion)
}

@Test func inspectImage_throwsImageNotFound_forNonExistent() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()

    await #expect(throws: TestContainersError.self) {
        try await docker.inspectImage("does-not-exist:never")
    }
}

@Test func inspectImage_withPlatform_returnsCorrectArchitecture() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let docker = DockerClient()

    // Pull multi-arch image
    try await docker.pullImage("alpine:3", platform: "linux/amd64")

    let inspection = try await docker.inspectImage("alpine:3", platform: "linux/amd64")
    #expect(inspection.architecture == "amd64")
}

@Test func pullPolicy_storesInRequest() {
    let request = ContainerRequest(image: "redis:7")
        .withPullPolicy(.neverPull)

    #expect(request.pullPolicy == .neverPull)
}

@Test func pullPolicy_defaultsToIfMissing() {
    let request = ContainerRequest(image: "redis:7")
    #expect(request.pullPolicy == .ifMissing)
}
```

### Step 10: Update Documentation

1. **Add inline documentation** to all public methods with `///` doc comments
2. **Update FEATURES.md** to mark "Image preflight checks" as implemented under Tier 3
3. **Add usage examples** to README (if image inspection is a major feature)
4. **Document error cases** (image not found, platform mismatch, etc.)

Example doc comment:

```swift
/// Inspect an image to retrieve comprehensive metadata
///
/// This method queries the local Docker daemon for image information including
/// architecture, exposed ports, environment variables, labels, and more.
///
/// - Parameters:
///   - image: Image reference (name:tag, name@digest, or image ID)
///   - platform: Optional platform specifier for multi-platform images (e.g., "linux/amd64")
/// - Returns: Detailed image metadata
/// - Throws: `TestContainersError.imageNotFound` if image doesn't exist locally
/// - Throws: `TestContainersError.commandFailed` if Docker command fails
/// - Throws: `DecodingError` if JSON parsing fails
///
/// # Example
/// ```swift
/// let docker = DockerClient()
/// let inspection = try await docker.inspectImage("redis:7-alpine")
/// print("Exposed ports: \(inspection.config.exposedPorts.keys)")
/// // Output: ["6379/tcp"]
/// ```
///
/// - Note: This method only checks the local image cache. Use `pullImage(_:platform:)` first if needed.
public func inspectImage(_ image: String, platform: String? = nil) async throws -> ImageInspection
```

## Testing Plan

### Unit Tests

1. **JSON Parsing Tests** (`ImageInspectionTests.swift`)
   - Parse complete image inspection JSON
   - Parse minimal image (no exposed ports, no volumes)
   - Parse multi-platform image
   - Handle null/missing fields gracefully
   - Date parsing (RFC3339 format with fractional seconds)
   - Exposed ports parsing (format: "port/protocol")
   - Environment array parsing
   - Labels dictionary parsing
   - Volumes parsing

2. **Pull Policy Tests** (`ContainerRequestTests.swift`)
   - Default pull policy is `.ifMissing`
   - `withPullPolicy()` sets policy correctly
   - Pull policy is `Hashable` (for `ContainerRequest` conformance)
   - All enum cases have correct raw values

3. **Error Type Tests**
   - `imageNotFound` error has correct description
   - Error includes image name and helpful message

### Integration Tests

1. **Image Existence Tests**
   - `imageExists()` returns true for local image (alpine, redis)
   - `imageExists()` returns false for non-existent image
   - `imageExists()` with platform filter
   - `imageExists()` handles malformed image names gracefully

2. **Image Inspection Tests**
   - Inspect well-known images (redis:7-alpine, postgres:15-alpine)
   - Verify architecture matches system or specified platform
   - Verify exposed ports match known images
   - Verify environment variables present
   - Verify labels present
   - Verify working directory correct
   - Cross-check image metadata with container runtime behavior

3. **Image Pull Tests**
   - Pull small image (alpine:3)
   - Pull with specific platform
   - Pull non-existent image fails with appropriate error
   - Pull from private registry (requires auth setup - optional)

4. **Platform-Specific Tests**
   - Inspect `linux/amd64` variant on Apple Silicon
   - Inspect `linux/arm64` variant
   - Platform mismatch error handling

5. **Error Handling Tests**
   - Inspect non-existent image throws `imageNotFound`
   - Invalid image reference handled gracefully
   - Docker not available handled gracefully

### Manual Testing

```bash
# Enable Docker integration tests
export TESTCONTAINERS_RUN_DOCKER_TESTS=1

# Run all tests
swift test

# Run specific test suite
swift test --filter ImageInspectionTests
swift test --filter ImageInspectionIntegrationTests

# Test with different images manually
swift run # or create test script

# Verify image inspection manually
docker image inspect redis:7-alpine
docker image inspect --platform linux/amd64 alpine:3
```

### Performance Testing

- Measure `imageExists()` performance (should be < 50ms)
- Measure `inspectImage()` performance (should be < 100ms)
- Verify no performance regression for existing container start flow
- Test with large images (e.g., several GB)

## Acceptance Criteria

### Must Have

- [x] `ImageInspection` struct with `Codable` conformance
- [x] `ImageConfig`, `EmptyObject`, `ImageRootFS` supporting types
- [x] `ImagePullPolicy` enum with `.always`, `.ifNotPresent`, `.never` cases (pre-existing)
- [x] `DockerClient.imageExists(_:platform:)` returns boolean (public)
- [x] `DockerClient.inspectImage(_:platform:)` returns `ImageInspection` (public)
- [x] `DockerClient.pullImage(_:platform:)` pulls image (public)
- [x] `ContainerRequest.imagePullPolicy` property with default `.ifNotPresent` (pre-existing)
- [x] `ContainerRequest.withImagePullPolicy(_:)` builder method (pre-existing)
- [x] `TestContainersError.imageNotFoundLocally(image:message:)` error case (pre-existing)
- [x] All types are `Sendable` for Swift Concurrency
- [x] JSON parsing handles Docker's PascalCase field names
- [x] Date parsing supports RFC3339 with fractional seconds
- [x] Exposed ports parsed from `"port/protocol": {}` format
- [x] Platform parameter passed to Docker CLI with `--platform` flag
- [x] Unit tests for JSON parsing (success and edge cases)
- [ ] Integration tests with real Docker images
- [x] Documentation comments on all public APIs
- [x] Error messages are clear and actionable

### Should Have

- [ ] `Container.imageInspection()` convenience method
- [ ] Helper to parse exposed ports to list of integers
- [ ] Helper to convert environment array to dictionary
- [ ] Performance under 100ms for typical images
- [ ] Helpful error message suggestions ("did you mean...?")
- [ ] Handle multi-platform images correctly
- [ ] Tests with various image types (alpine, redis, postgres, nginx)

### Nice to Have

- [ ] Pull progress reporting (requires streaming output parsing)
- [ ] Image size formatted in human-readable units (MB, GB)
- [ ] Image age calculation (time since created)
- [ ] Validate image reference format before calling Docker
- [ ] Cache inspection results to avoid repeated Docker calls
- [ ] Support for image digests (sha256:...) in addition to tags
- [ ] Comprehensive error recovery and retry logic

### Out of Scope (Future Features)

- **Pull policy enforcement**: Modifying container start to respect pull policy (requires changes to `runContainer`)
- **Image build**: Building images from Dockerfile
- **Registry authentication**: Logging into private registries
- **Image substitution**: Registry mirrors or custom image mappings
- **Image pruning/cleanup**: Removing unused images
- **Layer inspection**: Detailed layer-by-layer analysis
- **Image export/save**: Saving images to tar files
- **Image history**: Viewing image build history (`docker history`)

## References

### Docker CLI Commands

```bash
# Check if image exists locally
docker images redis:7 --quiet --no-trunc
# Output: sha256:abc123... (or empty if not found)

# Inspect image
docker image inspect redis:7-alpine
# Output: JSON array with image metadata

# Inspect specific platform
docker image inspect --platform linux/amd64 alpine:3

# Pull image
docker pull redis:7-alpine

# Pull specific platform
docker pull --platform linux/arm64 redis:7-alpine
```

### Docker Inspect JSON Structure

```json
[
  {
    "Id": "sha256:1234567890abcdef...",
    "RepoTags": ["redis:7-alpine", "redis:latest"],
    "RepoDigests": ["redis@sha256:..."],
    "Created": "2024-12-10T15:30:45.123456789Z",
    "Size": 31457280,
    "Architecture": "amd64",
    "Os": "linux",
    "Config": {
      "Env": ["PATH=/usr/bin", "REDIS_VERSION=7.2"],
      "Cmd": ["redis-server"],
      "Entrypoint": ["docker-entrypoint.sh"],
      "WorkingDir": "/data",
      "User": "redis",
      "ExposedPorts": { "6379/tcp": {} },
      "Labels": { "version": "7.2" },
      "Volumes": { "/data": {} }
    },
    "RootFS": {
      "Type": "layers",
      "Layers": ["sha256:...", "sha256:..."]
    }
  }
]
```

### Related Files

- **DockerClient**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`
- **ContainerRequest**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`
- **Container**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/Container.swift`
- **TestContainersError**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/TestContainersError.swift`
- **ProcessRunner**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ProcessRunner.swift`
- **Integration Tests**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

### Similar Implementations

- **testcontainers-go**: Image inspection and pull policy
  - https://github.com/testcontainers/testcontainers-go/blob/main/docker.go
- **Testcontainers Java**: `ImageFromDockerfile` and pull policies
  - https://github.com/testcontainers/testcontainers-java/
- **Docker API Documentation**: Image inspection endpoint
  - https://docs.docker.com/reference/api/engine/version/v1.47/#tag/Image

### Existing Patterns in Codebase

**Actor-based DockerClient** (`DockerClient.swift`):
```swift
public actor DockerClient {
    func runDocker(_ args: [String]) async throws -> CommandOutput
}
```

**Builder Pattern** (`ContainerRequest.swift`):
```swift
public func withExposedPort(_ containerPort: Int) -> Self {
    var copy = self
    copy.ports.append(...)
    return copy
}
```

**Error Handling** (`TestContainersError.swift`):
```swift
public enum TestContainersError: Error, CustomStringConvertible, Sendable {
    case commandFailed(command: [String], exitCode: Int32, stdout: String, stderr: String)
}
```

**Integration Test Pattern** (`DockerIntegrationTests.swift`):
```swift
@Test func canStartContainer_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }
    // ... test with real Docker
}
```

## Notes

### Why Image Preflight Checks Matter

1. **Better Error Messages**: Know if image is missing before attempting container start
2. **Dynamic Configuration**: Discover exposed ports and env vars from image metadata
3. **Validation**: Ensure image supports requested platform before running
4. **Performance**: Check local cache before pulling (save bandwidth/time)
5. **Testing**: Verify image expectations in test setup
6. **Module Development**: Service-specific containers can introspect their images

### Design Decisions

**Why `imageExists()` is Non-Throwing**:
- Existence checks are often used in conditional logic
- Throwing API would require verbose `do-catch` for simple checks
- Mirrors filesystem APIs like `FileManager.fileExists(atPath:)`

**Why Pull Policy is in ContainerRequest**:
- Future feature: enforce policy during container start
- Follows builder pattern for configuration
- Default `.ifMissing` matches Docker's behavior

**Why Platform Parameter in Inspect**:
- Multi-platform images can have different configs per architecture
- Must specify which variant to inspect
- Matches Docker CLI API (`docker image inspect --platform`)

**Why Not Parse Environment to Dictionary**:
- Docker stores as array of "KEY=VALUE" strings
- Some vars may have `=` in value: splitting is ambiguous
- Users can easily parse if needed: `env.split(separator: "=", maxSplits: 1)`
- Keep raw format for flexibility

### Future Enhancements

1. **Pull Policy Enforcement**: Modify `DockerClient.runContainer()` to respect pull policy
2. **Image Build**: Add `buildImage(dockerfile:context:)` method
3. **Registry Auth**: Add authentication for private registries
4. **Pull Progress**: Parse and report image pull progress
5. **Image Cache**: Cache inspection results to avoid repeated Docker calls
6. **Image Helpers**: Convenience methods like `.exposedPortNumbers()`, `.environmentDict()`
7. **Image Validation**: Validate image reference format before calling Docker
