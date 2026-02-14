# ``TestContainers``

Run Docker containers in Swift tests with automatic lifecycle management.

## Overview

TestContainers is a Swift package for running Docker containers in tests, designed to work with Swift Testing (`import Testing`). It provides a builder-pattern API for configuring containers, automatic readiness detection via wait strategies, and scoped lifecycle management that ensures containers are cleaned up after tests complete.

```swift
import Testing
import TestContainers

@Test func testWithRedis() async throws {
    let request = ContainerRequest(image: "redis:7")
        .withExposedPort(6379)
        .waitingFor(.tcpPort(6379))

    try await withContainer(request) { container in
        let port = try await container.hostPort(6379)
        // Connect to Redis at localhost:\(port)
    }
}
```

### Requirements

- Docker must be installed and available on `PATH`
- Swift 6.0+
- macOS or Linux

## Topics

### Essentials

- ``withContainer(_:dockerClient:operation:)``
- ``createContainer(_:dockerClient:)``
- ``Container``
- ``ContainerRequest``

### Configuration

- ``ContainerPort``
- ``BindMount``
- ``TmpfsMount``
- ``VolumeMount``
- ``ExtraHost``
- ``NetworkConnection``
- ``Capability``
- ``ContainerUser``
- ``ResourceLimits``
- ``ImagePullPolicy``
- ``RegistryAuth``
- ``NetworkMode``

### Wait Strategies

- ``WaitStrategy``
- ``HTTPWaitConfig``
- ``HTTPMethod``
- ``StatusCodeMatcher``
- ``BodyMatcher``
- ``HealthCheckConfig``

### Docker Image Building

- ``ImageFromDockerfile``

### Networking

- ``withNetwork(_:dockerClient:operation:)``
- ``Network``
- ``NetworkRequest``
- ``NetworkDriver``
- ``IPAMConfig``

### Multi-Container Orchestration

- ``withStack(_:dockerClient:operation:)``
- ``ContainerStack``
- ``RunningStack``
- ``ContainerDependency``
- ``DependencyWaitStrategy``

### Container Execution

- ``ExecOptions``
- ``ExecResult``

### Container Inspection

- ``ContainerInspection``
- ``ContainerState``
- ``ContainerConfig``
- ``NetworkSettings``
- ``PortBinding``
- ``NetworkAttachment``
- ``HealthStatus``
- ``HealthLog``

### Log Streaming

- ``LogConsumer``
- ``CollectingLogConsumer``
- ``PrintLogConsumer``
- ``CompositeLogConsumer``
- ``LogStreamOptions``
- ``LogEntry``
- ``LogStream``

### Lifecycle Hooks

- ``LifecycleHook``
- ``LifecycleContext``
- ``LifecyclePhase``

### Diagnostics & Retry

- ``DiagnosticsConfig``
- ``TimeoutDiagnostics``
- ``RetryPolicy``
- ``ArtifactConfig``
- ``CollectionTrigger``
- ``RetentionPolicy``

### Error Handling

- ``TestContainersError``
