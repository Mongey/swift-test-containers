# Feature 019: Resource Limits (CPU/Memory)

## Summary

Add support for setting resource limits (CPU and memory) on containers in swift-test-containers. This feature allows users to constrain container resource usage, which is essential for:
- Preventing resource exhaustion in CI environments
- Testing application behavior under resource constraints
- Simulating production resource limits in development
- Ensuring predictable test execution

## Current State

The `ContainerRequest` struct (defined in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`) currently supports:
- Image selection
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

The `DockerClient` actor (in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`) constructs Docker CLI arguments in the `runContainer` method, which currently generates flags for:
- `-d` (detached mode)
- `--name` (container name)
- `-e` (environment variables)
- `-p` (port mappings)
- `--label` (labels)

**Missing capability**: No support for Docker resource constraint flags like `--memory`, `--memory-reservation`, `--cpus`, `--cpu-shares`, etc.

## Requirements

Implement support for the following Docker resource limit options:

### Memory Limits
1. **Memory Limit** (`--memory` / `-m`)
   - Hard limit on memory usage
   - Format: Number + unit (b, k, m, g)
   - Example: `512m`, `1g`, `2048m`
   - Container is killed if it exceeds this limit

2. **Memory Reservation** (`--memory-reservation`)
   - Soft limit, lower than memory limit
   - Docker detects memory contention and tries to constrain containers to their reservation
   - Format: Same as memory limit
   - Example: `256m`

3. **Memory Swap Limit** (`--memory-swap`)
   - Total memory + swap that the container can use
   - Format: Number + unit, or `-1` for unlimited swap
   - Example: `1g`, `-1`

### CPU Limits
1. **CPU Limit** (`--cpus`)
   - Number of CPUs the container can use
   - Format: Decimal number
   - Example: `1.5` (one and a half CPUs), `0.5` (half a CPU)

2. **CPU Shares** (`--cpu-shares`)
   - Relative weight vs other containers (default: 1024)
   - Format: Integer
   - Example: `512`, `2048`

3. **CPU Period** (`--cpu-period`)
   - CFS (Completely Fair Scheduler) period in microseconds
   - Format: Integer (microseconds)
   - Default: `100000` (100ms)
   - Example: `100000`

4. **CPU Quota** (`--cpu-quota`)
   - CFS quota in microseconds per period
   - Format: Integer (microseconds)
   - Example: `50000` (50ms out of 100ms = 50% of one CPU)

## API Design

Add a new `ResourceLimits` struct to encapsulate resource constraints and extend `ContainerRequest` with builder methods:

```swift
public struct ResourceLimits: Sendable, Hashable {
    public var memory: String?
    public var memoryReservation: String?
    public var memorySwap: String?
    public var cpus: String?
    public var cpuShares: Int?
    public var cpuPeriod: Int?
    public var cpuQuota: Int?

    public init() {}
}

extension ContainerRequest {
    public var resourceLimits: ResourceLimits

    // Convenience methods for common use cases
    public func withMemoryLimit(_ limit: String) -> Self
    public func withMemoryReservation(_ reservation: String) -> Self
    public func withMemorySwap(_ swap: String) -> Self
    public func withCpuLimit(_ cpus: String) -> Self
    public func withCpuShares(_ shares: Int) -> Self
    public func withCpuPeriod(_ period: Int) -> Self
    public func withCpuQuota(_ quota: Int) -> Self

    // Advanced method for setting all at once
    public func withResourceLimits(_ limits: ResourceLimits) -> Self
}
```

### Usage Examples

```swift
// Example 1: Basic memory limit
let request = ContainerRequest(image: "postgres:15")
    .withMemoryLimit("512m")
    .withExposedPort(5432)

// Example 2: Memory with reservation
let request = ContainerRequest(image: "redis:7")
    .withMemoryLimit("1g")
    .withMemoryReservation("512m")
    .withExposedPort(6379)

// Example 3: CPU limits
let request = ContainerRequest(image: "nginx:latest")
    .withCpuLimit("0.5")  // Half a CPU core
    .withExposedPort(80)

// Example 4: CPU shares for relative priority
let request = ContainerRequest(image: "alpine:3")
    .withCpuShares(512)  // Lower priority (default is 1024)
    .withCommand(["sleep", "infinity"])

// Example 5: Advanced - all limits
let request = ContainerRequest(image: "mysql:8")
    .withMemoryLimit("2g")
    .withMemoryReservation("1g")
    .withCpuLimit("1.5")
    .withCpuShares(2048)
    .withExposedPort(3306)

// Example 6: Using ResourceLimits struct
var limits = ResourceLimits()
limits.memory = "1g"
limits.cpus = "2.0"

let request = ContainerRequest(image: "mongo:7")
    .withResourceLimits(limits)
    .withExposedPort(27017)
```

## Implementation Steps

### Step 1: Add ResourceLimits struct to ContainerRequest.swift

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

1. Define the `ResourceLimits` struct above `ContainerRequest`
2. Add `resourceLimits` property to `ContainerRequest`
3. Initialize `resourceLimits` to empty in `ContainerRequest.init(image:)`

```swift
public struct ResourceLimits: Sendable, Hashable {
    public var memory: String?
    public var memoryReservation: String?
    public var memorySwap: String?
    public var cpus: String?
    public var cpuShares: Int?
    public var cpuPeriod: Int?
    public var cpuQuota: Int?

    public init() {}
}
```

### Step 2: Add builder methods to ContainerRequest

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

Add the following methods after the existing builder methods (after `withHost`):

```swift
public func withMemoryLimit(_ limit: String) -> Self {
    var copy = self
    copy.resourceLimits.memory = limit
    return copy
}

public func withMemoryReservation(_ reservation: String) -> Self {
    var copy = self
    copy.resourceLimits.memoryReservation = reservation
    return copy
}

public func withMemorySwap(_ swap: String) -> Self {
    var copy = self
    copy.resourceLimits.memorySwap = swap
    return copy
}

public func withCpuLimit(_ cpus: String) -> Self {
    var copy = self
    copy.resourceLimits.cpus = cpus
    return copy
}

public func withCpuShares(_ shares: Int) -> Self {
    var copy = self
    copy.resourceLimits.cpuShares = shares
    return copy
}

public func withCpuPeriod(_ period: Int) -> Self {
    var copy = self
    copy.resourceLimits.cpuPeriod = period
    return copy
}

public func withCpuQuota(_ quota: Int) -> Self {
    var copy = self
    copy.resourceLimits.cpuQuota = quota
    return copy
}

public func withResourceLimits(_ limits: ResourceLimits) -> Self {
    var copy = self
    copy.resourceLimits = limits
    return copy
}
```

### Step 3: Update DockerClient.runContainer to include resource limit flags

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

Modify the `runContainer` method to add resource limit flags to the Docker run command. Add this code after the labels loop (around line 45) and before appending the image:

```swift
// Add resource limits
let limits = request.resourceLimits

if let memory = limits.memory {
    args += ["--memory", memory]
}

if let memoryReservation = limits.memoryReservation {
    args += ["--memory-reservation", memoryReservation]
}

if let memorySwap = limits.memorySwap {
    args += ["--memory-swap", memorySwap]
}

if let cpus = limits.cpus {
    args += ["--cpus", cpus]
}

if let cpuShares = limits.cpuShares {
    args += ["--cpu-shares", "\(cpuShares)"]
}

if let cpuPeriod = limits.cpuPeriod {
    args += ["--cpu-period", "\(cpuPeriod)"]
}

if let cpuQuota = limits.cpuQuota {
    args += ["--cpu-quota", "\(cpuQuota)"]
}
```

### Step 4: Input validation (Optional but recommended)

Add validation for resource limit strings to provide better error messages:

```swift
extension ResourceLimits {
    /// Validates that memory strings are in correct format (number + unit)
    /// Valid units: b, k, m, g
    func validate() throws {
        if let memory = memory {
            try validateMemoryString(memory, paramName: "memory")
        }
        if let memoryReservation = memoryReservation {
            try validateMemoryString(memoryReservation, paramName: "memoryReservation")
        }
        if let memorySwap = memorySwap, memorySwap != "-1" {
            try validateMemoryString(memorySwap, paramName: "memorySwap")
        }
        if let cpus = cpus {
            guard Double(cpus) != nil else {
                throw TestContainersError.invalidResourceLimit("cpus must be a valid decimal number, got: \(cpus)")
            }
        }
    }

    private func validateMemoryString(_ value: String, paramName: String) throws {
        let pattern = "^[0-9]+(b|k|m|g)$"
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        if regex.firstMatch(in: value, range: range) == nil {
            throw TestContainersError.invalidResourceLimit("\(paramName) must be in format: number + unit (b/k/m/g), got: \(value)")
        }
    }
}
```

Add new error case to `TestContainersError`:

```swift
case invalidResourceLimit(String)
```

## Testing Plan

### Unit Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests for the builder pattern and resource limits:

```swift
@Test func buildsMemoryLimits() {
    let request = ContainerRequest(image: "alpine:3")
        .withMemoryLimit("512m")
        .withMemoryReservation("256m")

    #expect(request.resourceLimits.memory == "512m")
    #expect(request.resourceLimits.memoryReservation == "256m")
}

@Test func buildsCpuLimits() {
    let request = ContainerRequest(image: "alpine:3")
        .withCpuLimit("1.5")
        .withCpuShares(2048)

    #expect(request.resourceLimits.cpus == "1.5")
    #expect(request.resourceLimits.cpuShares == 2048)
}

@Test func buildsAllResourceLimits() {
    var limits = ResourceLimits()
    limits.memory = "1g"
    limits.memoryReservation = "512m"
    limits.cpus = "2.0"
    limits.cpuShares = 1024

    let request = ContainerRequest(image: "alpine:3")
        .withResourceLimits(limits)

    #expect(request.resourceLimits.memory == "1g")
    #expect(request.resourceLimits.memoryReservation == "512m")
    #expect(request.resourceLimits.cpus == "2.0")
    #expect(request.resourceLimits.cpuShares == 1024)
}

@Test func defaultResourceLimitsAreNil() {
    let request = ContainerRequest(image: "alpine:3")

    #expect(request.resourceLimits.memory == nil)
    #expect(request.resourceLimits.cpus == nil)
    #expect(request.resourceLimits.cpuShares == nil)
}
```

### Integration Tests

**File**: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

Add Docker integration tests (gated behind `TESTCONTAINERS_RUN_DOCKER_TESTS=1`):

```swift
@Test func canStartContainerWithMemoryLimit_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7")
        .withMemoryLimit("256m")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

    try await withContainer(request) { container in
        // Verify container is running with limits
        // We can inspect the container to verify limits are set
        let port = try await container.hostPort(6379)
        #expect(port > 0)
    }
}

@Test func canStartContainerWithCpuLimit_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCpuLimit("0.5")
        .withCommand(["sleep", "5"])

    try await withContainer(request) { container in
        // Container should start and run successfully with CPU limit
        #expect(!container.id.isEmpty)
    }
}

@Test func canStartContainerWithMultipleResourceLimits_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "postgres:15")
        .withMemoryLimit("512m")
        .withMemoryReservation("256m")
        .withCpuLimit("1.0")
        .withCpuShares(1024)
        .withEnvironment(["POSTGRES_PASSWORD": "test"])
        .withExposedPort(5432)
        .waitingFor(.logContains("database system is ready to accept connections", timeout: .seconds(60)))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 5432)
        #expect(endpoint.contains(":"))

        // Verify logs show container started successfully
        let logs = try await container.logs()
        #expect(logs.contains("database system is ready to accept connections"))
    }
}
```

### Manual Testing

For validation, manually test with Docker inspect:

```bash
# Start container with resource limits
swift test --filter DockerIntegrationTests

# In another terminal, inspect running container
docker ps
docker inspect <container-id> --format '{{.HostConfig.Memory}}'
docker inspect <container-id> --format '{{.HostConfig.NanoCpus}}'
docker inspect <container-id> --format '{{.HostConfig.CpuShares}}'
```

Expected outputs:
- Memory: `536870912` (512MB in bytes)
- NanoCpus: `1000000000` (1.0 CPU * 1e9)
- CpuShares: `1024`

## Acceptance Criteria

This feature is considered complete when:

1. **API Implementation**
   - [ ] `ResourceLimits` struct is added with all required properties
   - [ ] All `with*` builder methods are implemented on `ContainerRequest`
   - [ ] `ContainerRequest` includes `resourceLimits` property initialized to empty defaults
   - [ ] Methods follow existing code patterns (immutable copy-and-modify)

2. **Docker Integration**
   - [ ] `DockerClient.runContainer` generates correct `--memory` flag when memory limit is set
   - [ ] `DockerClient.runContainer` generates correct `--memory-reservation` flag when set
   - [ ] `DockerClient.runContainer` generates correct `--memory-swap` flag when set
   - [ ] `DockerClient.runContainer` generates correct `--cpus` flag when CPU limit is set
   - [ ] `DockerClient.runContainer` generates correct `--cpu-shares` flag when set
   - [ ] `DockerClient.runContainer` generates correct `--cpu-period` flag when set
   - [ ] `DockerClient.runContainer` generates correct `--cpu-quota` flag when set
   - [ ] Flags are only added when corresponding limit is set (not nil)

3. **Testing**
   - [ ] Unit tests cover builder methods for all resource limit types
   - [ ] Unit tests verify default values are nil
   - [ ] Unit tests verify chaining multiple limits works correctly
   - [ ] Integration tests verify containers start with memory limits
   - [ ] Integration tests verify containers start with CPU limits
   - [ ] Integration tests verify containers start with multiple limits combined
   - [ ] Integration tests verify containers with limits can accept connections and function correctly

4. **Documentation**
   - [ ] Public API methods have doc comments explaining parameters
   - [ ] Doc comments include examples of valid values (e.g., "512m", "1g")
   - [ ] Doc comments reference Docker documentation for detailed behavior

5. **Code Quality**
   - [ ] Code follows Swift conventions and existing codebase style
   - [ ] All new code conforms to `Sendable` protocol
   - [ ] All new structs conform to `Hashable` protocol
   - [ ] No breaking changes to existing API

## References

- Docker run reference: https://docs.docker.com/engine/reference/run/#runtime-constraints-on-resources
- Docker memory limits: https://docs.docker.com/config/containers/resource_constraints/#memory
- Docker CPU limits: https://docs.docker.com/config/containers/resource_constraints/#cpu
- Existing `ContainerRequest` implementation: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`
- Existing `DockerClient` implementation: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

## Notes

- Resource limits are passed directly to Docker without validation in the initial implementation
- Docker will return errors if invalid values are provided (e.g., "512x" instead of "512m")
- Memory swap should be greater than or equal to memory limit, or set to `-1` for unlimited
- CPU shares only affect relative priority when containers compete for CPU time
- CPU period and quota provide fine-grained control but `--cpus` is simpler for most use cases
