import Testing
@testable import TestContainers

// MARK: - NetworkRequest Default Tests

@Test func networkRequest_defaultValues() {
    let request = NetworkRequest()

    #expect(request.name == nil)
    #expect(request.driver == .bridge)
    #expect(request.options == [:])
    #expect(request.labels["testcontainers.swift"] == "true")
    #expect(request.ipamConfig == nil)
    #expect(request.enableIPv6 == false)
    #expect(request.internal == false)
    #expect(request.attachable == false)
}

// MARK: - NetworkRequest Builder Tests

@Test func networkRequest_withName_setsName() {
    let request = NetworkRequest()
        .withName("test-network")

    #expect(request.name == "test-network")
}

@Test func networkRequest_withDriver_setsDriver() {
    let request = NetworkRequest()
        .withDriver(.overlay)

    #expect(request.driver == .overlay)
}

@Test func networkRequest_withOption_addsOption() {
    let request = NetworkRequest()
        .withOption("com.docker.network.driver.mtu", "1500")

    #expect(request.options["com.docker.network.driver.mtu"] == "1500")
}

@Test func networkRequest_withOption_multipleOptions() {
    let request = NetworkRequest()
        .withOption("com.docker.network.driver.mtu", "1500")
        .withOption("com.docker.network.bridge.name", "test-br0")

    #expect(request.options.count == 2)
    #expect(request.options["com.docker.network.driver.mtu"] == "1500")
    #expect(request.options["com.docker.network.bridge.name"] == "test-br0")
}

@Test func networkRequest_withLabel_addsLabel() {
    let request = NetworkRequest()
        .withLabel("env", "test")

    #expect(request.labels["env"] == "test")
    #expect(request.labels["testcontainers.swift"] == "true")
}

@Test func networkRequest_withLabel_multipleLabels() {
    let request = NetworkRequest()
        .withLabel("env", "test")
        .withLabel("team", "backend")

    #expect(request.labels["env"] == "test")
    #expect(request.labels["team"] == "backend")
    #expect(request.labels["testcontainers.swift"] == "true")
}

@Test func networkRequest_withIPAM_setsConfig() {
    let request = NetworkRequest()
        .withIPAM(IPAMConfig(
            subnet: "172.20.0.0/16",
            gateway: "172.20.0.1"
        ))

    #expect(request.ipamConfig?.subnet == "172.20.0.0/16")
    #expect(request.ipamConfig?.gateway == "172.20.0.1")
    #expect(request.ipamConfig?.ipRange == nil)
}

@Test func networkRequest_withIPAM_fullConfig() {
    let request = NetworkRequest()
        .withIPAM(IPAMConfig(
            subnet: "172.20.0.0/16",
            gateway: "172.20.0.1",
            ipRange: "172.20.10.0/24"
        ))

    #expect(request.ipamConfig?.subnet == "172.20.0.0/16")
    #expect(request.ipamConfig?.gateway == "172.20.0.1")
    #expect(request.ipamConfig?.ipRange == "172.20.10.0/24")
}

@Test func networkRequest_withIPv6_setsFlag() {
    let request = NetworkRequest()
        .withIPv6(true)

    #expect(request.enableIPv6 == true)
}

@Test func networkRequest_asInternal_setsFlag() {
    let request = NetworkRequest()
        .asInternal(true)

    #expect(request.internal == true)
}

@Test func networkRequest_asAttachable_setsFlag() {
    let request = NetworkRequest()
        .asAttachable(true)

    #expect(request.attachable == true)
}

// MARK: - NetworkRequest Builder Chaining

@Test func networkRequest_chainingPreservesAllValues() {
    let request = NetworkRequest()
        .withName("full-network")
        .withDriver(.bridge)
        .withOption("com.docker.network.driver.mtu", "1500")
        .withLabel("env", "test")
        .withIPAM(IPAMConfig(subnet: "172.20.0.0/16"))
        .withIPv6(true)
        .asInternal(true)
        .asAttachable(true)

    #expect(request.name == "full-network")
    #expect(request.driver == .bridge)
    #expect(request.options["com.docker.network.driver.mtu"] == "1500")
    #expect(request.labels["env"] == "test")
    #expect(request.ipamConfig?.subnet == "172.20.0.0/16")
    #expect(request.enableIPv6 == true)
    #expect(request.internal == true)
    #expect(request.attachable == true)
}

@Test func networkRequest_returnsNewInstance() {
    let original = NetworkRequest()
    let modified = original.withName("modified")

    #expect(original.name == nil)
    #expect(modified.name == "modified")
}

// MARK: - NetworkRequest Hashable Tests

@Test func networkRequest_isHashable() {
    let req1 = NetworkRequest().withName("net1")
    let req2 = NetworkRequest().withName("net1")
    let req3 = NetworkRequest().withName("net2")

    #expect(req1 == req2)
    #expect(req1 != req3)
}

@Test func networkRequest_hashable_considersDriver() {
    let req1 = NetworkRequest().withDriver(.bridge)
    let req2 = NetworkRequest().withDriver(.overlay)

    #expect(req1 != req2)
}

// MARK: - NetworkDriver Tests

@Test func networkDriver_rawValues() {
    #expect(NetworkDriver.bridge.rawValue == "bridge")
    #expect(NetworkDriver.host.rawValue == "host")
    #expect(NetworkDriver.overlay.rawValue == "overlay")
    #expect(NetworkDriver.macvlan.rawValue == "macvlan")
    #expect(NetworkDriver.none.rawValue == "none")
}

// MARK: - IPAMConfig Tests

@Test func ipamConfig_defaultsToNil() {
    let config = IPAMConfig()

    #expect(config.subnet == nil)
    #expect(config.gateway == nil)
    #expect(config.ipRange == nil)
}

@Test func ipamConfig_isHashable() {
    let config1 = IPAMConfig(subnet: "172.20.0.0/16")
    let config2 = IPAMConfig(subnet: "172.20.0.0/16")
    let config3 = IPAMConfig(subnet: "10.0.0.0/8")

    #expect(config1 == config2)
    #expect(config1 != config3)
}
