import Foundation
import OSLog
import SwiftUI

/// 应用状态中枢：协调网络接收与音频播放，驱动 UI 更新。
final class ReceiverEngine: ObservableObject {
    private let logger = Logger(subsystem: "com.eli.Auvol", category: "stream")

    @Published var isListening = false
    @Published var isPlaying = false
    @Published var sampleRate: Double = 0
    @Published var channels: Int = 0
    @Published var bufferLevelMs: Double = 0
    @Published var totalPackets: Int = 0
    @Published var underruns: Int = 0
    @Published var overflows: Int = 0
    @Published var lostPackets: Int = 0
    @Published var packetRate: Int = 0
    @Published var gapFrameRate: Int = 0
    @Published var port: UInt16 = 7777
    @Published var senderIP: String = ""

    private var network: NetworkReceiver?
    private var player: AudioPlayer?
    private var statsTimer: Timer?
    private var packetCount = 0
    private var lastStatsPacketCount = 0
    private var lastStatsUnderruns = 0
    private var lastStatsTime = Date()
    private var lastLoggedUnderruns = 0
    private var lastLoggedOverflows = 0
    private var lastLoggedLostPackets = 0
    private var lastAudioTime: Date?
    private var frameSize: UInt32 = 120
    private var lastSeq: UInt32?
    private var haveSeq = false
    private var currentConfig: AudioConfig?

    init() {
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    func start() {
        let p = AudioPlayer()
        player = p

        let net = NetworkReceiver(port: port)
        net.onConfig = { [weak self] cfg in self?.applyConfig(cfg) }
        net.onAudio = { [weak self] seq, data, frames in
            self?.handleAudio(seq: seq, data: data, frames: frames)
        }
        net.onSenderSeen = { [weak self] ip in
            DispatchQueue.main.async { self?.senderIP = ip }
        }
        net.start()
        network = net
        isListening = true

        lastStatsTime = Date()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }

    func stop() {
        network?.stop()
        player?.stop()
        statsTimer?.invalidate()
        isListening = false
        isPlaying = false
    }

    private func applyConfig(_ cfg: AudioConfig) {
        let configChanged = currentConfig != cfg
        currentConfig = cfg
        network?.setConfig(cfg)
        frameSize = cfg.frameSize
        player?.configure(sampleRate: cfg.sampleRate, channels: cfg.channels, frameSize: cfg.frameSize)
        if configChanged {
            lastSeq = nil
            haveSeq = false
        }
        DispatchQueue.main.async { [weak self] in
            self?.sampleRate = cfg.sampleRate
            self?.channels = Int(cfg.channels)
        }
    }

    private func handleAudio(seq: UInt32, data: UnsafePointer<Float>, frames: Int) {
        lastAudioTime = Date()
        if haveSeq, let prev = lastSeq {
            let expected = prev &+ 1
            if seq != expected {
                let gap = Int(seq &- expected)
                if gap > 0 && gap < 500 {
                    lostPackets += gap
                    player?.pushConcealment(frames: gap * Int(frameSize))
                }
            }
        } else {
            haveSeq = true
        }
        lastSeq = seq

        player?.push(data, frames: frames)
        packetCount += 1
    }

    private func updateStats() {
        guard let p = player else { return }
        let now = Date()
        let packetsBeforeStats = lastStatsPacketCount
        let recentlyReceivedAudio = lastAudioTime.map { now.timeIntervalSince($0) < 1.0 } ?? false
        isPlaying = p.isPlaying && recentlyReceivedAudio
        bufferLevelMs = p.bufferLevelMs
        underruns = p.underruns
        overflows = p.overflows
        totalPackets = packetCount

        let dt = now.timeIntervalSince(lastStatsTime)
        if dt >= 0.4 {
            packetRate = Int(Double(packetCount - lastStatsPacketCount) / dt)
            gapFrameRate = Int(Double(p.underruns - lastStatsUnderruns) / dt)
            lastStatsPacketCount = packetCount
            lastStatsUnderruns = p.underruns
            lastStatsTime = now
        }

        let receivedPacketsThisInterval = packetCount > packetsBeforeStats
        if recentlyReceivedAudio && receivedPacketsThisInterval && (p.underruns != lastLoggedUnderruns || p.overflows != lastLoggedOverflows || lostPackets != lastLoggedLostPackets) {
            logger.warning("stream anomaly packets=\(self.packetCount) underruns=\(p.underruns) overflows=\(p.overflows) lost=\(self.lostPackets) bufferMs=\(p.bufferLevelMs, privacy: .public)")
            lastLoggedUnderruns = p.underruns
            lastLoggedOverflows = p.overflows
            lastLoggedLostPackets = lostPackets
        }
    }
}
