import Foundation

/// UDP 接收器：监听 ALV1 协议数据包，解析后通过回调分发。
/// 同时通过 Bonjour 广播自己，便于 Windows 端发现（如集成 mDNS）。
final class NetworkReceiver {
    private var sock: Int32 = -1
    private var thread: Thread?
    private var running = false
    private var bonjour: NetService?
    private let port: UInt16
    private var channels: UInt32 = 2
    private var frameSize: UInt32 = 120

    var onConfig: ((AudioConfig) -> Void)?
    var onAudio: ((UInt32, UnsafePointer<Float>, Int) -> Void)?
    var onSenderSeen: ((String) -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }

        var rcvbuf: Int32 = 1 << 20
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let r = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { close(sock); sock = -1; return }

        let name = Host.current().localizedName ?? "Mac"
        bonjour = NetService(domain: "", type: "_auvol._udp.", name: name, port: Int32(port))
        bonjour?.publish()

        running = true
        thread = Thread { [weak self] in self?.receiveLoop() }
        thread?.name = "auvol-udp"
        thread?.start()
    }

    func stop() {
        running = false
        bonjour?.stop()
        if sock >= 0 { close(sock); sock = -1 }
    }

    func setConfig(_ cfg: AudioConfig) {
        channels = cfg.channels
        frameSize = cfg.frameSize
    }

    private func receiveLoop() {
        var buf = [UInt8](repeating: 0, count: 4096)
        var srcAddr = sockaddr_in()
        var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        while running {
            let n = withUnsafeMutablePointer(to: &srcAddr) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(sock, &buf, buf.count, 0, sa, &srcLen)
                }
            }
            guard n > 0 else { continue }

            let ip = ipString(srcAddr.sin_addr.s_addr)
            onSenderSeen?(ip)

            guard let pkt = PacketParser.parse(buf, length: Int(n)) else { continue }

            switch pkt {
            case .config(let cfg):
                onConfig?(cfg)
            case .audio(let seq, let offset, let floats):
                let expectedFloats = Int(channels * frameSize)
                guard floats == expectedFloats else { continue }
                buf.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    let payload = base.advanced(by: offset).assumingMemoryBound(to: Float.self)
                    onAudio?(seq, payload, floats / Int(channels))
                }
            }
        }
    }

    private func ipString(_ addr: in_addr_t) -> String {
        String(format: "%d.%d.%d.%d",
               addr & 0xff, (addr >> 8) & 0xff,
               (addr >> 16) & 0xff, (addr >> 24) & 0xff)
    }
}
