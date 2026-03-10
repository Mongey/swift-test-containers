import Foundation

/// Phases during container lifecycle where hooks can be executed.
public enum LifecyclePhase: String, Sendable, Hashable {
    /// Before the container is created/started.
    case preStart = "preStart"
    /// After the container has started and is ready.
    case postStart = "postStart"
    /// Before the container is stopped (graceful shutdown).
    case preStop = "preStop"
    /// After the container has been stopped.
    case postStop = "postStop"
    /// Before the container is terminated/removed.
    case preTerminate = "preTerminate"
    /// After the container has been terminated/removed.
    case postTerminate = "postTerminate"
}

/// Context provided to lifecycle hooks with access to container and configuration.
public struct LifecycleContext: Sendable {
    /// The running container (available in PostStart and later phases).
    public let container: Container?

    /// The container request configuration.
    public let request: ContainerRequest

    /// The container runtime for executing commands.
    public let runtime: any ContainerRuntime

    /// Creates a new lifecycle context.
    /// - Parameters:
    ///   - container: The container (nil for PreStart phase)
    ///   - request: The container request configuration
    ///   - runtime: The container runtime
    public init(container: Container?, request: ContainerRequest, runtime: any ContainerRuntime) {
        self.container = container
        self.request = request
        self.runtime = runtime
    }

    /// Returns the container or throws if not available.
    /// Use this in hooks that require a running container.
    /// - Returns: The container
    /// - Throws: `TestContainersError.lifecycleError` if container is not available
    public func requireContainer() throws -> Container {
        guard let container = container else {
            throw TestContainersError.lifecycleError("Container not available in this lifecycle phase")
        }
        return container
    }
}

/// A lifecycle hook that executes during a specific phase of container lifecycle.
/// Each hook has a unique identifier for tracking and deduplication.
public struct LifecycleHook: Sendable, Hashable {
    /// Unique identifier for this hook.
    public let id: UUID

    /// The action to execute when the hook is triggered.
    private let action: @Sendable (LifecycleContext) async throws -> Void

    /// Creates a new lifecycle hook.
    /// - Parameter action: The async action to execute
    public init(_ action: @escaping @Sendable (LifecycleContext) async throws -> Void) {
        self.id = UUID()
        self.action = action
    }

    /// Executes the hook action with the given context.
    /// - Parameter context: The lifecycle context
    /// - Throws: Any error from the action
    internal func execute(context: LifecycleContext) async throws {
        try await action(context)
    }

    // MARK: - Hashable

    public static func == (lhs: LifecycleHook, rhs: LifecycleHook) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Executes an array of lifecycle hooks in order.
/// - Parameters:
///   - hooks: The hooks to execute
///   - context: The lifecycle context
///   - phase: The current lifecycle phase (for error reporting)
/// - Throws: `TestContainersError.lifecycleHookFailed` if any hook fails
public func executeLifecycleHooks(
    _ hooks: [LifecycleHook],
    context: LifecycleContext,
    phase: LifecyclePhase
) async throws {
    for (index, hook) in hooks.enumerated() {
        do {
            try await hook.execute(context: context)
        } catch {
            throw TestContainersError.lifecycleHookFailed(
                phase: phase.rawValue,
                hookIndex: index,
                underlyingError: error
            )
        }
    }
}
