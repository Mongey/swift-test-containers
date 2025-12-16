import Testing
@testable import TestContainers

// MARK: - ImageFromDockerfile Tests

@Test func imageFromDockerfile_defaultValues() {
    let image = ImageFromDockerfile()

    #expect(image.dockerfilePath == "Dockerfile")
    #expect(image.buildContext == ".")
    #expect(image.buildArgs.isEmpty)
    #expect(image.targetStage == nil)
    #expect(image.noCache == false)
    #expect(image.pullBaseImages == false)
    #expect(image.buildTimeout == .seconds(300))
}

@Test func imageFromDockerfile_customInitialization() {
    let image = ImageFromDockerfile(
        dockerfilePath: "test/Dockerfile.dev",
        buildContext: "test"
    )

    #expect(image.dockerfilePath == "test/Dockerfile.dev")
    #expect(image.buildContext == "test")
}

@Test func imageFromDockerfile_withBuildArg_addsSingleArg() {
    let image = ImageFromDockerfile()
        .withBuildArg("VERSION", "1.0.0")

    #expect(image.buildArgs.count == 1)
    #expect(image.buildArgs["VERSION"] == "1.0.0")
}

@Test func imageFromDockerfile_withBuildArg_addsMultipleArgs() {
    let image = ImageFromDockerfile()
        .withBuildArg("VERSION", "1.0.0")
        .withBuildArg("ENV", "test")
        .withBuildArg("DEBUG", "true")

    #expect(image.buildArgs.count == 3)
    #expect(image.buildArgs["VERSION"] == "1.0.0")
    #expect(image.buildArgs["ENV"] == "test")
    #expect(image.buildArgs["DEBUG"] == "true")
}

@Test func imageFromDockerfile_withBuildArgs_addsMultipleAtOnce() {
    let image = ImageFromDockerfile()
        .withBuildArgs([
            "VERSION": "2.0.0",
            "ENV": "production"
        ])

    #expect(image.buildArgs.count == 2)
    #expect(image.buildArgs["VERSION"] == "2.0.0")
    #expect(image.buildArgs["ENV"] == "production")
}

@Test func imageFromDockerfile_withBuildArgs_mergesWithExisting() {
    let image = ImageFromDockerfile()
        .withBuildArg("EXISTING", "value")
        .withBuildArgs(["NEW1": "v1", "NEW2": "v2"])

    #expect(image.buildArgs.count == 3)
    #expect(image.buildArgs["EXISTING"] == "value")
    #expect(image.buildArgs["NEW1"] == "v1")
    #expect(image.buildArgs["NEW2"] == "v2")
}

@Test func imageFromDockerfile_withTargetStage_setsStage() {
    let image = ImageFromDockerfile()
        .withTargetStage("builder")

    #expect(image.targetStage == "builder")
}

@Test func imageFromDockerfile_withNoCache_enablesNoCache() {
    let image = ImageFromDockerfile()
        .withNoCache()

    #expect(image.noCache == true)
}

@Test func imageFromDockerfile_withNoCache_canDisable() {
    let image = ImageFromDockerfile()
        .withNoCache(true)
        .withNoCache(false)

    #expect(image.noCache == false)
}

@Test func imageFromDockerfile_withPullBaseImages_enablesPull() {
    let image = ImageFromDockerfile()
        .withPullBaseImages()

    #expect(image.pullBaseImages == true)
}

@Test func imageFromDockerfile_withPullBaseImages_canDisable() {
    let image = ImageFromDockerfile()
        .withPullBaseImages(true)
        .withPullBaseImages(false)

    #expect(image.pullBaseImages == false)
}

@Test func imageFromDockerfile_withBuildTimeout_setsTimeout() {
    let image = ImageFromDockerfile()
        .withBuildTimeout(.seconds(600))

    #expect(image.buildTimeout == .seconds(600))
}

@Test func imageFromDockerfile_immutability_originalUnchanged() {
    let original = ImageFromDockerfile()
    let modified = original.withBuildArg("KEY", "value")

    #expect(original.buildArgs.isEmpty)
    #expect(modified.buildArgs.count == 1)
}

@Test func imageFromDockerfile_chainingAllBuilderMethods() {
    let image = ImageFromDockerfile(
        dockerfilePath: "Dockerfile.test",
        buildContext: "./src"
    )
        .withBuildArg("VERSION", "1.0")
        .withBuildArgs(["ENV": "test", "DEBUG": "true"])
        .withTargetStage("production")
        .withNoCache()
        .withPullBaseImages()
        .withBuildTimeout(.seconds(180))

    #expect(image.dockerfilePath == "Dockerfile.test")
    #expect(image.buildContext == "./src")
    #expect(image.buildArgs.count == 3)
    #expect(image.targetStage == "production")
    #expect(image.noCache == true)
    #expect(image.pullBaseImages == true)
    #expect(image.buildTimeout == .seconds(180))
}

@Test func imageFromDockerfile_conformsToHashable() {
    let image1 = ImageFromDockerfile(dockerfilePath: "Dockerfile")
        .withBuildArg("A", "1")
    let image2 = ImageFromDockerfile(dockerfilePath: "Dockerfile")
        .withBuildArg("A", "1")
    let image3 = ImageFromDockerfile(dockerfilePath: "Dockerfile.different")
        .withBuildArg("A", "1")

    #expect(image1 == image2)
    #expect(image1 != image3)
}

@Test func imageFromDockerfile_hashableWithDifferentBuildArgs() {
    let image1 = ImageFromDockerfile()
        .withBuildArg("KEY", "value1")
    let image2 = ImageFromDockerfile()
        .withBuildArg("KEY", "value2")

    #expect(image1 != image2)
}

@Test func imageFromDockerfile_hashableWithDifferentTargetStage() {
    let image1 = ImageFromDockerfile()
        .withTargetStage("builder")
    let image2 = ImageFromDockerfile()
        .withTargetStage("runtime")

    #expect(image1 != image2)
}

@Test func imageFromDockerfile_canBeUsedAsSetElement() {
    let image1 = ImageFromDockerfile(dockerfilePath: "A")
    let image2 = ImageFromDockerfile(dockerfilePath: "B")
    let image3 = ImageFromDockerfile(dockerfilePath: "A")

    var set: Set<ImageFromDockerfile> = []
    set.insert(image1)
    set.insert(image2)
    set.insert(image3)

    #expect(set.count == 2)
}

@Test func imageFromDockerfile_canBeUsedAsDictionaryKey() {
    let image = ImageFromDockerfile(dockerfilePath: "test/Dockerfile")

    var dict: [ImageFromDockerfile: String] = [:]
    dict[image] = "test"

    #expect(dict[image] == "test")
}
