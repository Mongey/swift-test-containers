import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TestContainers

// MARK: - NginxContainer Unit Tests

@Test func nginxContainer_defaultValues() {
    let nginx = NginxContainer()

    #expect(nginx.request.image == "nginx:alpine")
    #expect(nginx.request.ports.contains { $0.containerPort == 80 })
}

@Test func nginxContainer_customImage() {
    let nginx = NginxContainer(image: "nginx:1.25")

    #expect(nginx.request.image == "nginx:1.25")
}

@Test func nginxContainer_defaultPort() {
    let nginx = NginxContainer()

    #expect(NginxContainer.defaultPort == 80)
    #expect(nginx.request.ports.contains { $0.containerPort == 80 })
}

@Test func nginxContainer_defaultWaitStrategy() {
    let nginx = NginxContainer()

    if case let .http(config) = nginx.request.waitStrategy {
        #expect(config.port == 80)
        #expect(config.path == "/")
    } else {
        Issue.record("Expected HTTP wait strategy, got \(nginx.request.waitStrategy)")
    }
}

@Test func nginxContainer_withExposedPort_addsPort() {
    let nginx = NginxContainer()
        .withExposedPort(443)

    #expect(nginx.request.ports.count == 2)
    #expect(nginx.request.ports.contains { $0.containerPort == 80 })
    #expect(nginx.request.ports.contains { $0.containerPort == 443 })
}

@Test func nginxContainer_withExposedPort_withHostPort() {
    let nginx = NginxContainer()
        .withExposedPort(8080, hostPort: 80)

    #expect(nginx.request.ports.contains { $0.containerPort == 8080 && $0.hostPort == 80 })
}

@Test func nginxContainer_withEnvironment() {
    let nginx = NginxContainer()
        .withEnvironment(["NGINX_HOST": "localhost", "NGINX_PORT": "8080"])

    #expect(nginx.request.environment["NGINX_HOST"] == "localhost")
    #expect(nginx.request.environment["NGINX_PORT"] == "8080")
}

@Test func nginxContainer_waitingFor_overridesDefault() {
    let nginx = NginxContainer()
        .waitingFor(.tcpPort(80, timeout: .seconds(45)))

    if case let .tcpPort(port, timeout, _) = nginx.request.waitStrategy {
        #expect(port == 80)
        #expect(timeout == .seconds(45))
    } else {
        Issue.record("Expected tcpPort wait strategy")
    }
}

@Test func nginxContainer_withCustomConfig() {
    let nginx = NginxContainer()
        .withCustomConfig("/path/to/nginx.conf")

    #expect(nginx.request.bindMounts.count == 1)
    #expect(nginx.request.bindMounts[0].hostPath == "/path/to/nginx.conf")
    #expect(nginx.request.bindMounts[0].containerPath == "/etc/nginx/nginx.conf")
    #expect(nginx.request.bindMounts[0].readOnly == true)
}

@Test func nginxContainer_withConfigFile_defaultFilename() {
    let nginx = NginxContainer()
        .withConfigFile("/path/to/custom.conf")

    #expect(nginx.request.bindMounts.count == 1)
    #expect(nginx.request.bindMounts[0].hostPath == "/path/to/custom.conf")
    #expect(nginx.request.bindMounts[0].containerPath == "/etc/nginx/conf.d/custom.conf")
    #expect(nginx.request.bindMounts[0].readOnly == true)
}

@Test func nginxContainer_withConfigFile_customFilename() {
    let nginx = NginxContainer()
        .withConfigFile("/path/to/myconfig.conf", as: "site.conf")

    #expect(nginx.request.bindMounts.count == 1)
    #expect(nginx.request.bindMounts[0].containerPath == "/etc/nginx/conf.d/site.conf")
}

@Test func nginxContainer_withStaticFiles_defaultDocRoot() {
    let nginx = NginxContainer()
        .withStaticFiles(from: "/path/to/html")

    #expect(nginx.request.bindMounts.count == 1)
    #expect(nginx.request.bindMounts[0].hostPath == "/path/to/html")
    #expect(nginx.request.bindMounts[0].containerPath == "/usr/share/nginx/html")
    #expect(nginx.request.bindMounts[0].readOnly == true)
}

@Test func nginxContainer_withStaticFiles_customDocRoot() {
    let nginx = NginxContainer()
        .withStaticFiles(from: "/path/to/html", at: "/var/www/html")

    #expect(nginx.request.bindMounts[0].containerPath == "/var/www/html")
}

@Test func nginxContainer_multipleConfigFiles() {
    let nginx = NginxContainer()
        .withConfigFile("/path/to/gzip.conf", as: "gzip.conf")
        .withConfigFile("/path/to/cache.conf", as: "cache.conf")
        .withConfigFile("/path/to/security.conf", as: "security.conf")

    #expect(nginx.request.bindMounts.count == 3)
}

@Test func nginxContainer_methodChaining() {
    let nginx = NginxContainer(image: "nginx:1.25")
        .withExposedPort(443)
        .withEnvironment(["DEBUG": "true"])
        .withStaticFiles(from: "/html")
        .withConfigFile("/config/extra.conf")

    #expect(nginx.request.image == "nginx:1.25")
    #expect(nginx.request.ports.count == 2)
    #expect(nginx.request.environment["DEBUG"] == "true")
    #expect(nginx.request.bindMounts.count == 2)
}

@Test func nginxContainer_builderReturnsNewInstance() {
    let original = NginxContainer()
    let modified = original.withExposedPort(443)

    #expect(original.request.ports.count == 1)
    #expect(modified.request.ports.count == 2)
}

// MARK: - Integration Tests

@Test func nginxContainer_startsSuccessfully() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nginx = NginxContainer()

    try await nginx.run { container in
        let url = try await container.url()
        #expect(url.hasPrefix("http://"))
        #expect(!url.isEmpty)
    }
}

@Test func nginxContainer_servesDefaultPage() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nginx = NginxContainer()

    try await nginx.run { container in
        let urlString = try await container.url()
        guard let url = URL(string: urlString) else {
            Issue.record("Invalid URL: \(urlString)")
            return
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse

        #expect(httpResponse.statusCode == 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("nginx") || body.contains("Welcome"))
    }
}

@Test func nginxContainer_urlWithPath() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nginx = NginxContainer()

    try await nginx.run { container in
        let baseUrl = try await container.url()
        let urlWithPath = try await container.url(path: "/")

        #expect(urlWithPath == baseUrl || urlWithPath == "\(baseUrl)/")

        let urlWithCustomPath = try await container.url(path: "/api/test")
        #expect(urlWithCustomPath.contains("/api/test"))
    }
}

@Test func nginxContainer_portMapping() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nginx = NginxContainer()

    try await nginx.run { container in
        let port = try await container.port()
        #expect(port > 0)

        let endpoint = try await container.endpoint()
        #expect(endpoint.contains(":"))
        #expect(endpoint.contains("\(port)"))
    }
}

@Test func nginxContainer_logs() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nginx = NginxContainer()

    try await nginx.run { container in
        // Make a request to generate logs
        let urlString = try await container.url()
        if let url = URL(string: urlString) {
            _ = try? await URLSession.shared.data(from: url)
        }

        let logs = try await container.logs()
        #expect(!logs.isEmpty)
    }
}

@Test func nginxContainer_serveStaticFiles() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create temp directory with test HTML
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("nginx-static-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    let testHTML = """
    <!DOCTYPE html>
    <html><body><h1>Hello from TestContainers!</h1></body></html>
    """
    try testHTML.write(to: tempDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

    let nginx = NginxContainer()
        .withStaticFiles(from: tempDir.path)

    try await nginx.run { container in
        let urlString = try await container.url()
        guard let url = URL(string: urlString) else {
            Issue.record("Invalid URL")
            return
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse

        #expect(httpResponse.statusCode == 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("Hello from TestContainers!"))
    }
}

@Test func nginxContainer_customConfig() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    // Create custom nginx config
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("nginx-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    let customConfig = """
    server {
        listen 80;
        location / {
            return 200 'Custom Config Works!';
            add_header Content-Type text/plain;
        }
    }
    """
    let configFile = tempDir.appendingPathComponent("custom.conf")
    try customConfig.write(to: configFile, atomically: true, encoding: .utf8)

    let nginx = NginxContainer()
        .withConfigFile(configFile.path, as: "default.conf")

    try await nginx.run { container in
        let urlString = try await container.url()
        guard let url = URL(string: urlString) else {
            Issue.record("Invalid URL")
            return
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse

        #expect(httpResponse.statusCode == 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("Custom Config Works!"))
    }
}

@Test func nginxContainer_underlyingContainer() async throws {
    let optedIn = ProcessInfo.processInfo.environment["TESTCONTAINERS_RUN_DOCKER_TESTS"] == "1"
    guard optedIn else { return }

    let nginx = NginxContainer()

    try await nginx.run { container in
        let underlying = container.underlyingContainer
        let id = await underlying.id
        #expect(!id.isEmpty)
    }
}
