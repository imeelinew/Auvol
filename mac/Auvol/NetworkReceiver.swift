import Foundation

/// One high-priority serial receive path. Packet parsing and ring writes stay off the UI thread.
final class NetworkReceiver {
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.eli.Auvol.udp", qos: .userInteractive)
    private let stateLock = NSLock()
    private let stopped = DispatchGroup()
    private var socketFD: Int32 = -1
    private var bonjour: NetService?
    private var lastSenderIP = ""

    var onConfig: ((StreamConfig) -> Void)?
    var onAudio: ((AudioPacket, UnsafePointer<Float>) -> Void)?
    var onSenderSeen: ((String) -> Void)?
    var onError: ((String) -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    @discardableResult
    func start() -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            onError?("socket() failed")
            return false
        }

        var receiveBuffer: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer,
                   socklen_t(MemoryLayout<Int32>.size))
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
                   socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            onError?("UDP port \(port) is unavailable")
            return false
        }

        stateLock.lock()
        socketFD = fd
        stateLock.unlock()

        let name = Host.current().localizedName ?? "Mac"
        bonjour = NetService(domain: "", type: "_auvol._udp.", name: name,
                             port: Int32(port))
        bonjour?.publish()

        stopped.enter()
        queue.async { [weak self] in
            self?.receiveLoop(fd: fd)
            self?.stopped.leave()
        }
        return true
    }

    func stop() {
        bonjour?.stop()
        bonjour = nil

        stateLock.lock()
        let fd = socketFD
        socketFD = -1
        stateLock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            _ = stopped.wait(timeout: .now() + 1)
        }
    }

    private func receiveLoop(fd: Int32) {
        var bytes = [UInt8](repeating: 0, count: 2048)

        while true {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, base, raw.count, 0, $0, &sourceLength)
                    }
                }
            }
            guard count > 0 else { return }
            guard let packet = PacketParser.parse(bytes, length: count) else { continue }

            let senderIP = ipString(source.sin_addr)
            if senderIP != lastSenderIP {
                lastSenderIP = senderIP
                onSenderSeen?(senderIP)
            }
            switch packet {
            case .config(let config):
                onConfig?(config)
            case .audio(let audio):
                bytes.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    let payload = base.advanced(by: audio.payloadOffset)
                        .assumingMemoryBound(to: Float.self)
                    onAudio?(audio, payload)
                }
            }
        }
    }

    private func ipString(_ address: in_addr) -> String {
        var address = address
        var storage = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return storage.withUnsafeMutableBufferPointer { buffer in
            guard inet_ntop(AF_INET, &address, buffer.baseAddress,
                            socklen_t(buffer.count)) != nil else { return "" }
            return String(cString: buffer.baseAddress!)
        }
    }

    deinit {
        stop()
    }
}
