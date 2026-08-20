import Darwin
import Foundation

@main
struct MouseControlChannelTests {
    private static var failures = 0

    private static func check(_ condition: @autoclosure () -> Bool,
                              _ message: String) {
        if !condition() {
            failures += 1
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }

    private static func write16(_ value: UInt16, to bytes: inout [UInt8],
                                at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func write32(_ value: UInt32, to bytes: inout [UInt8],
                                at offset: Int) {
        for index in 0..<4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }

    private static func write64(_ value: UInt64, to bytes: inout [UInt8],
                                at offset: Int) {
        for index in 0..<8 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }

    private static func send(_ bytes: [UInt8], from socketFD: Int32,
                             to localIP: String) {
        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = MouseControlChannel.port.bigEndian
        check(inet_pton(AF_INET, localIP, &destination.sin_addr) == 1,
              "could not create destination address")
        let result = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, base, raw.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        check(result == bytes.count, "UDP test packet was not sent")
    }

    private static func statePacket() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 24)
        write32(0x3149_4c41, to: &bytes, at: 0)
        bytes[4] = 2
        bytes[5] = 3 // Enabled, cursor hosted by Mac.
        write64(UInt64.max - 1, to: &bytes, at: 8)
        write64(UInt64.max - 1, to: &bytes, at: 16)
        return bytes
    }

    private static func eventPacket(sequence: UInt32, session: UInt64,
                                    dx: Int16) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 28)
        write32(0x3149_4c41, to: &bytes, at: 0)
        bytes[4] = 3
        write16(UInt16(bitPattern: dx), to: &bytes, at: 8)
        write32(sequence, to: &bytes, at: 16)
        write64(session, to: &bytes, at: 20)
        return bytes
    }

    static func main() {
        guard CommandLine.arguments.count == 3 else {
            FileHandle.standardError.write(
                Data("usage: test <channel-local-ip> <peer-source-ip>\n".utf8)
            )
            exit(2)
        }
        let localIP = CommandLine.arguments[1]
        let peerIP = CommandLine.arguments[2]
        let peerSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        check(peerSocket >= 0, "could not create peer socket")
        guard peerSocket >= 0 else { exit(1) }

        var source = sockaddr_in()
        source.sin_family = sa_family_t(AF_INET)
        source.sin_port = 0
        check(inet_pton(AF_INET, peerIP, &source.sin_addr) == 1,
              "could not create source address")
        let bindResult = withUnsafePointer(to: &source) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(peerSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        check(bindResult == 0, "could not bind peer socket (errno \(errno))")

        let becameAvailable = DispatchSemaphore(value: 0)
        let becameUnavailable = DispatchSemaphore(value: 0)
        let receivedEvent = DispatchSemaphore(value: 0)
        let eventLock = NSLock()
        var receivedDX: [Int16] = []

        let channel = MouseControlChannel(
            peerIP: peerIP,
            initial: MouseShareState(enabled: true, host: .mac)
        )
        channel.setLocalIP(localIP)
        channel.onPeerAvailability = { available in
            (available ? becameAvailable : becameUnavailable).signal()
        }
        channel.onEvent = { event in
            eventLock.lock()
            receivedDX.append(event.dx)
            eventLock.unlock()
            receivedEvent.signal()
        }
        check(channel.start() == nil, "mouse channel did not start")

        send(statePacket(), from: peerSocket, to: localIP)
        check(becameAvailable.wait(timeout: .now() + 1) == .success,
              "valid heartbeat did not establish the peer lease")
        check(channel.peerLeaseIsValid, "fresh peer lease is not valid")

        send(eventPacket(sequence: 7, session: 101, dx: 7),
             from: peerSocket, to: localIP)
        check(receivedEvent.wait(timeout: .now() + 1) == .success,
              "first event was not delivered")
        send(eventPacket(sequence: 1, session: 101, dx: 1),
             from: peerSocket, to: localIP)
        check(receivedEvent.wait(timeout: .now() + 0.2) == .timedOut,
              "out-of-order event was delivered")
        send(eventPacket(sequence: 1, session: 202, dx: 2),
             from: peerSocket, to: localIP)
        check(receivedEvent.wait(timeout: .now() + 1) == .success,
              "new sender session did not reset event sequencing")

        eventLock.lock()
        let values = receivedDX
        eventLock.unlock()
        check(values == [7, 2], "unexpected delivered event sequence: \(values)")

        Thread.sleep(forTimeInterval: 1.65)
        check(!channel.peerLeaseIsValid,
              "input callback lease did not expire after 1.5 seconds")
        check(becameUnavailable.wait(timeout: .now() + 0.8) == .success,
              "peer availability did not converge to disconnected")

        channel.stop()
        close(peerSocket)
        exit(failures == 0 ? 0 : 1)
    }
}
