import Foundation

/// Represents an image to be built from a Dockerfile.
///
/// Use this struct to specify how to build a Docker image from a Dockerfile
/// during test setup. The image will be built before the container starts
/// and automatically cleaned up after the test completes.
///
/// Example:
/// ```swift
/// let dockerfileImage = ImageFromDockerfile(
///     dockerfilePath: "test/Dockerfile",
///     buildContext: "test"
/// )
///     .withBuildArg("VERSION", "1.0.0")
///     .withTargetStage("test")
///
/// let request = ContainerRequest(imageFromDockerfile: dockerfileImage)
///     .withExposedPort(8080)
/// ```
public struct ImageFromDockerfile: Sendable, Hashable {
    /// Path to Dockerfile (absolute or relative).
    public var dockerfilePath: String

    /// Build context directory (directory sent to Docker daemon).
    public var buildContext: String

    /// Build arguments passed to docker build (--build-arg).
    public var buildArgs: [String: String]

    /// Target stage in multi-stage build (--target).
    public var targetStage: String?

    /// Disable build cache (--no-cache).
    public var noCache: Bool

    /// Always pull base images (--pull).
    public var pullBaseImages: Bool

    /// Build timeout.
    public var buildTimeout: Duration

    /// Initialize with Dockerfile path and build context.
    /// - Parameters:
    ///   - dockerfilePath: Path to Dockerfile (default: "Dockerfile" in context)
    ///   - buildContext: Directory for build context (default: ".")
    public init(dockerfilePath: String = "Dockerfile", buildContext: String = ".") {
        self.dockerfilePath = dockerfilePath
        self.buildContext = buildContext
        self.buildArgs = [:]
        self.targetStage = nil
        self.noCache = false
        self.pullBaseImages = false
        self.buildTimeout = .seconds(300)  // 5 minutes default
    }

    /// Add a build argument.
    ///
    /// Build arguments are passed to `docker build` with `--build-arg KEY=VALUE`
    /// and are available during Dockerfile ARG instructions.
    ///
    /// - Parameters:
    ///   - key: The argument name
    ///   - value: The argument value
    /// - Returns: Updated ImageFromDockerfile with the build argument added
    public func withBuildArg(_ key: String, _ value: String) -> Self {
        var copy = self
        copy.buildArgs[key] = value
        return copy
    }

    /// Add multiple build arguments.
    ///
    /// Build arguments are merged with existing arguments.
    /// New values override existing keys.
    ///
    /// - Parameter args: Dictionary of build arguments to add
    /// - Returns: Updated ImageFromDockerfile with the build arguments added
    public func withBuildArgs(_ args: [String: String]) -> Self {
        var copy = self
        for (key, value) in args {
            copy.buildArgs[key] = value
        }
        return copy
    }

    /// Target a specific build stage in a multi-stage Dockerfile.
    ///
    /// This is equivalent to `docker build --target <stage>`.
    /// The stage must be defined in the Dockerfile with `FROM ... AS <stage>`.
    ///
    /// - Parameter stage: The name of the build stage to target
    /// - Returns: Updated ImageFromDockerfile with the target stage set
    public func withTargetStage(_ stage: String) -> Self {
        var copy = self
        copy.targetStage = stage
        return copy
    }

    /// Disable Docker build cache.
    ///
    /// This is equivalent to `docker build --no-cache`.
    /// When enabled, Docker will not use cached layers from previous builds.
    ///
    /// - Parameter noCache: Whether to disable cache (default: true)
    /// - Returns: Updated ImageFromDockerfile with cache setting
    public func withNoCache(_ noCache: Bool = true) -> Self {
        var copy = self
        copy.noCache = noCache
        return copy
    }

    /// Always pull base images during build.
    ///
    /// This is equivalent to `docker build --pull`.
    /// When enabled, Docker will always attempt to pull newer versions
    /// of base images.
    ///
    /// - Parameter pull: Whether to pull base images (default: true)
    /// - Returns: Updated ImageFromDockerfile with pull setting
    public func withPullBaseImages(_ pull: Bool = true) -> Self {
        var copy = self
        copy.pullBaseImages = pull
        return copy
    }

    /// Set the build timeout.
    ///
    /// If the build takes longer than this duration, it will be cancelled.
    /// Default is 5 minutes (300 seconds).
    ///
    /// - Parameter timeout: The maximum time to wait for the build
    /// - Returns: Updated ImageFromDockerfile with the timeout set
    public func withBuildTimeout(_ timeout: Duration) -> Self {
        var copy = self
        copy.buildTimeout = timeout
        return copy
    }
}
