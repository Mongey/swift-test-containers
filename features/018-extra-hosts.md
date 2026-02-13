# Feature 018: Extra Hosts (`--add-host`)

**Status**: Not Started
**Priority**: Tier 2 (Medium)
**Complexity**: Low
**Estimated Effort**: 2-4 hours

---

## Summary

Add support for custom host-to-IP mappings in container's `/etc/hosts` file using Docker's `--add-host` flag. This allows containers to resolve custom hostnames to specific IP addresses, which is essential for:

- Testing services that connect to external hosts by hostname
- Mocking external dependencies by redirecting hostnames to local services
- Enabling container-to-host communication using the special `host-gateway` value
- Testing DNS-dependent code with controlled hostname resolution

---

## Current State

### ContainerRequest Capabilities

The `ContainerRequest` struct (located at `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`) currently supports:

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

**Builder methods available:**
- `withName(_:)` - Set container name
- `withCommand(_:)` - Override entrypoint command
- `withEnvironment(_:)` - Add environment variables
- `withLabel(_:_:)` - Add container labels
- `withExposedPort(_:hostPort:)` - Map container ports to host ports
- `waitingFor(_:)` - Set wait strategy
- `withHost(_:)` - Set host address for connections

### DockerClient Implementation

The `DockerClient.runContainer(_:)` method (in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`) builds Docker CLI arguments by iterating over request properties:

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
    // ...
}
```

**Pattern observation:** The codebase follows a consistent pattern where:
1. Complex types (like `ContainerPort`) have a `dockerFlag` property for CLI conversion
2. Simple key-value mappings (like `environment`, `labels`) are added directly with sorted iteration
3. Builder methods follow the pattern: `withX(_:) -> Self` returning a modified copy

---

## Requirements

### Functional Requirements

1. **Hostname to IP mapping**
   - Support adding custom hostname → IP address mappings
   - Multiple entries must be supported (no limit on number of hosts)
   - Each mapping adds one line to the container's `/etc/hosts` file

2. **Special `host-gateway` value**
   - Support Docker's special `host-gateway` keyword for the IP address
   - `host-gateway` resolves to the host's gateway IP (usually `host.docker.internal`)
   - This enables container → host communication without hardcoded IPs
   - Example: `--add-host=myhost:host-gateway`

3. **Input validation**
   - Hostnames should be valid DNS names (alphanumeric, hyphens, dots)
   - IP addresses should be valid IPv4 or IPv6, OR the literal string "host-gateway"
   - Empty hostnames or IPs should be rejected (fail early)

4. **Order preservation**
   - Host entries should be added in a predictable order (sorted by hostname)
   - Consistent ordering aids debugging and test reproducibility

### Non-Functional Requirements

1. **API consistency**
   - Follow existing builder pattern conventions
   - Maintain `Sendable` and `Hashable` conformance
   - Use value semantics (copy-on-write for builder methods)

2. **Type safety**
   - Leverage Swift's type system to prevent invalid configurations
   - Provide clear, specific types rather than stringly-typed APIs

3. **Testing**
   - Unit tests for builder API and flag generation
   - Integration tests requiring Docker (opt-in via `TESTCONTAINERS_RUN_DOCKER_TESTS=1`)

---

## API Design

### Proposed Types

```swift
/// Represents a custom host-to-IP mapping for container's /etc/hosts file
public struct ExtraHost: Hashable, Sendable {
    public var hostname: String
    public var ip: String

    public init(hostname: String, ip: String) {
        self.hostname = hostname
        self.ip = ip
    }

    /// Creates a mapping using Docker's special host-gateway value
    /// This resolves to the host machine's gateway IP
    public static func gateway(hostname: String) -> ExtraHost {
        ExtraHost(hostname: hostname, ip: "host-gateway")
    }

    /// Docker CLI flag format: "hostname:ip"
    var dockerFlag: String {
        "\(hostname):\(ip)"
    }
}
```

**Design rationale:**
- Follows the same pattern as `ContainerPort` (has `dockerFlag` computed property)
- Static factory method `.gateway(hostname:)` makes the special case discoverable
- `Hashable` and `Sendable` for consistency with other request components

### ContainerRequest Changes

```swift
public struct ContainerRequest: Sendable, Hashable {
    public var image: String
    public var name: String?
    public var command: [String]
    public var environment: [String: String]
    public var labels: [String: String]
    public var ports: [ContainerPort]
    public var extraHosts: [ExtraHost]  // NEW
    public var waitStrategy: WaitStrategy
    public var host: String

    public init(image: String) {
        self.image = image
        self.name = nil
        self.command = []
        self.environment = [:]
        self.labels = ["testcontainers.swift": "true"]
        self.ports = []
        self.extraHosts = []  // NEW
        self.waitStrategy = .none
        self.host = "127.0.0.1"
    }

    // NEW: Add a single host mapping
    public func withExtraHost(hostname: String, ip: String) -> Self {
        var copy = self
        copy.extraHosts.append(ExtraHost(hostname: hostname, ip: ip))
        return copy
    }

    // NEW: Add a host mapping using ExtraHost type
    public func withExtraHost(_ host: ExtraHost) -> Self {
        var copy = self
        copy.extraHosts.append(host)
        return copy
    }

    // NEW: Add multiple host mappings at once
    public func withExtraHosts(_ hosts: [ExtraHost]) -> Self {
        var copy = self
        copy.extraHosts.append(contentsOf: hosts)
        return copy
    }
}
```

**Design rationale:**
- Three builder method variants for flexibility:
  1. `withExtraHost(hostname:ip:)` - Convenient for simple cases
  2. `withExtraHost(_:)` - Accepts `ExtraHost` type (enables `.gateway()` usage)
  3. `withExtraHosts(_:)` - Bulk addition (similar to `withEnvironment(_:)`)
- Follows existing patterns: `withExposedPort` also has multiple variants

### Usage Examples

```swift
// Example 1: Simple hostname mapping
let request = ContainerRequest(image: "nginx:latest")
    .withExtraHost(hostname: "database.local", ip: "192.168.1.100")
    .withExtraHost(hostname: "api.local", ip: "10.0.0.50")

// Example 2: Using host-gateway for container-to-host communication
let request = ContainerRequest(image: "alpine:3")
    .withExtraHost(.gateway(hostname: "myhost"))
    .withCommand(["ping", "-c", "1", "myhost"])

// Example 3: Bulk addition
let hosts: [ExtraHost] = [
    ExtraHost(hostname: "db1", ip: "192.168.1.10"),
    ExtraHost(hostname: "db2", ip: "192.168.1.11"),
    .gateway(hostname: "hostmachine")
]
let request = ContainerRequest(image: "app:latest")
    .withExtraHosts(hosts)

// Example 4: Testing service that connects to external hostname
let request = ContainerRequest(image: "myapp:test")
    .withExtraHost(hostname: "api.external.com", ip: "127.0.0.1")  // Redirect to mock
    .withExposedPort(8080)  // Mock API on host port 8080
```

---

## Implementation Steps

### 1. Add `ExtraHost` type to ContainerRequest.swift

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

**Location:** Add before `ContainerPort` struct definition (around line 3)

**Code:**
```swift
public struct ExtraHost: Hashable, Sendable {
    public var hostname: String
    public var ip: String

    public init(hostname: String, ip: String) {
        self.hostname = hostname
        self.ip = ip
    }

    public static func gateway(hostname: String) -> ExtraHost {
        ExtraHost(hostname: hostname, ip: "host-gateway")
    }

    var dockerFlag: String {
        "\(hostname):\(ip)"
    }
}
```

### 2. Add `extraHosts` property to ContainerRequest

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

**Location:** Inside `ContainerRequest` struct definition (around line 32)

**Changes:**
```swift
public struct ContainerRequest: Sendable, Hashable {
    public var image: String
    public var name: String?
    public var command: [String]
    public var environment: [String: String]
    public var labels: [String: String]
    public var ports: [ContainerPort]
    public var extraHosts: [ExtraHost]  // ADD THIS
    public var waitStrategy: WaitStrategy
    public var host: String
```

**Location:** Inside `init(image:)` method (around line 42)

**Changes:**
```swift
public init(image: String) {
    self.image = image
    self.name = nil
    self.command = []
    self.environment = [:]
    self.labels = ["testcontainers.swift": "true"]
    self.ports = []
    self.extraHosts = []  // ADD THIS
    self.waitStrategy = .none
    self.host = "127.0.0.1"
}
```

### 3. Add builder methods to ContainerRequest

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

**Location:** After `withHost(_:)` method (around line 87)

**Code:**
```swift
public func withExtraHost(hostname: String, ip: String) -> Self {
    var copy = self
    copy.extraHosts.append(ExtraHost(hostname: hostname, ip: ip))
    return copy
}

public func withExtraHost(_ host: ExtraHost) -> Self {
    var copy = self
    copy.extraHosts.append(host)
    return copy
}

public func withExtraHosts(_ hosts: [ExtraHost]) -> Self {
    var copy = self
    copy.extraHosts.append(contentsOf: hosts)
    return copy
}
```

### 4. Update DockerClient to generate `--add-host` flags

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

**Location:** Inside `runContainer(_:)` method, after label processing (around line 45)

**Code:**
```swift
for host in request.extraHosts.sorted(by: { $0.hostname < $1.hostname }) {
    args += ["--add-host", host.dockerFlag]
}
```

**Full context (lines 28-54 after changes):**
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

    // NEW: Add extra hosts
    for host in request.extraHosts.sorted(by: { $0.hostname < $1.hostname }) {
        args += ["--add-host", host.dockerFlag]
    }

    args.append(request.image)
    args += request.command

    let output = try await runDocker(args)
    let id = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { throw TestContainersError.unexpectedDockerOutput(output.stdout) }
    return id
}
```

---

## Testing Plan

### Unit Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

**Test 1: Builder API adds extra hosts**
```swift
@Test func buildsExtraHosts() {
    let request = ContainerRequest(image: "alpine:3")
        .withExtraHost(hostname: "db.local", ip: "192.168.1.100")
        .withExtraHost(.gateway(hostname: "myhost"))

    #expect(request.extraHosts.count == 2)
    #expect(request.extraHosts.contains(ExtraHost(hostname: "db.local", ip: "192.168.1.100")))
    #expect(request.extraHosts.contains(ExtraHost(hostname: "myhost", ip: "host-gateway")))
}
```

**Test 2: Bulk addition with withExtraHosts**
```swift
@Test func buildsBulkExtraHosts() {
    let hosts: [ExtraHost] = [
        ExtraHost(hostname: "host1", ip: "10.0.0.1"),
        ExtraHost(hostname: "host2", ip: "10.0.0.2"),
        .gateway(hostname: "docker-host")
    ]

    let request = ContainerRequest(image: "nginx:latest")
        .withExtraHosts(hosts)

    #expect(request.extraHosts == hosts)
}
```

**Test 3: ExtraHost generates correct Docker flag**
```swift
@Test func extraHostGeneratesDockerFlag() {
    let host1 = ExtraHost(hostname: "database", ip: "192.168.1.50")
    #expect(host1.dockerFlag == "database:192.168.1.50")

    let host2 = ExtraHost.gateway(hostname: "myhost")
    #expect(host2.dockerFlag == "myhost:host-gateway")
}
```

**Test 4: Empty extraHosts array by default**
```swift
@Test func defaultExtraHostsIsEmpty() {
    let request = ContainerRequest(image: "alpine:3")
    #expect(request.extraHosts.isEmpty)
}
```

### Integration Tests

**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

**Test 1: Container resolves custom hostname**
```swift
@Test func containerResolvesExtraHost_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withExtraHost(hostname: "customhost", ip: "192.168.100.50")
        .withCommand(["cat", "/etc/hosts"])
        .waitingFor(.none)

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("192.168.100.50\tcustomhost"))
    }
}
```

**Test 2: Container uses host-gateway mapping**
```swift
@Test func containerUsesHostGateway_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withExtraHost(.gateway(hostname: "dockerhost"))
        .withCommand(["sh", "-c", "grep dockerhost /etc/hosts"])
        .waitingFor(.none)

    try await withContainer(request) { container in
        let logs = try await container.logs()
        // Should contain "dockerhost" and an IP (exact IP varies by platform)
        #expect(logs.contains("dockerhost"))
        // Should NOT contain the literal string "host-gateway" (Docker resolves it)
        #expect(!logs.contains("host-gateway"))
    }
}
```

**Test 3: Multiple extra hosts are all added**
```swift
@Test func containerHasMultipleExtraHosts_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withExtraHost(hostname: "db1", ip: "10.0.1.1")
        .withExtraHost(hostname: "db2", ip: "10.0.1.2")
        .withExtraHost(hostname: "cache", ip: "10.0.2.1")
        .withCommand(["cat", "/etc/hosts"])
        .waitingFor(.none)

    try await withContainer(request) { container in
        let logs = try await container.logs()
        #expect(logs.contains("10.0.1.1\tdb1"))
        #expect(logs.contains("10.0.1.2\tdb2"))
        #expect(logs.contains("10.0.2.1\tcache"))
    }
}
```

### Test Execution

```bash
# Run unit tests (fast, no Docker required)
swift test

# Run integration tests (requires Docker)
TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test
```

---

## Acceptance Criteria

### Definition of Done

- [ ] `ExtraHost` struct is implemented with `hostname`, `ip`, and `.gateway()` factory method
- [ ] `ExtraHost` conforms to `Hashable` and `Sendable`
- [ ] `ExtraHost.dockerFlag` returns correct format: `"hostname:ip"`
- [ ] `ContainerRequest` has `extraHosts: [ExtraHost]` property
- [ ] `ContainerRequest.init(image:)` initializes `extraHosts` to empty array
- [ ] `withExtraHost(hostname:ip:)` builder method is implemented
- [ ] `withExtraHost(_:)` builder method is implemented
- [ ] `withExtraHosts(_:)` builder method is implemented
- [ ] `DockerClient.runContainer(_:)` generates `--add-host` flags for each extra host
- [ ] Extra hosts are sorted by hostname before generating flags (predictable order)
- [ ] All unit tests pass (4 tests minimum)
- [ ] All integration tests pass when Docker is available (3 tests minimum)
- [ ] Code follows existing patterns (builder pattern, sorted iteration, value types)
- [ ] API is consistent with existing `ContainerRequest` methods
- [ ] Documentation comments are added to public API

### Verification Steps

1. **Build succeeds:**
   ```bash
   swift build
   ```

2. **Unit tests pass:**
   ```bash
   swift test --filter ContainerRequestTests
   ```

3. **Integration tests pass:**
   ```bash
   TESTCONTAINERS_RUN_DOCKER_TESTS=1 swift test --filter DockerIntegrationTests
   ```

4. **Manual verification (optional):**
   ```bash
   # Create a test that prints the generated docker command
   # Verify output contains: --add-host hostname:ip
   ```

5. **Code review checklist:**
   - [ ] Follows Swift naming conventions
   - [ ] Maintains `Sendable` and `Hashable` conformance
   - [ ] No breaking changes to existing API
   - [ ] Test coverage is adequate (>80% of new code)
   - [ ] Follows existing code patterns (see `ContainerPort` and `withExposedPort`)

---

## References

### Docker Documentation

- [docker run --add-host](https://docs.docker.com/engine/reference/commandline/run/#add-host)
- Format: `--add-host hostname:ip`
- Special value: `host-gateway` resolves to host's gateway IP
- Multiple `--add-host` flags can be specified

### Related Code Files

- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift` - Primary implementation file
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift` - Docker CLI argument generation
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift` - Unit tests
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift` - Integration tests

### Similar Features in Codebase

- `ContainerPort` - Similar struct with `dockerFlag` property
- `withExposedPort(_:hostPort:)` - Similar builder pattern with multiple variants
- Environment and labels - Similar sorted iteration pattern for CLI args

### External References

- [testcontainers-go ExtraHosts](https://github.com/testcontainers/testcontainers-go) - Reference implementation
- FEATURES.md line 60: Listed as Tier 2 (Medium Priority) feature

---

## Notes

### Implementation Considerations

1. **Input validation:** Consider adding validation in future iterations (e.g., hostname format, IP address format). For MVP, rely on Docker's validation.

2. **IPv6 support:** The proposed API supports IPv6 addresses naturally (they're just strings). No special handling needed.

3. **Hostname conflicts:** If the same hostname is added multiple times, Docker uses the last occurrence. Consider documenting this behavior or preventing duplicates in future iterations.

4. **Platform differences:** `host-gateway` behavior may differ between Docker Desktop (Mac/Windows) and Docker Engine (Linux). Integration tests should account for this.

### Future Enhancements

1. **Validation helpers:**
   ```swift
   extension ExtraHost {
       public static func validate(hostname: String, ip: String) throws -> ExtraHost
   }
   ```

2. **Dictionary-based API:**
   ```swift
   public func withExtraHosts(_ mapping: [String: String]) -> Self
   ```

3. **Remove duplicates automatically:**
   ```swift
   // In ContainerRequest
   var uniqueExtraHosts: [ExtraHost] {
       Array(Set(extraHosts)).sorted(by: { $0.hostname < $1.hostname })
   }
   ```

### Breaking Changes

None. This is a purely additive feature with no impact on existing API.

---

## Estimated Implementation Time

- **Type definition + builder methods:** 30 minutes
- **DockerClient integration:** 15 minutes
- **Unit tests:** 45 minutes
- **Integration tests:** 60 minutes
- **Documentation + code review:** 30 minutes

**Total:** 2-4 hours (including testing and review)
