import Foundation

/// HTTP methods supported for health check requests.
public enum HTTPMethod: String, Sendable, Hashable {
    case get = "GET"
    case post = "POST"
    case head = "HEAD"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
    case options = "OPTIONS"
}

/// Matcher for validating HTTP response status codes.
public enum StatusCodeMatcher: Sendable, Hashable {
    /// Matches only the exact status code.
    case exact(Int)
    /// Matches any status code within the range (inclusive).
    case range(ClosedRange<Int>)
    /// Matches any status code in the given set.
    case anyOf(Set<Int>)

    /// Returns true if the given status code matches this matcher.
    public func matches(_ code: Int) -> Bool {
        switch self {
        case .exact(let expected):
            return code == expected
        case .range(let range):
            return range.contains(code)
        case .anyOf(let codes):
            return codes.contains(code)
        }
    }
}

/// Matcher for validating HTTP response body content.
public enum BodyMatcher: Sendable, Hashable {
    /// Matches if the body contains the given substring.
    case contains(String)
    /// Matches if the body matches the given regular expression pattern.
    case regex(String)

    /// Returns true if the given body matches this matcher.
    public func matches(_ body: String) -> Bool {
        switch self {
        case .contains(let substring):
            return body.contains(substring)
        case .regex(let pattern):
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return false
            }
            let range = NSRange(body.startIndex..., in: body)
            return regex.firstMatch(in: body, range: range) != nil
        }
    }
}

/// Configuration for HTTP-based wait strategy.
///
/// Use this to configure how the container should be polled to determine
/// when it's ready to accept connections.
///
/// Example usage:
/// ```swift
/// let config = HTTPWaitConfig(port: 8080)
///     .withPath("/health")
///     .withStatusCode(200)
///     .withTimeout(.seconds(90))
/// ```
public struct HTTPWaitConfig: Sendable, Hashable {
    /// The container port to connect to.
    public var port: Int

    /// The URL path to request (default: "/").
    public var path: String

    /// The HTTP method to use (default: GET).
    public var method: HTTPMethod

    /// The matcher for validating response status codes (default: 200-299).
    public var statusCodeMatcher: StatusCodeMatcher

    /// Optional matcher for validating response body content.
    public var bodyMatcher: BodyMatcher?

    /// Additional headers to include in the request.
    public var headers: [String: String]

    /// Whether to use HTTPS instead of HTTP.
    public var useTLS: Bool

    /// Whether to allow insecure TLS connections (self-signed certificates).
    public var allowInsecureTLS: Bool

    /// Maximum time to wait for the container to become ready.
    public var timeout: Duration

    /// Time between polling attempts.
    public var pollInterval: Duration

    /// Timeout for individual HTTP requests.
    public var requestTimeout: Duration

    /// Creates a new HTTP wait configuration for the given port.
    ///
    /// - Parameter port: The container port to check for readiness.
    public init(port: Int) {
        self.port = port
        self.path = "/"
        self.method = .get
        self.statusCodeMatcher = .range(200...299)
        self.bodyMatcher = nil
        self.headers = [:]
        self.useTLS = false
        self.allowInsecureTLS = false
        self.timeout = .seconds(60)
        self.pollInterval = .milliseconds(200)
        self.requestTimeout = .seconds(5)
    }

    /// Sets the URL path to request.
    ///
    /// - Parameter path: The path (e.g., "/health"). A leading slash will be added if missing.
    /// - Returns: A new configuration with the updated path.
    public func withPath(_ path: String) -> Self {
        var copy = self
        copy.path = path.hasPrefix("/") ? path : "/\(path)"
        return copy
    }

    /// Sets the HTTP method to use.
    ///
    /// - Parameter method: The HTTP method (GET, POST, etc.).
    /// - Returns: A new configuration with the updated method.
    public func withMethod(_ method: HTTPMethod) -> Self {
        var copy = self
        copy.method = method
        return copy
    }

    /// Sets the expected status code to an exact value.
    ///
    /// - Parameter code: The expected status code.
    /// - Returns: A new configuration with the updated status code matcher.
    public func withStatusCode(_ code: Int) -> Self {
        var copy = self
        copy.statusCodeMatcher = .exact(code)
        return copy
    }

    /// Sets the expected status code to a range.
    ///
    /// - Parameter range: The acceptable status code range.
    /// - Returns: A new configuration with the updated status code matcher.
    public func withStatusCodeRange(_ range: ClosedRange<Int>) -> Self {
        var copy = self
        copy.statusCodeMatcher = .range(range)
        return copy
    }

    /// Sets a custom status code matcher.
    ///
    /// - Parameter matcher: The status code matcher to use.
    /// - Returns: A new configuration with the updated status code matcher.
    public func withStatusCodeMatcher(_ matcher: StatusCodeMatcher) -> Self {
        var copy = self
        copy.statusCodeMatcher = matcher
        return copy
    }

    /// Sets the body matcher to check for a substring.
    ///
    /// - Parameter substring: The substring that must be present in the response body.
    /// - Returns: A new configuration with the updated body matcher.
    public func withBodyContains(_ substring: String) -> Self {
        var copy = self
        copy.bodyMatcher = .contains(substring)
        return copy
    }

    /// Sets a custom body matcher.
    ///
    /// - Parameter matcher: The body matcher to use.
    /// - Returns: A new configuration with the updated body matcher.
    public func withBodyMatcher(_ matcher: BodyMatcher) -> Self {
        var copy = self
        copy.bodyMatcher = matcher
        return copy
    }

    /// Adds a single header to the request.
    ///
    /// - Parameters:
    ///   - name: The header name.
    ///   - value: The header value.
    /// - Returns: A new configuration with the added header.
    public func withHeader(_ name: String, _ value: String) -> Self {
        var copy = self
        copy.headers[name] = value
        return copy
    }

    /// Sets multiple headers for the request, merging with existing headers.
    ///
    /// - Parameter headers: Dictionary of header names and values.
    /// - Returns: A new configuration with the merged headers.
    public func withHeaders(_ headers: [String: String]) -> Self {
        var copy = self
        for (name, value) in headers {
            copy.headers[name] = value
        }
        return copy
    }

    /// Enables TLS (HTTPS) for the connection.
    ///
    /// - Parameter allowInsecure: If true, allows self-signed or invalid certificates.
    /// - Returns: A new configuration with TLS enabled.
    public func withTLS(allowInsecure: Bool = false) -> Self {
        var copy = self
        copy.useTLS = true
        copy.allowInsecureTLS = allowInsecure
        return copy
    }

    /// Sets the overall timeout for waiting for the container to be ready.
    ///
    /// - Parameter timeout: Maximum time to wait.
    /// - Returns: A new configuration with the updated timeout.
    public func withTimeout(_ timeout: Duration) -> Self {
        var copy = self
        copy.timeout = timeout
        return copy
    }

    /// Sets the interval between polling attempts.
    ///
    /// - Parameter interval: Time between checks.
    /// - Returns: A new configuration with the updated poll interval.
    public func withPollInterval(_ interval: Duration) -> Self {
        var copy = self
        copy.pollInterval = interval
        return copy
    }

    /// Sets the timeout for individual HTTP requests.
    ///
    /// - Parameter timeout: Maximum time for a single request.
    /// - Returns: A new configuration with the updated request timeout.
    public func withRequestTimeout(_ timeout: Duration) -> Self {
        var copy = self
        copy.requestTimeout = timeout
        return copy
    }
}
