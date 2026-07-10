import Foundation

enum ALV2 {
    /// Little-endian bytes spell "ALV2" on the wire.
    static let magic: UInt32 = 0x3256_4c41
    static let typeConfig: UInt16 = 0
    static let typeAudio: UInt16 = 1
    static let configHeaderBytes: UInt16 = 28
    static let audioHeaderBytes: UInt16 = 32
    static let stereoChannels: UInt16 = 2
    static let maximumPacketFrames: UInt16 = 180
}

struct StreamConfig: Equatable {
    let streamID: UInt32
    let sampleRate: Double
    let channels: UInt16
    let maximumPacketFrames: UInt16
    let capturePeriodFrames: UInt32
}

struct AudioPacket {
    let streamID: UInt32
    let sequence: UInt32
    let firstFrame: UInt64
    let frameCount: UInt16
    let flags: UInt16
    let payloadOffset: Int
}

enum Packet {
    case config(StreamConfig)
    case audio(AudioPacket)
}

enum PacketParser {
    static func parse(_ bytes: [UInt8], length: Int) -> Packet? {
        guard length >= 12, le32(bytes, 0) == ALV2.magic else { return nil }

        let type = le16(bytes, 4)
        let headerBytes = le16(bytes, 6)
        let streamID = le32(bytes, 8)
        guard streamID != 0 else { return nil }

        switch type {
        case ALV2.typeConfig:
            guard headerBytes == ALV2.configHeaderBytes,
                  length == Int(headerBytes) else { return nil }
            let sampleRate = le32(bytes, 12)
            let channels = le16(bytes, 16)
            let maximumPacketFrames = le16(bytes, 18)
            let capturePeriodFrames = le32(bytes, 20)
            guard (8_000...192_000).contains(sampleRate),
                  channels == ALV2.stereoChannels,
                  (1...ALV2.maximumPacketFrames).contains(maximumPacketFrames),
                  capturePeriodFrames > 0 else { return nil }
            return .config(StreamConfig(
                streamID: streamID,
                sampleRate: Double(sampleRate),
                channels: channels,
                maximumPacketFrames: maximumPacketFrames,
                capturePeriodFrames: capturePeriodFrames
            ))

        case ALV2.typeAudio:
            guard headerBytes == ALV2.audioHeaderBytes,
                  length >= Int(headerBytes) else { return nil }
            let sequence = le32(bytes, 12)
            let firstFrame = le64(bytes, 16)
            let frameCount = le16(bytes, 24)
            let channels = le16(bytes, 26)
            let flags = le16(bytes, 28)
            guard channels == ALV2.stereoChannels,
                  (1...ALV2.maximumPacketFrames).contains(frameCount) else { return nil }
            let payloadBytes = Int(frameCount) * Int(channels) * MemoryLayout<Float>.size
            guard length == Int(headerBytes) + payloadBytes else { return nil }
            return .audio(AudioPacket(
                streamID: streamID,
                sequence: sequence,
                firstFrame: firstFrame,
                frameCount: frameCount,
                flags: flags,
                payloadOffset: Int(headerBytes)
            ))

        default:
            return nil
        }
    }
}

private func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) |
        UInt16(bytes[offset + 1]) << 8
}

private func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) |
        UInt32(bytes[offset + 1]) << 8 |
        UInt32(bytes[offset + 2]) << 16 |
        UInt32(bytes[offset + 3]) << 24
}

private func le64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    UInt64(le32(bytes, offset)) |
        UInt64(le32(bytes, offset + 4)) << 32
}
