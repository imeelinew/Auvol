import Foundation
import SwiftUI

/// 应用状态中枢：协调网络接收与音频播放，驱动 UI 更新。
final class ReceiverEngine: ObservableObject {
    @Published var isListening = false
    @Published var isPlaying = false
    @Published var sampleRate: Double = 0
    @Published var channels: Int = 0
    @Published var bufferLevelMs: Double = 0
    @Published var totalPackets: Int = 0
    @Published var underruns: Int = 0
    @Published var overflows: Int = 0
    @Published var targetBufferMs: Int = 300
    @Published var port: UInt16 = 7777
    @Published var senderIP: String = ""

    private var network: NetworkReceiver?
    private var player: AudioPlayer?
    private var statsTimer: Timer?
    private var packetCount = 0

    init() {
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    func start() {
        let p = AudioPlayer()
        p.targetBufferMs = targetBufferMs
        player = p

        let net = NetworkReceiver(port: port)
        net.onConfig = { [weak self] cfg in self?.applyConfig(cfg) }
        net.onAudio = { [weak self] data, frames in self?.handleAudio(data: data, frames: frames) }
        net.onSenderSeen = { [weak self] ip in
            DispatchQueue.main.async { self?.senderIP = ip }
        }
        net.start()
        network = net
        isListening = true

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
        network?.setChannels(cfg.channels)
        player?.configure(sampleRate: cfg.sampleRate, channels: cfg.channels)
        DispatchQueue.main.async { [weak self] in
            self?.sampleRate = cfg.sampleRate
            self?.channels = Int(cfg.channels)
        }
    }

    private func handleAudio(data: UnsafePointer<Float>, frames: Int) {
        player?.push(data, frames: frames)
        packetCount += 1
    }

    private func updateStats() {
        guard let p = player else { return }
        p.targetBufferMs = targetBufferMs
        isPlaying = p.isPlaying
        bufferLevelMs = p.bufferLevelMs
        underruns = p.underruns
        overflows = p.overflows
        totalPackets = packetCount
    }
}
