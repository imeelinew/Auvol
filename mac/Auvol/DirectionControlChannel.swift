import Darwin
import Foundation

enum SynchronizedDirection: UInt8 {
    case windowsToMac = 0
    case macToWindows = 1
}

final class DirectionControlChannel {
    private enum MessageType: UInt8 {
        case setDirection = 1
        case acknowledgement = 2
    }

    private struct DirectionState: Equatable {
        let version: UInt64
        let originID: UInt64
        let direction: SynchronizedDirection

        func outranks(_ other: DirectionState) -> Bool {
            version != other.version ? version > other.version : originID > other.originID
        }

        func hasSameKey(as other: DirectionState) -> Bool {
            version == other.version && originID == other.originID
        }
    }

    private static let magic: UInt32 = 0x3143_4c41 // Wire bytes: ALC1
    private static let packetBytes = 24
    private static let controlPort: UInt16 = 7778
    private static let deviceIDKey = "alv2ControlDeviceID"
    private static let clockKey = "alv2ControlClock"
    private static let winnerVersionKey = "alv2ControlWinnerVersion"
    private static let winnerOriginKey = "alv2ControlWinnerOrigin"
    private static let winnerDirectionKey = "alv2ControlWinnerDirection"

    private let queue = DispatchQueue(label: "com.eli.Auvol.direction-control",
                                      qos: .userInitiated)
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var peerIP: String
    private let deviceID: UInt64
    private var clock: UInt64
    private var winner: DirectionState
    private var pending: DirectionState?
    private var retryToken: UInt64 = 0

    var onDirection: ((SynchronizedDirection) -> Void)?

    init(peerIP: String, initialDirection: SynchronizedDirection) {
        self.peerIP = peerIP
        let defaults = UserDefaults.standard
        let savedDeviceID = Self.readUInt64(Self.deviceIDKey, from: defaults)
        let generatedDeviceID = UInt64.random(in: 1...UInt64.max)
        deviceID = savedDeviceID == 0 ? generatedDeviceID : savedDeviceID

        let savedClock = Self.readUInt64(Self.clockKey, from: defaults)
        let savedVersion = Self.readUInt64(Self.winnerVersionKey, from: defaults)
        let savedOrigin = Self.readUInt64(Self.winnerOriginKey, from: defaults)
        let savedDirection = SynchronizedDirection(rawValue:
            UInt8(defaults.integer(forKey: Self.winnerDirectionKey)))
        clock = max(savedClock, savedVersion)
        winner = DirectionState(version: savedVersion,
                                originID: savedOrigin,
                                direction: savedVersion > 0
                                    ? (savedDirection ?? initialDirection)
                                    : initialDirection)
        defaults.set(String(deviceID), forKey: Self.deviceIDKey)
        persistState()
    }

    func start() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return "Cannot open direction control socket" }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.controlPort.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let result = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            return "UDP port \(Self.controlPort) is unavailable (\(String(cString: strerror(code))))"
        }

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        socketFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainIncoming() }
        readSource = source
        source.resume()
        return nil
    }

    func stop() {
        queue.sync {
            retryToken &+= 1
            pending = nil
            readSource?.cancel()
            readSource = nil
            if socketFD >= 0 {
                close(socketFD)
                socketFD = -1
            }
        }
    }

    func setPeerIP(_ value: String) {
        queue.async { [weak self] in self?.peerIP = value }
    }

    func publish(_ direction: SynchronizedDirection) {
        queue.async { [weak self] in
            guard let self else { return }
            clock = max(clock, winner.version) &+ 1
            if clock == 0 { clock = 1 }
            let state = DirectionState(version: clock,
                                       originID: deviceID,
                                       direction: direction)
            winner = state
            pending = state
            retryToken &+= 1
            persistState()
            send(state, type: .setDirection, to: peerAddress())
            scheduleRetry(state, token: retryToken, delayIndex: 0)
        }
    }

    private func scheduleRetry(_ state: DirectionState,
                               token: UInt64,
                               delayIndex: Int) {
        let delays = [0.15, 0.40, 0.90]
        guard delayIndex < delays.count else {
            if pending == state { pending = nil }
            return
        }
        queue.asyncAfter(deadline: .now() + delays[delayIndex]) { [weak self] in
            guard let self, retryToken == token, pending == state else { return }
            send(state, type: .setDirection, to: peerAddress())
            scheduleRetry(state, token: token, delayIndex: delayIndex + 1)
        }
    }

    private func drainIncoming() {
        guard socketFD >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 64)
        while true {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socketFD, base, raw.count, 0, $0, &sourceLength)
                    }
                }
            }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            guard count > 0 else { return }
            guard sourceMatchesPeer(source),
                  let (type, incoming) = parse(bytes, length: count) else { continue }
            receive(type: type, state: incoming, source: source)
        }
    }

    private func receive(type: MessageType,
                         state incoming: DirectionState,
                         source: sockaddr_in) {
        if incoming.version > clock {
            clock = incoming.version
            persistState()
        }

        switch type {
        case .setDirection:
            if incoming.outranks(winner) {
                accept(incoming)
            }
            send(winner, type: .acknowledgement, to: source)

        case .acknowledgement:
            if incoming.outranks(winner) {
                accept(incoming)
            }
            if let pending,
               incoming.hasSameKey(as: pending) || incoming.outranks(pending) {
                self.pending = nil
                retryToken &+= 1
            }
        }
    }

    private func accept(_ state: DirectionState) {
        winner = state
        if let pending, state.outranks(pending) {
            self.pending = nil
            retryToken &+= 1
        }
        persistState()
        DispatchQueue.main.async { [weak self] in
            self?.onDirection?(state.direction)
        }
    }

    private func send(_ state: DirectionState,
                      type: MessageType,
                      to address: sockaddr_in?) {
        guard socketFD >= 0, var address else { return }
        var bytes = [UInt8](repeating: 0, count: Self.packetBytes)
        Self.write32(Self.magic, to: &bytes, at: 0)
        bytes[4] = type.rawValue
        bytes[5] = state.direction.rawValue
        Self.write64(state.version, to: &bytes, at: 8)
        Self.write64(state.originID, to: &bytes, at: 16)
        _ = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, base, raw.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func parse(_ bytes: [UInt8],
                       length: Int) -> (MessageType, DirectionState)? {
        guard length == Self.packetBytes,
              Self.read32(bytes, at: 0) == Self.magic,
              let type = MessageType(rawValue: bytes[4]),
              let direction = SynchronizedDirection(rawValue: bytes[5]),
              bytes[6] == 0, bytes[7] == 0 else { return nil }
        return (type, DirectionState(version: Self.read64(bytes, at: 8),
                                     originID: Self.read64(bytes, at: 16),
                                     direction: direction))
    }

    private func peerAddress() -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.controlPort.bigEndian
        guard inet_pton(AF_INET, peerIP, &address.sin_addr) == 1 else { return nil }
        return address
    }

    private func sourceMatchesPeer(_ source: sockaddr_in) -> Bool {
        guard let peer = peerAddress() else { return false }
        return source.sin_addr.s_addr == peer.sin_addr.s_addr
    }

    private func persistState() {
        let defaults = UserDefaults.standard
        defaults.set(String(clock), forKey: Self.clockKey)
        defaults.set(String(winner.version), forKey: Self.winnerVersionKey)
        defaults.set(String(winner.originID), forKey: Self.winnerOriginKey)
        defaults.set(Int(winner.direction.rawValue),
                     forKey: Self.winnerDirectionKey)
    }

    private static func readUInt64(_ key: String,
                                   from defaults: UserDefaults) -> UInt64 {
        UInt64(defaults.string(forKey: key) ?? "") ?? 0
    }

    private static func read32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
            UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 |
            UInt32(bytes[offset + 3]) << 24
    }

    private static func read64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        UInt64(read32(bytes, at: offset)) |
            UInt64(read32(bytes, at: offset + 4)) << 32
    }

    private static func write32(_ value: UInt32,
                                to bytes: inout [UInt8],
                                at offset: Int) {
        for index in 0..<4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }

    private static func write64(_ value: UInt64,
                                to bytes: inout [UInt8],
                                at offset: Int) {
        for index in 0..<8 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }

    deinit {
        stop()
    }
}
