import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// Reference-counted wrapper around `HTTPClient` that calls `syncShutdown()` on deinit.
///
/// This ensures the HTTPClient is properly cleaned up when all copies of
/// `DockerHTTPClient` (a value type) go out of scope, preventing the
/// "Client not shut down before deinit" fatal error.
private final class ManagedHTTPClient: @unchecked Sendable {
    let client: HTTPClient

    init() {
        self.client = HTTPClient(eventLoopGroupProvider: .singleton)
    }

    deinit {
        try? client.syncShutdown()
    }
}

/// HTTP client for communicating with the Docker Engine API over a Unix domain socket.
///
/// Uses AsyncHTTPClient with the `http+unix://` URL scheme to send requests
/// to the Docker daemon socket (default: `/var/run/docker.sock`).
/// Pinned to Docker Engine API version v1.43 (Docker Engine 24.0+).
struct DockerHTTPClient: Sendable {
    private let managed: ManagedHTTPClient
    private var httpClient: HTTPClient { managed.client }
    private let socketAuthority: String
    private let apiVersion: String = "v1.43"

    init(socketPath: String = "/var/run/docker.sock") {
        self.managed = ManagedHTTPClient()
        // Percent-encode the socket path for use in http+unix:// URLs.
        // '/' must become %2F so the URL parser treats the whole path as the authority.
        self.socketAuthority = socketPath.replacingOccurrences(of: "/", with: "%2F")
    }

    // MARK: - URL Building

    private func url(for path: String, queryItems: [(String, String)] = []) -> String {
        var base = "http+unix://\(socketAuthority)/\(apiVersion)\(path)"
        if !queryItems.isEmpty {
            let query = queryItems
                .map { key, value in
                    let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                    let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                    return "\(escapedKey)=\(escapedValue)"
                }
                .joined(separator: "&")
            base += "?\(query)"
        }
        return base
    }

    // MARK: - HTTP Methods

    /// Perform a GET request, returning the status code and response body.
    func get(
        _ path: String,
        queryItems: [(String, String)] = [],
        timeout: TimeAmount = .seconds(30)
    ) async throws -> (status: HTTPResponseStatus, body: Data) {
        var request = HTTPClientRequest(url: url(for: path, queryItems: queryItems))
        request.method = .GET
        let response = try await httpClient.execute(request, timeout: timeout)
        let body = try await response.body.collect(upTo: 10 * 1024 * 1024) // 10 MB limit
        return (response.status, Data(buffer: body))
    }

    /// Perform a POST request with an optional JSON body.
    func post(
        _ path: String,
        body: Data? = nil,
        queryItems: [(String, String)] = [],
        headers: [(String, String)] = [],
        timeout: TimeAmount = .seconds(30)
    ) async throws -> (status: HTTPResponseStatus, body: Data) {
        var request = HTTPClientRequest(url: url(for: path, queryItems: queryItems))
        request.method = .POST
        for (name, value) in headers {
            request.headers.add(name: name, value: value)
        }
        if let body {
            request.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            request.body = .bytes(body)
        }
        let response = try await httpClient.execute(request, timeout: timeout)
        let responseBody = try await response.body.collect(upTo: 10 * 1024 * 1024)
        return (response.status, Data(buffer: responseBody))
    }

    /// Perform a PUT request with an optional JSON body.
    func put(
        _ path: String,
        body: Data? = nil,
        queryItems: [(String, String)] = [],
        timeout: TimeAmount = .seconds(30)
    ) async throws -> (status: HTTPResponseStatus, body: Data) {
        var request = HTTPClientRequest(url: url(for: path, queryItems: queryItems))
        request.method = .PUT
        if let body {
            request.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            request.body = .bytes(body)
        }
        let response = try await httpClient.execute(request, timeout: timeout)
        let responseBody = try await response.body.collect(upTo: 10 * 1024 * 1024)
        return (response.status, Data(buffer: responseBody))
    }

    /// Perform a DELETE request.
    func delete(
        _ path: String,
        queryItems: [(String, String)] = [],
        timeout: TimeAmount = .seconds(30)
    ) async throws -> (status: HTTPResponseStatus, body: Data) {
        var request = HTTPClientRequest(url: url(for: path, queryItems: queryItems))
        request.method = .DELETE
        let response = try await httpClient.execute(request, timeout: timeout)
        let body = try await response.body.collect(upTo: 10 * 1024 * 1024)
        return (response.status, Data(buffer: body))
    }

    /// Perform a streaming POST request and collect the full response body.
    ///
    /// Used for endpoints like image pull that stream progress JSON objects.
    /// Uses a long timeout to accommodate large image downloads.
    func postStreaming(
        _ path: String,
        body: Data? = nil,
        queryItems: [(String, String)] = [],
        headers: [(String, String)] = [],
        timeout: TimeAmount = .seconds(600)
    ) async throws -> (status: HTTPResponseStatus, body: Data) {
        var request = HTTPClientRequest(url: url(for: path, queryItems: queryItems))
        request.method = .POST
        for (name, value) in headers {
            request.headers.add(name: name, value: value)
        }
        if let body {
            request.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            request.body = .bytes(body)
        }
        let response = try await httpClient.execute(request, timeout: timeout)
        let responseBody = try await response.body.collect(upTo: 100 * 1024 * 1024) // 100 MB for streaming
        return (response.status, Data(buffer: responseBody))
    }

    /// Perform a GET request and return the raw response for streaming.
    ///
    /// The caller is responsible for consuming the response body.
    func getStream(
        _ path: String,
        queryItems: [(String, String)] = [],
        timeout: TimeAmount = .seconds(3600)
    ) async throws -> HTTPClientResponse {
        var request = HTTPClientRequest(url: url(for: path, queryItems: queryItems))
        request.method = .GET
        return try await httpClient.execute(request, timeout: timeout)
    }

    /// Perform a POST request and return the raw response for streaming.
    ///
    /// Used for exec start which returns a multiplexed stream.
    func postStream(
        _ path: String,
        body: Data? = nil,
        queryItems: [(String, String)] = [],
        timeout: TimeAmount = .seconds(3600)
    ) async throws -> HTTPClientResponse {
        var request = HTTPClientRequest(url: url(for: path, queryItems: queryItems))
        request.method = .POST
        if let body {
            request.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            request.body = .bytes(body)
        }
        return try await httpClient.execute(request, timeout: timeout)
    }

    // MARK: - Helpers

    /// Decode a JSON response body, throwing an API error for non-success status codes.
    func decodeResponse<T: Decodable>(
        _ type: T.Type,
        status: HTTPResponseStatus,
        body: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        guard (200..<300).contains(status.code) else {
            let message = parseErrorMessage(from: body)
            throw TestContainersError.apiError(
                statusCode: Int(status.code),
                message: message
            )
        }
        return try decoder.decode(T.self, from: body)
    }

    /// Check that a response has a success status code, throwing an API error otherwise.
    func requireSuccess(status: HTTPResponseStatus, body: Data) throws {
        guard (200..<300).contains(status.code) else {
            let message = parseErrorMessage(from: body)
            throw TestContainersError.apiError(
                statusCode: Int(status.code),
                message: message
            )
        }
    }

    /// Parse an error message from a Docker API error response body.
    private func parseErrorMessage(from body: Data) -> String {
        struct ErrorResponse: Decodable {
            let message: String
        }
        if let error = try? JSONDecoder().decode(ErrorResponse.self, from: body) {
            return error.message
        }
        return String(data: body, encoding: .utf8) ?? "Unknown error"
    }
}
