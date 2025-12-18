# Feature 020: Privileged Mode and Capabilities

**Status: ✅ Implemented**
**Priority**: Medium (Tier 2)
**Complexity**: Low
**Implementation Approach**: Docker CLI

---

## Implementation Notes

This feature was implemented on 2025-12-18. Key implementation details:

### Files Modified
- `Sources/TestContainers/ContainerRequest.swift` - Added `Capability` type, request properties, and builder methods
- `Sources/TestContainers/DockerClient.swift` - Added `--privileged`, `--cap-add`, and `--cap-drop` flags
- `Tests/TestContainersTests/ContainerRequestTests.swift` - Unit tests for privileged/capability configuration
- `Tests/TestContainersTests/DockerClientArgumentTests.swift` - Argument-level test with a mocked Docker script

### Test Coverage
- Builder unit tests for privileged mode and capability add/drop accumulation
- Argument assembly test verifying deterministic flag ordering and values

## Summary

Add support for running containers in privileged mode or with specific Linux capabilities. This enables containers to perform operations that require elevated permissions, such as:

- Running Docker-in-Docker (DinD) scenarios
- Network operations (packet capture, raw sockets, routing)
- Device access and manipulation
- System administration tasks in containers
- Testing security-sensitive code

This feature extends `ContainerRequest` with three new builder methods:
- `.withPrivileged(true)` - Run container with all capabilities
- `.withCapabilityAdd([...])` - Grant specific capabilities
- `.withCapabilityDrop([...])` - Remove specific capabilities

---

## Current State

### ContainerRequest Properties

The current `ContainerRequest` struct (from `/Sources/TestContainers/ContainerRequest.swift`) supports:

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

### Builder Pattern

The codebase uses a consistent builder pattern where methods:
- Take parameters for configuration
- Return `Self` for method chaining
- Create a mutable copy, modify it, and return it

Example from existing code:
```swift
public func withLabel(_ key: String, _ value: String) -> Self {
    var copy = self
    copy.labels[key] = value
    return copy
}
```

### DockerClient.runContainer

The `DockerClient.runContainer` method (from `/Sources/TestContainers/DockerClient.swift`) builds Docker CLI arguments:

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    if let name = request.name {
        args += ["--name", name]
    }

    for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
        args += ["-e", "\(key)=\(value)"]
    }

    for mapping in request.ports {
        args += ["-p", mapping.dockerFlag]
    }

    for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
        args += ["--label", "\(key)=\(value)"]
    }

    args.append(request.image)
    args += request.command

    let output = try await runDocker(args)
    // ... parse container ID
}
```

**Missing**: No support for `--privileged`, `--cap-add`, or `--cap-drop` flags.

---

## Requirements

### Functional Requirements

1. **Privileged Mode**: Enable/disable privileged mode (grants all capabilities)
2. **Add Capabilities**: Grant specific Linux capabilities to container
3. **Drop Capabilities**: Remove specific Linux capabilities from container
4. **Combine Modes**: Support both `withCapabilityAdd` and `withCapabilityDrop` together
5. **Validation**: Do not enforce exclusivity; Docker allows `--privileged` with `--cap-add`/`--cap-drop`

### Non-Functional Requirements

1. **Type Safety**: Use Swift enums or structs for capability names
2. **Consistency**: Follow existing builder pattern conventions
3. **Documentation**: Clear docs with use case examples
4. **Platform Awareness**: Note that capabilities are Linux-specific

---

## API Design

### New Types

```swift
/// Represents a Linux capability that can be granted or dropped from a container.
/// Full list: https://man7.org/linux/man-pages/man7/capabilities.7.html
public struct Capability: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // Common capabilities as static constants
    public static let netAdmin = Capability(rawValue: "NET_ADMIN")
    public static let netRaw = Capability(rawValue: "NET_RAW")
    public static let sysAdmin = Capability(rawValue: "SYS_ADMIN")
    public static let sysTime = Capability(rawValue: "SYS_TIME")
    public static let sysModule = Capability(rawValue: "SYS_MODULE")
    public static let sysRawio = Capability(rawValue: "SYS_RAWIO")
    public static let auditControl = Capability(rawValue: "AUDIT_CONTROL")
    public static let auditRead = Capability(rawValue: "AUDIT_READ")
    public static let chown = Capability(rawValue: "CHOWN")
    public static let dacOverride = Capability(rawValue: "DAC_OVERRIDE")
    public static let fowner = Capability(rawValue: "FOWNER")
    public static let fsetid = Capability(rawValue: "FSETID")
    public static let kill = Capability(rawValue: "KILL")
    public static let setgid = Capability(rawValue: "SETGID")
    public static let setuid = Capability(rawValue: "SETUID")
    public static let setpcap = Capability(rawValue: "SETPCAP")
    public static let netBindService = Capability(rawValue: "NET_BIND_SERVICE")
    public static let netBroadcast = Capability(rawValue: "NET_BROADCAST")
    public static let ipcLock = Capability(rawValue: "IPC_LOCK")
    public static let ipcOwner = Capability(rawValue: "IPC_OWNER")
    public static let sysChroot = Capability(rawValue: "SYS_CHROOT")
    public static let sysPtrace = Capability(rawValue: "SYS_PTRACE")
    public static let sysPacct = Capability(rawValue: "SYS_PACCT")
    public static let sysResource = Capability(rawValue: "SYS_RESOURCE")
    public static let sysBoot = Capability(rawValue: "SYS_BOOT")
    public static let sysNice = Capability(rawValue: "SYS_NICE")
    public static let sysTtyConfig = Capability(rawValue: "SYS_TTY_CONFIG")
    public static let mknod = Capability(rawValue: "MKNOD")
    public static let lease = Capability(rawValue: "LEASE")
    public static let auditWrite = Capability(rawValue: "AUDIT_WRITE")
    public static let setfcap = Capability(rawValue: "SETFCAP")
    public static let macOverride = Capability(rawValue: "MAC_OVERRIDE")
    public static let macAdmin = Capability(rawValue: "MAC_ADMIN")
    public static let syslog = Capability(rawValue: "SYSLOG")
    public static let wakeAlarm = Capability(rawValue: "WAKE_ALARM")
    public static let blockSuspend = Capability(rawValue: "BLOCK_SUSPEND")
    public static let perfmon = Capability(rawValue: "PERFMON")
    public static let bpf = Capability(rawValue: "BPF")
    public static let checkpointRestore = Capability(rawValue: "CHECKPOINT_RESTORE")
}
```

### Extended ContainerRequest

```swift
public struct ContainerRequest: Sendable, Hashable {
    // ... existing properties ...

    public var privileged: Bool
    public var capabilitiesToAdd: Set<Capability>
    public var capabilitiesToDrop: Set<Capability>
}
```

### Builder Methods

```swift
extension ContainerRequest {
    /// Run the container in privileged mode, granting all capabilities.
    ///
    /// Privileged mode gives the container nearly all capabilities of the host machine.
    /// This is typically used for:
    /// - Docker-in-Docker scenarios
    /// - Network debugging (packet capture, routing)
    /// - Device access
    /// - System administration tasks
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "docker:dind")
    ///     .withPrivileged(true)
    /// ```
    ///
    /// - Parameter privileged: Whether to run in privileged mode (default: false)
    /// - Returns: A new ContainerRequest with privileged mode configured
    public func withPrivileged(_ privileged: Bool = true) -> Self {
        var copy = self
        copy.privileged = privileged
        return copy
    }

    /// Add specific Linux capabilities to the container.
    ///
    /// Capabilities are a fine-grained alternative to privileged mode, allowing you to
    /// grant specific permissions without full host access.
    ///
    /// Common use cases:
    /// - `.netAdmin`: Network configuration, routing tables
    /// - `.netRaw`: Use RAW and PACKET sockets
    /// - `.sysAdmin`: Various system administration operations
    /// - `.sysTime`: Set system clock
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "alpine:3")
    ///     .withCapabilityAdd([.netAdmin, .netRaw])
    /// ```
    ///
    /// - Parameter capabilities: Set of capabilities to add
    /// - Returns: A new ContainerRequest with capabilities added
    public func withCapabilityAdd(_ capabilities: Set<Capability>) -> Self {
        var copy = self
        copy.capabilitiesToAdd.formUnion(capabilities)
        return copy
    }

    /// Drop specific Linux capabilities from the container.
    ///
    /// Use this to remove default capabilities for defense-in-depth security.
    /// Containers run with a default set of capabilities; dropping them further
    /// restricts what the container can do.
    ///
    /// Example:
    /// ```swift
    /// let request = ContainerRequest(image: "nginx:latest")
    ///     .withCapabilityDrop([.netRaw, .netBindService])
    /// ```
    ///
    /// - Parameter capabilities: Set of capabilities to drop
    /// - Returns: A new ContainerRequest with capabilities dropped
    public func withCapabilityDrop(_ capabilities: Set<Capability>) -> Self {
        var copy = self
        copy.capabilitiesToDrop.formUnion(capabilities)
        return copy
    }
}
```

### Convenience Overloads

```swift
extension ContainerRequest {
    /// Add a single capability to the container.
    ///
    /// - Parameter capability: The capability to add
    /// - Returns: A new ContainerRequest with the capability added
    public func withCapabilityAdd(_ capability: Capability) -> Self {
        withCapabilityAdd([capability])
    }

    /// Drop a single capability from the container.
    ///
    /// - Parameter capability: The capability to drop
    /// - Returns: A new ContainerRequest with the capability dropped
    public func withCapabilityDrop(_ capability: Capability) -> Self {
        withCapabilityDrop([capability])
    }
}
```

---

## Implementation Steps

### Step 1: Define the Capability Type

**File**: `/Sources/TestContainers/ContainerRequest.swift`

Add the `Capability` struct at the top of the file, before `ContainerRequest`:

```swift
/// Represents a Linux capability that can be granted or dropped from a container.
/// Full list: https://man7.org/linux/man-pages/man7/capabilities.7.html
public struct Capability: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // Static constants for common capabilities (see API Design section)
}
```

### Step 2: Extend ContainerRequest with New Properties

**File**: `/Sources/TestContainers/ContainerRequest.swift`

Add three new properties to `ContainerRequest`:

```swift
public struct ContainerRequest: Sendable, Hashable {
    // ... existing properties ...

    public var privileged: Bool
    public var capabilitiesToAdd: Set<Capability>
    public var capabilitiesToDrop: Set<Capability>

    public init(image: String) {
        // ... existing initialization ...
        self.privileged = false
        self.capabilitiesToAdd = []
        self.capabilitiesToDrop = []
    }
}
```

### Step 3: Add Builder Methods

**File**: `/Sources/TestContainers/ContainerRequest.swift`

Add the three builder methods and convenience overloads to the `ContainerRequest` extension:

```swift
extension ContainerRequest {
    public func withPrivileged(_ privileged: Bool = true) -> Self { ... }
    public func withCapabilityAdd(_ capabilities: Set<Capability>) -> Self { ... }
    public func withCapabilityAdd(_ capability: Capability) -> Self { ... }
    public func withCapabilityDrop(_ capabilities: Set<Capability>) -> Self { ... }
    public func withCapabilityDrop(_ capability: Capability) -> Self { ... }
}
```

### Step 4: Update DockerClient.runContainer

**File**: `/Sources/TestContainers/DockerClient.swift`

In the `runContainer` method, add handling for the new flags after the labels section:

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    // ... existing name, environment, ports, labels ...

    // Add privileged flag
    if request.privileged {
        args.append("--privileged")
    }

    // Add capabilities
    for capability in request.capabilitiesToAdd.sorted(by: { $0.rawValue < $1.rawValue }) {
        args += ["--cap-add", capability.rawValue]
    }

    // Drop capabilities
    for capability in request.capabilitiesToDrop.sorted(by: { $0.rawValue < $1.rawValue }) {
        args += ["--cap-drop", capability.rawValue]
    }

    args.append(request.image)
    args += request.command

    // ... rest of method ...
}
```

**Note**: Sorting capabilities ensures deterministic CLI argument order for testing.

### Step 5: Update Documentation

**File**: `/FEATURES.md`

Move "Privileged mode / capabilities" from Tier 2 "Not Implemented" to the "Implemented" section:

```markdown
**Container configuration**
- [x] Privileged mode / capabilities
```

---

## Testing Plan

### Unit Tests

**File**: `/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests for builder methods and property accumulation:

```swift
@Test func buildsPrivilegedRequest() {
    let request = ContainerRequest(image: "alpine:3")
        .withPrivileged(true)

    #expect(request.privileged == true)
}

@Test func buildsRequestWithCapabilitiesAdded() {
    let request = ContainerRequest(image: "alpine:3")
        .withCapabilityAdd(.netAdmin)
        .withCapabilityAdd([.netRaw, .sysTime])

    #expect(request.capabilitiesToAdd == [.netAdmin, .netRaw, .sysTime])
}

@Test func buildsRequestWithCapabilitiesDropped() {
    let request = ContainerRequest(image: "alpine:3")
        .withCapabilityDrop(.netRaw)
        .withCapabilityDrop([.chown, .setuid])

    #expect(request.capabilitiesToDrop == [.netRaw, .chown, .setuid])
}

@Test func combinesCapabilityAddAndDrop() {
    let request = ContainerRequest(image: "alpine:3")
        .withCapabilityAdd([.netAdmin, .sysTime])
        .withCapabilityDrop([.chown, .setuid])

    #expect(request.capabilitiesToAdd == [.netAdmin, .sysTime])
    #expect(request.capabilitiesToDrop == [.chown, .setuid])
}

@Test func capabilityHasCorrectRawValue() {
    #expect(Capability.netAdmin.rawValue == "NET_ADMIN")
    #expect(Capability.sysTime.rawValue == "SYS_TIME")
}

@Test func supportsCustomCapabilities() {
    let custom = Capability(rawValue: "CUSTOM_CAP")
    #expect(custom.rawValue == "CUSTOM_CAP")
}
```

### Integration Tests

**File**: `/Tests/TestContainersTests/DockerIntegrationTests.swift`

Add integration tests that verify the Docker CLI flags are generated correctly:

```swift
@Test func canRunPrivilegedContainer_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Docker-in-Docker requires privileged mode
    let request = ContainerRequest(image: "docker:dind")
        .withPrivileged(true)
        .withCommand(["docker", "version"])
        .waitingFor(.logContains("Server:", timeout: .seconds(30)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("Server:"))
    }
}

@Test func canRunContainerWithCapabilities_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Test that NET_ADMIN capability allows network operations
    let request = ContainerRequest(image: "alpine:3")
        .withCapabilityAdd(.netAdmin)
        .withCommand(["sh", "-c", "ip link add dummy0 type dummy && echo SUCCESS"])
        .waitingFor(.logContains("SUCCESS", timeout: .seconds(10)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("SUCCESS"))
    }
}

@Test func canDropCapabilities_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Test that dropping CHOWN prevents chown operations
    let request = ContainerRequest(image: "alpine:3")
        .withCapabilityDrop(.chown)
        .withCommand(["sh", "-c", "touch /tmp/test && chown nobody /tmp/test || echo FAILED"])
        .waitingFor(.logContains("FAILED", timeout: .seconds(10)))

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("FAILED"))
    }
}
```

### Manual Testing

Test with common scenarios:

1. **Docker-in-Docker**:
   ```swift
   let request = ContainerRequest(image: "docker:dind")
       .withPrivileged(true)
   ```

2. **Network administration**:
   ```swift
   let request = ContainerRequest(image: "alpine:3")
       .withCapabilityAdd([.netAdmin, .netRaw])
   ```

3. **Security hardening**:
   ```swift
   let request = ContainerRequest(image: "nginx:latest")
       .withCapabilityDrop([.netRaw, .chown, .setuid])
   ```

---

## Acceptance Criteria

### Definition of Done

- [x] `Capability` struct implemented with common capability constants
- [x] `ContainerRequest` extended with `privileged`, `capabilitiesToAdd`, `capabilitiesToDrop` properties
- [x] Builder methods `withPrivileged`, `withCapabilityAdd`, `withCapabilityDrop` implemented
- [x] Convenience overloads for single capability add/drop implemented
- [x] `DockerClient.runContainer` generates correct `--privileged`, `--cap-add`, `--cap-drop` flags
- [x] Unit tests pass for builder methods and property accumulation
- [x] Argument-level test verifies CLI flags with a mocked Docker script
- [x] Documentation strings added to all public APIs
- [x] `FEATURES.md` updated to reflect implementation status
- [x] Code follows existing patterns (builder style, sorted output for determinism)

### Success Metrics

- Can start privileged containers for Docker-in-Docker scenarios
- Can grant specific capabilities without full privileged mode
- Can drop capabilities for security hardening
- API is type-safe and discoverable through autocomplete
- Behavior matches Docker CLI (`docker run --privileged`, `--cap-add`, `--cap-drop`)

---

## References

### Docker Documentation

- [Docker run reference - Runtime privilege](https://docs.docker.com/reference/cli/docker/container/run/#privileged)
- [Docker run reference - Capabilities](https://docs.docker.com/reference/cli/docker/container/run/#cap-add)
- [Linux capabilities man page](https://man7.org/linux/man-pages/man7/capabilities.7.html)

### Example Docker Commands

```bash
# Privileged mode
docker run --privileged docker:dind

# Add specific capabilities
docker run --cap-add=NET_ADMIN --cap-add=NET_RAW alpine:3

# Drop capabilities
docker run --cap-drop=CHOWN --cap-drop=SETUID nginx:latest

# Combine add and drop
docker run --cap-add=SYS_TIME --cap-drop=NET_RAW alpine:3
```

### Similar Implementations

- [testcontainers-go](https://github.com/testcontainers/testcontainers-go/blob/main/container.go) - `.WithPrivilegedMode()`, `.WithCapAdd()`, `.WithCapDrop()`
- [testcontainers-java](https://github.com/testcontainers/testcontainers-java) - `withPrivilegedMode()`, `withCapabilities()`

---

## Open Questions

### 1. Should privileged mode and explicit capabilities be mutually exclusive?

**Decision**: Allow both to be specified, but document that `--privileged` grants all capabilities and may override `--cap-add`/`--cap-drop`. Docker allows both flags together.

**Rationale**: Docker doesn't prevent this combination, so we shouldn't either. Users may have complex scenarios where they want privileged mode but explicitly drop certain capabilities.

### 2. Should we validate capability names?

**Decision**: No runtime validation. Use a struct with static constants for common capabilities, but allow custom capability strings via `RawRepresentable`.

**Rationale**:
- Linux kernel versions add new capabilities over time
- Different Docker versions may support different capabilities
- Users may need to test custom/experimental capabilities
- Invalid capabilities will be caught by Docker CLI with clear error messages

### 3. Should we provide capability sets (e.g., "networking", "admin")?

**Decision**: Not in the initial implementation. Start with individual capabilities.

**Future enhancement**: Could add convenience constants like:
```swift
extension Set where Element == Capability {
    static let networking: Set<Capability> = [.netAdmin, .netRaw, .netBindService]
    static let administration: Set<Capability> = [.sysAdmin, .sysTime, .sysResource]
}
```

---

## Future Enhancements

### Additional Security Options

After this feature is implemented, consider adding:

1. **Security options** (`--security-opt`):
   - AppArmor profiles
   - SELinux labels
   - Seccomp profiles
   - No-new-privileges flag

2. **Read-only root filesystem** (`--read-only`):
   ```swift
   public func withReadOnlyRootFilesystem(_ readOnly: Bool = true) -> Self
   ```

3. **User/Group** (`--user`):
   ```swift
   public func withUser(_ user: String) -> Self
   ```

These would complement the capabilities feature for comprehensive container security configuration.
