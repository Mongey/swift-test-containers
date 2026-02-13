# Feature 016: User/Groups Support (`--user`)

**Status:** Not Implemented
**Priority:** Tier 2 (Medium)
**Category:** Container Configuration
**Implementation:** Docker CLI (`docker run --user`)

---

## Summary

Add support for running containers as a specific user and/or group using the `docker run --user` flag. This feature allows tests to verify application behavior under different user permissions, security contexts, and filesystem access patterns.

The `--user` flag accepts multiple formats:
- User ID only: `--user 1000`
- User ID and group ID: `--user 1000:1000`
- Username only: `--user postgres`
- Username and group name: `--user postgres:postgres`
- Username and group ID: `--user postgres:999`

This is essential for testing applications that:
- Run as non-root users in production
- Require specific file ownership/permissions
- Need to validate security boundaries
- Implement least-privilege security models

---

## Current State

### ContainerRequest Capabilities

The `ContainerRequest` struct (in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`) currently supports:

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

**Builder methods pattern:**
- `withName(_:)` - Sets container name
- `withCommand(_:)` - Sets command to execute
- `withEnvironment(_:)` - Merges environment variables
- `withLabel(_:_:)` - Adds a label
- `withExposedPort(_:hostPort:)` - Exposes a port
- `waitingFor(_:)` - Sets wait strategy
- `withHost(_:)` - Sets host for connections

**Current docker run construction** (in `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`):

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

    // ... execute docker run
}
```

**No user/group support exists.** Containers currently run as whatever user the image's `USER` directive specifies (often root).

---

## Requirements

### Functional Requirements

1. **Support all Docker `--user` formats:**
   - User ID only (integer)
   - User ID:Group ID (integer:integer)
   - Username only (string)
   - Username:Group name (string:string)
   - Username:Group ID (string:integer)

2. **Type-safe API:**
   - Prevent invalid combinations at compile time where possible
   - Validate inputs at construction time
   - Clear error messages for invalid formats

3. **Optional configuration:**
   - User/group should be optional (nil = use image default)
   - Must not break existing code (backward compatible)

4. **Consistent with existing patterns:**
   - Follow builder pattern used by other `with*` methods
   - Support method chaining
   - Struct should remain `Sendable` and `Hashable`

### Non-Functional Requirements

1. **Performance:** No performance overhead (simple string formatting)
2. **Security:** No validation of whether user/group exists (Docker handles this)
3. **Platform:** Works on all platforms where Docker runs
4. **Testing:** Unit tests for all formats + integration test with actual container

---

## API Design

### Proposed Type

```swift
/// Represents a user and optional group for running a container
public struct ContainerUser: Sendable, Hashable {
    let dockerFlag: String

    /// Run as user ID only
    public init(uid: Int) {
        self.dockerFlag = "\(uid)"
    }

    /// Run as user ID and group ID
    public init(uid: Int, gid: Int) {
        self.dockerFlag = "\(uid):\(gid)"
    }

    /// Run as username only
    public init(username: String) {
        precondition(!username.isEmpty, "username cannot be empty")
        self.dockerFlag = username
    }

    /// Run as username and group name
    public init(username: String, group: String) {
        precondition(!username.isEmpty, "username cannot be empty")
        precondition(!group.isEmpty, "group cannot be empty")
        self.dockerFlag = "\(username):\(group)"
    }

    /// Run as username and group ID
    public init(username: String, gid: Int) {
        precondition(!username.isEmpty, "username cannot be empty")
        self.dockerFlag = "\(username):\(gid)"
    }
}
```

### ContainerRequest Changes

Add to `ContainerRequest`:

```swift
public struct ContainerRequest: Sendable, Hashable {
    // ... existing fields ...
    public var user: ContainerUser?  // NEW

    public init(image: String) {
        // ... existing initialization ...
        self.user = nil  // NEW
    }

    /// Run container as the specified user/group
    public func withUser(_ user: ContainerUser) -> Self {
        var copy = self
        copy.user = user
        return copy
    }

    /// Run container as the specified user ID
    public func withUser(uid: Int) -> Self {
        withUser(ContainerUser(uid: uid))
    }

    /// Run container as the specified user ID and group ID
    public func withUser(uid: Int, gid: Int) -> Self {
        withUser(ContainerUser(uid: uid, gid: gid))
    }

    /// Run container as the specified username
    public func withUser(username: String) -> Self {
        withUser(ContainerUser(username: username))
    }

    /// Run container as the specified username and group
    public func withUser(username: String, group: String) -> Self {
        withUser(ContainerUser(username: username, group: group))
    }
}
```

### DockerClient Changes

Update `runContainer` in `DockerClient`:

```swift
func runContainer(_ request: ContainerRequest) async throws -> String {
    var args: [String] = ["run", "-d"]

    if let name = request.name {
        args += ["--name", name]
    }

    // NEW: Add user flag if specified
    if let user = request.user {
        args += ["--user", user.dockerFlag]
    }

    for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
        args += ["-e", "\(key)=\(value)"]
    }

    // ... rest unchanged ...
}
```

### Usage Examples

```swift
// Example 1: Run as user ID 1000
let request = ContainerRequest(image: "nginx:latest")
    .withUser(uid: 1000)

// Example 2: Run as user ID 1000, group ID 1000
let request = ContainerRequest(image: "postgres:16")
    .withUser(uid: 1000, gid: 1000)

// Example 3: Run as username "postgres"
let request = ContainerRequest(image: "postgres:16")
    .withUser(username: "postgres")

// Example 4: Run as username "postgres", group "postgres"
let request = ContainerRequest(image: "postgres:16")
    .withUser(username: "postgres", group: "postgres")

// Example 5: Using ContainerUser directly for complex cases
let user = ContainerUser(username: "nginx", gid: 999)
let request = ContainerRequest(image: "nginx:latest")
    .withUser(user)
```

---

## Implementation Steps

### 1. Create ContainerUser Type
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

- [ ] Add `ContainerUser` struct before `ContainerRequest`
- [ ] Implement all 5 initializers with preconditions
- [ ] Add `dockerFlag` computed property
- [ ] Ensure conformance to `Sendable` and `Hashable`

### 2. Update ContainerRequest
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`

- [ ] Add `public var user: ContainerUser?` field
- [ ] Initialize `user = nil` in `init(image:)`
- [ ] Add `withUser(_ user: ContainerUser) -> Self` builder method
- [ ] Add convenience overloads: `withUser(uid:)`, `withUser(uid:gid:)`, `withUser(username:)`, `withUser(username:group:)`

### 3. Update DockerClient
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/DockerClient.swift`

- [ ] In `runContainer(_:)`, add check for `request.user`
- [ ] Insert `["--user", user.dockerFlag]` into args array
- [ ] Position after `--name` but before environment variables (maintains logical grouping)

### 4. Add Unit Tests
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/ContainerRequestTests.swift`

Add tests for:
- [ ] `ContainerUser.init(uid:)` creates correct flag
- [ ] `ContainerUser.init(uid:gid:)` creates correct flag
- [ ] `ContainerUser.init(username:)` creates correct flag
- [ ] `ContainerUser.init(username:group:)` creates correct flag
- [ ] `ContainerUser.init(username:gid:)` creates correct flag
- [ ] Empty username triggers precondition failure
- [ ] Empty group triggers precondition failure
- [ ] `withUser(uid:)` sets user correctly
- [ ] `withUser(uid:gid:)` sets user correctly
- [ ] `withUser(username:)` sets user correctly
- [ ] `withUser(username:group:)` sets user correctly
- [ ] `withUser(_:)` with ContainerUser works
- [ ] Builder chaining preserves user setting

### 5. Add Integration Test
**File:** `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Tests/TestContainersTests/DockerIntegrationTests.swift`

- [ ] Add test that starts container with `withUser(uid: 1000)`
- [ ] Use `docker exec` to verify container runs as correct user
- [ ] Test with Alpine Linux image (lightweight, has `id` command)
- [ ] Verify output of `id -u` matches expected UID
- [ ] Verify output of `id -g` matches expected GID (when specified)

Example:
```swift
@Test func canRunContainerAsSpecificUser_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withUser(uid: 1000, gid: 1000)
        .withCommand(["sleep", "30"])

    try await withContainer(request) { container in
        // Would need exec support - see feature 002-exec-in-container
        // For now, verify container starts successfully
        #expect(container.id.isEmpty == false)
    }
}
```

**Note:** Full integration test requires exec support (planned feature). Initial test can verify container starts without error.

### 6. Update Documentation
**Files:**
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/FEATURES.md`
- `/Users/conor.mongey/workspace/Mongey/swift-test-containers/README.md` (if applicable)

- [ ] Move "User / groups (`--user`)" from "Not Implemented" to "Implemented" in FEATURES.md
- [ ] Add usage example to README if appropriate
- [ ] Update any inline documentation/comments

---

## Testing Plan

### Unit Tests

**File:** `Tests/TestContainersTests/ContainerRequestTests.swift`

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `buildsUserFlag_uid` | Create user with UID only | `dockerFlag == "1000"` |
| `buildsUserFlag_uidGid` | Create user with UID:GID | `dockerFlag == "1000:1000"` |
| `buildsUserFlag_username` | Create user with username | `dockerFlag == "postgres"` |
| `buildsUserFlag_usernameGroup` | Create user with username:group | `dockerFlag == "postgres:postgres"` |
| `buildsUserFlag_usernameGid` | Create user with username:GID | `dockerFlag == "nginx:999"` |
| `precondition_emptyUsername` | Empty username triggers assertion | Precondition failure |
| `precondition_emptyGroup` | Empty group triggers assertion | Precondition failure |
| `withUser_setsUserUid` | Builder with UID | `request.user?.dockerFlag == "1000"` |
| `withUser_setsUserUidGid` | Builder with UID:GID | `request.user?.dockerFlag == "1000:1000"` |
| `withUser_setsUsername` | Builder with username | `request.user?.dockerFlag == "postgres"` |
| `withUser_setsUsernameGroup` | Builder with username:group | `request.user?.dockerFlag == "postgres:postgres"` |
| `withUser_chainable` | Builder returns chainable self | Can chain with other builders |
| `withUser_hashable` | Requests with same user are equal | `req1 == req2` when users match |

### Integration Tests

**File:** `Tests/TestContainersTests/DockerIntegrationTests.swift`

**Prerequisites:** Requires exec support (feature not yet implemented)

**Future integration test (when exec available):**

```swift
@Test func containerRunsAsSpecifiedUser_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withUser(uid: 1000, gid: 1000)
        .withCommand(["sleep", "60"])

    try await withContainer(request) { container in
        // Execute 'id -u' to get current UID
        let uidOutput = try await container.exec(["id", "-u"])
        #expect(uidOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1000")

        // Execute 'id -g' to get current GID
        let gidOutput = try await container.exec(["id", "-g"])
        #expect(gidOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1000")
    }
}
```

**Interim integration test (without exec):**

```swift
@Test func containerStartsWithUserFlag_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Alpine runs as root by default; setting user to 1000 should work
    let request = ContainerRequest(image: "alpine:3")
        .withUser(uid: 1000, gid: 1000)
        .withCommand(["sleep", "10"])

    try await withContainer(request) { container in
        // Verify container starts successfully
        #expect(!container.id.isEmpty)

        // Verify container doesn't crash (sleep command continues)
        try await Task.sleep(for: .seconds(2))
        // If we get here without error, container is running
    }
}
```

### Manual Testing

```bash
# Set environment variable
export TESTCONTAINERS_RUN_DOCKER_TESTS=1

# Run tests
swift test

# Verify docker commands being generated (add logging if needed)
# Expected: docker run -d --user 1000:1000 alpine:3 sleep 10
```

---

## Acceptance Criteria

### Definition of Done

- [x] **Code Complete:**
  - [ ] `ContainerUser` struct implemented with all 5 initializers
  - [ ] `ContainerRequest.user` field added
  - [ ] `ContainerRequest.withUser(...)` builder methods added (5 overloads)
  - [ ] `DockerClient.runContainer` updated to pass `--user` flag

- [x] **Tests Passing:**
  - [ ] 13+ unit tests covering all ContainerUser initializers
  - [ ] Unit tests for builder methods and chaining
  - [ ] Unit tests for precondition failures
  - [ ] Integration test verifying container starts with user flag
  - [ ] All existing tests still pass (backward compatibility)

- [x] **Documentation:**
  - [ ] Inline code comments for public API
  - [ ] FEATURES.md updated (move from planned to implemented)
  - [ ] README.md updated with usage example (if applicable)

- [x] **Code Quality:**
  - [ ] No compiler warnings
  - [ ] Code follows existing style conventions
  - [ ] `Sendable` and `Hashable` conformance maintained
  - [ ] Type-safe API (compile-time safety where possible)

- [x] **Integration:**
  - [ ] Backward compatible (existing code unaffected)
  - [ ] Works with existing builder pattern
  - [ ] Properly positions `--user` flag in docker command
  - [ ] Manual testing confirms docker containers run as correct user

### Success Metrics

1. **Functionality:** Containers start with correct user/group as verified by Docker
2. **API Usability:** Common use cases (UID, UID:GID, username) require ≤1 line of code
3. **Type Safety:** Invalid inputs (empty strings) caught at compile/runtime
4. **Performance:** Zero overhead (simple string formatting)
5. **Compatibility:** Zero breaking changes to existing code

---

## Related Features

### Dependencies
- None (standalone feature)

### Enables
- **Feature 002: Exec in Container** - Can verify user permissions inside container
- **Feature 005: Bind Mounts** - User/group critical for file ownership in bind mounts
- **PostgresContainer Module** - Can run Postgres as `postgres` user (security best practice)

### Related Docker Flags
- `--group-add` - Add additional groups (future enhancement)
- `--privileged` - Conflicts conceptually with running as non-root

---

## Security Considerations

1. **No validation:** Library does not validate if user/group exists in image - Docker handles this
2. **Root access:** Setting `--user root` or `--user 0` explicitly runs as root (allowed)
3. **Bind mounts:** Running as non-root with bind mounts requires careful host permission setup
4. **Image compatibility:** Some images expect to run as specific users (e.g., postgres:16 expects `postgres` user)

---

## Future Enhancements

1. **Additional groups:** Support `--group-add` for supplementary groups
2. **User namespace remapping:** Support Docker's user namespace features
3. **Convenience helpers:** Static properties like `ContainerUser.root`, `ContainerUser.nobody`
4. **Image inspection:** Query image to determine default user before override

---

## References

- Docker documentation: https://docs.docker.com/engine/reference/run/#user
- testcontainers-go: https://github.com/testcontainers/testcontainers-go (uses functional options)
- Existing implementation: `/Users/conor.mongey/workspace/Mongey/swift-test-containers/Sources/TestContainers/ContainerRequest.swift`
- Port flag pattern: `ContainerPort.dockerFlag` (lines 12-17 in ContainerRequest.swift)
