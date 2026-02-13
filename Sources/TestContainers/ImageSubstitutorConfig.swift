/// Configuration for transforming Docker image references before container creation.
///
/// Image substitutors enable registry mirroring, organization prefixes, and custom
/// image transformations without changing container request code.
///
/// Example:
/// ```swift
/// let request = ContainerRequest(image: "redis:7")
///     .withImageSubstitutor(.registryMirror("mirror.company.com"))
/// // Will pull from: mirror.company.com/redis:7
/// ```
public struct ImageSubstitutorConfig: Sendable, Hashable {
    private let _substitute: @Sendable (String) -> String
    private let identifier: String

    /// Creates a substitutor from a closure.
    ///
    /// - Parameters:
    ///   - identifier: Unique identifier for this substitutor (used for Hashable)
    ///   - substitute: Transformation function applied to image references
    public init(identifier: String, substitute: @escaping @Sendable (String) -> String) {
        self.identifier = identifier
        self._substitute = substitute
    }

    /// Transforms an image reference using this substitutor's logic.
    public func substitute(_ image: String) -> String {
        _substitute(image)
    }

    /// Creates a substitutor that prefixes all unqualified images with a registry host.
    ///
    /// Images that already contain a registry (identified by containing a dot or colon
    /// before the first slash) are left unchanged.
    ///
    /// - Parameter registryHost: Registry host (e.g., "mirror.company.com", "localhost:5000")
    /// - Returns: Substitutor that adds registry prefix to unqualified images
    public static func registryMirror(_ registryHost: String) -> Self {
        Self(identifier: "registry-mirror:\(registryHost)") { image in
            if image.contains("/") && !image.hasPrefix("library/") {
                let beforeSlash = image.prefix(while: { $0 != "/" })
                if beforeSlash.contains(".") || beforeSlash.contains(":") {
                    return image
                }
            }
            let imageName = image.hasPrefix("library/") ? String(image.dropFirst(8)) : image
            return "\(registryHost)/\(imageName)"
        }
    }

    /// Creates a substitutor that adds a prefix to repository names.
    ///
    /// Images with an explicit registry (containing a dot or colon before the first slash)
    /// are left unchanged.
    ///
    /// - Parameter prefix: Repository prefix (e.g., "myorg", "mirrors/dockerhub")
    /// - Returns: Substitutor that adds repository prefix
    public static func repositoryPrefix(_ prefix: String) -> Self {
        Self(identifier: "repo-prefix:\(prefix)") { image in
            if let slashIndex = image.firstIndex(of: "/") {
                let beforeSlash = image[..<slashIndex]
                if beforeSlash.contains(".") || beforeSlash.contains(":") {
                    return image
                }
            }
            return "\(prefix)/\(image)"
        }
    }

    /// Creates a substitutor that replaces the registry portion of image references.
    ///
    /// - Parameters:
    ///   - from: Registry to replace (e.g., "docker.io")
    ///   - to: Replacement registry (e.g., "mirror.company.com")
    /// - Returns: Substitutor that replaces the registry
    public static func replaceRegistry(from: String, to: String) -> Self {
        Self(identifier: "replace-registry:\(from)->\(to)") { image in
            if image.hasPrefix("\(from)/") {
                return "\(to)/\(image.dropFirst(from.count + 1))"
            }
            // Unqualified images default to Docker Hub
            if !image.contains("/") || image.hasPrefix("library/") {
                let imageName = image.hasPrefix("library/") ? String(image.dropFirst(8)) : image
                if from == "docker.io" || from == "registry-1.docker.io" {
                    return "\(to)/\(imageName)"
                }
            }
            return image
        }
    }

    /// Chains this substitutor with another, applying this one first then the other.
    ///
    /// - Parameter other: Next substitutor to apply after this one
    /// - Returns: Chained substitutor
    public func then(_ other: ImageSubstitutorConfig) -> Self {
        Self(identifier: "\(identifier) | \(other.identifier)") { image in
            other.substitute(self.substitute(image))
        }
    }

    public static func == (lhs: ImageSubstitutorConfig, rhs: ImageSubstitutorConfig) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}
