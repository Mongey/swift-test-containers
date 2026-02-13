import Foundation

/// Generates identifiers used for parallel-safe container execution.
public enum ContainerNameGenerator {
    /// Generate a unique container name with the format `<prefix>-<timestamp>-<uuid8>`.
    public static func generateUniqueName(prefix: String = "tc-swift") -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let uuidPrefix = UUID().uuidString.prefix(8).lowercased()
        return "\(prefix)-\(timestamp)-\(uuidPrefix)"
    }

    /// Generate a unique session identifier.
    public static func generateSessionID() -> String {
        UUID().uuidString
    }
}
