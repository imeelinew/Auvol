import Foundation

enum ALV1 {
    static let magic: UInt32      = 0x414C5631
    static let typeConfig: UInt32 = 0
    static let typeAudio: UInt32  = 1
}

struct AudioConfig: Equatable {
    let sampleRate: Double
    let channels: UInt32
    let frameSize: UInt32
}

enum Packet {
    case config(AudioConfig)
    case audio(payloadOffset: Int, payloadFloats: Int)
}

enum PacketParser {
    static func parse(_ buf: [UInt8], length: Int) -> Packet? {
        guard length >= 8 else { return nil }
        guard le32(buf, 0) == ALV1.magic else { return nil }
        let type = le32(buf, 4)

        switch type {
        case ALV1.typeConfig:
            guard length >= 20 else { return nil }
            return .config(AudioConfig(
                sampleRate: Double(le32(buf, 8)),
                channels:   le32(buf, 12),
                frameSize:  le32(buf, 16)))
        case ALV1.typeAudio:
            guard length >= 20 else { return nil }
            let floats = (length - 20) / MemoryLayout<Float>.size
            return .audio(payloadOffset: 20, payloadFloats: floats)
        default:
            return nil
        }
    }
}

private func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24
}
