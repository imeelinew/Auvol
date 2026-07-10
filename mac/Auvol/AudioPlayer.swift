import AVFoundation
import CoreAudio
import Foundation
import OSLog

struct AudioPlayerStats {
    let bufferFrames: UInt32
    let pushedFrames: UInt64
    let renderedFrames: UInt64
    let underrunFrames: UInt64
    let overflowFrames: UInt64
    let renderQuantumFrames: UInt32
    let maximumRenderQuantumFrames: UInt32
    let ratePPM: Double
}

/// Real-time audio sink: the render callback only performs atomic ring reads and copies.
/// A slow PLL controls Apple's varispeed unit to absorb independent Windows/Mac clocks.
final class AudioPlayer {
    private let logger = Logger(subsystem: "com.eli.Auvol", category: "audio")
    private let engine = AVAudioEngine()
    private let stateLock = NSLock()
    private let controllerQueue = DispatchQueue(
        label: "com.eli.Auvol.clock",
        qos: .userInteractive
    )

    private var sourceNode: AVAudioSourceNode?
    private var varispeedNode: AVAudioUnitVarispeed?
    private var ring: OpaquePointer?
    private var configured: StreamConfig?
    private var running = false
    private var primed = false
    private var firstPushUptime: UInt64?
    private var targetBufferMs = 15
    private var outputDeviceBufferFrames: UInt32 = 0

    private var controllerTimer: DispatchSourceTimer?
    private var controllerToken: UInt64 = 0
    private var filteredFillError = 0.0
    private var integralCorrection = 0.0
    private var rateCorrection = 0.0
    private var configurationObserver: NSObjectProtocol?

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.restartAfterOutputChange()
        }
    }

    var isPlaying: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && primed && engine.isRunning
    }

    func setTargetBufferMs(_ milliseconds: Int) {
        stateLock.lock()
        targetBufferMs = min(80, max(8, milliseconds))
        stateLock.unlock()
    }

    @discardableResult
    func configure(_ config: StreamConfig) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard configured != config else { return false }

        teardownLocked()
        outputDeviceBufferFrames = requestLowLatencyOutputBuffer()

        let capacity = UInt32(config.sampleRate / 2)
        guard let newRing = auvol_ring_create(capacity),
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: config.sampleRate,
                  channels: AVAudioChannelCount(ALV2.stereoChannels)
              ) else {
            return false
        }

        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                for buffer in buffers {
                    if let data = buffer.mData {
                        memset(data, 0, Int(buffer.mDataByteSize))
                    }
                }
                return noErr
            }
            auvol_ring_render_stereo(newRing, left, right, frameCount)
            return noErr
        }
        let varispeed = AVAudioUnitVarispeed()
        varispeed.rate = 1

        engine.attach(source)
        engine.attach(varispeed)
        engine.connect(source, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()

        ring = newRing
        sourceNode = source
        varispeedNode = varispeed
        configured = config
        do {
            try engine.start()
            running = true
        } catch {
            logger.error("engine warm-up failed: \(error.localizedDescription, privacy: .public)")
            teardownLocked()
            return false
        }
        startControllerLocked()
        logger.notice("configured stream=\(config.streamID) sampleRate=\(config.sampleRate, privacy: .public) outputBufferFrames=\(self.outputDeviceBufferFrames)")
        return true
    }

    @discardableResult
    func push(_ samples: UnsafePointer<Float>, frames: UInt32) -> Bool {
        stateLock.lock()
        guard let ring else {
            stateLock.unlock()
            return false
        }
        if firstPushUptime == nil {
            firstPushUptime = DispatchTime.now().uptimeNanoseconds
        }
        let written = auvol_ring_write(ring, samples, frames)
        stateLock.unlock()
        if written == frames {
            maybeStart()
            return true
        }
        return false
    }

    @discardableResult
    func pushSilence(frames: UInt32) -> Bool {
        guard frames > 0 else { return true }
        stateLock.lock()
        guard let ring else {
            stateLock.unlock()
            return false
        }
        if firstPushUptime == nil {
            firstPushUptime = DispatchTime.now().uptimeNanoseconds
        }
        let written = auvol_ring_write_silence(ring, frames)
        stateLock.unlock()
        if written == frames {
            maybeStart()
            return true
        }
        return false
    }

    func snapshot() -> AudioPlayerStats {
        stateLock.lock()
        defer { stateLock.unlock() }
        var raw = AuvolAudioRingStats()
        if let ring {
            auvol_ring_snapshot(ring, &raw)
        }
        return AudioPlayerStats(
            bufferFrames: raw.availableFrames,
            pushedFrames: raw.pushedFrames,
            renderedFrames: raw.renderedFrames,
            underrunFrames: raw.underrunFrames,
            overflowFrames: raw.overflowFrames,
            renderQuantumFrames: raw.lastRenderFrames,
            maximumRenderQuantumFrames: raw.maxRenderFrames,
            ratePPM: rateCorrection * 1_000_000
        )
    }

    func stop() {
        stateLock.lock()
        teardownLocked()
        stateLock.unlock()
    }

    func resetBuffer() {
        stateLock.lock()
        if engine.isRunning { engine.stop() }
        if let ring {
            auvol_ring_reset(ring)
        }
        primed = false
        firstPushUptime = nil
        filteredFillError = 0
        integralCorrection = 0
        rateCorrection = 0
        varispeedNode?.rate = 1
        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            running = false
            logger.error("engine re-prime failed: \(error.localizedDescription, privacy: .public)")
        }
        stateLock.unlock()
    }

    private func maybeStart() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running,
              !primed,
              let ring,
              let configured,
              let firstPushUptime,
              sourceNode != nil else { return }

        // WASAPI loopback releases a one-time startup backlog. Keep the output
        // gated until that burst is fully received, then retain only live audio.
        guard DispatchTime.now().uptimeNanoseconds - firstPushUptime >= 200_000_000
        else { return }

        let targetFrames = UInt32(configured.sampleRate * Double(targetBufferMs) / 1_000)
        let safetyFrames = max(UInt32(configured.maximumPacketFrames),
                               outputDeviceBufferFrames)
        let primeFrames = targetFrames + safetyFrames
        let availableFrames = auvol_ring_available(ring)
        guard availableFrames >= primeFrames else { return }
        if availableFrames > primeFrames {
            // Playback has not started, so removing pre-start backlog is inaudible.
            _ = auvol_ring_discard(ring, availableFrames - primeFrames)
        }

        auvol_ring_set_playback_enabled(ring, 1)
        primed = true
        logger.notice("primed availableFrames=\(auvol_ring_available(ring)) targetFrames=\(targetFrames) safetyFrames=\(safetyFrames)")
    }

    private func startControllerLocked() {
        controllerToken &+= 1
        let token = controllerToken
        filteredFillError = 0
        integralCorrection = 0
        rateCorrection = 0

        let timer = DispatchSource.makeTimerSource(queue: controllerQueue)
        timer.schedule(deadline: .now() + .milliseconds(50),
                       repeating: .milliseconds(50),
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.updateClockController(token: token)
        }
        controllerTimer = timer
        timer.resume()
    }

    private func updateClockController(token: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard token == controllerToken,
              running,
              primed,
              let ring,
              let configured,
              let varispeedNode else { return }

        let targetFrames = max(1, configured.sampleRate * Double(targetBufferMs) / 1_000)
        let available = Double(auvol_ring_available(ring))
        let error = min(2, max(-1, (available - targetFrames) / targetFrames))

        // The low-pass rejects packet/callback burst cadence. The integral learns clock skew.
        filteredFillError += (error - filteredFillError) * 0.08
        integralCorrection += filteredFillError * 0.000_005
        integralCorrection = min(0.001, max(-0.001, integralCorrection))

        let desired = filteredFillError * 0.001 + integralCorrection
        let clamped = min(0.0015, max(-0.0015, desired))
        rateCorrection += (clamped - rateCorrection) * 0.10
        varispeedNode.rate = Float(1 + rateCorrection)
    }

    private func restartAfterOutputChange() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard configured != nil, running, !engine.isRunning else { return }
        outputDeviceBufferFrames = requestLowLatencyOutputBuffer()
        if let ring {
            auvol_ring_reset(ring)
        }
        primed = false
        firstPushUptime = nil
        engine.prepare()
        do {
            try engine.start()
        } catch {
            running = false
            logger.error("engine restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func teardownLocked() {
        configured = nil
        controllerToken &+= 1
        controllerTimer?.cancel()
        controllerTimer = nil

        if engine.isRunning {
            engine.stop()
        }
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        if let varispeedNode {
            engine.disconnectNodeOutput(varispeedNode)
            engine.detach(varispeedNode)
        }
        engine.reset()

        sourceNode = nil
        varispeedNode = nil
        if let ring {
            auvol_ring_destroy(ring)
        }
        ring = nil
        running = false
        primed = false
        firstPushUptime = nil
        filteredFillError = 0
        integralCorrection = 0
        rateCorrection = 0
    }

    /// macOS exposes the output quantum at device scope. Request 128 frames when supported.
    private func requestLowLatencyOutputBuffer() -> UInt32 {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultOutput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutput,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != 0 else { return 0 }

        var range = AudioValueRange()
        size = UInt32(MemoryLayout<AudioValueRange>.size)
        var rangeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID,
            &rangeAddress,
            0,
            nil,
            &size,
            &range
        ) == noErr else { return 0 }

        var requested = UInt32(min(range.mMaximum,
                                   max(range.mMinimum, 128)).rounded())
        var frameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(
            deviceID,
            &frameAddress,
            0,
            nil,
            size,
            &requested
        )
        _ = AudioObjectGetPropertyData(
            deviceID,
            &frameAddress,
            0,
            nil,
            &size,
            &requested
        )
        return requested
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        stop()
    }
}
