import CoreAudio
import Foundation
import OSLog
import SwiftUI

enum TransportRole: String, CaseIterable, Hashable {
    case receive
    case send

    var title: String {
        switch self {
        case .receive: return "Receive from Windows"
        case .send: return "Send to Windows"
        }
    }
}

/// The selected role is a desired state. This supervisor keeps that state alive until paused.
final class ReceiverEngine: ObservableObject {
    private static let targetBufferKey = "alv2TargetBufferMs"
    private static let peerIPKey = "alv2PeerIP"
    private static let roleKey = "alv2MacRole"
    private static let defaultTargetBufferMs = 12
    private static let signalThreshold: Float = 0.000_01

    @Published var role: TransportRole = .receive
    @Published private(set) var isPaused = false
    @Published private(set) var isListening = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isSending = false
    @Published private(set) var isRecovering = false
    @Published private(set) var statusMessage = "Starting"
    @Published private(set) var signalLevelDBFS = -120.0
    @Published private(set) var hasSignal = false
    @Published private(set) var outputDeviceName = ""
    @Published private(set) var captureCallbackAgeMs = 0.0
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
    @Published var sourcePeriodMs = 0.0
    @Published var outputQuantumMs = 0.0
    @Published var senderIP = ""
    @Published var peerIP = "192.168.101.170"
    @Published var errorMessage = ""
    @Published var port: UInt16 = 7777

    private let logger = Logger(subsystem: "com.eli.Auvol", category: "stream")
    private let metricsLock = NSLock()
    private let lifecycleLock = NSLock()
    private let player = AudioPlayer()
    private let sender = AudioSender()
    private var network: NetworkReceiver?
    private var statsTimer: Timer?
    private var recoveryWorkItem: DispatchWorkItem?
    private var peerChangeWorkItem: DispatchWorkItem?

    private var desiredRole: TransportRole = .receive
    private var transportGeneration: UInt64 = 0
    private var desiredPaused = false
    private var transportRecovering = false
    private var recoveryAttempt = 0
    private var recoveryReason = ""
    private var transportStartedAt = Date.distantPast

    private var activeConfig: StreamConfig?
    private var expectedFrame: UInt64?
    private var expectedSequence: UInt32?
    private var receivedPackets: UInt64 = 0
    private var lostPacketCount: UInt64 = 0
    private var latePacketCount: UInt64 = 0
    private var captureGlitchCount: UInt64 = 0
    private var ingressPeak: Float = 0
    private var lastAudioTime: Date?
    private var lastSignalTime: Date?

    private var previousPacketCount: UInt64 = 0
    private var previousUnderrunFrames: UInt64 = 0
    private var previousRenderedFrames: UInt64 = 0
    private var previousSenderCallbackCount: UInt64 = 0
    private var previousSendErrors: UInt64 = 0
    private var previousStatsTime = Date()
    private var lastLoggedLostPackets: UInt64 = 0
    private var lastLoggedUnderrunFrames: UInt64 = 0
    private var lastLoggedOverflowFrames: UInt64 = 0
    private var lastTelemetryTime = Date.distantPast
    private let initialRole: TransportRole

    init(initialRole: TransportRole = .receive, initialPeerIP: String? = nil) {
        let arguments = CommandLine.arguments
        let hasExplicitRole = arguments.contains("--send") || arguments.contains("--receive")
        let savedRole = UserDefaults.standard.string(forKey: Self.roleKey)
            .flatMap(TransportRole.init(rawValue:))
        let selectedRole = hasExplicitRole ? initialRole : (savedRole ?? initialRole)
        self.initialRole = selectedRole
        self.role = selectedRole
        self.desiredRole = selectedRole

        let saved = UserDefaults.standard.object(forKey: Self.targetBufferKey) as? Int
        targetBufferMs = min(80, max(8, saved ?? Self.defaultTargetBufferMs))
        peerIP = initialPeerIP ?? UserDefaults.standard.string(forKey: Self.peerIPKey) ?? peerIP
        player.setTargetBufferMs(targetBufferMs)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activate(self.initialRole)
        }
    }

    var isActive: Bool { !isPaused }

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        activate(role)
    }

    func setTargetBufferMs(_ milliseconds: Int) {
        let clamped = min(80, max(8, milliseconds))
        targetBufferMs = clamped
        UserDefaults.standard.set(clamped, forKey: Self.targetBufferKey)
        player.setTargetBufferMs(clamped)
    }

    /// Selecting a direction always activates it; Stop is only a total pause.
    func activate(_ newRole: TransportRole) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.activate(newRole) }
            return
        }
        recoveryWorkItem?.cancel()
        peerChangeWorkItem?.cancel()
        role = newRole
        isPaused = false
        UserDefaults.standard.set(newRole.rawValue, forKey: Self.roleKey)
        let generation = setDesiredState(role: newRole, paused: false)
        recoveryAttempt = 0
        recoveryReason = ""
        transportRecovering = false
        stopTransportResources()
        resetMetrics()
        ensureStatsTimer()
        startTransport(role: newRole, generation: generation)
    }

    func setPeerIP(_ value: String) {
        peerIP = value
        UserDefaults.standard.set(value, forKey: Self.peerIPKey)
        peerChangeWorkItem?.cancel()
        guard role == .send, !isPaused else { return }
        let generation = currentGeneration()
        let item = DispatchWorkItem { [weak self] in
            self?.beginRecovery("Destination changed", expectedGeneration: generation)
        }
        peerChangeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        recoveryWorkItem?.cancel()
        peerChangeWorkItem?.cancel()
        _ = setDesiredState(role: role, paused: true)
        isPaused = true
        transportRecovering = false
        isRecovering = false
        recoveryReason = ""
        statsTimer?.invalidate()
        statsTimer = nil
        stopTransportResources()
        errorMessage = ""
        statusMessage = "Paused"
    }

    private func startTransport(role: TransportRole, generation: UInt64) {
        guard isCurrent(generation, role: role) else { return }
        transportStartedAt = Date()
        errorMessage = ""
        switch role {
        case .receive:
            startReceiver(generation: generation)
        case .send:
            startSender(generation: generation)
        }
    }

    private func startReceiver(generation: UInt64) {
        let receiver = NetworkReceiver(port: port)
        receiver.onConfig = { [weak self] config in
            self?.applyConfig(config, generation: generation)
        }
        receiver.onAudio = { [weak self] packet, samples in
            self?.handleAudio(packet, samples: samples, generation: generation)
        }
        receiver.onSenderSeen = { [weak self] address in
            guard let self, self.isCurrent(generation, role: .receive) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(generation, role: .receive) else { return }
                self.senderIP = address
            }
        }
        receiver.onFailure = { [weak self] message in
            DispatchQueue.main.async { [weak self] in
                self?.beginRecovery(message, expectedGeneration: generation)
            }
        }
        if let error = receiver.start() {
            beginRecovery(error, expectedGeneration: generation)
            return
        }
        guard isCurrent(generation, role: .receive) else {
            receiver.stop()
            return
        }
        network = receiver
        isListening = true
        transportRecovering = false
        publishRecoveryState(playerRecovering: false)
        statusMessage = "Waiting for Windows audio"
        logger.notice("receiver generation=\(generation) listening on UDP \(self.port)")
    }

    private func startSender(generation: UInt64) {
        guard let error = sender.start(targetIP: peerIP, port: port) else {
            guard isCurrent(generation, role: .send) else {
                sender.stop()
                return
            }
            isSending = true
            transportRecovering = false
            publishRecoveryState(playerRecovering: false)
            statusMessage = "Starting system-audio capture"
            logger.notice("sender generation=\(generation) to \(self.peerIP, privacy: .public):\(self.port)")
            return
        }
        beginRecovery(error, expectedGeneration: generation)
    }

    private func beginRecovery(_ reason: String, expectedGeneration: UInt64) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.beginRecovery(reason, expectedGeneration: expectedGeneration)
            }
            return
        }
        guard isCurrent(expectedGeneration, role: role) else { return }
        recoveryWorkItem?.cancel()
        let nextGeneration = setDesiredState(role: role, paused: false)
        stopTransportResources()
        transportRecovering = true
        recoveryReason = reason
        recoveryAttempt += 1
        publishRecoveryState(playerRecovering: false)

        let delays = [0.10, 0.25, 0.50, 1.0, 2.0]
        let delay = delays[min(recoveryAttempt - 1, delays.count - 1)]
        statusMessage = "Recovering · \(reason)"
        logger.warning("transport recovery generation=\(nextGeneration) delay=\(delay, privacy: .public)s reason=\(reason, privacy: .public)")
        let desired = role
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrent(nextGeneration, role: desired) else { return }
            self.startTransport(role: desired, generation: nextGeneration)
        }
        recoveryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func stopTransportResources() {
        network?.stop()
        network = nil
        player.stop()
        sender.stop()
        metricsLock.lock()
        activeConfig = nil
        expectedFrame = nil
        expectedSequence = nil
        receivedPackets = 0
        lostPacketCount = 0
        latePacketCount = 0
        captureGlitchCount = 0
        ingressPeak = 0
        lastAudioTime = nil
        lastSignalTime = nil
        metricsLock.unlock()
        isListening = false
        isPlaying = false
        isSending = false
    }

    private func setDesiredState(role: TransportRole, paused: Bool) -> UInt64 {
        lifecycleLock.lock()
        transportGeneration &+= 1
        desiredRole = role
        desiredPaused = paused
        let generation = transportGeneration
        lifecycleLock.unlock()
        return generation
    }

    private func currentGeneration() -> UInt64 {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return transportGeneration
    }

    private func isCurrent(_ generation: UInt64, role: TransportRole) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return transportGeneration == generation && desiredRole == role && !desiredPaused
    }

    private func resetMetrics() {
        previousPacketCount = 0
        previousUnderrunFrames = 0
        previousRenderedFrames = 0
        previousSenderCallbackCount = 0
        previousSendErrors = 0
        previousStatsTime = Date()
        lastLoggedLostPackets = 0
        lastLoggedUnderrunFrames = 0
        lastLoggedOverflowFrames = 0
        packetRate = 0
        lostPackets = 0
        latePackets = 0
        captureGlitches = 0
        starvedFramesPerSecond = 0
        overflowFrames = 0
        driftPPM = 0
        bufferLevelMs = 0
        outputQuantumMs = 0
        signalLevelDBFS = -120
        hasSignal = false
        captureCallbackAgeMs = 0
    }

    private func ensureStatsTimer() {
        guard statsTimer == nil else { return }
        previousStatsTime = Date()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
        statsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyConfig(_ config: StreamConfig, generation: UInt64) {
        guard isCurrent(generation, role: .receive) else { return }
        let playerReady = player.ensureConfigured(config)
        guard isCurrent(generation, role: .receive) else { return }

        metricsLock.lock()
        let streamChanged = activeConfig?.streamID != config.streamID
        let configurationChanged = activeConfig != config
        activeConfig = config
        if configurationChanged {
            expectedFrame = nil
            expectedSequence = nil
        }
        if streamChanged {
            receivedPackets = 0
            lostPacketCount = 0
            latePacketCount = 0
            captureGlitchCount = 0
            ingressPeak = 0
        }
        metricsLock.unlock()

        if configurationChanged {
            logger.notice("accepted stream=\(config.streamID) sampleRate=\(config.sampleRate, privacy: .public) sourcePeriodFrames=\(config.sourcePeriodFrames) packetFrames=\(config.maximumPacketFrames)")
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(generation, role: .receive) else { return }
            self.sampleRate = config.sampleRate
            self.sourcePeriodMs = Double(config.sourcePeriodFrames) / config.sampleRate * 1_000
            if !playerReady {
                self.statusMessage = "Recovering Mac audio output"
            }
        }
    }

    private func handleAudio(_ packet: AudioPacket,
                             samples: UnsafePointer<Float>,
                             generation: UInt64) {
        guard isCurrent(generation, role: .receive) else { return }
        var peak: Float = 0
        let sampleCount = Int(packet.frameCount) * Int(ALV2.stereoChannels)
        for index in 0..<sampleCount {
            peak = max(peak, abs(samples[index]))
        }

        var gapFrames: UInt64 = 0
        var shouldReset = false
        metricsLock.lock()
        guard let config = activeConfig, config.streamID == packet.streamID else {
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
        ingressPeak = max(ingressPeak, peak)
        lastAudioTime = Date()
        if peak >= Self.signalThreshold { lastSignalTime = Date() }
        metricsLock.unlock()

        if shouldReset {
            player.resetBuffer()
        } else if gapFrames > 0 {
            _ = player.pushSilence(frames: UInt32(gapFrames))
        }
        _ = player.push(samples, frames: UInt32(packet.frameCount))
    }

    private func updateStats() {
        guard !isPaused else { return }
        if role == .send {
            updateSenderStats()
        } else {
            updateReceiverStats()
        }
    }

    private func updateReceiverStats() {
        let playerStats = player.snapshot()
        metricsLock.lock()
        let packets = receivedPackets
        let lost = lostPacketCount
        let late = latePacketCount
        let glitches = captureGlitchCount
        let lastAudio = lastAudioTime
        let lastSignal = lastSignalTime
        let peak = ingressPeak
        ingressPeak = 0
        let config = activeConfig
        metricsLock.unlock()

        let now = Date()
        let elapsed = max(0.001, now.timeIntervalSince(previousStatsTime))
        let packetDelta = packets >= previousPacketCount ? packets - previousPacketCount : packets
        let underrunDelta = playerStats.underrunFrames >= previousUnderrunFrames
            ? playerStats.underrunFrames - previousUnderrunFrames
            : playerStats.underrunFrames
        packetRate = Int(Double(packetDelta) / elapsed)
        starvedFramesPerSecond = Int(Double(underrunDelta) / elapsed)
        previousPacketCount = packets
        previousUnderrunFrames = playerStats.underrunFrames
        previousStatsTime = now

        if let config {
            bufferLevelMs = Double(playerStats.bufferFrames) / config.sampleRate * 1_000
            outputQuantumMs = Double(playerStats.renderQuantumFrames) / config.sampleRate * 1_000
        } else {
            bufferLevelMs = 0
            outputQuantumMs = 0
        }
        outputDeviceName = playerStats.outputDeviceName
        lostPackets = lost
        latePackets = late
        captureGlitches = glitches
        overflowFrames = playerStats.overflowFrames
        driftPPM = playerStats.ratePPM
        publishSignal(peak: peak, lastSignal: lastSignal, now: now)

        let audioFresh = lastAudio.map { now.timeIntervalSince($0) < 0.75 } ?? false
        isPlaying = player.isPlaying && audioFresh
        if config != nil && audioFresh &&
            playerStats.lastRenderProgressAgeMs > 900 && !playerStats.isRecovering {
            player.requestRecovery(reason: "render callback stalled")
        }
        if playerStats.renderedFrames != previousRenderedFrames {
            previousRenderedFrames = playerStats.renderedFrames
            recoveryAttempt = 0
        }
        publishRecoveryState(playerRecovering: playerStats.isRecovering)
        refreshStatus(audioFresh: audioFresh)

        if isPlaying && now.timeIntervalSince(lastTelemetryTime) >= 2 {
            logger.notice("receive packetsPerSec=\(self.packetRate) signalDBFS=\(self.signalLevelDBFS, privacy: .public) lost=\(lost) late=\(late) starvedPerSec=\(self.starvedFramesPerSecond) overflowFrames=\(playerStats.overflowFrames) bufferMs=\(self.bufferLevelMs, privacy: .public) targetMs=\(self.targetBufferMs) sourcePeriodMs=\(self.sourcePeriodMs, privacy: .public) outputQuantumMs=\(self.outputQuantumMs, privacy: .public) ratePPM=\(self.driftPPM, privacy: .public) device=\(playerStats.outputDeviceName, privacy: .public)")
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

    private func updateSenderStats() {
        let stats = sender.snapshot()
        let now = Date()
        let elapsed = max(0.001, now.timeIntervalSince(previousStatsTime))
        let packetDelta = stats.packetsSent >= previousPacketCount
            ? stats.packetsSent - previousPacketCount : stats.packetsSent
        packetRate = Int(Double(packetDelta) / elapsed)
        previousPacketCount = stats.packetsSent
        previousStatsTime = now
        sampleRate = stats.sampleRate
        sourcePeriodMs = stats.sampleRate > 0
            ? Double(stats.capturePeriodFrames) / stats.sampleRate * 1_000 : 0
        captureCallbackAgeMs = max(0, stats.callbackAgeMs)
        outputDeviceName = defaultSystemOutputDeviceName()
        metricsLock.lock()
        if stats.capturePeak >= Self.signalThreshold { lastSignalTime = now }
        let senderLastSignal = lastSignalTime
        metricsLock.unlock()
        publishSignal(peak: stats.capturePeak,
                      lastSignal: senderLastSignal,
                      now: now)
        isSending = sender.isRunning

        let generation = currentGeneration()
        if stats.sourceOutputDeviceID != 0 && stats.currentOutputDeviceID != 0 &&
            stats.sourceOutputDeviceID != stats.currentOutputDeviceID {
            beginRecovery("Mac output device changed", expectedGeneration: generation)
            return
        }
        let startupAge = now.timeIntervalSince(transportStartedAt)
        if startupAge > 1.5 && stats.callbackAgeMs > 900 {
            beginRecovery("System-audio capture stalled", expectedGeneration: generation)
            return
        }
        if stats.callbackCount > previousSenderCallbackCount {
            previousSenderCallbackCount = stats.callbackCount
            recoveryAttempt = 0
        }
        if stats.sendErrors > previousSendErrors {
            previousSendErrors = stats.sendErrors
            if stats.sendErrors > 3 {
                beginRecovery("UDP sender failed", expectedGeneration: generation)
                return
            }
        }
        publishRecoveryState(playerRecovering: false)
        refreshStatus(audioFresh: stats.callbackAgeMs >= 0 && stats.callbackAgeMs < 900)
        if isSending && now.timeIntervalSince(lastTelemetryTime) >= 2 {
            logger.notice("send packetsPerSec=\(self.packetRate) signalDBFS=\(self.signalLevelDBFS, privacy: .public) callbackAgeMs=\(stats.callbackAgeMs, privacy: .public) sendErrors=\(stats.sendErrors) sampleRate=\(stats.sampleRate, privacy: .public) sourcePeriodMs=\(self.sourcePeriodMs, privacy: .public) device=\(self.outputDeviceName, privacy: .public)")
            lastTelemetryTime = now
        }
    }

    private func publishSignal(peak: Float, lastSignal: Date?, now: Date) {
        if peak >= Self.signalThreshold {
            signalLevelDBFS = max(-120, min(6, 20 * log10(Double(peak))))
            hasSignal = true
        } else if lastSignal.map({ now.timeIntervalSince($0) < 0.75 }) ?? false {
            hasSignal = true
        } else {
            signalLevelDBFS = -120
            hasSignal = false
        }
    }

    private func publishRecoveryState(playerRecovering: Bool) {
        isRecovering = transportRecovering || playerRecovering
        if !isRecovering { recoveryReason = "" }
    }

    private func refreshStatus(audioFresh: Bool) {
        if isPaused {
            statusMessage = "Paused"
        } else if isRecovering {
            statusMessage = recoveryReason.isEmpty
                ? "Recovering audio output"
                : "Recovering · \(recoveryReason)"
        } else if role == .send {
            if !audioFresh {
                statusMessage = "Starting system-audio capture"
            } else if hasSignal {
                statusMessage = "Sending Mac audio to Windows"
            } else {
                statusMessage = "Connected · Mac audio is silent"
            }
        } else if !audioFresh {
            statusMessage = "Waiting for Windows audio"
        } else if hasSignal && isPlaying {
            statusMessage = "Playing Windows audio"
        } else if isPlaying {
            statusMessage = "Connected · incoming audio is silent"
        } else {
            statusMessage = "Preparing Mac audio output"
        }
    }

    private func defaultSystemOutputDeviceName() -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var defaultOutput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &defaultOutput, 0, nil, &size,
                                         &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return "No output device" }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil,
                                         &size, &name) == noErr,
              let name else {
            return "Output device \(deviceID)"
        }
        return name.takeUnretainedValue() as String
    }

    deinit {
        recoveryWorkItem?.cancel()
        peerChangeWorkItem?.cancel()
        statsTimer?.invalidate()
        network?.stop()
        player.stop()
        sender.stop()
    }
}
