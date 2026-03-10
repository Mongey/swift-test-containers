import Foundation

/// Parser for Docker's multiplexed stream format.
///
/// When a container is created without a TTY, Docker multiplexes stdout and stderr
/// into a single stream using 8-byte frame headers:
///
/// ```
/// [stream_type: 1 byte] [padding: 3 bytes] [payload_size: 4 bytes big-endian] [payload: N bytes]
/// ```
///
/// Stream types:
/// - 0: stdin (not used in output)
/// - 1: stdout
/// - 2: stderr
///
/// Reference: https://docs.docker.com/engine/api/v1.43/#tag/Container/operation/ContainerAttach
enum DockerMultiplexedStream {
    /// A single frame from a multiplexed stream.
    struct Frame {
        enum StreamType: UInt8 {
            case stdin = 0
            case stdout = 1
            case stderr = 2
        }

        let streamType: StreamType
        let payload: Data
    }

    /// Parse all frames from a complete multiplexed stream response body.
    ///
    /// - Parameter data: The raw response body
    /// - Returns: Array of parsed frames
    static func parseFrames(from data: Data) -> [Frame] {
        var frames: [Frame] = []
        var offset = 0

        while offset + 8 <= data.count {
            let streamByte = data[data.startIndex + offset]
            guard let streamType = Frame.StreamType(rawValue: streamByte) else {
                // Unknown stream type, skip this frame header
                // Try to read the size to advance past it
                let size = readUInt32BigEndian(data, at: offset + 4)
                offset += 8 + Int(size)
                continue
            }

            let payloadSize = readUInt32BigEndian(data, at: offset + 4)
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + Int(payloadSize)

            guard payloadEnd <= data.count else {
                break // Incomplete frame
            }

            let payload = data[data.startIndex + payloadStart ..< data.startIndex + payloadEnd]
            frames.append(Frame(streamType: streamType, payload: Data(payload)))
            offset = payloadEnd
        }

        return frames
    }

    /// Extract combined stdout and stderr text from a multiplexed stream.
    ///
    /// Combines all stdout and stderr frames into a single string,
    /// matching the behavior of `docker logs` CLI output.
    static func demultiplexToString(from data: Data) -> String {
        let frames = parseFrames(from: data)
        var result = Data()
        for frame in frames where frame.streamType == .stdout || frame.streamType == .stderr {
            result.append(frame.payload)
        }
        return String(data: result, encoding: .utf8) ?? ""
    }

    /// Extract stdout text only from a multiplexed stream.
    static func stdoutString(from data: Data) -> String {
        let frames = parseFrames(from: data)
        var result = Data()
        for frame in frames where frame.streamType == .stdout {
            result.append(frame.payload)
        }
        return String(data: result, encoding: .utf8) ?? ""
    }

    /// Extract stderr text only from a multiplexed stream.
    static func stderrString(from data: Data) -> String {
        let frames = parseFrames(from: data)
        var result = Data()
        for frame in frames where frame.streamType == .stderr {
            result.append(frame.payload)
        }
        return String(data: result, encoding: .utf8) ?? ""
    }

    /// Extract stdout and stderr separately from a multiplexed stream.
    static func demultiplex(from data: Data) -> (stdout: String, stderr: String) {
        let frames = parseFrames(from: data)
        var stdoutData = Data()
        var stderrData = Data()
        for frame in frames {
            switch frame.streamType {
            case .stdout:
                stdoutData.append(frame.payload)
            case .stderr:
                stderrData.append(frame.payload)
            case .stdin:
                break
            }
        }
        return (
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    // MARK: - Helpers

    private static func readUInt32BigEndian(_ data: Data, at offset: Int) -> UInt32 {
        let idx = data.startIndex + offset
        return (UInt32(data[idx]) << 24)
            | (UInt32(data[idx + 1]) << 16)
            | (UInt32(data[idx + 2]) << 8)
            | UInt32(data[idx + 3])
    }
}
