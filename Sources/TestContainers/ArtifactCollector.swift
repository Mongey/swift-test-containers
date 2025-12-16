import Foundation

/// Actor responsible for collecting and persisting container artifacts.
///
/// The collector captures container logs, metadata, and configuration when
/// tests fail, providing debugging information for test failures.
///
/// Example usage:
/// ```swift
/// let collector = ArtifactCollector(config: ArtifactConfig()
///     .withOutputDirectory("/tmp/artifacts")
///     .withTrigger(.always))
///
/// let artifacts = await collector.collect(
///     container: container,
///     testName: "MyTests.testExample",
///     error: nil
/// )
/// ```
public actor ArtifactCollector {
    private let config: ArtifactConfig
    private let fileManager: FileManager

    /// The current configuration.
    public var configuration: ArtifactConfig {
        config
    }

    /// Create a new artifact collector with the given configuration.
    ///
    /// - Parameter config: Configuration for artifact collection (defaults to .default)
    public init(config: ArtifactConfig = .default) {
        self.config = config
        self.fileManager = FileManager.default
    }

    /// Check if artifacts should be collected based on configuration and error.
    ///
    /// - Parameter error: The error that occurred (if any)
    /// - Returns: true if artifacts should be collected
    public func shouldCollect(error: Error?) -> Bool {
        guard config.enabled else { return false }

        switch config.trigger {
        case .onFailure:
            return error != nil
        case .always:
            return true
        case .onTimeout:
            if let testError = error as? TestContainersError {
                if case .timeout = testError {
                    return true
                }
            }
            return false
        }
    }

    /// Create the artifact directory path for a container.
    ///
    /// - Parameters:
    ///   - testName: Name of the test
    ///   - containerId: Container ID
    /// - Returns: Path to the artifact directory
    public func makeArtifactDirectory(testName: String, containerId: String) -> String {
        let sanitizedTestName = sanitizePathComponent(testName)
        let timestamp = formatTimestamp(Date())
        let dirName = "\(containerId.prefix(12))_\(timestamp)"

        return "\(config.outputDirectory)/\(sanitizedTestName)/\(dirName)"
    }

    /// Collect artifacts for a container.
    ///
    /// - Parameters:
    ///   - container: The container to collect artifacts from
    ///   - testName: Name of the test (for organizing artifacts)
    ///   - error: The error that occurred (if any)
    /// - Returns: The collected artifacts, or nil if collection was skipped/failed
    public func collect(
        container: Container,
        testName: String?,
        error: Error?
    ) async -> ArtifactCollection? {
        guard shouldCollect(error: error) else { return nil }

        let effectiveTestName = testName ?? "unknown-test"
        let containerId = container.id
        let artifactDir = makeArtifactDirectory(testName: effectiveTestName, containerId: containerId)

        // Create the directory
        do {
            try fileManager.createDirectory(
                atPath: artifactDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            // Directory creation failed - silently fail
            return nil
        }

        var logsFile: String?
        var metadataFile: String?
        var requestFile: String?
        var errorFile: String?

        // Collect logs
        if config.collectLogs {
            logsFile = await collectLogs(container: container, outputDir: artifactDir)
        }

        // Collect metadata
        if config.collectMetadata {
            metadataFile = await collectMetadata(container: container, outputDir: artifactDir)
        }

        // Collect request
        if config.collectRequest {
            requestFile = await collectRequest(container: container, outputDir: artifactDir)
        }

        // Collect error info
        if let error = error {
            errorFile = collectError(error: error, testName: effectiveTestName, containerId: containerId, outputDir: artifactDir)
        }

        let collection = ArtifactCollection(
            artifactDirectory: artifactDir,
            logsFile: logsFile,
            metadataFile: metadataFile,
            requestFile: requestFile,
            errorFile: errorFile
        )

        // Apply retention policy in background
        Task {
            await applyRetentionPolicy(for: effectiveTestName)
        }

        return collection.isEmpty ? nil : collection
    }

    // MARK: - Private Collection Methods

    private func collectLogs(container: Container, outputDir: String) async -> String? {
        do {
            let logs = try await container.logs()
            let logsPath = "\(outputDir)/logs.txt"
            try logs.write(toFile: logsPath, atomically: true, encoding: .utf8)
            return logsPath
        } catch {
            return nil
        }
    }

    private func collectMetadata(container: Container, outputDir: String) async -> String? {
        do {
            let containerId = container.id
            let request = container.request

            let artifact = ContainerArtifact(
                containerId: containerId,
                imageName: request.image,
                containerName: request.name,
                captureTime: Date(),
                containerState: "unknown", // Would need inspect to get actual state
                exitCode: nil,
                environment: request.environment,
                labels: request.labels,
                ports: request.ports.map { "\($0.containerPort)/tcp" },
                inspectJSON: nil
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(artifact)

            let metadataPath = "\(outputDir)/metadata.json"
            try data.write(to: URL(fileURLWithPath: metadataPath))
            return metadataPath
        } catch {
            return nil
        }
    }

    private func collectRequest(container: Container, outputDir: String) async -> String? {
        let request = container.request

        // Create a simplified request representation
        var requestInfo: [String: Any] = [
            "image": request.image,
            "command": request.command,
            "environment": request.environment,
            "labels": request.labels,
            "ports": request.ports.map { $0.containerPort },
            "host": request.host
        ]

        if let name = request.name {
            requestInfo["name"] = name
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: requestInfo, options: [.prettyPrinted, .sortedKeys])
            let requestPath = "\(outputDir)/request.json"
            try data.write(to: URL(fileURLWithPath: requestPath))
            return requestPath
        } catch {
            return nil
        }
    }

    private func collectError(error: Error, testName: String, containerId: String, outputDir: String) -> String? {
        let errorContent = """
        Error: \(type(of: error))
        Message: \(error.localizedDescription)

        Test: \(testName)
        Container: \(containerId)
        Captured: \(ISO8601DateFormatter().string(from: Date()))

        Details:
        \(String(describing: error))
        """

        let errorPath = "\(outputDir)/error.txt"
        do {
            try errorContent.write(toFile: errorPath, atomically: true, encoding: .utf8)
            return errorPath
        } catch {
            return nil
        }
    }

    // MARK: - Retention Policy

    private func applyRetentionPolicy(for testName: String) async {
        let testDir = "\(config.outputDirectory)/\(sanitizePathComponent(testName))"

        guard fileManager.fileExists(atPath: testDir) else { return }

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: testDir)
            guard !contents.isEmpty else { return }

            switch config.retentionPolicy {
            case .keepAll:
                // Do nothing
                break

            case let .keepLast(count):
                // Sort by name (which includes timestamp) and remove oldest
                let sorted = contents.sorted()
                if sorted.count > count {
                    let toRemove = sorted.prefix(sorted.count - count)
                    for dir in toRemove {
                        try? fileManager.removeItem(atPath: "\(testDir)/\(dir)")
                    }
                }

            case let .keepForDays(days):
                let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
                for dir in contents {
                    let path = "\(testDir)/\(dir)"
                    if let attrs = try? fileManager.attributesOfItem(atPath: path),
                       let modDate = attrs[.modificationDate] as? Date,
                       modDate < cutoff {
                        try? fileManager.removeItem(atPath: path)
                    }
                }
            }
        } catch {
            // Silently ignore retention policy errors
        }
    }

    // MARK: - Helpers

    private func sanitizePathComponent(_ name: String) -> String {
        // Replace characters that are problematic in file paths
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalidChars).joined(separator: "_")
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }
}
