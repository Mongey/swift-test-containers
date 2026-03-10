import Foundation

/// Backward-compatible alias for multi-container dependency orchestration.
public typealias ContainerGroup = ContainerStack

/// Backward-compatible alias for a running container group handle.
public typealias ContainerGroupHandle = RunningStack

/// Runs a container group with scoped lifecycle management.
///
/// This delegates to `withStack` to preserve a single orchestration implementation.
public func withContainerGroup<T>(
    _ group: ContainerGroup,
    runtime: any ContainerRuntime = DockerClient(),
    logger: TCLogger = .null,
    operation: @Sendable (ContainerGroupHandle) async throws -> T
) async throws -> T {
    try await withStack(group, runtime: runtime, logger: logger, operation: operation)
}
