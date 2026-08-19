import Darwin
import Foundation

enum CursorHost: UInt8 {
    case windows = 0
    case mac = 1
}

struct MouseShareState: Equatable {
    var enabled: Bool
    var host: CursorHost
}

struct MouseWireEvent {
    var buttons: UInt8
    var dx: Int16
    var dy: Int16
    var wheel: Int16
    var hwheel: Int16
    var sequence: UInt32
}

final class MouseControlChannel {
    private enum MessageType: UInt8 {
        case setState = 1
        case acknowledgement = 2
        case event = 3
    }

    private struct WireState: Equatable {
        let version: UInt64
        let originID: UInt64
        let enabled: Bool
        let host: CursorHost

        var share: MouseShareState {
            MouseShareState(enabled: enabled, host: host)
        }

        func outranks(_ other: WireState) -> Bool {
            version != other.version ? version > other.version : originID > other.originID
        }

        func hasSameKey(as other: WireState) -> Bool {
            version == other.version && originID == other.originID
        }
    }

    private static let magic: UInt32 = 0x3149_4c41 // Wire bytes: ALI1
    private static let stateBytes = 24
    private static let eventBytes = 20
    static let port: UInt16 = 7780
    private static let deviceIDKey = "ali1ControlDeviceID"
    private static let clockKey = "ali1ControlClock"
    private static let winnerVersionKey = "ali1ControlWinnerVersion"
    private static let winnerOriginKey = "ali1ControlWinnerOrigin"
    private static let winnerFlagsKey = "ali1ControlWinnerFlags"

    private let queue = DispatchQueue(label: "com.eli.Auvol.mouse-control",
                                      qos: .userInteractive)
    private let sendLock = NSLock()
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var peerIP: String
    private var localIP: String?
    private let deviceID: UInt64
    private var clock: UInt64
    private var winner: WireState
    private var pending: WireState?
    private var retryToken: UInt64 = 0
    private var heartbeatToken: UInt64 = 0
    private var eventSequence: UInt32 = 0

    var onState: ((MouseShareState) -> Void)?
    var onEvent: ((MouseWireEvent) -> Void)?

    init(peerIP: String, initial: MouseShareState) {
        self.peerIP = peerIP
        self.localIP = nil
        let defaults = UserDefaults.standard
        let savedDeviceID = Self.readUInt64(Self.deviceIDKey, from: defaults)
        deviceID = savedDeviceID == 0
            ? UInt64.random(in: 1...UInt64.max)
            : savedDeviceID
        let savedClock = Self.readUInt64(Self.clockKey, from: defaults)
        let savedVersion = Self.readUInt64(Self.winnerVersionKey, from: defaults)
        let savedOrigin = Self.readUInt64(Self.winnerOriginKey, from: defaults)
        let savedFlags = UInt8(defaults.integer(forKey: Self.winnerFlagsKey))
        clock = max(savedClock, savedVersion)
        if savedVersion > 0 {
            winner = WireState(version: savedVersion,
                               originID: savedOrigin,
                               enabled: (savedFlags & 1) != 0,
                               host: (savedFlags & 2) != 0 ? .mac : .windows)
        } else {
            winner = WireState(version: 0,
                               originID: 0,
                               enabled: initial.enabled,
                               host: initial.host)
        }
        defaults.set(String(deviceID), forKey: Self.deviceIDKey)
        persistState()
    }

    var current: MouseShareState { winner.share }

    func start() -> String? {
        let fd = makeSocket(localIP: localIP)
        guard let fd else {
            return "UDP port \(Self.port) is unavailable"
        }
        socketFD = fd
        attachReader(fd)
        queue.async { [weak self] in
            guard let self else { return }
            heartbeatToken &+= 1
            scheduleHeartbeat(token: heartbeatToken)
        }
        return nil
    }

    func stop() {
        queue.sync {
            retryToken &+= 1
            heartbeatToken &+= 1
            pending = nil
            readSource?.cancel()
            readSource = nil
            sendLock.lock()
            if socketFD >= 0 {
                close(socketFD)
                socketFD = -1
            }
            sendLock.unlock()
        }
    }

    func setPeerIP(_ value: String) {
        queue.async { [weak self] in self?.peerIP = value }
    }

    func setLocalIP(_ value: String?) {
        queue.async { [weak self] in self?.rebind(localIP: value) }
    }

    func publish(_ share: MouseShareState) {
        queue.async { [weak self] in
            guard let self else { return }
            clock = max(clock, winner.version) &+ 1
            if clock == 0 { clock = 1 }
            let state = WireState(version: clock,
                                  originID: deviceID,
                                  enabled: share.enabled,
                                  host: share.host)
            winner = state
            pending = state
            retryToken &+= 1
            persistState()
            send(state, type: .setState, to: peerAddress())
            scheduleRetry(state, token: retryToken, delayIndex: 0)
        }
    }

    func sendEvent(buttons: UInt8, dx: Int16, dy: Int16,
                   wheel: Int16, hwheel: Int16) {
        eventSequence &+= 1
        if eventSequence == 0 { eventSequence = 1 }
        var bytes = [UInt8](repeating: 0, count: Self.eventBytes)
        Self.write32(Self.magic, to: &bytes, at: 0)
        bytes[4] = MessageType.event.rawValue
        bytes[5] = buttons
        Self.write16(UInt16(bitPattern: dx), to: &bytes, at: 8)
        Self.write16(UInt16(bitPattern: dy), to: &bytes, at: 10)
        Self.write16(UInt16(bitPattern: wheel), to: &bytes, at: 12)
        Self.write16(UInt16(bitPattern: hwheel), to: &bytes, at: 14)
        Self.write32(eventSequence, to: &bytes, at: 16)
        sendLock.lock()
        defer { sendLock.unlock() }
        guard socketFD >= 0, var address = peerAddress() else { return }
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

    private func rebind(localIP: String?) {
        guard self.localIP != localIP else { return }
        self.localIP = localIP
        guard socketFD >= 0 else { return }
        readSource?.cancel()
        readSource = nil
        sendLock.lock()
        close(socketFD)
        socketFD = -1
        sendLock.unlock()
        var fd = makeSocket(localIP: localIP)
        if fd == nil, localIP != nil {
            self.localIP = nil
            fd = makeSocket(localIP: nil)
        }
        guard let fd else { return }
        sendLock.lock()
        socketFD = fd
        sendLock.unlock()
        attachReader(fd)
    }

    private func attachReader(_ fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainIncoming() }
        readSource = source
        source.resume()
    }

    private func makeSocket(localIP: String?) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        if let localIP {
            guard inet_pton(AF_INET, localIP, &address.sin_addr) == 1 else {
                close(fd)
                return nil
            }
        } else {
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
        }
        let result = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var dscp: Int32 = 0xb8
        setsockopt(fd, IPPROTO_IP, IP_TOS, &dscp, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func scheduleRetry(_ state: WireState, token: UInt64, delayIndex: Int) {
        let delays = [0.15, 0.40, 0.90]
        guard delayIndex < delays.count else {
            if pending == state { pending = nil }
            return
        }
        queue.asyncAfter(deadline: .now() + delays[delayIndex]) { [weak self] in
            guard let self, retryToken == token, pending == state else { return }
            send(state, type: .setState, to: peerAddress())
            scheduleRetry(state, token: token, delayIndex: delayIndex + 1)
        }
    }

    private func scheduleHeartbeat(token: UInt64) {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, heartbeatToken == token, socketFD >= 0 else { return }
            send(winner, type: .acknowledgement, to: peerAddress())
            scheduleHeartbeat(token: token)
        }
    }

    private func drainIncoming() {
        guard socketFD >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 64)
        while true {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            sendLock.lock()
            let count = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socketFD, base, raw.count, 0, $0, &sourceLength)
                    }
                }
            }
            sendLock.unlock()
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            guard count > 0 else { return }
            guard sourceMatchesPeer(source) else { continue }
            if let event = parseEvent(bytes, length: count) {
                onEvent?(event)
                continue
            }
            guard let (type, incoming) = parseState(bytes, length: count) else { continue }
            receive(type: type, state: incoming, source: source)
        }
    }

    private func receive(type: MessageType, state incoming: WireState,
                         source: sockaddr_in) {
        if incoming.version > clock {
            clock = incoming.version
            persistState()
        }
        switch type {
        case .setState:
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
        case .event:
            break
        }
    }

    private func accept(_ state: WireState) {
        winner = state
        if let pending, state.outranks(pending) {
            self.pending = nil
            retryToken &+= 1
        }
        persistState()
        onState?(state.share)
    }

    private func send(_ state: WireState, type: MessageType, to address: sockaddr_in?) {
        guard var address else { return }
        var bytes = [UInt8](repeating: 0, count: Self.stateBytes)
        Self.write32(Self.magic, to: &bytes, at: 0)
        bytes[4] = type.rawValue
        bytes[5] = (state.enabled ? 1 : 0) | (state.host == .mac ? 2 : 0)
        Self.write64(state.version, to: &bytes, at: 8)
        Self.write64(state.originID, to: &bytes, at: 16)
        sendLock.lock()
        defer { sendLock.unlock() }
        guard socketFD >= 0 else { return }
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

    private func parseState(_ bytes: [UInt8],
                            length: Int) -> (MessageType, WireState)? {
        guard length == Self.stateBytes,
              Self.read32(bytes, at: 0) == Self.magic,
              let type = MessageType(rawValue: bytes[4]),
              type != .event,
              bytes[6] == 0, bytes[7] == 0 else { return nil }
        let host: CursorHost = (bytes[5] & 2) != 0 ? .mac : .windows
        return (type, WireState(version: Self.read64(bytes, at: 8),
                                originID: Self.read64(bytes, at: 16),
                                enabled: (bytes[5] & 1) != 0,
                                host: host))
    }

    private func parseEvent(_ bytes: [UInt8], length: Int) -> MouseWireEvent? {
        guard length == Self.eventBytes,
              Self.read32(bytes, at: 0) == Self.magic,
              bytes[4] == MessageType.event.rawValue else { return nil }
        return MouseWireEvent(
            buttons: bytes[5],
            dx: Int16(bitPattern: Self.read16(bytes, at: 8)),
            dy: Int16(bitPattern: Self.read16(bytes, at: 10)),
            wheel: Int16(bitPattern: Self.read16(bytes, at: 12)),
            hwheel: Int16(bitPattern: Self.read16(bytes, at: 14)),
            sequence: Self.read32(bytes, at: 16)
        )
    }

    private func peerAddress() -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
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
        let flags = (winner.enabled ? 1 : 0) | (winner.host == .mac ? 2 : 0)
        defaults.set(flags, forKey: Self.winnerFlagsKey)
    }

    private static func readUInt64(_ key: String, from defaults: UserDefaults) -> UInt64 {
        UInt64(defaults.string(forKey: key) ?? "") ?? 0
    }

    private static func read16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
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

    private static func write16(_ value: UInt16, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func write32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        for index in 0..<4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }

    private static func write64(_ value: UInt64, to bytes: inout [UInt8], at offset: Int) {
        for index in 0..<8 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }

    deinit {
        stop()
    }
}
