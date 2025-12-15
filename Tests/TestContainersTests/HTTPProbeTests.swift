import Testing
import Foundation
@testable import TestContainers

// MARK: - HTTPProbe Basic Tests

@Test func httpProbe_invalidURL_returnsFalse() async {
    let result = await HTTPProbe.check(
        url: "not a valid url",
        method: .get,
        headers: [:],
        statusCodeMatcher: .range(200...299),
        bodyMatcher: nil,
        allowInsecureTLS: false,
        requestTimeout: .seconds(5)
    )
    #expect(result == false)
}

@Test func httpProbe_emptyURL_returnsFalse() async {
    let result = await HTTPProbe.check(
        url: "",
        method: .get,
        headers: [:],
        statusCodeMatcher: .range(200...299),
        bodyMatcher: nil,
        allowInsecureTLS: false,
        requestTimeout: .seconds(5)
    )
    #expect(result == false)
}

@Test func httpProbe_connectionRefused_returnsFalse() async {
    // Use a port that's unlikely to have anything listening
    let result = await HTTPProbe.check(
        url: "http://127.0.0.1:59999",
        method: .get,
        headers: [:],
        statusCodeMatcher: .range(200...299),
        bodyMatcher: nil,
        allowInsecureTLS: false,
        requestTimeout: .seconds(1)
    )
    #expect(result == false)
}

@Test func httpProbe_unreachableHost_returnsFalse() async {
    // Use an IP address that's not routable (documentation range)
    let result = await HTTPProbe.check(
        url: "http://192.0.2.1:80",
        method: .get,
        headers: [:],
        statusCodeMatcher: .range(200...299),
        bodyMatcher: nil,
        allowInsecureTLS: false,
        requestTimeout: .milliseconds(500)
    )
    #expect(result == false)
}

@Test func httpProbe_shortTimeout_returnsFalse() async {
    // Very short timeout should fail
    let result = await HTTPProbe.check(
        url: "http://127.0.0.1:59999",
        method: .get,
        headers: [:],
        statusCodeMatcher: .range(200...299),
        bodyMatcher: nil,
        allowInsecureTLS: false,
        requestTimeout: .milliseconds(1)
    )
    #expect(result == false)
}

// MARK: - Network Tests (require external network access)
// These tests are skipped by default and only run during integration testing.
// They verify the actual HTTP functionality works with real servers.

@Test(.disabled("Requires external network access - enable for integration testing"))
func httpProbe_network_successfulGET() async {
    let result = await HTTPProbe.check(
        url: "https://httpbin.org/status/200",
        method: .get,
        headers: [:],
        statusCodeMatcher: .exact(200),
        bodyMatcher: nil,
        allowInsecureTLS: false,
        requestTimeout: .seconds(30)
    )
    #expect(result == true)
}

@Test(.disabled("Requires external network access - enable for integration testing"))
func httpProbe_network_statusCodeMismatch() async {
    let result = await HTTPProbe.check(
        url: "https://httpbin.org/status/404",
        method: .get,
        headers: [:],
        statusCodeMatcher: .exact(200),
        bodyMatcher: nil,
        allowInsecureTLS: false,
        requestTimeout: .seconds(30)
    )
    #expect(result == false)
}

@Test(.disabled("Requires external network access - enable for integration testing"))
func httpProbe_network_bodyMatching() async {
    let result = await HTTPProbe.check(
        url: "https://httpbin.org/get",
        method: .get,
        headers: [:],
        statusCodeMatcher: .range(200...299),
        bodyMatcher: .contains("httpbin"),
        allowInsecureTLS: false,
        requestTimeout: .seconds(30)
    )
    #expect(result == true)
}

@Test(.disabled("Requires external network access - enable for integration testing"))
func httpProbe_network_postMethod() async {
    let result = await HTTPProbe.check(
        url: "https://httpbin.org/post",
        method: .post,
        headers: [:],
        statusCodeMatcher: .range(200...299),
        bodyMatcher: nil,
        allowInsecureTLS: false,
        requestTimeout: .seconds(30)
    )
    #expect(result == true)
}

@Test(.disabled("Requires external network access - enable for integration testing"))
func httpProbe_network_customHeaders() async {
    let result = await HTTPProbe.check(
        url: "https://httpbin.org/headers",
        method: .get,
        headers: ["X-Custom-Header": "TestValue123"],
        statusCodeMatcher: .range(200...299),
        bodyMatcher: .contains("TestValue123"),
        allowInsecureTLS: false,
        requestTimeout: .seconds(30)
    )
    #expect(result == true)
}
