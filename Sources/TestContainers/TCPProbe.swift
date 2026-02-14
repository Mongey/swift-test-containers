import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum TCPProbe {
    static func canConnect(host: String, port: Int, timeout: Duration) -> Bool {
        let timeoutMs = max(1, Int(timeout.components.seconds * 1000) + Int(timeout.components.attoseconds / 1_000_000_000_000_000))
        return canConnect(host: host, port: port, timeoutMs: timeoutMs)
    }

    private static func canConnect(host: String, port: Int, timeoutMs: Int) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        hints.ai_protocol = Int32(IPPROTO_TCP)
        #endif

        var infoPtr: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        let status = getaddrinfo(host, portString, &hints, &infoPtr)
        guard status == 0, let firstInfo = infoPtr else { return false }
        defer { freeaddrinfo(firstInfo) }

        var current = infoPtr
        while let info = current?.pointee {
            defer { current = info.ai_next }

            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if fd < 0 { continue }
            defer { close(fd) }

            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let connectResult = withUnsafePointer(to: info.ai_addr.pointee) { addrPtr -> Int32 in
                let rawPtr = UnsafeRawPointer(addrPtr).assumingMemoryBound(to: sockaddr.self)
                return DarwinConnect.connect(fd, rawPtr, info.ai_addrlen)
            }

            if connectResult == 0 { return true }
            if errno != EINPROGRESS { continue }

            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pollResult = poll(&pfd, 1, Int32(timeoutMs))
            if pollResult <= 0 { continue }

            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout.size(ofValue: soError))
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) != 0 { continue }
            if soError == 0 { return true }
        }

        return false
    }
}

private enum DarwinConnect {
    static func connect(_ socket: Int32, _ address: UnsafePointer<sockaddr>, _ addressLen: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.connect(socket, address, addressLen)
        #else
        return Glibc.connect(socket, address, addressLen)
        #endif
    }
}

