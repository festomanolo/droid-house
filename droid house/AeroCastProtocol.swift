import Foundation

// MARK: - AeroCast Wire Protocol
//
// A single TCP stream carries both the device's screen and its audio from the
// Android companion to the Mac, tunnelled through `adb forward tcp:8081`.
//
// Stream layout:
//
//   ┌──────────────────────────────────────────────┐
//   │ HEADER   "AERO" magic (4B) + version (1B)    │
//   ├──────────────────────────────────────────────┤
//   │ PACKET   type(1) flags(1) pts(8) length(4)   │  ← 14-byte fixed header
//   │          payload (length bytes)              │
//   ├──────────────────────────────────────────────┤
//   │ PACKET   …                                   │
//   └──────────────────────────────────────────────┘
//
// All multi-byte integers are big-endian, matching Java's DataOutputStream so
// the companion can write them without any byte-order gymnastics.

enum AeroCastProtocol {
    static let magic: [UInt8] = [0x41, 0x45, 0x52, 0x4F]  // "AERO"
    static let version: UInt8 = 1
    static let headerLength = 5
    static let packetHeaderLength = 14
    static let port: UInt16 = 8081

    enum PacketType: UInt8 {
        /// UTF-8 JSON describing the streams: width, height, sampleRate, channels.
        case streamInfo   = 1
        /// H.264 SPS/PPS parameter sets, Annex-B framed.
        case videoConfig  = 2
        /// H.264 access unit, Annex-B framed.
        case videoFrame   = 3
        /// Describes the PCM format (redundant with streamInfo, sent on audio start).
        case audioConfig  = 4
        /// Raw signed 16-bit little-endian interleaved PCM.
        case audioFrame   = 5
        /// Keep-alive so a silent, static screen doesn't look like a dead socket.
        case heartbeat    = 6
    }

    struct PacketFlags: OptionSet {
        let rawValue: UInt8
        static let keyFrame = PacketFlags(rawValue: 1 << 0)
        static let endOfStream = PacketFlags(rawValue: 1 << 1)
    }

    struct Packet {
        let type: PacketType
        let flags: PacketFlags
        /// Presentation timestamp in microseconds on the device's clock.
        let presentationTimeUs: Int64
        let payload: Data
    }

    struct StreamInfo: Codable {
        var width: Int
        var height: Int
        var sampleRate: Int
        var channels: Int
        var videoBitRate: Int?
        var frameRate: Int?
        var deviceName: String?
    }
}

// MARK: - Incremental parser

/// Accumulates bytes off the socket and emits whole packets as they complete.
/// TCP gives no message boundaries, so every read has to survive being handed a
/// fragment of a header, several packets at once, or anything in between.
struct AeroCastStreamParser {

    enum ParseError: LocalizedError {
        case badMagic
        case unsupportedVersion(UInt8)
        case unknownPacketType(UInt8)
        case payloadTooLarge(UInt32)

        var errorDescription: String? {
            switch self {
            case .badMagic:
                return "Stream did not begin with the AeroCast magic bytes."
            case .unsupportedVersion(let v):
                return "Companion speaks AeroCast v\(v); this Mac speaks v\(AeroCastProtocol.version)."
            case .unknownPacketType(let t):
                return "Unknown AeroCast packet type \(t)."
            case .payloadTooLarge(let n):
                return "Refusing an implausible \(n)-byte AeroCast payload."
            }
        }
    }

    /// Hard ceiling on a single payload, so a desynced stream can't be coaxed
    /// into allocating gigabytes before we notice.
    private static let maxPayload: UInt32 = 32 * 1024 * 1024

    private var buffer = Data()
    private var handshakeComplete = false

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Pulls every complete packet currently in the buffer.
    /// Throws if the stream is malformed — the caller should tear the
    /// connection down rather than try to resynchronise.
    mutating func drain() throws -> [AeroCastProtocol.Packet] {
        var packets: [AeroCastProtocol.Packet] = []

        if !handshakeComplete {
            guard buffer.count >= AeroCastProtocol.headerLength else { return [] }
            let magic = [UInt8](buffer.prefix(4))
            guard magic == AeroCastProtocol.magic else { throw ParseError.badMagic }
            let version = buffer[buffer.startIndex + 4]
            guard version == AeroCastProtocol.version else {
                throw ParseError.unsupportedVersion(version)
            }
            buffer.removeFirst(AeroCastProtocol.headerLength)
            handshakeComplete = true
        }

        while buffer.count >= AeroCastProtocol.packetHeaderLength {
            let header = [UInt8](buffer.prefix(AeroCastProtocol.packetHeaderLength))

            let rawType = header[0]
            guard let type = AeroCastProtocol.PacketType(rawValue: rawType) else {
                throw ParseError.unknownPacketType(rawType)
            }
            let flags = AeroCastProtocol.PacketFlags(rawValue: header[1])

            var pts: Int64 = 0
            for i in 2..<10 { pts = (pts << 8) | Int64(header[i]) }

            var length: UInt32 = 0
            for i in 10..<14 { length = (length << 8) | UInt32(header[i]) }

            guard length <= Self.maxPayload else { throw ParseError.payloadTooLarge(length) }

            let total = AeroCastProtocol.packetHeaderLength + Int(length)
            guard buffer.count >= total else { break }   // wait for the rest

            let payloadStart = buffer.index(buffer.startIndex, offsetBy: AeroCastProtocol.packetHeaderLength)
            let payloadEnd = buffer.index(buffer.startIndex, offsetBy: total)
            let payload = Data(buffer[payloadStart..<payloadEnd])

            packets.append(
                AeroCastProtocol.Packet(
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

// MARK: - Annex-B helpers

enum AnnexB {
    /// Splits an Annex-B buffer into its constituent NAL units, dropping the
    /// 3- or 4-byte start codes.
    static func nalUnits(in data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        guard bytes.count > 3 else { return units }

        // Index of the first byte *after* each start code.
        var starts: [Int] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append(i + 3)
                    i += 3
                    continue
                } else if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append(i + 4)
                    i += 4
                    continue
                }
            }
            i += 1
        }

        guard !starts.isEmpty else { return units }

        for (index, start) in starts.enumerated() {
            // A NAL runs until the start code of the next one — which sits 3 or
            // 4 bytes before that NAL's first payload byte.
            let end: Int
            if index + 1 < starts.count {
                let nextStart = starts[index + 1]
                var codeLength = 3
                if nextStart >= 4 &&
                    bytes[nextStart - 4] == 0 && bytes[nextStart - 3] == 0 &&
                    bytes[nextStart - 2] == 0 && bytes[nextStart - 1] == 1 {
                    codeLength = 4
                }
                end = nextStart - codeLength
            } else {
                end = bytes.count
            }
            guard end > start else { continue }
            units.append(Data(bytes[start..<end]))
        }

        return units
    }

    /// H.264 NAL unit type (lower 5 bits of the first byte).
    static func type(of nal: Data) -> UInt8 {
        guard let first = nal.first else { return 0 }
        return first & 0x1F
    }

    static let sps: UInt8 = 7
    static let pps: UInt8 = 8
    static let idr: UInt8 = 5

    /// Converts Annex-B NAL units into the 4-byte-length-prefixed AVCC layout
    /// that `CMBlockBuffer` / VideoToolbox expects.
    static func avccBuffer(from nals: [Data]) -> Data {
        var out = Data()
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(nal)
        }
        return out
    }
}
