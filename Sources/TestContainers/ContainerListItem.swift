import Foundation

/// Represents a container item from `docker ps` JSON output.
///
/// Used for listing containers during cleanup operations.
/// The fields map to Docker's JSON format output from `docker ps --format "{{json .}}"`.
public struct ContainerListItem: Sendable, Decodable, Equatable {
    /// Container ID (short form)
    public let id: String

    /// Container names (comma-separated, each prefixed with /)
    public let names: String

    /// Image name used by the container
    public let image: String

    /// Creation timestamp (Unix seconds)
    public let created: Int

    /// Labels as a comma-separated string (key=value,key2=value2)
    public let labels: String

    /// Container state (running, exited, created, etc.)
    public let state: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case names = "Names"
        case image = "Image"
        case created = "Created"
        case createdAt = "CreatedAt"
        case labels = "Labels"
        case state = "State"
    }

    /// Create a new ContainerListItem.
    public init(
        id: String,
        names: String,
        image: String,
        created: Int,
        labels: String,
        state: String
    ) {
        self.id = id
        self.names = names
        self.image = image
        self.created = created
        self.labels = labels
        self.state = state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        names = try container.decode(String.self, forKey: .names)
        image = try container.decode(String.self, forKey: .image)
        labels = try container.decode(String.self, forKey: .labels)
        state = try container.decode(String.self, forKey: .state)

        if let created = try container.decodeIfPresent(Int.self, forKey: .created) {
            self.created = created
        } else if let createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt),
                  let parsedDate = Self.parseDockerCreatedAt(createdAt) {
            created = Int(parsedDate.timeIntervalSince1970)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.created,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Container list item missing both Created and CreatedAt fields"
                )
            )
        }
    }

    private static func parseDockerCreatedAt(_ value: String) -> Date? {
        let formatters = [
            "yyyy-MM-dd HH:mm:ss Z zzz",
            "yyyy-MM-dd HH:mm:ss ZZZZ zzz",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss",
        ]

        for format in formatters {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

    /// Parse the labels string into a dictionary.
    ///
    /// Docker outputs labels as comma-separated `key=value` pairs.
    /// This property parses them into a dictionary for easier access.
    ///
    /// Example: `"key1=value1,key2=value2"` becomes `["key1": "value1", "key2": "value2"]`
    public var parsedLabels: [String: String] {
        guard !labels.isEmpty else { return [:] }

        var result: [String: String] = [:]
        let pairs = labels.split(separator: ",")

        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                result[String(parts[0])] = String(parts[1])
            } else if parts.count == 1 {
                // Label with no value
                result[String(parts[0])] = ""
            }
        }

        return result
    }

    /// Get the first container name without the leading slash.
    ///
    /// Docker prefixes container names with `/` in the output.
    /// This property returns the first name without the prefix.
    public var firstName: String? {
        guard !names.isEmpty else { return nil }

        let firstNameWithSlash = names.split(separator: ",").first.map(String.init) ?? names
        if firstNameWithSlash.hasPrefix("/") {
            return String(firstNameWithSlash.dropFirst())
        }
        return firstNameWithSlash
    }

    /// Get the creation date.
    public var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(created))
    }

    /// Create a ContainerListItem from a Docker Engine API container list response.
    ///
    /// The API format differs from CLI: Names is an array, Labels is a dictionary.
    init(fromAPI item: APIContainerListItem) {
        self.id = item.Id
        // API returns names as ["/name1", "/name2"], CLI as "name1,name2"
        self.names = item.Names.joined(separator: ",")
        self.image = item.Image
        self.created = item.Created
        // Convert labels dict to comma-separated key=value string
        if let labels = item.Labels, !labels.isEmpty {
            self.labels = labels
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
        } else {
            self.labels = ""
        }
        self.state = item.State
    }
}
