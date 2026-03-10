import Foundation

/// Comprehensive image metadata from `docker image inspect`.
public struct ImageInspection: Sendable, Equatable {
    public let id: String
    public let repoTags: [String]
    public let repoDigests: [String]
    public let created: Date
    public let size: Int64
    public let architecture: String
    public let os: String
    public let author: String
    public let config: ImageConfig
    public let rootFS: ImageRootFS

    /// Parse image inspection from Docker CLI JSON output (array format).
    ///
    /// - Parameter json: JSON string from `docker image inspect` command
    /// - Returns: Parsed `ImageInspection`
    /// - Throws: `TestContainersError.unexpectedDockerOutput` if JSON is empty or invalid
    public static func parse(from json: String) throws -> ImageInspection {
        guard let data = json.data(using: .utf8) else {
            throw TestContainersError.unexpectedDockerOutput("Invalid UTF-8 in JSON")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeDockerImageDate)

        let inspections = try decoder.decode([ImageInspection].self, from: data)
        guard let inspection = inspections.first else {
            throw TestContainersError.unexpectedDockerOutput("docker image inspect returned empty array")
        }

        return inspection
    }

    /// Parse image inspection from Docker Engine API JSON response (single object).
    ///
    /// The API endpoint `GET /images/{name}/json` returns a single object,
    /// unlike the CLI which wraps it in an array.
    ///
    /// - Parameter data: Raw JSON data from the API response
    /// - Returns: Parsed `ImageInspection`
    public static func parseFromAPI(data: Data) throws -> ImageInspection {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeDockerImageDate)
        return try decoder.decode(ImageInspection.self, from: data)
    }
}

/// Image configuration (default settings from Dockerfile).
public struct ImageConfig: Sendable, Equatable {
    public let user: String
    public let env: [String]
    public let cmd: [String]?
    public let entrypoint: [String]?
    public let workingDir: String
    public let exposedPorts: [String: EmptyObject]
    public let labels: [String: String]
    public let volumes: Set<String>

    /// Returns exposed port numbers parsed from the "port/protocol" keys.
    public func exposedPortNumbers() -> [Int] {
        exposedPorts.keys.compactMap { key in
            let parts = key.split(separator: "/")
            guard let first = parts.first else { return nil }
            return Int(first)
        }
    }

    /// Converts the environment array to a dictionary.
    ///
    /// Each entry is in the format "KEY=VALUE". Values containing `=` are preserved.
    public func environmentDictionary() -> [String: String] {
        var dict: [String: String] = [:]
        for entry in env {
            let parts = entry.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                dict[String(parts[0])] = String(parts[1])
            }
        }
        return dict
    }
}

/// Empty JSON object used by Docker for set-like maps (e.g., ExposedPorts, Volumes).
public struct EmptyObject: Sendable, Equatable, Decodable {
    public init() {}
}

/// Image root filesystem information.
public struct ImageRootFS: Sendable, Equatable {
    public let type: String
    public let layers: [String]
}

// MARK: - Codable Conformance

extension ImageInspection: Decodable {
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case repoTags = "RepoTags"
        case repoDigests = "RepoDigests"
        case created = "Created"
        case size = "Size"
        case architecture = "Architecture"
        case os = "Os"
        case author = "Author"
        case config = "Config"
        case rootFS = "RootFS"
    }
}

extension ImageConfig: Decodable {
    enum CodingKeys: String, CodingKey {
        case user = "User"
        case env = "Env"
        case cmd = "Cmd"
        case entrypoint = "Entrypoint"
        case workingDir = "WorkingDir"
        case exposedPorts = "ExposedPorts"
        case labels = "Labels"
        case volumes = "Volumes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        user = try container.decodeIfPresent(String.self, forKey: .user) ?? ""
        env = try container.decodeIfPresent([String].self, forKey: .env) ?? []
        cmd = try container.decodeIfPresent([String].self, forKey: .cmd)
        entrypoint = try container.decodeIfPresent([String].self, forKey: .entrypoint)
        workingDir = try container.decodeIfPresent(String.self, forKey: .workingDir) ?? ""
        exposedPorts = try container.decodeIfPresent([String: EmptyObject].self, forKey: .exposedPorts) ?? [:]
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]

        // Docker stores volumes as {"path": {}} - extract just the keys
        let volumeMap = try container.decodeIfPresent([String: EmptyObject].self, forKey: .volumes) ?? [:]
        volumes = Set(volumeMap.keys)
    }
}

extension ImageRootFS: Decodable {
    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case layers = "Layers"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        layers = try container.decodeIfPresent([String].self, forKey: .layers) ?? []
    }
}

// MARK: - Date Helpers

/// Custom date decoder for Docker image dates.
private func decodeDockerImageDate(_ decoder: Decoder) throws -> Date {
    let container = try decoder.singleValueContainer()
    let dateString = try container.decode(String.self)

    // Try ISO8601 with fractional seconds
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: dateString) {
        return date
    }

    // Try without fractional seconds
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: dateString) {
        return date
    }

    throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid date format: \(dateString)"
    )
}
