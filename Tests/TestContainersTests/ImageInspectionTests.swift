import Foundation
import Testing
@testable import TestContainers

// MARK: - JSON Parsing Tests

@Test func imageInspection_parsesFullRedisImage() throws {
    let json = """
    [{
        "Id": "sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        "RepoTags": ["redis:7-alpine", "redis:latest"],
        "RepoDigests": ["redis@sha256:abcd1234"],
        "Created": "2024-12-10T15:30:45.123456789Z",
        "Size": 31457280,
        "Architecture": "amd64",
        "Os": "linux",
        "Author": "",
        "Config": {
            "Hostname": "",
            "Domainname": "",
            "User": "redis",
            "Env": [
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "REDIS_VERSION=7.2.3"
            ],
            "Cmd": ["redis-server"],
            "Image": "",
            "Volumes": {
                "/data": {}
            },
            "WorkingDir": "/data",
            "Entrypoint": ["docker-entrypoint.sh"],
            "OnBuild": null,
            "Labels": {
                "maintainer": "Redis Docker Team",
                "org.opencontainers.image.version": "7.2.3"
            },
            "ExposedPorts": {
                "6379/tcp": {}
            }
        },
        "RootFS": {
            "Type": "layers",
            "Layers": [
                "sha256:layer1abc",
                "sha256:layer2def"
            ]
        }
    }]
    """

    let inspection = try ImageInspection.parse(from: json)

    #expect(inspection.id == "sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef")
    #expect(inspection.repoTags == ["redis:7-alpine", "redis:latest"])
    #expect(inspection.repoDigests == ["redis@sha256:abcd1234"])
    #expect(inspection.size == 31457280)
    #expect(inspection.architecture == "amd64")
    #expect(inspection.os == "linux")
    #expect(inspection.author == "")

    // Config checks
    #expect(inspection.config.user == "redis")
    #expect(inspection.config.workingDir == "/data")
    #expect(inspection.config.cmd == ["redis-server"])
    #expect(inspection.config.entrypoint == ["docker-entrypoint.sh"])
    #expect(inspection.config.env.contains("REDIS_VERSION=7.2.3"))
    #expect(inspection.config.exposedPorts.keys.contains("6379/tcp"))
    #expect(inspection.config.labels["org.opencontainers.image.version"] == "7.2.3")
    #expect(inspection.config.volumes.contains("/data"))

    // RootFS checks
    #expect(inspection.rootFS.type == "layers")
    #expect(inspection.rootFS.layers.count == 2)
}

@Test func imageInspection_parsesMinimalAlpineImage() throws {
    let json = """
    [{
        "Id": "sha256:minimal123",
        "RepoTags": ["alpine:3"],
        "RepoDigests": [],
        "Created": "2024-12-15T00:00:00Z",
        "Size": 7123456,
        "Architecture": "arm64",
        "Os": "linux",
        "Author": "",
        "Config": {
            "Env": ["PATH=/bin"],
            "Cmd": ["/bin/sh"],
            "WorkingDir": "/",
            "User": "",
            "Labels": null,
            "ExposedPorts": null,
            "Volumes": null,
            "Entrypoint": null,
            "OnBuild": null
        },
        "RootFS": {
            "Type": "layers",
            "Layers": ["sha256:singlelayer"]
        }
    }]
    """

    let inspection = try ImageInspection.parse(from: json)

    #expect(inspection.architecture == "arm64")
    #expect(inspection.config.cmd == ["/bin/sh"])
    #expect(inspection.config.entrypoint == nil)
    #expect(inspection.config.exposedPorts.isEmpty)
    #expect(inspection.config.volumes.isEmpty)
    #expect(inspection.config.labels.isEmpty)
}

@Test func imageInspection_parsesCreatedDate() throws {
    let json = """
    [{
        "Id": "sha256:datetest",
        "RepoTags": ["test:1"],
        "RepoDigests": [],
        "Created": "2024-12-10T15:30:45.123456789Z",
        "Size": 100,
        "Architecture": "amd64",
        "Os": "linux",
        "Author": "",
        "Config": {
            "Env": [],
            "Cmd": null,
            "WorkingDir": "",
            "User": "",
            "Labels": null,
            "ExposedPorts": null,
            "Volumes": null,
            "Entrypoint": null,
            "OnBuild": null
        },
        "RootFS": {
            "Type": "layers",
            "Layers": []
        }
    }]
    """

    let inspection = try ImageInspection.parse(from: json)
    // Just verify it parses without error - exact Date comparison is fragile
    #expect(inspection.created.timeIntervalSince1970 > 0)
}

@Test func imageInspection_throwsOnEmptyArray() {
    let json = "[]"
    #expect(throws: TestContainersError.self) {
        try ImageInspection.parse(from: json)
    }
}

@Test func imageInspection_throwsOnInvalidJSON() {
    let json = "not json"
    #expect(throws: (any Error).self) {
        try ImageInspection.parse(from: json)
    }
}

@Test func imageInspection_exposedPortNumbers() throws {
    let json = """
    [{
        "Id": "sha256:ports",
        "RepoTags": ["multi:1"],
        "RepoDigests": [],
        "Created": "2024-12-10T00:00:00Z",
        "Size": 100,
        "Architecture": "amd64",
        "Os": "linux",
        "Author": "",
        "Config": {
            "Env": [],
            "Cmd": null,
            "WorkingDir": "",
            "User": "",
            "Labels": null,
            "ExposedPorts": {
                "6379/tcp": {},
                "8080/tcp": {},
                "9090/udp": {}
            },
            "Volumes": null,
            "Entrypoint": null,
            "OnBuild": null
        },
        "RootFS": {
            "Type": "layers",
            "Layers": []
        }
    }]
    """

    let inspection = try ImageInspection.parse(from: json)
    let portNumbers = inspection.config.exposedPortNumbers()

    #expect(portNumbers.contains(6379))
    #expect(portNumbers.contains(8080))
    #expect(portNumbers.contains(9090))
    #expect(portNumbers.count == 3)
}

@Test func imageInspection_environmentDictionary() throws {
    let json = """
    [{
        "Id": "sha256:envtest",
        "RepoTags": ["env:1"],
        "RepoDigests": [],
        "Created": "2024-12-10T00:00:00Z",
        "Size": 100,
        "Architecture": "amd64",
        "Os": "linux",
        "Author": "",
        "Config": {
            "Env": [
                "PATH=/usr/bin",
                "REDIS_VERSION=7.2.3",
                "COMPLEX=value=with=equals"
            ],
            "Cmd": null,
            "WorkingDir": "",
            "User": "",
            "Labels": null,
            "ExposedPorts": null,
            "Volumes": null,
            "Entrypoint": null,
            "OnBuild": null
        },
        "RootFS": {
            "Type": "layers",
            "Layers": []
        }
    }]
    """

    let inspection = try ImageInspection.parse(from: json)
    let envDict = inspection.config.environmentDictionary()

    #expect(envDict["PATH"] == "/usr/bin")
    #expect(envDict["REDIS_VERSION"] == "7.2.3")
    #expect(envDict["COMPLEX"] == "value=with=equals")
}

@Test func imageInspection_isSendable() {
    // Compile-time check: these assignments verify Sendable conformance
    func requireSendable<T: Sendable>(_: T.Type) {}
    requireSendable(ImageInspection.self)
    requireSendable(ImageConfig.self)
    requireSendable(ImageRootFS.self)
}
