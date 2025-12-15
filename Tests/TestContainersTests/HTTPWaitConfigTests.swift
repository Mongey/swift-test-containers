import Testing
@testable import TestContainers

// MARK: - HTTPMethod Tests

@Test func httpMethod_rawValues() {
    #expect(HTTPMethod.get.rawValue == "GET")
    #expect(HTTPMethod.post.rawValue == "POST")
    #expect(HTTPMethod.head.rawValue == "HEAD")
    #expect(HTTPMethod.put.rawValue == "PUT")
    #expect(HTTPMethod.delete.rawValue == "DELETE")
    #expect(HTTPMethod.patch.rawValue == "PATCH")
    #expect(HTTPMethod.options.rawValue == "OPTIONS")
}

// MARK: - StatusCodeMatcher Tests

@Test func statusCodeMatcher_exact_matchesOnlyThatCode() {
    let matcher = StatusCodeMatcher.exact(200)
    #expect(matcher.matches(200) == true)
    #expect(matcher.matches(201) == false)
    #expect(matcher.matches(404) == false)
    #expect(matcher.matches(500) == false)
}

@Test func statusCodeMatcher_range_matchesCodesInRange() {
    let matcher = StatusCodeMatcher.range(200...299)
    #expect(matcher.matches(200) == true)
    #expect(matcher.matches(204) == true)
    #expect(matcher.matches(299) == true)
    #expect(matcher.matches(199) == false)
    #expect(matcher.matches(300) == false)
    #expect(matcher.matches(404) == false)
}

@Test func statusCodeMatcher_anyOf_matchesCodesInSet() {
    let matcher = StatusCodeMatcher.anyOf([200, 201, 204])
    #expect(matcher.matches(200) == true)
    #expect(matcher.matches(201) == true)
    #expect(matcher.matches(204) == true)
    #expect(matcher.matches(202) == false)
    #expect(matcher.matches(404) == false)
}

// MARK: - BodyMatcher Tests

@Test func bodyMatcher_contains_matchesSubstring() {
    let matcher = BodyMatcher.contains("healthy")
    #expect(matcher.matches("status: healthy") == true)
    #expect(matcher.matches("healthy") == true)
    #expect(matcher.matches("HEALTHY") == false)  // case sensitive
    #expect(matcher.matches("status: unhealthy") == true)  // substring is present
    #expect(matcher.matches("status: down") == false)
    #expect(matcher.matches("") == false)
}

@Test func bodyMatcher_contains_emptySubstringBehavior() {
    // Note: Swift's String.contains("") returns false (platform-specific behavior)
    let matcher = BodyMatcher.contains("")
    // Match actual Swift runtime behavior
    #expect(matcher.matches("anything") == "anything".contains(""))
    #expect(matcher.matches("") == "".contains(""))
}

@Test func bodyMatcher_regex_matchesPattern() {
    let matcher = BodyMatcher.regex("status.*healthy")
    #expect(matcher.matches("status: healthy") == true)
    #expect(matcher.matches("status is healthy") == true)
    #expect(matcher.matches("healthy status") == false)
    #expect(matcher.matches("") == false)
}

@Test func bodyMatcher_regex_matchesJsonPattern() {
    let matcher = BodyMatcher.regex("\"status\"\\s*:\\s*\"ok\"")
    #expect(matcher.matches("{\"status\": \"ok\"}") == true)
    #expect(matcher.matches("{\"status\":\"ok\"}") == true)
    #expect(matcher.matches("{\"status\": \"error\"}") == false)
}

// MARK: - HTTPWaitConfig Tests

@Test func httpWaitConfig_defaultValues() {
    let config = HTTPWaitConfig(port: 8080)

    #expect(config.port == 8080)
    #expect(config.path == "/")
    #expect(config.method == .get)
    #expect(config.statusCodeMatcher == .range(200...299))
    #expect(config.bodyMatcher == nil)
    #expect(config.headers == [:])
    #expect(config.useTLS == false)
    #expect(config.allowInsecureTLS == false)
    #expect(config.timeout == .seconds(60))
    #expect(config.pollInterval == .milliseconds(200))
    #expect(config.requestTimeout == .seconds(5))
}

@Test func httpWaitConfig_withPath() {
    let config = HTTPWaitConfig(port: 8080)
        .withPath("/health")

    #expect(config.path == "/health")
    #expect(config.port == 8080)  // Other values unchanged
}

@Test func httpWaitConfig_withPath_addsLeadingSlashIfMissing() {
    let config = HTTPWaitConfig(port: 8080)
        .withPath("health")

    #expect(config.path == "/health")
}

@Test func httpWaitConfig_withMethod() {
    let config = HTTPWaitConfig(port: 8080)
        .withMethod(.post)

    #expect(config.method == .post)
}

@Test func httpWaitConfig_withStatusCode() {
    let config = HTTPWaitConfig(port: 8080)
        .withStatusCode(201)

    #expect(config.statusCodeMatcher == .exact(201))
}

@Test func httpWaitConfig_withStatusCodeRange() {
    let config = HTTPWaitConfig(port: 8080)
        .withStatusCodeRange(200...204)

    #expect(config.statusCodeMatcher == .range(200...204))
}

@Test func httpWaitConfig_withStatusCodeMatcher() {
    let config = HTTPWaitConfig(port: 8080)
        .withStatusCodeMatcher(.anyOf([200, 204]))

    #expect(config.statusCodeMatcher == .anyOf([200, 204]))
}

@Test func httpWaitConfig_withBodyContains() {
    let config = HTTPWaitConfig(port: 8080)
        .withBodyContains("healthy")

    #expect(config.bodyMatcher == .contains("healthy"))
}

@Test func httpWaitConfig_withBodyMatcher() {
    let config = HTTPWaitConfig(port: 8080)
        .withBodyMatcher(.regex("status.*ok"))

    #expect(config.bodyMatcher == .regex("status.*ok"))
}

@Test func httpWaitConfig_withHeader() {
    let config = HTTPWaitConfig(port: 8080)
        .withHeader("Authorization", "Bearer token")

    #expect(config.headers == ["Authorization": "Bearer token"])
}

@Test func httpWaitConfig_withHeaders() {
    let config = HTTPWaitConfig(port: 8080)
        .withHeaders(["X-Custom": "value", "Accept": "application/json"])

    #expect(config.headers["X-Custom"] == "value")
    #expect(config.headers["Accept"] == "application/json")
}

@Test func httpWaitConfig_withHeader_accumulatesHeaders() {
    let config = HTTPWaitConfig(port: 8080)
        .withHeader("X-First", "1")
        .withHeader("X-Second", "2")

    #expect(config.headers["X-First"] == "1")
    #expect(config.headers["X-Second"] == "2")
}

@Test func httpWaitConfig_withTLS() {
    let config = HTTPWaitConfig(port: 443)
        .withTLS()

    #expect(config.useTLS == true)
    #expect(config.allowInsecureTLS == false)
}

@Test func httpWaitConfig_withTLS_allowInsecure() {
    let config = HTTPWaitConfig(port: 443)
        .withTLS(allowInsecure: true)

    #expect(config.useTLS == true)
    #expect(config.allowInsecureTLS == true)
}

@Test func httpWaitConfig_withTimeout() {
    let config = HTTPWaitConfig(port: 8080)
        .withTimeout(.seconds(120))

    #expect(config.timeout == .seconds(120))
}

@Test func httpWaitConfig_withPollInterval() {
    let config = HTTPWaitConfig(port: 8080)
        .withPollInterval(.milliseconds(500))

    #expect(config.pollInterval == .milliseconds(500))
}

@Test func httpWaitConfig_withRequestTimeout() {
    let config = HTTPWaitConfig(port: 8080)
        .withRequestTimeout(.seconds(10))

    #expect(config.requestTimeout == .seconds(10))
}

@Test func httpWaitConfig_builderChaining() {
    let config = HTTPWaitConfig(port: 8080)
        .withPath("/api/health")
        .withMethod(.get)
        .withStatusCode(200)
        .withBodyContains("ok")
        .withHeader("Accept", "application/json")
        .withTLS(allowInsecure: true)
        .withTimeout(.seconds(90))
        .withPollInterval(.milliseconds(500))
        .withRequestTimeout(.seconds(3))

    #expect(config.port == 8080)
    #expect(config.path == "/api/health")
    #expect(config.method == .get)
    #expect(config.statusCodeMatcher == .exact(200))
    #expect(config.bodyMatcher == .contains("ok"))
    #expect(config.headers["Accept"] == "application/json")
    #expect(config.useTLS == true)
    #expect(config.allowInsecureTLS == true)
    #expect(config.timeout == .seconds(90))
    #expect(config.pollInterval == .milliseconds(500))
    #expect(config.requestTimeout == .seconds(3))
}

// MARK: - Hashable Conformance Tests

@Test func httpWaitConfig_hashable() {
    let config1 = HTTPWaitConfig(port: 8080).withPath("/health")
    let config2 = HTTPWaitConfig(port: 8080).withPath("/health")
    let config3 = HTTPWaitConfig(port: 8080).withPath("/ready")

    #expect(config1 == config2)
    #expect(config1 != config3)

    var set = Set<HTTPWaitConfig>()
    set.insert(config1)
    set.insert(config2)
    #expect(set.count == 1)
}

@Test func statusCodeMatcher_hashable() {
    let matcher1 = StatusCodeMatcher.exact(200)
    let matcher2 = StatusCodeMatcher.exact(200)
    let matcher3 = StatusCodeMatcher.exact(201)

    #expect(matcher1 == matcher2)
    #expect(matcher1 != matcher3)
}

@Test func bodyMatcher_hashable() {
    let matcher1 = BodyMatcher.contains("test")
    let matcher2 = BodyMatcher.contains("test")
    let matcher3 = BodyMatcher.regex("test")

    #expect(matcher1 == matcher2)
    #expect(matcher1 != matcher3)
}

// MARK: - WaitStrategy Integration Tests

@Test func waitStrategy_httpCase() {
    let config = HTTPWaitConfig(port: 8080).withPath("/health")
    let strategy = WaitStrategy.http(config)

    // Verify it compiles and works with the enum
    switch strategy {
    case .http(let extractedConfig):
        #expect(extractedConfig.port == 8080)
        #expect(extractedConfig.path == "/health")
    default:
        Issue.record("Expected .http case")
    }
}

@Test func waitStrategy_httpCase_hashable() {
    let strategy1 = WaitStrategy.http(HTTPWaitConfig(port: 8080))
    let strategy2 = WaitStrategy.http(HTTPWaitConfig(port: 8080))
    let strategy3 = WaitStrategy.http(HTTPWaitConfig(port: 9090))

    #expect(strategy1 == strategy2)
    #expect(strategy1 != strategy3)
}
