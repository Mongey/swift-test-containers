# Feature: HTTP/HTTPS Wait Strategy

## Implementation Status

**Status: ✅ Implemented**

The HTTP/HTTPS wait strategy has been implemented with full support for:
- All HTTP methods (GET, POST, HEAD, PUT, DELETE, PATCH, OPTIONS)
- Status code validation (exact, range, set matching)
- Response body validation (substring and regex matching)
- TLS/HTTPS support with option to allow insecure connections
- Custom headers
- Configurable timeouts and poll intervals

### Files Added/Modified:
- `Sources/TestContainers/HTTPWaitConfig.swift` - Configuration struct with builder pattern
- `Sources/TestContainers/HTTPProbe.swift` - HTTP health check probe
- `Sources/TestContainers/ContainerRequest.swift` - Added `.http(HTTPWaitConfig)` case to `WaitStrategy`
- `Sources/TestContainers/Container.swift` - Added HTTP wait logic in `waitUntilReady()`
- `Tests/TestContainersTests/HTTPWaitConfigTests.swift` - Unit tests for configuration
- `Tests/TestContainersTests/HTTPProbeTests.swift` - Unit tests for HTTP probe
- `Tests/TestContainersTests/HTTPWaitStrategyIntegrationTests.swift` - Integration tests with Docker

## Summary

Implement an HTTP/HTTPS wait strategy for swift-test-containers that allows tests to wait for containers to be ready by polling HTTP endpoints. This is essential for testing web services, REST APIs, and other HTTP-based containers where TCP port availability doesn't necessarily indicate application readiness.

## Current State

### Wait Strategy Architecture

The current wait strategy implementation is defined in `/Sources/TestContainers/ContainerRequest.swift`:

```swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
}
```

### How Wait Strategies Work Today

1. **Strategy Definition**: Wait strategies are enum cases with associated values that capture configuration (port, log text, timeouts, poll intervals)

2. **Strategy Application**: Container requests use the builder pattern via `waitingFor(_:)` method:
   ```swift
   ContainerRequest(image: "redis:7")
       .withExposedPort(6379)
       .waitingFor(.tcpPort(6379, timeout: .seconds(30)))
   ```

3. **Strategy Execution**: Implemented in `Container.waitUntilReady()` at `/Sources/TestContainers/Container.swift:36-52`:
   ```swift
   func waitUntilReady() async throws {
       switch request.waitStrategy {
       case .none:
           return
       case let .logContains(needle, timeout, pollInterval):
           try await Waiter.wait(timeout: timeout, pollInterval: pollInterval,
                                description: "container logs to contain '\(needle)'") {
               let text = try await docker.logs(id: id)
               return text.contains(needle)
           }
       case let .tcpPort(containerPort, timeout, pollInterval):
           let hostPort = try await docker.port(id: id, containerPort: containerPort)
           let host = request.host
           try await Waiter.wait(timeout: timeout, pollInterval: pollInterval,
                                description: "TCP port \(host):\(hostPort) to accept connections") {
               TCPProbe.canConnect(host: host, port: hostPort, timeout: .milliseconds(200))
           }
       }
   }
   ```

4. **Polling Infrastructure**: Uses `Waiter.wait()` at `/Sources/TestContainers/Waiter.swift`:
   - Generic polling mechanism with configurable timeout and poll interval
   - Uses `ContinuousClock` for precise timing
   - Throws `TestContainersError.timeout` on failure

5. **Probing Mechanism**: `TCPProbe` at `/Sources/TestContainers/TCPProbe.swift`:
   - Low-level socket connection testing
   - Non-blocking connect with `poll()` for timeout handling
   - Cross-platform support (Darwin/Glibc)

## Requirements

### Core Functionality

1. **HTTP Methods Support**
   - GET (default)
   - POST
   - HEAD
   - PUT
   - DELETE
   - PATCH
   - OPTIONS

2. **URL Configuration**
   - Port number (required)
   - Path (default: "/")
   - Query parameters support

3. **Response Validation**
   - HTTP status code matching (default: 200-299 range)
   - Custom status code predicates (e.g., exact match, range, set)
   - Response body matching (substring, regex, predicate)
   - Response header validation

4. **Security**
   - HTTP support
   - HTTPS/TLS support
   - Certificate validation (with option to disable for self-signed certs)

5. **Timing Configuration**
   - Configurable timeout (default: 60 seconds)
   - Configurable poll interval (default: 200ms)
   - Per-request timeout for HTTP calls

6. **Error Handling**
   - Network errors should not fail immediately (retry until timeout)
   - Connection refused should be treated as "not ready"
   - DNS resolution failures should be retried
   - Proper error descriptions for timeout failures

### Non-Functional Requirements

1. **Performance**
   - Minimal overhead per probe
   - Efficient polling without excessive CPU usage
   - Connection reuse where appropriate

2. **Compatibility**
   - Cross-platform (macOS, Linux)
   - Works with both HTTP/1.1 and HTTP/2
   - Compatible with Swift Concurrency

3. **Maintainability**
   - Follow existing code patterns
   - Maintain consistency with `.tcpPort` and `.logContains` strategies
   - Use native Swift HTTP APIs where possible

## API Design

### Proposed Swift API

```swift
// Add to WaitStrategy enum in ContainerRequest.swift
public enum WaitStrategy: Sendable, Hashable {
    case none
    case tcpPort(Int, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case logContains(String, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(200))
    case http(HTTPWaitConfig)
}

// New HTTPWaitConfig struct with builder pattern
public struct HTTPWaitConfig: Sendable, Hashable {
    public var port: Int
    public var path: String
    public var method: HTTPMethod
    public var statusCodeMatcher: StatusCodeMatcher
    public var bodyMatcher: BodyMatcher?
    public var headers: [String: String]
    public var useTLS: Bool
    public var allowInsecureTLS: Bool
    public var timeout: Duration
    public var pollInterval: Duration
    public var requestTimeout: Duration

    public init(port: Int) {
        self.port = port
        self.path = "/"
        self.method = .get
        self.statusCodeMatcher = .range(200...299)
        self.bodyMatcher = nil
        self.headers = [:]
        self.useTLS = false
        self.allowInsecureTLS = false
        self.timeout = .seconds(60)
        self.pollInterval = .milliseconds(200)
        self.requestTimeout = .seconds(5)
    }

    // Builder methods
    public func withPath(_ path: String) -> Self
    public func withMethod(_ method: HTTPMethod) -> Self
    public func withStatusCode(_ code: Int) -> Self
    public func withStatusCodeRange(_ range: ClosedRange<Int>) -> Self
    public func withStatusCodeMatcher(_ matcher: StatusCodeMatcher) -> Self
    public func withBodyContains(_ substring: String) -> Self
    public func withBodyMatcher(_ matcher: BodyMatcher) -> Self
    public func withHeader(_ name: String, _ value: String) -> Self
    public func withHeaders(_ headers: [String: String]) -> Self
    public func withTLS(allowInsecure: Bool = false) -> Self
    public func withTimeout(_ timeout: Duration) -> Self
    public func withPollInterval(_ interval: Duration) -> Self
    public func withRequestTimeout(_ timeout: Duration) -> Self
}

public enum HTTPMethod: String, Sendable, Hashable {
    case get = "GET"
    case post = "POST"
    case head = "HEAD"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
    case options = "OPTIONS"
}

public enum StatusCodeMatcher: Sendable, Hashable {
    case exact(Int)
    case range(ClosedRange<Int>)
    case anyOf(Set<Int>)
    case predicate(String) // Description for Hashable, actual closure stored separately

    func matches(_ code: Int) -> Bool
}

public enum BodyMatcher: Sendable, Hashable {
    case contains(String)
    case regex(String)
    case predicate(String) // Description for Hashable, actual closure stored separately

    func matches(_ body: String) -> Bool
}
```

### Usage Examples

```swift
// Simple HTTP health check
let request = ContainerRequest(image: "nginx:latest")
    .withExposedPort(80)
    .waitingFor(.http(HTTPWaitConfig(port: 80)))

// Custom path and status code
let request = ContainerRequest(image: "myapp:latest")
    .withExposedPort(8080)
    .waitingFor(.http(
        HTTPWaitConfig(port: 8080)
            .withPath("/health")
            .withStatusCode(200)
    ))

// HTTPS with custom path and body matching
let request = ContainerRequest(image: "api:latest")
    .withExposedPort(443)
    .waitingFor(.http(
        HTTPWaitConfig(port: 443)
            .withTLS(allowInsecure: true)
            .withPath("/api/health")
            .withBodyContains("\"status\":\"healthy\"")
            .withTimeout(.seconds(90))
    ))

// Complex validation with custom method and headers
let request = ContainerRequest(image: "service:latest")
    .withExposedPort(8080)
    .waitingFor(.http(
        HTTPWaitConfig(port: 8080)
            .withMethod(.post)
            .withPath("/ready")
            .withHeader("X-Health-Check", "true")
            .withStatusCodeRange(200...299)
            .withRequestTimeout(.seconds(3))
    ))
```

## Implementation Steps

### 1. Create HTTPProbe Module

**File**: `/Sources/TestContainers/HTTPProbe.swift`

- Implement `HTTPProbe.check()` function similar to `TCPProbe.canConnect()`
- Use `URLSession` with async/await for HTTP requests
- Configure custom timeout per request
- Handle TLS/SSL configuration (certificate validation)
- Return result indicating success/failure (no exceptions for network errors)
- Support all HTTP methods
- Handle redirects appropriately

**Key considerations**:
- Use `URLSession` with custom configuration for timeout control
- Catch and handle network errors gracefully (return false, don't throw)
- Support custom headers
- Handle both HTTP and HTTPS schemes

### 2. Define HTTPWaitConfig and Supporting Types

**File**: `/Sources/TestContainers/HTTPWaitConfig.swift`

- Define `HTTPWaitConfig` struct with builder pattern
- Define `HTTPMethod` enum
- Define `StatusCodeMatcher` enum with match logic
- Define `BodyMatcher` enum with match logic
- Implement `Hashable` and `Sendable` conformance for all types
- Add comprehensive documentation

**Key considerations**:
- Maintain consistency with existing builder pattern
- Ensure all types are `Sendable` for Swift Concurrency
- Implement `Hashable` for `WaitStrategy` enum compatibility
- Consider how to make predicate matchers Hashable (use description strings)

### 3. Extend WaitStrategy Enum

**File**: `/Sources/TestContainers/ContainerRequest.swift`

- Add `.http(HTTPWaitConfig)` case to `WaitStrategy` enum
- Ensure enum remains `Sendable` and `Hashable`

### 4. Implement HTTP Wait Logic

**File**: `/Sources/TestContainers/Container.swift`

- Add case handler in `waitUntilReady()` for `.http` strategy
- Get host port mapping using existing `docker.port()` method
- Construct URL using host, port, and config
- Call `Waiter.wait()` with `HTTPProbe.check()` predicate
- Provide descriptive error message for timeouts

**Implementation pattern**:
```swift
case let .http(config):
    let hostPort = try await docker.port(id: id, containerPort: config.port)
    let host = request.host
    let scheme = config.useTLS ? "https" : "http"
    let url = "\(scheme)://\(host):\(hostPort)\(config.path)"

    try await Waiter.wait(
        timeout: config.timeout,
        pollInterval: config.pollInterval,
        description: "HTTP endpoint \(url) to return expected response"
    ) {
        await HTTPProbe.check(
            url: url,
            method: config.method,
            headers: config.headers,
            statusCodeMatcher: config.statusCodeMatcher,
            bodyMatcher: config.bodyMatcher,
            allowInsecureTLS: config.allowInsecureTLS,
            requestTimeout: config.requestTimeout
        )
    }
```

### 5. Add Unit Tests

**File**: `/Tests/TestContainersTests/HTTPWaitConfigTests.swift`

- Test `HTTPWaitConfig` builder pattern
- Test default values
- Test all builder methods
- Test `StatusCodeMatcher` logic (exact, range, anyOf)
- Test `BodyMatcher` logic (contains, regex)
- Test `Hashable` conformance
- Test URL path handling (escaping, query params)

**File**: `/Tests/TestContainersTests/HTTPProbeTests.swift`

- Mock HTTP server for testing (if feasible)
- Test successful HTTP connection
- Test HTTPS connection
- Test various status codes
- Test body matching
- Test timeout behavior
- Test connection refused handling
- Test invalid URL handling

### 6. Add Integration Tests

**File**: `/Tests/TestContainersTests/HTTPWaitStrategyIntegrationTests.swift`

- Test with real nginx container (HTTP)
- Test with custom path
- Test with status code validation
- Test with body matching
- Test timeout scenarios
- Test HTTPS container (if suitable test image available)
- Test failure cases (wrong port, wrong path)

**Example tests**:
```swift
@Test func httpWaitStrategy_nginx() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "nginx:latest")
        .withExposedPort(80)
        .waitingFor(.http(HTTPWaitConfig(port: 80)))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 80)
        #expect(!endpoint.isEmpty)
    }
}

@Test func httpWaitStrategy_customPathAndStatus() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "kennethreitz/httpbin")
        .withExposedPort(80)
        .waitingFor(.http(
            HTTPWaitConfig(port: 80)
                .withPath("/status/200")
                .withStatusCode(200)
        ))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 80)
        #expect(!endpoint.isEmpty)
    }
}

@Test func httpWaitStrategy_bodyMatching() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "nginx:latest")
        .withExposedPort(80)
        .waitingFor(.http(
            HTTPWaitConfig(port: 80)
                .withBodyContains("Welcome to nginx")
        ))

    try await withContainer(request) { container in
        let endpoint = try await container.endpoint(for: 80)
        #expect(!endpoint.isEmpty)
    }
}
```

### 7. Documentation

- Update README.md with HTTP wait strategy examples
- Add inline documentation to all public APIs
- Document common use cases
- Document HTTPS/TLS considerations
- Add troubleshooting section for common issues

## Testing Plan

### Unit Tests

1. **HTTPWaitConfig Tests**
   - Builder pattern functionality
   - Default value validation
   - Immutability verification
   - Hashable conformance

2. **StatusCodeMatcher Tests**
   - Exact matching: `matches(200)` returns true for 200, false for others
   - Range matching: `range(200...299)` matches 200-299
   - Set matching: `anyOf([200, 204])` matches only those codes

3. **BodyMatcher Tests**
   - Substring matching with various inputs
   - Regex pattern matching
   - Empty body handling
   - Large body performance

4. **HTTPProbe Tests** (with mock server if possible)
   - Successful requests
   - Failed requests
   - Timeout handling
   - TLS validation
   - Error recovery

### Integration Tests

1. **Basic HTTP Container**
   - nginx with default config
   - Verify container starts and responds
   - Verify timeout works

2. **Custom Path Testing**
   - Container with specific health endpoint
   - Verify path is correctly used
   - Test with query parameters

3. **Status Code Validation**
   - Test exact status code matching
   - Test status code ranges
   - Test failure on wrong status code

4. **Body Matching**
   - Test substring matching in response
   - Test with JSON responses
   - Test with HTML responses

5. **HTTPS Testing** (if suitable image available)
   - Container with TLS
   - Verify HTTPS connection
   - Test certificate validation bypass

6. **Failure Scenarios**
   - Wrong port (should timeout)
   - Wrong path (should timeout if 404 not accepted)
   - Container that never becomes ready
   - Verify timeout error messages are clear

7. **Complex Scenarios**
   - Multiple headers
   - POST requests with body validation
   - Custom timeout configurations
   - Combination with other strategies (if multiple strategies supported in future)

### Manual Testing Checklist

- [ ] Test with common web frameworks (nginx, Apache, etc.)
- [ ] Test with REST API containers (Spring Boot, Node.js Express, etc.)
- [ ] Test with health check endpoints
- [ ] Test timeout behavior with slow-starting containers
- [ ] Verify error messages are helpful
- [ ] Test on macOS and Linux
- [ ] Performance test with rapid polling

## Acceptance Criteria

### Must Have

- [x] `WaitStrategy.http()` case added to enum
- [x] `HTTPWaitConfig` struct with builder pattern implemented
- [x] `HTTPProbe` module with async HTTP checking
- [x] Support for HTTP and HTTPS
- [x] Support for all common HTTP methods (GET, POST, HEAD, PUT, DELETE, PATCH, OPTIONS)
- [x] Status code validation (exact match and ranges)
- [x] Custom path support
- [x] Custom headers support
- [x] Configurable timeouts (overall and per-request)
- [x] Configurable poll interval
- [x] Integration with existing `Container.waitUntilReady()` flow
- [x] Unit tests with >80% code coverage
- [x] Integration tests with real containers
- [x] Documentation in code (doc comments)
- [ ] Updated README with examples

### Should Have

- [x] Response body matching (substring)
- [x] Response body matching (regex)
- [x] TLS certificate validation control (allow insecure)
- [x] Helpful error messages on timeout
- [x] Query parameter support in paths
- [x] Performance optimization (connection reuse if beneficial)

### Nice to Have

- [ ] Response header validation
- [ ] Redirect following configuration
- [ ] Request body support for POST/PUT/PATCH
- [ ] Authentication support (Basic Auth, Bearer tokens)
- [ ] Custom predicates for status code and body matching
- [ ] Metrics/logging for debugging failed waits

### Definition of Done

- [x] All "Must Have" and "Should Have" criteria completed (except README update)
- [x] All tests passing
- [ ] Code review completed
- [ ] Documentation reviewed
- [ ] Manually tested with at least 3 different container images
- [x] No regressions in existing wait strategies
- [x] Follows existing code style and patterns
- [x] All public APIs have documentation comments
- [ ] README updated with clear examples

## References

### Related Files

- `/Sources/TestContainers/ContainerRequest.swift` - WaitStrategy enum (updated with `.http` case)
- `/Sources/TestContainers/Container.swift` - waitUntilReady() implementation (updated with HTTP handling)
- `/Sources/TestContainers/HTTPWaitConfig.swift` - **NEW** HTTP wait configuration with builder pattern
- `/Sources/TestContainers/HTTPProbe.swift` - **NEW** HTTP health check probe implementation
- `/Sources/TestContainers/Waiter.swift` - Generic polling mechanism
- `/Sources/TestContainers/TCPProbe.swift` - TCP connection testing (reference implementation)
- `/Sources/TestContainers/TestContainersError.swift` - Error types

### Test Files

- `/Tests/TestContainersTests/HTTPWaitConfigTests.swift` - **NEW** Unit tests for HTTPWaitConfig
- `/Tests/TestContainersTests/HTTPProbeTests.swift` - **NEW** Unit tests for HTTPProbe
- `/Tests/TestContainersTests/HTTPWaitStrategyIntegrationTests.swift` - **NEW** Integration tests with Docker

### Similar Implementations

- Testcontainers Java: `HttpWaitStrategy`
- Testcontainers Go: `wait.ForHTTP()`
- Testcontainers Node: `Wait.forHttp()`

### Swift HTTP APIs

- `URLSession` - Standard HTTP client
- `URLRequest` - Request configuration
- `HTTPURLResponse` - Response handling
- Swift Concurrency - async/await support
