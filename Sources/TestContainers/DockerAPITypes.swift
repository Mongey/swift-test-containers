import Foundation

// MARK: - Version

/// Response from `GET /version`.
struct DockerVersionResponse: Decodable {
    let Version: String
    let ApiVersion: String
    let Os: String
    let Arch: String
}

// MARK: - Container Create

/// Response from `POST /containers/create`.
struct CreateContainerResponse: Decodable {
    let Id: String
    let Warnings: [String]?
}

// MARK: - Network

/// Request body for `POST /networks/create`.
struct CreateNetworkRequest: Encodable {
    let Name: String
    let Driver: String
    let Internal: Bool
    let EnableIPv6: Bool
    let Attachable: Bool
    let Labels: [String: String]?
    let Options: [String: String]?
    let IPAM: APIIPAMConfig?
}

struct APIIPAMConfig: Encodable {
    let Config: [APIIPAMPoolConfig]?
}

struct APIIPAMPoolConfig: Encodable {
    let Subnet: String?
    let Gateway: String?
    let IPRange: String?
}

/// Response from `POST /networks/create`.
struct CreateNetworkResponse: Decodable {
    let Id: String
    let Warning: String?
}

/// Request body for `POST /networks/{id}/connect`.
struct NetworkConnectRequest: Encodable {
    let Container: String
    let EndpointConfig: APIEndpointConfig?
}

struct APIEndpointConfig: Encodable {
    let Aliases: [String]?
    let IPAMConfig: APIEndpointIPAMConfig?
}

struct APIEndpointIPAMConfig: Encodable {
    let IPv4Address: String?
    let IPv6Address: String?
}

// MARK: - Volume

/// Request body for `POST /volumes/create`.
struct CreateVolumeRequest: Encodable {
    let Name: String
    let Driver: String
    let DriverOpts: [String: String]?
}

// MARK: - Exec

/// Request body for `POST /containers/{id}/exec`.
struct ExecCreateRequest: Encodable {
    let AttachStdout: Bool
    let AttachStderr: Bool
    let Detach: Bool
    let Tty: Bool
    let Cmd: [String]
    let Env: [String]?
    let User: String?
    let WorkingDir: String?
}

/// Response from `POST /containers/{id}/exec`.
struct ExecCreateResponse: Decodable {
    let Id: String
}

/// Request body for `POST /exec/{id}/start`.
struct ExecStartRequest: Encodable {
    let Detach: Bool
    let Tty: Bool
}

/// Response from `GET /exec/{id}/json`.
struct ExecInspectResponse: Decodable {
    let ExitCode: Int32
    let Running: Bool
}

// MARK: - Auth

/// Request body for `POST /auth` and X-Registry-Auth header.
struct DockerAuthConfig: Codable {
    let username: String
    let password: String
    let serveraddress: String
}

// MARK: - Image Pull

/// A single progress line from streaming `POST /images/create`.
struct PullProgressResponse: Decodable {
    let status: String?
    let error: String?
    let id: String?
}

// MARK: - Container List (API format)

/// A container list item from `GET /containers/json`.
///
/// The API format differs from the CLI `docker ps --format "{{json .}}"`:
/// - `Names` is an array of strings (each prefixed with `/`)
/// - `Labels` is a dictionary
/// - `Created` is always a Unix timestamp
struct APIContainerListItem: Decodable {
    let Id: String
    let Names: [String]
    let Image: String
    let Created: Int
    let Labels: [String: String]?
    let State: String
}

// MARK: - Container Create Body

/// Full request body for `POST /containers/create`.
///
/// This mirrors the Docker Engine API container creation payload.
/// See: https://docs.docker.com/engine/api/v1.43/#tag/Container/operation/ContainerCreate
struct ContainerCreateBody: Encodable {
    var Hostname: String?
    var User: String?
    var Env: [String]?
    var Cmd: [String]?
    var Image: String
    var WorkingDir: String?
    var Entrypoint: [String]?
    var Labels: [String: String]?
    var ExposedPorts: [String: EmptyEncodableObject]?
    var Healthcheck: APIHealthcheck?
    var HostConfig: APIHostConfig?
    var NetworkingConfig: APINetworkingConfig?
}

struct EmptyEncodableObject: Encodable {}

struct APIHealthcheck: Encodable {
    var Test: [String]
    var Interval: Int64?
    var Timeout: Int64?
    var StartPeriod: Int64?
    var Retries: Int?
}

struct APIHostConfig: Encodable {
    var PortBindings: [String: [APIPortBinding]]?
    var Binds: [String]?
    var Tmpfs: [String: String]?
    var Memory: Int64?
    var MemoryReservation: Int64?
    var MemorySwap: Int64?
    var NanoCPUs: Int64?
    var CpuShares: Int64?
    var CpuPeriod: Int64?
    var CpuQuota: Int64?
    var Privileged: Bool?
    var CapAdd: [String]?
    var CapDrop: [String]?
    var NetworkMode: String?
    var ExtraHosts: [String]?
    var RestartPolicy: APIRestartPolicy?
}

struct APIPortBinding: Encodable {
    var HostIp: String
    var HostPort: String
}

struct APIRestartPolicy: Encodable {
    var Name: String
}

struct APINetworkingConfig: Encodable {
    var EndpointsConfig: [String: APIEndpointSettings]
}

struct APIEndpointSettings: Encodable {
    var Aliases: [String]?
    var IPAMConfig: APIEndpointIPAMConfig?
}
