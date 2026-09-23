import Foundation

// MARK: - Studio Camera & Microphone Wire Protocol
//
// A dedicated high-throughput TCP stream carrying uncompressed studio-grade
// 48 kHz stereo PCM audio and low-latency hardware-encoded H.264 video
// (30-60 Mbps, 60 FPS) from the Android companion to the Mac.
//
// Wire layout:
//   ┌──────────────────────────────────────────────┐
//   │ HEADER   "STUD" magic (4B) + version (1B)    │
//   ├──────────────────────────────────────────────┤
//   │ PACKET   type(1) flags(1) pts(8) length(4)   │  ← 14-byte fixed header
//   │          payload (length bytes)              │
//   ├──────────────────────────────────────────────┤
//   │ PACKET   …                                   │
//   └──────────────────────────────────────────────┘
//
// All multi-byte integers are big-endian (network byte order).

enum StudioCamProtocol {
    static let magic: [UInt8] = [0x53, 0x54, 0x55, 0x44]  // "STUD"
    static let version: UInt8 = 1
    static let headerLength = 5
    static let packetHeaderLength = 14
    static let defaultPort: UInt16 = 8082

    enum PacketType: UInt8 {
        /// JSON metadata: resolution, framerate, audio specs, camera lens ID/facing.
        case streamInfo  = 1
        /// H.264 SPS/PPS parameter sets, Annex-B framed.
        case videoConfig = 2
        /// H.264 video frame (IDR or non-IDR slice), Annex-B framed.
        case videoFrame  = 3
        /// Audio format descriptor (sample rate, channels, bit depth).
        case audioConfig = 4
        /// Raw uncompressed signed 16-bit little-endian interleaved PCM (bit-perfect).
        case audioFrame  = 5
        /// Heartbeat keep-alive.
        case heartbeat   = 6
    }

    struct PacketFlags: OptionSet {
        let rawValue: UInt8
        static let keyFrame    = PacketFlags(rawValue: 1 << 0)
        static let endOfStream = PacketFlags(rawValue: 1 << 1)
        static let unprocessed = PacketFlags(rawValue: 1 << 2) // Raw unadulterated mic hardware
    }

    struct Packet: Equatable {
        let type: PacketType
        let flags: PacketFlags
        /// Presentation timestamp in microseconds on device clock.
        let presentationTimeUs: Int64
        let payload: Data
    }

    struct StreamInfo: Codable, Equatable {
        var width: Int
        var height: Int
        var frameRate: Int
        var videoBitRate: Int
        var sampleRate: Int
        var channels: Int
        var lensFacing: String       // "back" or "front"
        var lensName: String         // e.g. "Main (Wide)", "Ultra-Wide", "Telephoto"
        var deviceModel: String?
        var micSource: String?       // "unprocessed" or "standard"
    }

    /// Serializes a stream packet into wire bytes.
    static func serializePacket(type: PacketType, flags: PacketFlags = [], pts: Int64 = 0, payload: Data) -> Data {
        var data = Data(capacity: packetHeaderLength + payload.count)
        data.append(type.rawValue)
        data.append(flags.rawValue)

        var bigPts = pts.bigEndian
        withUnsafeBytes(of: &bigPts) { data.append(contentsOf: $0) }

        var bigLen = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &bigLen) { data.append(contentsOf: $0) }

        data.append(payload)
        return data
    }

    /// Creates the 5-byte stream handshake.
    static func handshakeData() -> Data {
        var data = Data(magic)
        data.append(version)
        return data
    }
}

// MARK: - Incremental Stream Parser

struct StudioCamStreamParser {
    enum ParseError: LocalizedError, Equatable {
        case badMagic
        case unsupportedVersion(UInt8)
        case unknownPacketType(UInt8)
        case payloadTooLarge(UInt32)

        var errorDescription: String? {
            switch self {
            case .badMagic:
                return "Stream did not start with Studio magic bytes (STUD)."
            case .unsupportedVersion(let v):
                return "Companion speaks StudioCam v\(v); host speaks v\(StudioCamProtocol.version)."
            case .unknownPacketType(let t):
                return "Unknown StudioCam packet type: \(t)."
            case .payloadTooLarge(let len):
                return "StudioCam packet payload is too large: \(len) bytes."
            }
        }
    }

    private static let maxPayload: UInt32 = 64 * 1024 * 1024 // 64 MB ceiling
    private var buffer = Data()
    private var handshakeComplete = false

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func drain() throws -> [StudioCamProtocol.Packet] {
        var packets: [StudioCamProtocol.Packet] = []

        if !handshakeComplete {
            guard buffer.count >= StudioCamProtocol.headerLength else { return [] }
            let magic = [UInt8](buffer.prefix(4))
            guard magic == StudioCamProtocol.magic else { throw ParseError.badMagic }
            let version = buffer[buffer.startIndex + 4]
            guard version == StudioCamProtocol.version else {
                throw ParseError.unsupportedVersion(version)
            }
            buffer.removeFirst(StudioCamProtocol.headerLength)
            handshakeComplete = true
        }

        while buffer.count >= StudioCamProtocol.packetHeaderLength {
            let header = [UInt8](buffer.prefix(StudioCamProtocol.packetHeaderLength))
            let rawType = header[0]
            guard let type = StudioCamProtocol.PacketType(rawValue: rawType) else {
                throw ParseError.unknownPacketType(rawType)
            }
            let flags = StudioCamProtocol.PacketFlags(rawValue: header[1])

            var pts: Int64 = 0
            for i in 2..<10 { pts = (pts << 8) | Int64(header[i]) }

            var length: UInt32 = 0
            for i in 10..<14 { length = (length << 8) | UInt32(header[i]) }

            guard length <= Self.maxPayload else { throw ParseError.payloadTooLarge(length) }

            let total = StudioCamProtocol.packetHeaderLength + Int(length)
            guard buffer.count >= total else { break }

            let pStart = buffer.index(buffer.startIndex, offsetBy: StudioCamProtocol.packetHeaderLength)
            let pEnd = buffer.index(buffer.startIndex, offsetBy: total)
            let payload = Data(buffer[pStart..<pEnd])

            packets.append(
                StudioCamProtocol.Packet(
                    type: type,
                    flags: flags,
                    presentationTimeUs: pts,
                    payload: payload
                )
            )

            buffer.removeFirst(total)
        }

        return packets
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        handshakeComplete = false
    }
}
