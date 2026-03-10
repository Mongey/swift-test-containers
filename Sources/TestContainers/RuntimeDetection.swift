import Foundation

/// Supported container runtime types.
public enum ContainerRuntimeType: String, Sendable {
    case docker
    case appleContainer = "apple"
}

/// Detects and returns the appropriate container runtime.
///
/// Selection priority:
/// 1. Explicit `preferred` parameter
/// 2. `TESTCONTAINERS_RUNTIME` environment variable (`apple` or `docker`)
/// 3. Default to `DockerClient()` for backward compatibility
///
/// - Parameter preferred: Explicitly preferred runtime type, if any
/// - Returns: A container runtime instance
public func detectRuntime(preferred: ContainerRuntimeType? = nil) -> any ContainerRuntime {
    let runtimeType: ContainerRuntimeType

    if let preferred {
        runtimeType = preferred
    } else if let envValue = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUNTIME"],
              let fromEnv = ContainerRuntimeType(rawValue: envValue.lowercased()) {
        runtimeType = fromEnv
    } else {
        return DockerClient()
    }

    switch runtimeType {
    case .docker:
        return DockerClient()
    case .appleContainer:
        return AppleContainerClient()
    }
}
