import Foundation
import Testing
@testable import TestContainers

@Test func containerNameGenerator_generateUniqueName_hasDefaultPrefixAndFormat() {
    let name = ContainerNameGenerator.generateUniqueName()

    #expect(name.hasPrefix("tc-swift-"))

    let parts = name.split(separator: "-")
    #expect(parts.count == 4)

    if let timestamp = Int(parts[2]) {
        #expect(timestamp > 0)
    } else {
        Issue.record("Expected numeric timestamp in generated container name")
    }

    let uuidPrefix = String(parts[3])
    #expect(uuidPrefix.count == 8)
    #expect(
        uuidPrefix.range(
            of: "^[a-f0-9]{8}$",
            options: String.CompareOptions.regularExpression
        ) != nil
    )
}

@Test func containerNameGenerator_generateUniqueName_supportsCustomPrefix() {
    let name = ContainerNameGenerator.generateUniqueName(prefix: "my-suite")
    #expect(name.hasPrefix("my-suite-"))
}

@Test func containerNameGenerator_generateUniqueName_isUniqueAcrossRapidCalls() {
    var names: Set<String> = []

    for _ in 0..<100 {
        let name = ContainerNameGenerator.generateUniqueName()
        #expect(names.contains(name) == false)
        names.insert(name)
    }
}

@Test func containerNameGenerator_generateUniqueName_isUniqueWhenConcurrent() async throws {
    let names = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<100 {
            group.addTask {
                ContainerNameGenerator.generateUniqueName()
            }
        }

        var generated: [String] = []
        for try await name in group {
            generated.append(name)
        }
        return generated
    }

    #expect(names.count == 100)
    #expect(Set(names).count == 100)
}

@Test func containerNameGenerator_generateSessionId_isUUID() {
    let sessionId = ContainerNameGenerator.generateSessionID()
    #expect(UUID(uuidString: sessionId) != nil)
}
