# Feature 022: Extended Container Labels

**Status:** Implemented
**Priority:** Tier 2 (Medium)
**Estimated Effort:** Small (2-4 hours)

---

## Summary

Extend the label support in `ContainerRequest` to enable users to set arbitrary custom labels beyond the library's default `testcontainers.swift=true` label. This includes support for:

- Adding multiple custom labels via a single builder method
- Using label prefixes for organizational grouping
- Merging user-defined labels with library defaults
- Preserving label ordering for predictable Docker CLI output

Labels are metadata key-value pairs attached to Docker containers that enable filtering, organization, and integration with external tooling (monitoring systems, cleanup scripts, CI/CD pipelines).

---

## Current State

### Existing Implementation

The library currently supports basic label functionality in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`:

```swift
public struct ContainerRequest: Sendable, Hashable {
    // ...
    public var labels: [String: String]
    // ...

    public init(image: String) {
        // ...
        self.labels = ["testcontainers.swift": "true"]
        // ...
    }

    public func withLabel(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.labels[key] = value
        return copy
    }
}
```

Labels are passed to Docker in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`:

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]
    // ...
    for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
        args += ["--label", "\(key)=\(value)"]
    }
    // ...
}
```

### Current Capabilities

- ✅ Default library label (`testcontainers.swift=true`) applied automatically
- ✅ Single label addition via `withLabel(_:_:)` builder method
- ✅ Labels passed to `docker run --label` correctly
- ✅ Deterministic ordering (sorted by key) for CLI stability

### Current Limitations

- ❌ No bulk label addition (requires chaining multiple `withLabel` calls)
- ❌ No label prefix helper for organizational conventions
- ❌ No explicit merge semantics (though implicit via dictionary assignment)
- ❌ No convenience for common label patterns (owner, environment, version, etc.)

---

## Requirements

### Functional Requirements

1. **Bulk Label Addition**
   - Accept a dictionary of labels and merge them with existing labels
   - User labels should override existing labels with the same key
   - Library default labels should remain unless explicitly overridden

2. **Label Prefixes**
   - Support adding labels with a common prefix (e.g., `com.myapp.*`)
   - Useful for organizational standards and avoiding key conflicts
   - Should combine prefix with user-provided keys automatically

3. **Merge with Defaults**
   - User-provided labels should merge with the default `testcontainers.swift=true` label
   - Users should be able to override/remove default labels if needed
   - Maintain backward compatibility with existing code

4. **Label Inheritance**
   - Labels set on `ContainerRequest` should flow through to the created container
   - Labels should be accessible for inspection (future feature)
   - Labels should persist through container lifecycle

### Non-Functional Requirements

1. **API Consistency**
   - Follow existing builder pattern conventions in `ContainerRequest`
   - Use method chaining with `-> Self` return types
   - Maintain `Sendable` and `Hashable` conformance

2. **Performance**
   - Label operations should be O(n) where n is the number of labels
   - No significant overhead during container startup

3. **Testing**
   - Unit tests for builder API correctness
   - Integration tests verifying labels reach Docker correctly

---

## API Design

### Proposed API Extensions

Add the following methods to `ContainerRequest` in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`:

```swift
public struct ContainerRequest: Sendable, Hashable {
    // ... existing properties ...

    /// Adds multiple labels to the container.
    /// Labels are merged with existing labels; new values override existing keys.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "redis:7")
    ///     .withLabels([
    ///         "app.name": "redis-cache",
    ///         "app.environment": "test",
    ///         "app.version": "1.0.0"
    ///     ])
    /// ```
    public func withLabels(_ labels: [String: String]) -> Self {
        var copy = self
        for (key, value) in labels {
            copy.labels[key] = value
        }
        return copy
    }

    /// Adds multiple labels with a common prefix.
    /// Useful for organizational label conventions.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "postgres:15")
    ///     .withLabels(prefix: "com.mycompany.db", [
    ///         "name": "users-db",
    ///         "tier": "integration-test",
    ///         "owner": "platform-team"
    ///     ])
    /// // Results in labels:
    /// // - com.mycompany.db.name=users-db
    /// // - com.mycompany.db.tier=integration-test
    /// // - com.mycompany.db.owner=platform-team
    /// ```
    public func withLabels(prefix: String, _ labels: [String: String]) -> Self {
        var copy = self
        for (key, value) in labels {
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            copy.labels[fullKey] = value
        }
        return copy
    }

    /// Removes a label by key if it exists.
    /// Useful for removing default labels or cleaning up during request building.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "alpine:3")
    ///     .withoutLabel("testcontainers.swift")
    /// ```
    public func withoutLabel(_ key: String) -> Self {
        var copy = self
        copy.labels.removeValue(forKey: key)
        return copy
    }
}
```

### API Usage Examples

#### Example 1: Adding Multiple Custom Labels

```swift
let request = ContainerRequest(image: "redis:7")
    .withLabels([
        "app.name": "user-session-cache",
        "app.environment": "integration-test",
        "app.version": "2.1.0",
        "app.owner": "backend-team"
    ])
    .withExposedPort(6379)

try await withContainer(request) { container in
    // Container has labels:
    // - testcontainers.swift=true (default)
    // - app.name=user-session-cache
    // - app.environment=integration-test
    // - app.version=2.1.0
    // - app.owner=backend-team
}
```

#### Example 2: Using Label Prefixes

```swift
let request = ContainerRequest(image: "postgres:15")
    .withLabels(prefix: "com.acme.database", [
        "name": "orders-db",
        "schema-version": "3.2",
        "backup-policy": "daily"
    ])
    .withEnvironment([
        "POSTGRES_PASSWORD": "test"
    ])

try await withContainer(request) { container in
    // Container has labels:
    // - testcontainers.swift=true
    // - com.acme.database.name=orders-db
    // - com.acme.database.schema-version=3.2
    // - com.acme.database.backup-policy=daily
}
```

#### Example 3: Combining Multiple Label Methods

```swift
let request = ContainerRequest(image: "nginx:1.25")
    .withLabel("service.type", "web-server")
    .withLabels(prefix: "monitoring", [
        "enabled": "true",
        "port": "9113",
        "scrape-interval": "30s"
    ])
    .withLabels([
        "deployment.id": "test-\(UUID().uuidString)",
        "deployment.timestamp": "\(Date().timeIntervalSince1970)"
    ])
```

#### Example 4: Removing Default Labels

```swift
// Remove default label for custom container management
let request = ContainerRequest(image: "alpine:3")
    .withoutLabel("testcontainers.swift")
    .withLabel("managed-by", "custom-cleanup-script")
```

---

## Implementation Steps

### 1. Add New Builder Methods to ContainerRequest

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

**Changes:**
- Add `withLabels(_:)` method for bulk label addition
- Add `withLabels(prefix:_:)` method for prefixed labels
- Add `withoutLabel(_:)` method for label removal
- Ensure all methods follow the existing builder pattern
- Preserve `Sendable` and `Hashable` conformance

**Implementation notes:**
- Use dictionary iteration and assignment (consistent with `withEnvironment` at line 59-63)
- Follow the same copy-modify-return pattern as other builders
- String interpolation for prefix joining

### 2. Add Unit Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

**Test cases:**

```swift
@Test func addsMultipleLabels() {
    let request = ContainerRequest(image: "alpine:3")
        .withLabels([
            "app.name": "test-app",
            "app.version": "1.0"
        ])

    #expect(request.labels["testcontainers.swift"] == "true")
    #expect(request.labels["app.name"] == "test-app")
    #expect(request.labels["app.version"] == "1.0")
    #expect(request.labels.count == 3)
}

@Test func addsPrefixedLabels() {
    let request = ContainerRequest(image: "alpine:3")
        .withLabels(prefix: "com.acme", [
            "team": "platform",
            "env": "test"
        ])

    #expect(request.labels["com.acme.team"] == "platform")
    #expect(request.labels["com.acme.env"] == "test")
}

@Test func emptyPrefixAddsLabelsWithoutDot() {
    let request = ContainerRequest(image: "alpine:3")
        .withLabels(prefix: "", [
            "key": "value"
        ])

    #expect(request.labels["key"] == "value")
    #expect(request.labels[".key"] == nil)
}

@Test func overridesExistingLabels() {
    let request = ContainerRequest(image: "alpine:3")
        .withLabel("version", "1.0")
        .withLabels(["version": "2.0"])

    #expect(request.labels["version"] == "2.0")
}

@Test func removesLabels() {
    let request = ContainerRequest(image: "alpine:3")
        .withLabel("temp", "value")
        .withoutLabel("temp")

    #expect(request.labels["temp"] == nil)
    #expect(request.labels["testcontainers.swift"] == "true")
}

@Test func removesDefaultLabel() {
    let request = ContainerRequest(image: "alpine:3")
        .withoutLabel("testcontainers.swift")

    #expect(request.labels["testcontainers.swift"] == nil)
    #expect(request.labels.isEmpty)
}

@Test func chainsMultipleLabelOperations() {
    let request = ContainerRequest(image: "redis:7")
        .withLabel("single", "value")
        .withLabels(["bulk1": "v1", "bulk2": "v2"])
        .withLabels(prefix: "prefix", ["key": "val"])
        .withoutLabel("bulk1")

    #expect(request.labels["single"] == "value")
    #expect(request.labels["bulk1"] == nil)
    #expect(request.labels["bulk2"] == "v2")
    #expect(request.labels["prefix.key"] == "val")
    #expect(request.labels["testcontainers.swift"] == "true")
}
```

### 3. Add Integration Tests (Optional)

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

**Test case:**

```swift
@Test func appliesCustomLabelsToContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "5"])
        .withLabels([
            "test.feature": "extended-labels",
            "test.timestamp": "\(Date().timeIntervalSince1970)"
        ])
        .withLabels(prefix: "org.example", [
            "owner": "integration-tests"
        ])

    try await withContainer(request) { container in
        // Verify container started successfully
        #expect(!container.id.isEmpty)

        // Future: Once inspect is implemented, verify labels were applied
        // let info = try await container.inspect()
        // #expect(info.labels["test.feature"] == "extended-labels")
        // #expect(info.labels["org.example.owner"] == "integration-tests")
    }
}
```

### 4. Update Documentation

**Files to update:**
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/README.md` - Add example to features section
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md` - Mark line 64 as implemented

**README.md addition:**

```markdown
### Custom Labels

Add metadata labels to containers for organization and tooling integration:

```swift
let request = ContainerRequest(image: "postgres:15")
    .withLabels([
        "app.name": "user-service-db",
        "app.environment": "test"
    ])
    .withLabels(prefix: "com.acme", [
        "owner": "platform-team",
        "version": "1.0.0"
    ])
```
```

---

## Testing Plan

### Unit Tests (Required)

Focus on builder API correctness and label merging logic:

1. ✅ Adding multiple labels via `withLabels(_:)`
2. ✅ Adding prefixed labels via `withLabels(prefix:_:)`
3. ✅ Handling empty prefix (no leading dot)
4. ✅ Overriding existing labels
5. ✅ Removing labels via `withoutLabel(_:)`
6. ✅ Removing default labels
7. ✅ Chaining multiple label operations
8. ✅ Label count validation
9. ✅ Dictionary ordering independence (labels should work regardless of insertion order)

**Test execution:**
```bash
swift test --filter ContainerRequestTests
```

### Integration Tests (Optional)

Verify labels are correctly passed to Docker and attached to containers:

1. ✅ Custom labels appear on created containers (requires container inspection)
2. ✅ Label prefixes are correctly formatted
3. ✅ Default labels coexist with custom labels
4. ✅ Removed labels do not appear on container

**Test execution:**
```bash
TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test --filter DockerIntegrationTests
```

**Note:** Full integration test validation requires container inspection support (see Feature 023). Until then, integration tests can verify containers start successfully with custom labels but cannot directly inspect label values.

### Manual Testing

For validation beyond automated tests:

```bash
# Start a container with custom labels
# (Run test code or create a small Swift script)

# Inspect container labels
docker inspect <container-id> --format '{{json .Config.Labels}}' | jq

# Expected output should include:
# {
#   "testcontainers.swift": "true",
#   "app.name": "test-app",
#   "com.acme.owner": "platform-team",
#   ...
# }
```

---

## Acceptance Criteria

### Definition of Done

- [x] `withLabels(_:)` method implemented and tested
- [x] `withLabels(prefix:_:)` method implemented and tested
- [x] `withoutLabel(_:)` method implemented and tested
- [x] All unit tests pass
- [ ] Integration test added (passes if `TESTCONTAINERS_RUN_DOCKER_TESTS=1`)
- [ ] Documentation updated (README.md)
- [x] Feature marked as implemented in FEATURES.md
- [x] Code follows existing patterns in ContainerRequest
- [x] Sendable and Hashable conformance maintained
- [x] No breaking changes to existing API

### Success Criteria

Users can:
1. Add multiple labels in a single builder call
2. Use label prefixes for organizational conventions
3. Override default labels if needed
4. Remove labels during request construction
5. Chain label operations with other builder methods
6. Verify labels in Docker inspection (manual or programmatic)

### Out of Scope (Future Work)

- Container inspection API to read labels from running containers (Feature 023)
- Label-based container filtering for cleanup (Feature 024)
- Label validation (key/value format constraints)
- Label templates or preset configurations
- Dynamic label generation (timestamp, UUID helpers)

---

## Dependencies

### Upstream
None - this feature is self-contained.

### Downstream
- **Feature 023: Container Inspection** - Will expose labels via `Container.inspect()`
- **Feature 024: Label-based Cleanup** - Will use labels for identifying test containers

---

## References

### Related Code
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` - Lines 31, 41, 65-69
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift` - Lines 43-45

### Docker Documentation
- [Docker labels documentation](https://docs.docker.com/config/labels-custom-metadata/)
- [Docker run --label flag](https://docs.docker.com/engine/reference/commandline/run/#label)

### Similar Implementations
- **testcontainers-go:** `ContainerRequest.Labels` field with map merging
- **testcontainers-java:** `GenericContainer.withLabel()` and `withLabels()`
- **testcontainers-node:** `GenericContainer.withLabels()` accepting object literal

---

## Notes

### Design Decisions

1. **Why separate `withLabels(prefix:_:)` instead of users building prefixed keys themselves?**
   - Convenience for common organizational patterns
   - Reduces string concatenation errors
   - Makes prefix conventions more visible in code

2. **Why allow removing default labels?**
   - Advanced users may have custom cleanup strategies
   - Enables integration with external container management tools
   - Follows principle of least surprise (users have full control)

3. **Why not validate label keys/values?**
   - Docker itself has minimal restrictions
   - Validation would add complexity and maintenance burden
   - Users can discover invalid labels via Docker error messages
   - Can be added later if demand emerges

### Implementation Complexity

- **Estimated LOC:** ~40 lines (3 methods + docs)
- **Test LOC:** ~100 lines (7-8 test functions)
- **Risk Level:** Low (no Docker CLI changes, pure builder logic)
- **Backward Compatibility:** 100% (additive only)
