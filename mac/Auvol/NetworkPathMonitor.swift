import Darwin
import Foundation
import OSLog
import SystemConfiguration

enum NetworkPathKind: String {
    case fallback
    case wired

    var title: String {
        switch self {
        case .fallback: return "Fallback network"
        case .wired: return "Wired Ethernet"
        }
    }
}

struct NetworkPathSelection: Equatable {
    let peerIP: String
    let localIP: String?
    let kind: NetworkPathKind
}

/// Finds an Auvol peer on an active Ethernet interface. This discovery channel
/// is deliberately separate from ALV2 audio and ALC1 direction control.
final class NetworkPathMonitor {
    private static let discoveryPort: UInt16 = 7779
    private static let discoveryMagic: UInt32 = 0x3150_5541 // Wire bytes: AUP1.
    private static let packetBytes = 32
    private static let request: UInt8 = 1
    private static let response: UInt8 = 2
    private static let deviceIDKey = "auvolNetworkDiscoveryDeviceID"

    private struct Candidate {
        let name: String
        let localAddress: UInt32
        let broadcastAddress: UInt32
        let localIP: String
    }

    private let queue = DispatchQueue(label: "com.eli.Auvol.network-path",
                                       qos: .utility)
    private let logger = Logger(subsystem: "com.eli.Auvol", category: "network-path")
    private let stateLock = NSLock()
    private let deviceID: UInt64
    private var fallbackPeerIP: String
    private var running = false
    private var activeSelection: NetworkPathSelection?
    private var listenerFD: Int32 = -1

    var onSelection: ((NetworkPathSelection) -> Void)?

    init(fallbackPeerIP: String) {
        let defaults = UserDefaults.standard
        let saved = UInt64(defaults.string(forKey: Self.deviceIDKey) ?? "") ?? 0
        let generated = UInt64.random(in: 1...UInt64.max)
        deviceID = saved == 0 ? generated : saved
        defaults.set(String(deviceID), forKey: Self.deviceIDKey)
        self.fallbackPeerIP = fallbackPeerIP
    }

    func start() {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            return
        }
        running = true
        stateLock.unlock()
        queue.async { [weak self] in self?.run() }
    }

    func stop() {
        stateLock.lock()
        running = false
        stateLock.unlock()
    }

    func setFallbackPeerIP(_ value: String) {
        stateLock.lock()
        fallbackPeerIP = value
        stateLock.unlock()
    }

    private func run() {
        guard let listener = openListener() else {
            stateLock.lock()
            running = false
            stateLock.unlock()
            return
        }
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            close(listener)
            return
        }
        listenerFD = listener
        stateLock.unlock()

        var failures = 0
        publish(NetworkPathSelection(peerIP: fallbackPeerAddress(),
                                     localIP: nil, kind: .fallback))
        while isRunning() {
            if let wired = probeWired(listener) {
                failures = 0
                publish(wired)
            } else {
                failures += 1
                if failures >= 2 {
                    if failures == 2 {
                        logger.notice("wired discovery unavailable; using fallback")
                    }
                    publish(NetworkPathSelection(peerIP: fallbackPeerAddress(),
                                                 localIP: nil,
                                                 kind: .fallback))
                }
            }
            // Keep the listener active in overlapping windows on both peers;
            // the discovery socket is intentionally separate from audio.
            for _ in 0..<2 where isRunning() {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        stateLock.lock()
        if listenerFD == listener { listenerFD = -1 }
        stateLock.unlock()
        close(listener)
    }

    private func isRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func fallbackPeerAddress() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return fallbackPeerIP
    }

    private func publish(_ selection: NetworkPathSelection) {
        stateLock.lock()
        let changed = activeSelection != selection
        if changed { activeSelection = selection }
        let callback = changed ? onSelection : nil
        stateLock.unlock()
        if changed {
            logger.notice("network path=\(selection.kind.rawValue, privacy: .public) peer=\(selection.peerIP, privacy: .public) local=\(selection.localIP ?? "none", privacy: .public)")
            callback?(selection)
        }
    }

    private func interfaceTypes() -> [String: String] {
        var result: [String: String] = [:]
        let all = SCNetworkInterfaceCopyAll() as NSArray
        for case let interface as SCNetworkInterface in all {
            guard let name = SCNetworkInterfaceGetBSDName(interface)
                    .map({ String($0) }) else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(interface)
                .map { String($0) } ?? ""
            result[name] = type
        }
        return result
    }

    private func candidates() -> [Candidate] {
        let types = interfaceTypes()
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var result: [Candidate] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0,
                  let namePointer = entry.pointee.ifa_name,
                  let addressPointer = entry.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            let name = String(cString: namePointer)
            guard types[name] == "Ethernet" || types[name] == "FireWire",
                  let netmaskPointer = entry.pointee.ifa_netmask else { continue }
            let address = addressPointer.withMemoryRebound(
                to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = netmaskPointer.withMemoryRebound(
                to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let hostAddress = UInt32(bigEndian: address)
            let hostMask = UInt32(bigEndian: netmask)
            let broadcast = ((hostAddress & hostMask) | ~hostMask).bigEndian
            guard let localIP = ipv4String(address), !localIP.isEmpty else { continue }
            result.append(Candidate(name: name,
                                    localAddress: address,
                                    broadcastAddress: broadcast,
                                    localIP: localIP))
        }
        return result
    }

    private func openListener() -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
                   socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.discoveryPort.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
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
        return fd
    }

    private func openProbe(_ candidate: Candidate) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        let interfaceIndex = candidate.name.withCString { if_nametoindex($0) }
        guard interfaceIndex != 0 else {
            close(fd)
            return nil
        }
        var boundInterface = interfaceIndex
        guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &boundInterface,
                         socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
            close(fd)
            return nil
        }
        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast,
                   socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr = in_addr(s_addr: candidate.localAddress)
        let bindResult = withUnsafePointer(to: &local) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            return nil
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return fd
    }

    private func probeWired(_ listener: Int32) -> NetworkPathSelection? {
        let available = candidates()
        guard !available.isEmpty else { return nil }

        let nonce = UInt64.random(in: 1...UInt64.max)
        let request = packet(type: Self.request, deviceID: deviceID, nonce: nonce)
        var sockets: [Int32] = []
        var socketCandidates: [Candidate] = []
        defer { sockets.forEach { close($0) } }

        for candidate in available {
            guard let fd = openProbe(candidate) else { continue }
            var destination = sockaddr_in()
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = Self.discoveryPort.bigEndian
            destination.sin_addr = in_addr(s_addr: candidate.broadcastAddress)
            let sent = request.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, base, raw.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == request.count else {
                close(fd)
                continue
            }
            sockets.append(fd)
            socketCandidates.append(candidate)
        }
        guard !sockets.isEmpty else { return nil }

        let deadline = Date().addingTimeInterval(0.35)
        while isRunning(), Date() < deadline {
            var descriptors = [pollfd(fd: listener,
                                      events: Int16(POLLIN), revents: 0)]
            descriptors.append(contentsOf: sockets.map {
                pollfd(fd: $0, events: Int16(POLLIN), revents: 0)
            })
            let result = descriptors.withUnsafeMutableBufferPointer { buffer in
                poll(buffer.baseAddress, nfds_t(buffer.count), 50)
            }
            guard result >= 0 else { break }

            if descriptors[0].revents & Int16(POLLIN) != 0 {
                drainRequests(listener)
            }
            for index in sockets.indices {
                guard descriptors[index + 1].revents & Int16(POLLIN) != 0 else {
                    continue
                }
                var bytes = [UInt8](repeating: 0, count: Self.packetBytes)
                var source = sockaddr_in()
                var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = bytes.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return withUnsafeMutablePointer(to: &source) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(sockets[index], base, raw.count, 0, $0,
                                     &sourceLength)
                        }
                    }
                }
                guard count == Self.packetBytes,
                      let parsed = parse(bytes, length: count),
                      parsed.type == Self.response,
                      parsed.deviceID != deviceID,
                      parsed.nonce == nonce,
                      let peerIP = ipv4String(source.sin_addr.s_addr) else {
                    continue
                }
                return NetworkPathSelection(peerIP: peerIP,
                                            localIP: socketCandidates[index].localIP,
                                            kind: .wired)
            }
        }
        return nil
    }

    private func drainRequests(_ listener: Int32) {
        while true {
            var bytes = [UInt8](repeating: 0, count: Self.packetBytes)
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(listener, base, raw.count, 0, $0, &sourceLength)
                    }
                }
            }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            guard count == Self.packetBytes,
                  let parsed = parse(bytes, length: count),
                  parsed.type == Self.request,
                  parsed.deviceID != deviceID else { continue }
            let response = packet(type: Self.response,
                                  deviceID: deviceID,
                                  nonce: parsed.nonce)
            response.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                withUnsafePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(listener, base, raw.count, 0, $0, sourceLength)
                    }
                }
            }
        }
    }

    private func packet(type: UInt8, deviceID: UInt64, nonce: UInt64) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.packetBytes)
        write32(Self.discoveryMagic, to: &bytes, at: 0)
        bytes[4] = type
        bytes[5] = 1
        write64(deviceID, to: &bytes, at: 8)
        write64(nonce, to: &bytes, at: 16)
        return bytes
    }

    private func parse(_ bytes: [UInt8], length: Int)
        -> (type: UInt8, deviceID: UInt64, nonce: UInt64)? {
        guard length == Self.packetBytes,
              read32(bytes, at: 0) == Self.discoveryMagic,
              bytes[5] == 1, bytes[6] == 0, bytes[7] == 0,
              bytes[4] == Self.request || bytes[4] == Self.response else {
            return nil
        }
        let deviceID = read64(bytes, at: 8)
        let nonce = read64(bytes, at: 16)
        guard deviceID != 0, nonce != 0 else { return nil }
        return (bytes[4], deviceID, nonce)
    }

    private func ipv4String(_ address: UInt32) -> String? {
        var address = in_addr(s_addr: address)
        var storage = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return storage.withUnsafeMutableBufferPointer { buffer in
            guard inet_ntop(AF_INET, &address, buffer.baseAddress,
                            socklen_t(buffer.count)) != nil,
                  let base = buffer.baseAddress else { return nil }
            return String(cString: base)
        }
    }

    private func write32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { raw in
            bytes.replaceSubrange(offset..<(offset + 4), with: raw)
        }
    }

    private func write64(_ value: UInt64, to bytes: inout [UInt8], at offset: Int) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { raw in
            bytes.replaceSubrange(offset..<(offset + 8), with: raw)
        }
    }

    private func read32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[offset + index]) << (UInt32(index) * 8)
        }
        return value
    }

    private func read64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << (UInt64(index) * 8)
        }
        return value
    }

    deinit {
        stop()
    }
}
