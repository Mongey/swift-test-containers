import Testing
@testable import TestContainers

// MARK: - Registry Mirror Tests

@Test func registryMirror_addsRegistryToSimpleImage() {
    let substitutor = ImageSubstitutorConfig.registryMirror("mirror.company.com")
    let result = substitutor.substitute("redis:7")
    #expect(result == "mirror.company.com/redis:7")
}

@Test func registryMirror_addsRegistryToImageWithoutTag() {
    let substitutor = ImageSubstitutorConfig.registryMirror("mirror.company.com")
    let result = substitutor.substitute("nginx")
    #expect(result == "mirror.company.com/nginx")
}

@Test func registryMirror_preservesQualifiedImage() {
    let substitutor = ImageSubstitutorConfig.registryMirror("mirror.company.com")
    let result = substitutor.substitute("gcr.io/project/image:1.0")
    #expect(result == "gcr.io/project/image:1.0")
}

@Test func registryMirror_preservesImageWithPort() {
    let substitutor = ImageSubstitutorConfig.registryMirror("mirror.company.com")
    let result = substitutor.substitute("localhost:5000/myapp:dev")
    #expect(result == "localhost:5000/myapp:dev")
}

@Test func registryMirror_handlesLibraryPrefix() {
    let substitutor = ImageSubstitutorConfig.registryMirror("mirror.company.com")
    let result = substitutor.substitute("library/redis:7")
    #expect(result == "mirror.company.com/redis:7")
}

// MARK: - Repository Prefix Tests

@Test func repositoryPrefix_addsPrefix() {
    let substitutor = ImageSubstitutorConfig.repositoryPrefix("myorg")
    let result = substitutor.substitute("nginx:latest")
    #expect(result == "myorg/nginx:latest")
}

@Test func repositoryPrefix_addsPrefixToRepoImage() {
    let substitutor = ImageSubstitutorConfig.repositoryPrefix("mirrors")
    let result = substitutor.substitute("someuser/app:v1")
    #expect(result == "mirrors/someuser/app:v1")
}

@Test func repositoryPrefix_preservesRegistryQualifiedImage() {
    let substitutor = ImageSubstitutorConfig.repositoryPrefix("myorg")
    let result = substitutor.substitute("gcr.io/project/image:1.0")
    #expect(result == "gcr.io/project/image:1.0")
}

@Test func repositoryPrefix_preservesImageWithPort() {
    let substitutor = ImageSubstitutorConfig.repositoryPrefix("myorg")
    let result = substitutor.substitute("localhost:5000/myapp:dev")
    #expect(result == "localhost:5000/myapp:dev")
}

// MARK: - Replace Registry Tests

@Test func replaceRegistry_replacesDockerHub() {
    let substitutor = ImageSubstitutorConfig.replaceRegistry(from: "docker.io", to: "local.registry")
    let result = substitutor.substitute("redis:7")
    #expect(result == "local.registry/redis:7")
}

@Test func replaceRegistry_replacesExplicitRegistry() {
    let substitutor = ImageSubstitutorConfig.replaceRegistry(from: "docker.io", to: "mirror.co")
    let result = substitutor.substitute("docker.io/library/nginx:latest")
    #expect(result == "mirror.co/library/nginx:latest")
}

@Test func replaceRegistry_leavesNonMatchingRegistryAlone() {
    let substitutor = ImageSubstitutorConfig.replaceRegistry(from: "docker.io", to: "local.registry")
    let result = substitutor.substitute("gcr.io/project/image:1.0")
    #expect(result == "gcr.io/project/image:1.0")
}

@Test func replaceRegistry_handlesLibraryPrefix() {
    let substitutor = ImageSubstitutorConfig.replaceRegistry(from: "docker.io", to: "mirror.co")
    let result = substitutor.substitute("library/redis:7")
    #expect(result == "mirror.co/redis:7")
}

// MARK: - Custom Substitutor Tests

@Test func customSubstitutor_appliesClosureLogic() {
    let substitutor = ImageSubstitutorConfig(identifier: "version-pin") { image in
        return image.replacingOccurrences(of: "latest", with: "1.0.0")
    }
    let result = substitutor.substitute("nginx:latest")
    #expect(result == "nginx:1.0.0")
}

@Test func customSubstitutor_passthrough() {
    let substitutor = ImageSubstitutorConfig(identifier: "passthrough") { $0 }
    let result = substitutor.substitute("redis:7")
    #expect(result == "redis:7")
}

// MARK: - Chaining Tests

@Test func chainedSubstitutors_applyInOrder() {
    let substitutor = ImageSubstitutorConfig
        .repositoryPrefix("mirrors")
        .then(.registryMirror("registry.company.com"))

    let result = substitutor.substitute("postgres:16")
    #expect(result == "registry.company.com/mirrors/postgres:16")
}

@Test func chainedSubstitutors_multipleLevels() {
    let sub = ImageSubstitutorConfig(identifier: "add-tag") { image in
        if !image.contains(":") {
            return "\(image):latest"
        }
        return image
    }
    .then(.repositoryPrefix("myorg"))
    .then(.registryMirror("mirror.co"))

    let result = sub.substitute("nginx")
    #expect(result == "mirror.co/myorg/nginx:latest")
}

// MARK: - Hashable / Sendable Tests

@Test func imageSubstitutor_hashable_sameIdentifierAreEqual() {
    let s1 = ImageSubstitutorConfig.registryMirror("mirror.co")
    let s2 = ImageSubstitutorConfig.registryMirror("mirror.co")
    #expect(s1 == s2)
}

@Test func imageSubstitutor_hashable_differentIdentifierAreNotEqual() {
    let s1 = ImageSubstitutorConfig.registryMirror("mirror1.co")
    let s2 = ImageSubstitutorConfig.registryMirror("mirror2.co")
    #expect(s1 != s2)
}

@Test func imageSubstitutor_hashable_differentFactoriesAreNotEqual() {
    let s1 = ImageSubstitutorConfig.registryMirror("test")
    let s2 = ImageSubstitutorConfig.repositoryPrefix("test")
    #expect(s1 != s2)
}

@Test func imageSubstitutor_canBeUsedInSet() {
    let s1 = ImageSubstitutorConfig.registryMirror("a")
    let s2 = ImageSubstitutorConfig.registryMirror("a")
    let s3 = ImageSubstitutorConfig.registryMirror("b")

    let set: Set<ImageSubstitutorConfig> = [s1, s2, s3]
    #expect(set.count == 2)
}
