import Foundation
import Testing
@testable import TestContainers

// MARK: - JSON Parsing Unit Tests

@Test func parsesRunningContainerInspection() throws {
    let json = """
    [{
        "Id": "abc123def456",
        "Created": "2025-12-15T10:56:24.952960502Z",
        "Name": "/test-container",
        "State": {
            "Status": "running",
            "Running": true,
            "Paused": false,
            "Restarting": false,
            "OOMKilled": false,
            "Dead": false,
            "Pid": 12345,
            "ExitCode": 0,
            "Error": "",
            "StartedAt": "2025-12-15T10:56:25.049568794Z",
            "FinishedAt": "0001-01-01T00:00:00Z"
        },
        "Config": {
            "Hostname": "abc123",
            "User": "",
            "Env": ["PATH=/usr/bin", "REDIS_VERSION=7.0"],
            "Cmd": ["redis-server"],
            "Image": "redis:7",
            "WorkingDir": "/data",
            "Entrypoint": ["docker-entrypoint.sh"],
            "Labels": {"app": "test", "version": "1.0"}
        },
        "NetworkSettings": {
            "Bridge": "",
            "SandboxID": "sandbox123",
            "Ports": {
                "6379/tcp": [
                    {"HostIp": "0.0.0.0", "HostPort": "32768"}
                ]
            },
            "IPAddress": "172.17.0.2",
            "Gateway": "172.17.0.1",
            "MacAddress": "02:42:ac:11:00:02",
            "Networks": {
                "bridge": {
                    "NetworkID": "net123",
                    "EndpointID": "ep123",
                    "Gateway": "172.17.0.1",
                    "IPAddress": "172.17.0.2",
                    "IPPrefixLen": 16,
                    "MacAddress": "02:42:ac:11:00:02",
                    "Aliases": null
                }
            }
        }
    }]
    """

    let inspection = try ContainerInspection.parse(from: json)

    #expect(inspection.id == "abc123def456")
    #expect(inspection.name == "/test-container")

    // State checks
    #expect(inspection.state.status == .running)
    #expect(inspection.state.running == true)
    #expect(inspection.state.paused == false)
    #expect(inspection.state.restarting == false)
    #expect(inspection.state.oomKilled == false)
    #expect(inspection.state.dead == false)
    #expect(inspection.state.pid == 12345)
    #expect(inspection.state.exitCode == 0)
    #expect(inspection.state.error == "")
    #expect(inspection.state.startedAt != nil)
    #expect(inspection.state.finishedAt == nil) // Zero date should be nil
    #expect(inspection.state.health == nil)

    // Config checks
    #expect(inspection.config.hostname == "abc123")
    #expect(inspection.config.user == "")
    #expect(inspection.config.env.contains("PATH=/usr/bin"))
    #expect(inspection.config.env.contains("REDIS_VERSION=7.0"))
    #expect(inspection.config.cmd == ["redis-server"])
    #expect(inspection.config.image == "redis:7")
    #expect(inspection.config.workingDir == "/data")
    #expect(inspection.config.entrypoint == ["docker-entrypoint.sh"])
    #expect(inspection.config.labels["app"] == "test")
    #expect(inspection.config.labels["version"] == "1.0")

    // Network checks
    #expect(inspection.networkSettings.bridge == "")
    #expect(inspection.networkSettings.sandboxID == "sandbox123")
    #expect(inspection.networkSettings.ipAddress == "172.17.0.2")
    #expect(inspection.networkSettings.gateway == "172.17.0.1")
    #expect(inspection.networkSettings.macAddress == "02:42:ac:11:00:02")

    // Port bindings
    #expect(inspection.networkSettings.ports.count == 1)
    let portBinding = try #require(inspection.networkSettings.ports.first)
    #expect(portBinding.containerPort == 6379)
    #expect(portBinding.protocol == "tcp")
    #expect(portBinding.hostIP == "0.0.0.0")
    #expect(portBinding.hostPort == 32768)

    // Networks
    let bridgeNetwork = try #require(inspection.networkSettings.networks["bridge"])
    #expect(bridgeNetwork.networkID == "net123")
    #expect(bridgeNetwork.endpointID == "ep123")
    #expect(bridgeNetwork.gateway == "172.17.0.1")
    #expect(bridgeNetwork.ipAddress == "172.17.0.2")
    #expect(bridgeNetwork.ipPrefixLen == 16)
    #expect(bridgeNetwork.macAddress == "02:42:ac:11:00:02")
}

@Test func parsesStoppedContainerInspection() throws {
    let json = """
    [{
        "Id": "stopped123",
        "Created": "2025-12-15T10:00:00Z",
        "Name": "/stopped-container",
        "State": {
            "Status": "exited",
            "Running": false,
            "Paused": false,
            "Restarting": false,
            "OOMKilled": false,
            "Dead": false,
            "Pid": 0,
            "ExitCode": 1,
            "Error": "process exited with code 1",
            "StartedAt": "2025-12-15T10:00:01Z",
            "FinishedAt": "2025-12-15T10:00:10Z"
        },
        "Config": {
            "Hostname": "stopped123",
            "User": "root",
            "Env": [],
            "Cmd": ["exit", "1"],
            "Image": "alpine:3",
            "WorkingDir": "",
            "Entrypoint": null,
            "Labels": {}
        },
        "NetworkSettings": {
            "Bridge": "",
            "SandboxID": "",
            "Ports": {},
            "IPAddress": "",
            "Gateway": "",
            "MacAddress": "",
            "Networks": {}
        }
    }]
    """

    let inspection = try ContainerInspection.parse(from: json)

    #expect(inspection.state.status == .exited)
    #expect(inspection.state.running == false)
    #expect(inspection.state.pid == 0)
    #expect(inspection.state.exitCode == 1)
    #expect(inspection.state.error == "process exited with code 1")
    #expect(inspection.state.startedAt != nil)
    #expect(inspection.state.finishedAt != nil)

    #expect(inspection.config.entrypoint.isEmpty)
    #expect(inspection.config.labels.isEmpty)
}

@Test func parsesContainerWithHealth() throws {
    let json = """
    [{
        "Id": "healthy123",
        "Created": "2025-12-15T10:00:00Z",
        "Name": "/healthy-container",
        "State": {
            "Status": "running",
            "Running": true,
            "Paused": false,
            "Restarting": false,
            "OOMKilled": false,
            "Dead": false,
            "Pid": 5678,
            "ExitCode": 0,
            "Error": "",
            "StartedAt": "2025-12-15T10:00:01Z",
            "FinishedAt": "0001-01-01T00:00:00Z",
            "Health": {
                "Status": "healthy",
                "FailingStreak": 0,
                "Log": [
                    {
                        "Start": "2025-12-15T10:00:05Z",
                        "End": "2025-12-15T10:00:05.5Z",
                        "ExitCode": 0,
                        "Output": "OK"
                    }
                ]
            }
        },
        "Config": {
            "Hostname": "healthy123",
            "User": "",
            "Env": [],
            "Cmd": ["server"],
            "Image": "healthcheck:latest",
            "WorkingDir": "/app",
            "Entrypoint": [],
            "Labels": {}
        },
        "NetworkSettings": {
            "Bridge": "",
            "SandboxID": "sandbox456",
            "Ports": {},
            "IPAddress": "172.17.0.5",
            "Gateway": "172.17.0.1",
            "MacAddress": "02:42:ac:11:00:05",
            "Networks": {}
        }
    }]
    """

    let inspection = try ContainerInspection.parse(from: json)

    let health = try #require(inspection.state.health)
    #expect(health.status == .healthy)
    #expect(health.failingStreak == 0)
    #expect(health.log.count == 1)

    let logEntry = try #require(health.log.first)
    #expect(logEntry.exitCode == 0)
    #expect(logEntry.output == "OK")
}

@Test func parsesContainerWithUnhealthyStatus() throws {
    let json = """
    [{
        "Id": "unhealthy123",
        "Created": "2025-12-15T10:00:00Z",
        "Name": "/unhealthy-container",
        "State": {
            "Status": "running",
            "Running": true,
            "Paused": false,
            "Restarting": false,
            "OOMKilled": false,
            "Dead": false,
            "Pid": 9999,
            "ExitCode": 0,
            "Error": "",
            "StartedAt": "2025-12-15T10:00:01Z",
            "FinishedAt": "0001-01-01T00:00:00Z",
            "Health": {
                "Status": "unhealthy",
                "FailingStreak": 3,
                "Log": []
            }
        },
        "Config": {
            "Hostname": "unhealthy123",
            "User": "",
            "Env": [],
            "Cmd": [],
            "Image": "test:latest",
            "WorkingDir": "",
            "Entrypoint": [],
            "Labels": {}
        },
        "NetworkSettings": {
            "Bridge": "",
            "SandboxID": "",
            "Ports": {},
            "IPAddress": "",
            "Gateway": "",
            "MacAddress": "",
            "Networks": {}
        }
    }]
    """

    let inspection = try ContainerInspection.parse(from: json)

    let health = try #require(inspection.state.health)
    #expect(health.status == .unhealthy)
    #expect(health.failingStreak == 3)
}

@Test func parsesContainerWithMultiplePorts() throws {
    let json = """
    [{
        "Id": "multiport123",
        "Created": "2025-12-15T10:00:00Z",
        "Name": "/multiport-container",
        "State": {
            "Status": "running",
            "Running": true,
            "Paused": false,
            "Restarting": false,
            "OOMKilled": false,
            "Dead": false,
            "Pid": 1234,
            "ExitCode": 0,
            "Error": "",
            "StartedAt": "2025-12-15T10:00:01Z",
            "FinishedAt": "0001-01-01T00:00:00Z"
        },
        "Config": {
            "Hostname": "multiport123",
            "User": "",
            "Env": [],
            "Cmd": [],
            "Image": "test:latest",
            "WorkingDir": "",
            "Entrypoint": [],
            "Labels": {}
        },
        "NetworkSettings": {
            "Bridge": "",
            "SandboxID": "sandbox789",
            "Ports": {
                "80/tcp": [
                    {"HostIp": "0.0.0.0", "HostPort": "8080"},
                    {"HostIp": "::", "HostPort": "8080"}
                ],
                "443/tcp": [
                    {"HostIp": "0.0.0.0", "HostPort": "8443"}
                ],
                "53/udp": [
                    {"HostIp": "0.0.0.0", "HostPort": "5353"}
                ]
            },
            "IPAddress": "172.17.0.10",
            "Gateway": "172.17.0.1",
            "MacAddress": "02:42:ac:11:00:10",
            "Networks": {}
        }
    }]
    """

    let inspection = try ContainerInspection.parse(from: json)

    // Should have 4 port bindings total (80 has 2 bindings)
    #expect(inspection.networkSettings.ports.count == 4)

    // Check TCP port 80
    let port80Bindings = inspection.networkSettings.ports.filter { $0.containerPort == 80 }
    #expect(port80Bindings.count == 2)
    #expect(port80Bindings.allSatisfy { $0.protocol == "tcp" })
    #expect(port80Bindings.allSatisfy { $0.hostPort == 8080 })

    // Check UDP port 53
    let port53Bindings = inspection.networkSettings.ports.filter { $0.containerPort == 53 }
    #expect(port53Bindings.count == 1)
    let udpBinding = try #require(port53Bindings.first)
    #expect(udpBinding.protocol == "udp")
    #expect(udpBinding.hostPort == 5353)
}

@Test func parsesContainerWithUnboundPorts() throws {
    let json = """
    [{
        "Id": "unbound123",
        "Created": "2025-12-15T10:00:00Z",
        "Name": "/unbound-container",
        "State": {
            "Status": "running",
            "Running": true,
            "Paused": false,
            "Restarting": false,
            "OOMKilled": false,
            "Dead": false,
            "Pid": 1111,
            "ExitCode": 0,
            "Error": "",
            "StartedAt": "2025-12-15T10:00:01Z",
            "FinishedAt": "0001-01-01T00:00:00Z"
        },
        "Config": {
            "Hostname": "unbound123",
            "User": "",
            "Env": [],
            "Cmd": [],
            "Image": "test:latest",
            "WorkingDir": "",
            "Entrypoint": [],
            "Labels": {}
        },
        "NetworkSettings": {
            "Bridge": "",
            "SandboxID": "sandbox000",
            "Ports": {
                "8080/tcp": null,
                "9090/tcp": [
                    {"HostIp": "0.0.0.0", "HostPort": "9090"}
                ]
            },
            "IPAddress": "172.17.0.11",
            "Gateway": "172.17.0.1",
            "MacAddress": "02:42:ac:11:00:11",
            "Networks": {}
        }
    }]
    """

    let inspection = try ContainerInspection.parse(from: json)

    #expect(inspection.networkSettings.ports.count == 2)

    // Unbound port should have nil hostPort
    let unboundPort = inspection.networkSettings.ports.first { $0.containerPort == 8080 }
    #expect(unboundPort != nil)
    #expect(unboundPort?.hostPort == nil)
    #expect(unboundPort?.hostIP == nil)

    // Bound port should have values
    let boundPort = inspection.networkSettings.ports.first { $0.containerPort == 9090 }
    #expect(boundPort != nil)
    #expect(boundPort?.hostPort == 9090)
}

@Test func parsesAllContainerStates() throws {
    let states = ["created", "running", "paused", "restarting", "removing", "exited", "dead"]

    for state in states {
        let json = """
        [{
            "Id": "\(state)-container",
            "Created": "2025-12-15T10:00:00Z",
            "Name": "/\(state)-container",
            "State": {
                "Status": "\(state)",
                "Running": \(state == "running"),
                "Paused": \(state == "paused"),
                "Restarting": \(state == "restarting"),
                "OOMKilled": false,
                "Dead": \(state == "dead"),
                "Pid": 0,
                "ExitCode": 0,
                "Error": "",
                "StartedAt": "0001-01-01T00:00:00Z",
                "FinishedAt": "0001-01-01T00:00:00Z"
            },
            "Config": {
                "Hostname": "test",
                "User": "",
                "Env": [],
                "Cmd": [],
                "Image": "test:latest",
                "WorkingDir": "",
                "Entrypoint": [],
                "Labels": {}
            },
            "NetworkSettings": {
                "Bridge": "",
                "SandboxID": "",
                "Ports": {},
                "IPAddress": "",
                "Gateway": "",
                "MacAddress": "",
                "Networks": {}
            }
        }]
        """

        let inspection = try ContainerInspection.parse(from: json)
        #expect(inspection.state.status.rawValue == state)
    }
}

@Test func parsesContainerWithMultipleNetworks() throws {
    let json = """
    [{
        "Id": "multinet123",
        "Created": "2025-12-15T10:00:00Z",
        "Name": "/multinet-container",
        "State": {
            "Status": "running",
            "Running": true,
            "Paused": false,
            "Restarting": false,
            "OOMKilled": false,
            "Dead": false,
            "Pid": 2222,
            "ExitCode": 0,
            "Error": "",
            "StartedAt": "2025-12-15T10:00:01Z",
            "FinishedAt": "0001-01-01T00:00:00Z"
        },
        "Config": {
            "Hostname": "multinet123",
            "User": "",
            "Env": [],
            "Cmd": [],
            "Image": "test:latest",
            "WorkingDir": "",
            "Entrypoint": [],
            "Labels": {}
        },
        "NetworkSettings": {
            "Bridge": "",
            "SandboxID": "sandbox-multi",
            "Ports": {},
            "IPAddress": "172.17.0.20",
            "Gateway": "172.17.0.1",
            "MacAddress": "02:42:ac:11:00:20",
            "Networks": {
                "bridge": {
                    "NetworkID": "bridge-net-id",
                    "EndpointID": "bridge-ep-id",
                    "Gateway": "172.17.0.1",
                    "IPAddress": "172.17.0.20",
                    "IPPrefixLen": 16,
                    "MacAddress": "02:42:ac:11:00:20",
                    "Aliases": ["alias1", "alias2"]
                },
                "custom-network": {
                    "NetworkID": "custom-net-id",
                    "EndpointID": "custom-ep-id",
                    "Gateway": "10.0.0.1",
                    "IPAddress": "10.0.0.5",
                    "IPPrefixLen": 24,
                    "MacAddress": "02:42:0a:00:00:05",
                    "Aliases": ["myalias"]
                }
            }
        }
    }]
    """

    let inspection = try ContainerInspection.parse(from: json)

    #expect(inspection.networkSettings.networks.count == 2)

    let bridgeNet = try #require(inspection.networkSettings.networks["bridge"])
    #expect(bridgeNet.ipAddress == "172.17.0.20")
    #expect(bridgeNet.aliases == ["alias1", "alias2"])

    let customNet = try #require(inspection.networkSettings.networks["custom-network"])
    #expect(customNet.ipAddress == "10.0.0.5")
    #expect(customNet.ipPrefixLen == 24)
    #expect(customNet.aliases == ["myalias"])
}

@Test func parsesContainerCreatedTimestamp() throws {
    let json = """
    [{
        "Id": "timestamp123",
        "Created": "2025-12-15T14:30:45.123456789Z",
        "Name": "/timestamp-container",
        "State": {
            "Status": "running",
            "Running": true,
            "Paused": false,
            "Restarting": false,
            "OOMKilled": false,
            "Dead": false,
            "Pid": 3333,
            "ExitCode": 0,
            "Error": "",
            "StartedAt": "2025-12-15T14:30:46Z",
            "FinishedAt": "0001-01-01T00:00:00Z"
        },
        "Config": {
            "Hostname": "timestamp123",
            "User": "",
            "Env": [],
            "Cmd": [],
            "Image": "test:latest",
            "WorkingDir": "",
            "Entrypoint": [],
            "Labels": {}
        },
        "NetworkSettings": {
            "Bridge": "",
            "SandboxID": "",
            "Ports": {},
            "IPAddress": "",
            "Gateway": "",
            "MacAddress": "",
            "Networks": {}
        }
    }]
    """

    let inspection = try ContainerInspection.parse(from: json)

    // Created should be a valid date in December 2025
    let calendar = Calendar(identifier: .gregorian)
    let components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: inspection.created)
    #expect(components.year == 2025)
    #expect(components.month == 12)
    #expect(components.day == 15)
    #expect(components.hour == 14)
    #expect(components.minute == 30)
}

@Test func failsOnEmptyArray() throws {
    let json = "[]"

    #expect(throws: TestContainersError.self) {
        try ContainerInspection.parse(from: json)
    }
}

@Test func failsOnInvalidJson() throws {
    let json = "not valid json"

    #expect(throws: Error.self) {
        try ContainerInspection.parse(from: json)
    }
}

// MARK: - Integration Tests

@Test func canInspectRunningContainer_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "redis:7-alpine")
        .withExposedPort(6379)
        .withEnvironment(["CUSTOM_VAR": "test-value"])
        .withLabel("test-label", "label-value")
        .waitingFor(.tcpPort(6379, timeout: .seconds(30)))

    try await withContainer(request) { container in
        let inspection = try await container.inspect()

        // Verify state
        #expect(inspection.state.status == .running)
        #expect(inspection.state.running == true)
        #expect(inspection.state.paused == false)
        #expect(inspection.state.pid > 0)
        #expect(inspection.state.exitCode == 0)

        // Verify config
        #expect(inspection.config.image == "redis:7-alpine")
        #expect(inspection.config.env.contains("CUSTOM_VAR=test-value"))
        #expect(inspection.config.labels["test-label"] == "label-value")

        // Verify network - IP may be empty on Docker Desktop for macOS
        // but network settings should be present
        #expect(!inspection.networkSettings.networks.isEmpty)

        // Verify ports - should have at least one binding for 6379
        let redisPort = inspection.networkSettings.ports.first { $0.containerPort == 6379 }
        #expect(redisPort != nil)
        #expect(redisPort?.protocol == "tcp")
        #expect(redisPort?.hostPort != nil)

        // Cross-check with existing hostPort API
        let hostPort = try await container.hostPort(6379)
        #expect(redisPort?.hostPort == hostPort)
    }
}

@Test func canInspectContainerWithoutHealthCheck_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "sleep 10"])

    try await withContainer(request) { container in
        let inspection = try await container.inspect()

        // Alpine without healthcheck should have no health status
        #expect(inspection.state.health == nil)
        #expect(inspection.state.status == .running)
    }
}

@Test func canInspectContainerWithHealthCheck_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sh", "-c", "touch /tmp/healthy && sleep 60"])
        .withHealthCheck(command: ["test", "-f", "/tmp/healthy"], interval: .seconds(1))
        .waitingFor(.healthCheck(timeout: .seconds(30)))

    try await withContainer(request) { container in
        let inspection = try await container.inspect()

        // Should have health status after waiting
        let health = try #require(inspection.state.health)
        #expect(health.status == .healthy)
        #expect(health.failingStreak == 0)
    }
}

@Test func inspectReturnsContainerName_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let containerName = "test-inspect-\(UUID().uuidString.prefix(8))"
    let request = ContainerRequest(image: "alpine:3")
        .withName(containerName)
        .withCommand(["sleep", "10"])

    try await withContainer(request) { container in
        let inspection = try await container.inspect()

        // Docker prefixes names with /
        #expect(inspection.name == "/\(containerName)")
    }
}

@Test func inspectReturnsMultipleEnvVars_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withEnvironment([
            "VAR1": "value1",
            "VAR2": "value2",
            "VAR3": "value3"
        ])
        .withCommand(["sleep", "10"])

    try await withContainer(request) { container in
        let inspection = try await container.inspect()

        #expect(inspection.config.env.contains("VAR1=value1"))
        #expect(inspection.config.env.contains("VAR2=value2"))
        #expect(inspection.config.env.contains("VAR3=value3"))
    }
}

@Test func inspectReturnsMultipleLabels_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let request = ContainerRequest(image: "alpine:3")
        .withLabel("app", "myapp")
        .withLabel("env", "test")
        .withLabel("version", "1.2.3")
        .withCommand(["sleep", "10"])

    try await withContainer(request) { container in
        let inspection = try await container.inspect()

        #expect(inspection.config.labels["app"] == "myapp")
        #expect(inspection.config.labels["env"] == "test")
        #expect(inspection.config.labels["version"] == "1.2.3")
    }
}

@Test func inspectReturnsCreatedTimestamp_whenOptedIn() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let beforeCreate = Date()

    let request = ContainerRequest(image: "alpine:3")
        .withCommand(["sleep", "10"])

    try await withContainer(request) { container in
        let inspection = try await container.inspect()
        let afterCreate = Date()

        // Created time should be between before and after
        #expect(inspection.created >= beforeCreate)
        #expect(inspection.created <= afterCreate)
    }
}
