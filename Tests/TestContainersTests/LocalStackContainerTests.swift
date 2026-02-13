import Foundation
import Testing
@testable import TestContainers

// MARK: - AWSService Tests

@Test func awsService_rawValues() {
    #expect(AWSService.s3.rawValue == "s3")
    #expect(AWSService.sqs.rawValue == "sqs")
    #expect(AWSService.dynamodb.rawValue == "dynamodb")
    #expect(AWSService.sns.rawValue == "sns")
    #expect(AWSService.lambda.rawValue == "lambda")
    #expect(AWSService.cloudwatch.rawValue == "cloudwatch")
    #expect(AWSService.cloudformation.rawValue == "cloudformation")
    #expect(AWSService.apigateway.rawValue == "apigateway")
    #expect(AWSService.kinesis.rawValue == "kinesis")
    #expect(AWSService.secretsmanager.rawValue == "secretsmanager")
    #expect(AWSService.ssm.rawValue == "ssm")
    #expect(AWSService.stepfunctions.rawValue == "stepfunctions")
    #expect(AWSService.eventbridge.rawValue == "eventbridge")
    #expect(AWSService.iam.rawValue == "iam")
    #expect(AWSService.sts.rawValue == "sts")
    #expect(AWSService.kms.rawValue == "kms")
}

@Test func awsService_serviceName() {
    #expect(AWSService.s3.serviceName == "s3")
    #expect(AWSService.dynamodb.serviceName == "dynamodb")
}

@Test func awsService_isHashable() {
    let set: Set<AWSService> = [.s3, .sqs, .s3]
    #expect(set.count == 2)
}

// MARK: - LocalStackContainer Default Values

@Test func localStack_defaultValues() {
    let ls = LocalStackContainer()

    #expect(ls.image == "localstack/localstack:3.4")
    #expect(ls.services == nil)
    #expect(ls.region == "us-east-1")
    #expect(ls.port == 4566)
    #expect(ls.environment.isEmpty)
    #expect(ls.timeout == .seconds(60))
    #expect(ls.host == "127.0.0.1")
}

@Test func localStack_defaultConstants() {
    #expect(LocalStackContainer.defaultImage == "localstack/localstack:3.4")
    #expect(LocalStackContainer.defaultPort == 4566)
    #expect(LocalStackContainer.defaultRegion == "us-east-1")
}

// MARK: - Builder Methods

@Test func localStack_withImage() {
    let ls = LocalStackContainer()
        .withImage("localstack/localstack:2.3.0")

    #expect(ls.image == "localstack/localstack:2.3.0")
}

@Test func localStack_withServices() {
    let ls = LocalStackContainer()
        .withServices([.s3, .sqs, .dynamodb])

    #expect(ls.services == [.s3, .sqs, .dynamodb])
}

@Test func localStack_withService() {
    let ls = LocalStackContainer()
        .withService(.s3)
        .withService(.sqs)

    #expect(ls.services == [.s3, .sqs])
}

@Test func localStack_withRegion() {
    let ls = LocalStackContainer()
        .withRegion("eu-west-1")

    #expect(ls.region == "eu-west-1")
}

@Test func localStack_withEnvironment() {
    let ls = LocalStackContainer()
        .withEnvironment(["DEBUG": "1"])

    #expect(ls.environment["DEBUG"] == "1")
}

@Test func localStack_withTimeout() {
    let ls = LocalStackContainer()
        .withTimeout(.seconds(90))

    #expect(ls.timeout == .seconds(90))
}

@Test func localStack_withHost() {
    let ls = LocalStackContainer()
        .withHost("localhost")

    #expect(ls.host == "localhost")
}

@Test func localStack_waitingFor() {
    let ls = LocalStackContainer()
        .waitingFor(.tcpPort(4566, timeout: .seconds(30)))

    #expect(ls.waitStrategy != nil)
}

// MARK: - Builder Immutability

@Test func localStack_builderReturnsNewInstance() {
    let original = LocalStackContainer()
    let modified = original.withRegion("ap-south-1")

    #expect(original.region == "us-east-1")
    #expect(modified.region == "ap-south-1")
}

@Test func localStack_withServiceDoesNotMutateOriginal() {
    let original = LocalStackContainer()
    let modified = original.withService(.s3)

    #expect(original.services == nil)
    #expect(modified.services == [.s3])
}

// MARK: - Hashable

@Test func localStack_isHashable() {
    let ls1 = LocalStackContainer().withServices([.s3])
    let ls2 = LocalStackContainer().withServices([.s3])
    let ls3 = LocalStackContainer().withServices([.sqs])

    #expect(ls1 == ls2)
    #expect(ls1 != ls3)
}

// MARK: - Method Chaining

@Test func localStack_methodChaining() {
    let ls = LocalStackContainer(image: "localstack/localstack:2.3.0")
        .withServices([.s3, .sqs])
        .withRegion("eu-west-1")
        .withEnvironment(["DEBUG": "1"])
        .withTimeout(.seconds(120))
        .withHost("localhost")

    #expect(ls.image == "localstack/localstack:2.3.0")
    #expect(ls.services == [.s3, .sqs])
    #expect(ls.region == "eu-west-1")
    #expect(ls.environment["DEBUG"] == "1")
    #expect(ls.timeout == .seconds(120))
    #expect(ls.host == "localhost")
}

// MARK: - toContainerRequest Tests

@Test func localStack_toContainerRequest_setsImage() {
    let ls = LocalStackContainer(image: "localstack/localstack:2.3.0")

    let request = ls.toContainerRequest()

    #expect(request.image == "localstack/localstack:2.3.0")
}

@Test func localStack_toContainerRequest_setsPort() {
    let ls = LocalStackContainer()

    let request = ls.toContainerRequest()

    #expect(request.ports.contains { $0.containerPort == 4566 })
}

@Test func localStack_toContainerRequest_setsRegionEnv() {
    let ls = LocalStackContainer()
        .withRegion("us-west-2")

    let request = ls.toContainerRequest()

    #expect(request.environment["DEFAULT_REGION"] == "us-west-2")
}

@Test func localStack_toContainerRequest_setsDefaultRegionEnv() {
    let ls = LocalStackContainer()

    let request = ls.toContainerRequest()

    #expect(request.environment["DEFAULT_REGION"] == "us-east-1")
}

@Test func localStack_toContainerRequest_setsServicesEnv() {
    let ls = LocalStackContainer()
        .withServices([.s3, .sqs])

    let request = ls.toContainerRequest()

    let services = request.environment["SERVICES"]
    #expect(services != nil)
    #expect(services!.contains("s3"))
    #expect(services!.contains("sqs"))
}

@Test func localStack_toContainerRequest_servicesSortedAlpha() {
    let ls = LocalStackContainer()
        .withServices([.sqs, .dynamodb, .s3])

    let request = ls.toContainerRequest()

    #expect(request.environment["SERVICES"] == "dynamodb,s3,sqs")
}

@Test func localStack_toContainerRequest_noServicesEnvWhenNil() {
    let ls = LocalStackContainer()

    let request = ls.toContainerRequest()

    #expect(request.environment["SERVICES"] == nil)
}

@Test func localStack_toContainerRequest_setsLocalhostHost() {
    let ls = LocalStackContainer()

    let request = ls.toContainerRequest()

    #expect(request.environment["LOCALSTACK_HOST"] != nil)
}

@Test func localStack_toContainerRequest_setsModuleLabel() {
    let ls = LocalStackContainer()

    let request = ls.toContainerRequest()

    #expect(request.labels["testcontainers.module"] == "localstack")
}

@Test func localStack_toContainerRequest_setsHttpWaitStrategy() {
    let ls = LocalStackContainer()

    let request = ls.toContainerRequest()

    if case let .http(config) = request.waitStrategy {
        #expect(config.port == 4566)
        #expect(config.path == "/_localstack/health")
    } else {
        Issue.record("Expected .http wait strategy, got \(request.waitStrategy)")
    }
}

@Test func localStack_toContainerRequest_customWaitStrategy() {
    let ls = LocalStackContainer()
        .waitingFor(.tcpPort(4566, timeout: .seconds(30)))

    let request = ls.toContainerRequest()

    if case let .tcpPort(port, timeout, _) = request.waitStrategy {
        #expect(port == 4566)
        #expect(timeout == .seconds(30))
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

@Test func localStack_toContainerRequest_customEnvironment() {
    let ls = LocalStackContainer()
        .withEnvironment(["DEBUG": "1", "CUSTOM_VAR": "value"])

    let request = ls.toContainerRequest()

    #expect(request.environment["DEBUG"] == "1")
    #expect(request.environment["CUSTOM_VAR"] == "value")
    // Standard env vars should still be present
    #expect(request.environment["DEFAULT_REGION"] == "us-east-1")
}

@Test func localStack_toContainerRequest_setsHost() {
    let ls = LocalStackContainer()
        .withHost("localhost")

    let request = ls.toContainerRequest()

    #expect(request.host == "localhost")
}

@Test func localStack_toContainerRequest_persistenceAddsVolume() {
    let ls = LocalStackContainer()
        .withPersistence(true)

    let request = ls.toContainerRequest()

    #expect(request.volumes.contains { $0.containerPath == "/var/lib/localstack" })
}

@Test func localStack_toContainerRequest_noPersistenceNoVolume() {
    let ls = LocalStackContainer()

    let request = ls.toContainerRequest()

    #expect(!request.volumes.contains { $0.containerPath == "/var/lib/localstack" })
}

// MARK: - Endpoint Helpers

@Test func localStack_buildEndpoint() {
    let endpoint = LocalStackContainer.buildEndpoint(host: "127.0.0.1", port: 4566)
    #expect(endpoint == "http://127.0.0.1:4566")
}

@Test func localStack_buildEndpoint_customPort() {
    let endpoint = LocalStackContainer.buildEndpoint(host: "localhost", port: 49152)
    #expect(endpoint == "http://localhost:49152")
}
