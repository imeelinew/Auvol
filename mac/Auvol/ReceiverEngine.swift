import Foundation
import OSLog
import SwiftUI

final class ReceiverEngine: ObservableObject {
    private static let targetBufferKey = "alv2TargetBufferMs"
    private static let defaultTargetBufferMs = 12

    @Published var isListening = false
    @Published var isPlaying = false
    @Published var sampleRate: Double = 0
    @Published var bufferLevelMs: Double = 0
    @Published var targetBufferMs = ReceiverEngine.defaultTargetBufferMs
    @Published var packetRate = 0
    @Published var lostPackets: UInt64 = 0
    @Published var latePackets: UInt64 = 0
    @Published var captureGlitches: UInt64 = 0
    @Published var starvedFramesPerSecond = 0
    @Published var overflowFrames: UInt64 = 0
    @Published var driftPPM = 0.0
    @Published var capturePeriodMs = 0.0
    @Published var outputQuantumMs = 0.0
    @Published var senderIP = ""
    @Published var errorMessage = ""
    @Published var port: UInt16 = 7777

    private let logger = Logger(subsystem: "com.eli.Auvol", category: "stream")
    private let metricsLock = NSLock()
    private let player = AudioPlayer()
    private var network: NetworkReceiver?
    private var statsTimer: Timer?

    private var activeConfig: StreamConfig?
    private var expectedFrame: UInt64?
    private var expectedSequence: UInt32?
    private var receivedPackets: UInt64 = 0
    private var lostPacketCount: UInt64 = 0
    private var latePacketCount: UInt64 = 0
    private var captureGlitchCount: UInt64 = 0
    private var lastAudioTime: Date?

    private var previousPacketCount: UInt64 = 0
    private var previousUnderrunFrames: UInt64 = 0
    private var previousStatsTime = Date()
    private var lastLoggedLostPackets: UInt64 = 0
    private var lastLoggedUnderrunFrames: UInt64 = 0
    private var lastLoggedOverflowFrames: UInt64 = 0
    private var lastTelemetryTime = Date.distantPast

    init() {
        let saved = UserDefaults.standard.object(forKey: Self.targetBufferKey) as? Int
        targetBufferMs = min(80, max(8, saved ?? Self.defaultTargetBufferMs))
        player.setTargetBufferMs(targetBufferMs)
        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    func setTargetBufferMs(_ milliseconds: Int) {
        let clamped = min(80, max(8, milliseconds))
        targetBufferMs = clamped
        UserDefaults.standard.set(clamped, forKey: Self.targetBufferKey)
        player.setTargetBufferMs(clamped)
    }

    func start() {
        guard network == nil else { return }
        errorMessage = ""

        let receiver = NetworkReceiver(port: port)
        receiver.onConfig = { [weak self] config in
            self?.applyConfig(config)
        }
        receiver.onAudio = { [weak self] packet, samples in
            self?.handleAudio(packet, samples: samples)
        }
        receiver.onSenderSeen = { [weak self] address in
            DispatchQueue.main.async {
                self?.senderIP = address
            }
        }
        receiver.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.errorMessage = message
                self?.isListening = false
            }
        }
        guard receiver.start() else { return }
        network = receiver
        isListening = true

        previousStatsTime = Date()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in self?.updateStats()
        }
    }

    func stop() {
        statsTimer?.invalidate()
        statsTimer = nil
        network?.stop()
        network = nil
        player.stop()
        isListening = false
        isPlaying = false
    }

    private func applyConfig(_ config: StreamConfig) {
        metricsLock.lock()
        let streamChanged = activeConfig?.streamID != config.streamID
        let configurationChanged = activeConfig != config
        metricsLock.unlock()
        guard configurationChanged else { return }

        guard player.configure(config) else {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "Unsupported audio format"
            }
            return
        }
        metricsLock.lock()
        activeConfig = config
        expectedFrame = nil
        expectedSequence = nil
        if streamChanged {
            receivedPackets = 0
            lostPacketCount = 0
            latePacketCount = 0
            captureGlitchCount = 0
        }
        metricsLock.unlock()

        logger.notice("accepted stream=\(config.streamID) sampleRate=\(config.sampleRate, privacy: .public) capturePeriodFrames=\(config.capturePeriodFrames) packetFrames=\(config.maximumPacketFrames)")
        DispatchQueue.main.async { [weak self] in
            self?.sampleRate = config.sampleRate
            self?.capturePeriodMs = Double(config.capturePeriodFrames)
                / config.sampleRate * 1_000
            self?.errorMessage = ""
        }
    }

    private func handleAudio(_ packet: AudioPacket,
                             samples: UnsafePointer<Float>) {
        var gapFrames: UInt64 = 0
        var shouldReset = false

        metricsLock.lock()
        guard let config = activeConfig,
              config.streamID == packet.streamID else {
            metricsLock.unlock()
            return
        }

        if let expectedFrame {
            if packet.firstFrame < expectedFrame {
                latePacketCount &+= 1
                metricsLock.unlock()
                return
            }
            gapFrames = packet.firstFrame - expectedFrame
            if gapFrames > UInt64(config.sampleRate * 0.05) {
                shouldReset = true
                gapFrames = 0
            }
        }

        if let expectedSequence {
            let sequenceGap = packet.sequence &- expectedSequence
            if sequenceGap > 0 && sequenceGap < 10_000 {
                lostPacketCount &+= UInt64(sequenceGap)
            }
        }
        if packet.flags & 1 != 0 {
            captureGlitchCount &+= 1
            shouldReset = receivedPackets > 0
        }

        expectedFrame = packet.firstFrame &+ UInt64(packet.frameCount)
        expectedSequence = packet.sequence &+ 1
        receivedPackets &+= 1
        lastAudioTime = Date()
        metricsLock.unlock()

        if shouldReset {
            player.resetBuffer()
        } else if gapFrames > 0 {
            _ = player.pushSilence(frames: UInt32(gapFrames))
        }
        _ = player.push(samples, frames: UInt32(packet.frameCount))
    }

    private func updateStats() {
        let playerStats = player.snapshot()

        metricsLock.lock()
        let packets = receivedPackets
        let lost = lostPacketCount
        let late = latePacketCount
        let glitches = captureGlitchCount
        let lastAudio = lastAudioTime
        let config = activeConfig
        metricsLock.unlock()

        let now = Date()
        let elapsed = max(0.001, now.timeIntervalSince(previousStatsTime))
        let packetDelta = packets >= previousPacketCount
            ? packets - previousPacketCount
            : packets
        let underrunDelta = playerStats.underrunFrames >= previousUnderrunFrames
            ? playerStats.underrunFrames - previousUnderrunFrames
            : playerStats.underrunFrames
        packetRate = Int(Double(packetDelta) / elapsed)
        starvedFramesPerSecond = Int(
            Double(underrunDelta) / elapsed
        )
        previousPacketCount = packets
        previousUnderrunFrames = playerStats.underrunFrames
        previousStatsTime = now

        if let config {
            bufferLevelMs = Double(playerStats.bufferFrames) / config.sampleRate * 1_000
            outputQuantumMs = Double(playerStats.renderQuantumFrames)
                / config.sampleRate * 1_000
        } else {
            bufferLevelMs = 0
            outputQuantumMs = 0
        }
        lostPackets = lost
        latePackets = late
        captureGlitches = glitches
        overflowFrames = playerStats.overflowFrames
        driftPPM = playerStats.ratePPM
        isPlaying = player.isPlaying &&
            (lastAudio.map { now.timeIntervalSince($0) < 0.75 } ?? false)

        if isPlaying && now.timeIntervalSince(lastTelemetryTime) >= 2 {
            logger.notice("telemetry packetsPerSec=\(self.packetRate) lost=\(lost) late=\(late) starvedPerSec=\(self.starvedFramesPerSecond) overflowFrames=\(playerStats.overflowFrames) bufferMs=\(self.bufferLevelMs, privacy: .public) targetMs=\(self.targetBufferMs) capturePeriodMs=\(self.capturePeriodMs, privacy: .public) outputQuantumMs=\(self.outputQuantumMs, privacy: .public) ratePPM=\(self.driftPPM, privacy: .public)")
            lastTelemetryTime = now
        }

        if isPlaying &&
            (lost != lastLoggedLostPackets ||
             playerStats.underrunFrames != lastLoggedUnderrunFrames ||
             playerStats.overflowFrames != lastLoggedOverflowFrames) {
            logger.warning("stream packets=\(packets) lost=\(lost) late=\(late) underrunFrames=\(playerStats.underrunFrames) overflowFrames=\(playerStats.overflowFrames) bufferMs=\(self.bufferLevelMs, privacy: .public) ratePPM=\(self.driftPPM, privacy: .public)")
            lastLoggedLostPackets = lost
            lastLoggedUnderrunFrames = playerStats.underrunFrames
            lastLoggedOverflowFrames = playerStats.overflowFrames
        }
    }
}
