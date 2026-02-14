import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP probe for checking if an HTTP endpoint is ready.
enum HTTPProbe {
    /// Checks if an HTTP endpoint responds as expected.
    ///
    /// - Parameters:
    ///   - url: The full URL to request.
    ///   - method: The HTTP method to use.
    ///   - headers: Additional headers to include in the request.
    ///   - statusCodeMatcher: Matcher for validating the response status code.
    ///   - bodyMatcher: Optional matcher for validating the response body.
    ///   - allowInsecureTLS: Whether to allow self-signed certificates.
    ///   - requestTimeout: Timeout for the individual HTTP request.
    /// - Returns: `true` if the endpoint responds as expected, `false` otherwise.
    static func check(
        url: String,
        method: HTTPMethod,
        headers: [String: String],
        statusCodeMatcher: StatusCodeMatcher,
        bodyMatcher: BodyMatcher?,
        allowInsecureTLS: Bool,
        requestTimeout: Duration
    ) async -> Bool {
        guard let url = URL(string: url) else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = requestTimeout.timeInterval

        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let session: URLSession
        #if canImport(Darwin)
        if allowInsecureTLS {
            let delegate = InsecureTLSDelegate()
            session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        } else {
            session = URLSession(configuration: .ephemeral)
        }
        #else
        session = URLSession(configuration: .ephemeral)
        #endif

        defer {
            session.invalidateAndCancel()
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            // Check status code
            guard statusCodeMatcher.matches(httpResponse.statusCode) else {
                return false
            }

            // Check body if matcher is provided
            if let bodyMatcher = bodyMatcher {
                let body = String(data: data, encoding: .utf8) ?? ""
                guard bodyMatcher.matches(body) else {
                    return false
                }
            }

            return true
        } catch {
            // Network errors, connection refused, etc. - treat as not ready
            return false
        }
    }
}

#if canImport(Darwin)
/// URLSession delegate that allows insecure TLS connections.
private final class InsecureTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
#endif

/// Extension to convert Duration to TimeInterval for URLRequest.
private extension Duration {
    var timeInterval: TimeInterval {
        let seconds = Double(components.seconds)
        let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000_000
        return seconds + attoseconds
    }
}
