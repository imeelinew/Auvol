import AVFoundation
import AudioToolbox
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
    let isHealthy: Bool
    let isRecovering: Bool
    let engineRunning: Bool
    let outputDeviceID: UInt32
    let outputDeviceName: String
    let lastRenderProgressAgeMs: Double
}

/// Real-time audio sink with a replaceable AVAudioEngine graph.
///
/// Hardware notifications never manipulate AVAudioEngine on Apple's callback queue.
/// They only enqueue a debounced rebuild on `lifecycleQueue`. The render callback
/// remains allocation-free and lock-free; graph/ring ownership changes are serialized.
final class AudioPlayer {
    private struct OutputDevice {
        let id: AudioDeviceID
        let name: String
        let bufferFrames: UInt32
    }

    private struct DetachedGraph {
        let engine: AVAudioEngine?
        let sourceNode: AVAudioSourceNode?
        let varispeedNode: AVAudioUnitVarispeed?
        let ring: OpaquePointer?
        let configurationObserver: NSObjectProtocol?
    }

    private enum RebuildReason: CustomStringConvertible {
        case newStream
        case outputDeviceChanged
        case engineConfigurationChanged
        case streamDiscontinuity
        case watchdog(String)
        case retry(String)

        var description: String {
            switch self {
            case .newStream: return "new stream"
            case .outputDeviceChanged: return "default output changed"
            case .engineConfigurationChanged: return "engine configuration changed"
            case .streamDiscontinuity: return "stream discontinuity"
            case .watchdog(let detail): return "watchdog: \(detail)"
            case .retry(let detail): return "retry: \(detail)"
            }
        }
    }

    private static let renderStallNanoseconds: UInt64 = 750_000_000
    private static let rebuildDebounceNanoseconds: UInt64 = 200_000_000
    private static let retryDelays: [TimeInterval] = [0.10, 0.25, 0.50, 1.0, 2.0]

    private let logger = Logger(subsystem: "com.eli.Auvol", category: "audio")
    private let stateLock = NSLock()
    private let lifecycleQueue = DispatchQueue(
        label: "com.eli.Auvol.audio-lifecycle",
        qos: .userInteractive
    )
    private let controllerQueue = DispatchQueue(
        label: "com.eli.Auvol.clock",
        qos: .userInteractive
    )
    private let lifecycleQueueKey = DispatchSpecificKey<UInt8>()

    // Accessed under stateLock. AVAudioEngine methods are invoked only by lifecycleQueue.
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var varispeedNode: AVAudioUnitVarispeed?
    private var ring: OpaquePointer?
    private var configured: StreamConfig?
    private var running = false
    private var engineRunning = false
    private var recovering = false
    private var primed = false
    private var firstPushUptime: UInt64?
    private var targetBufferMs = 15
    private var outputDeviceBufferFrames: UInt32 = 0
    private var outputDeviceID: AudioDeviceID = 0
    private var outputDeviceName = ""

    private var lastObservedPushedFrames: UInt64 = 0
    private var lastObservedRenderedFrames: UInt64 = 0
    private var lastPushProgressUptime: UInt64 = 0
    private var lastRenderProgressUptime: UInt64 = 0

    private var controllerTimer: DispatchSourceTimer?
    private var controllerToken: UInt64 = 0
    private var filteredFillError = 0.0
    private var integralCorrection = 0.0
    private var rateCorrection = 0.0
    private var configurationObserver: NSObjectProtocol?

    // Accessed only on lifecycleQueue.
    private var lifecycleGeneration: UInt64 = 0
    private var pendingRebuild: DispatchWorkItem?
    private var retryAttempt = 0
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerInstalled = false

    init() {
        lifecycleQueue.setSpecific(key: lifecycleQueueKey, value: 1)
        installDefaultOutputListener()
    }

    var isPlaying: Bool {
        let actualEngineRunning = currentEngineIsRunning()
        let currentOutputID = Self.readDefaultOutputDeviceID() ?? 0
        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        refreshProgressLocked(now: now)
        let healthy = graphIsHealthyLocked(
            now: now,
            actualEngineRunning: actualEngineRunning,
            currentOutputID: currentOutputID
        )
        let result = primed && healthy
        stateLock.unlock()
        return result
    }

    func setTargetBufferMs(_ milliseconds: Int) {
        stateLock.lock()
        targetBufferMs = min(80, max(8, milliseconds))
        stateLock.unlock()
    }

    /// Idempotently ensures that the requested stream has a healthy graph.
    /// The same config is a no-op only while the graph is healthy and bound to
    /// the current default output. A failed build remains desired and retries.
    @discardableResult
    func ensureConfigured(_ config: StreamConfig) -> Bool {
        lifecycleSync {
            let actualEngineRunning = currentEngineIsRunning()
            let currentOutputID = Self.readDefaultOutputDeviceID() ?? 0
            let now = DispatchTime.now().uptimeNanoseconds

            stateLock.lock()
            refreshProgressLocked(now: now)
            let sameConfig = configured == config
            let healthy = sameConfig && graphIsHealthyLocked(
                now: now,
                actualEngineRunning: actualEngineRunning,
                currentOutputID: currentOutputID
            )
            let recoveryAlreadyScheduled = sameConfig && recovering
            if !sameConfig {
                configured = config
            }
            stateLock.unlock()

            if healthy { return true }
            if recoveryAlreadyScheduled { return false }

            beginNewGeneration()
            return rebuildGraph(
                generation: lifecycleGeneration,
                reason: sameConfig ? .watchdog("same config, unhealthy graph") : .newStream
            )
        }
    }

    @discardableResult
    func configure(_ config: StreamConfig) -> Bool {
        ensureConfigured(config)
    }

    /// Non-blocking recovery entry point for transport/render watchdogs.
    func requestRecovery(reason: String) {
        lifecycleQueue.async { [weak self] in
            self?.scheduleDebouncedRebuild(reason: .watchdog(reason))
        }
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
        let actualEngineRunning = currentEngineIsRunning()
        let currentOutputID = Self.readDefaultOutputDeviceID() ?? 0
        let now = DispatchTime.now().uptimeNanoseconds

        stateLock.lock()
        defer { stateLock.unlock() }
        var raw = AuvolAudioRingStats()
        if let ring {
            auvol_ring_snapshot(ring, &raw)
        }
        refreshProgressLocked(raw: raw, now: now)
        let healthy = graphIsHealthyLocked(
            now: now,
            actualEngineRunning: actualEngineRunning,
            currentOutputID: currentOutputID
        )
        let renderAge = lastRenderProgressUptime == 0
            ? 0
            : Double(now &- lastRenderProgressUptime) / 1_000_000
        return AudioPlayerStats(
            bufferFrames: raw.availableFrames,
            pushedFrames: raw.pushedFrames,
            renderedFrames: raw.renderedFrames,
            underrunFrames: raw.underrunFrames,
            overflowFrames: raw.overflowFrames,
            renderQuantumFrames: raw.lastRenderFrames,
            maximumRenderQuantumFrames: raw.maxRenderFrames,
            ratePPM: rateCorrection * 1_000_000,
            isHealthy: healthy,
            isRecovering: recovering,
            engineRunning: actualEngineRunning,
            outputDeviceID: outputDeviceID,
            outputDeviceName: outputDeviceName,
            lastRenderProgressAgeMs: renderAge
        )
    }

    func stop() {
        lifecycleSync {
            beginNewGeneration()
            stateLock.lock()
            configured = nil
            recovering = false
            let detached = detachGraphLocked(clearOutputDevice: true)
            stateLock.unlock()
            dispose(detached)
        }
    }

    /// A discontinuity uses the same known-good full rebuild path as a device change.
    func resetBuffer() {
        lifecycleSync {
            stateLock.lock()
            let hasConfig = configured != nil
            stateLock.unlock()
            guard hasConfig else { return }
            beginNewGeneration()
            _ = rebuildGraph(
                generation: lifecycleGeneration,
                reason: .streamDiscontinuity
            )
        }
    }

    private func maybeStart() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running,
              engineRunning,
              !recovering,
              !primed,
              let ring,
              let configured,
              let firstPushUptime,
              sourceNode != nil else { return }

        // WASAPI loopback may release a one-time startup backlog. Wait until that
        // burst settles, then retain only the live low-latency tail.
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- firstPushUptime >= 200_000_000 else { return }

        let targetFrames = UInt32(configured.sampleRate * Double(targetBufferMs) / 1_000)
        let safetyFrames = max(UInt32(configured.maximumPacketFrames),
                               outputDeviceBufferFrames)
        let primeFrames = targetFrames + safetyFrames
        let availableFrames = auvol_ring_available(ring)
        guard availableFrames >= primeFrames else { return }
        if availableFrames > primeFrames {
            _ = auvol_ring_discard(ring, availableFrames - primeFrames)
        }

        auvol_ring_set_playback_enabled(ring, 1)
        primed = true
        lastPushProgressUptime = now
        lastRenderProgressUptime = now
        logger.notice("primed availableFrames=\(auvol_ring_available(ring)) targetFrames=\(targetFrames) safetyFrames=\(safetyFrames) output=\(self.outputDeviceName, privacy: .public)")
    }

    private func installDefaultOutputListener() {
        lifecycleQueue.async { [weak self] in
            guard let self, !self.defaultOutputListenerInstalled else { return }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleDebouncedRebuild(reason: .outputDeviceChanged)
            }
            var address = Self.defaultOutputAddress
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                self.lifecycleQueue,
                listener
            )
            guard status == noErr else {
                self.logger.error("cannot observe default output: \(status)")
                return
            }
            self.defaultOutputListener = listener
            self.defaultOutputListenerInstalled = true
        }
    }

    private func removeDefaultOutputListener() {
        guard defaultOutputListenerInstalled,
              let defaultOutputListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            lifecycleQueue,
            defaultOutputListener
        )
        self.defaultOutputListener = nil
        defaultOutputListenerInstalled = false
    }

    private func scheduleDebouncedRebuild(reason: RebuildReason) {
        dispatchPrecondition(condition: .onQueue(lifecycleQueue))
        stateLock.lock()
        let hasConfig = configured != nil
        if hasConfig { recovering = true }
        stateLock.unlock()
        guard hasConfig else { return }

        beginNewGeneration()
        let generation = lifecycleGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == self.lifecycleGeneration else { return }
            self.pendingRebuild = nil
            _ = self.rebuildGraph(generation: generation, reason: reason)
        }
        pendingRebuild = item
        lifecycleQueue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(Self.rebuildDebounceNanoseconds)),
            execute: item
        )
        logger.notice("scheduled audio rebuild generation=\(generation) reason=\(reason.description, privacy: .public)")
    }

    private func beginNewGeneration() {
        dispatchPrecondition(condition: .onQueue(lifecycleQueue))
        lifecycleGeneration &+= 1
        retryAttempt = 0
        pendingRebuild?.cancel()
        pendingRebuild = nil
    }

    @discardableResult
    private func rebuildGraph(generation: UInt64,
                              reason: RebuildReason) -> Bool {
        dispatchPrecondition(condition: .onQueue(lifecycleQueue))
        guard generation == lifecycleGeneration else { return false }

        stateLock.lock()
        guard let config = configured else {
            recovering = false
            stateLock.unlock()
            return false
        }
        recovering = true
        let detached = detachGraphLocked(clearOutputDevice: false)
        stateLock.unlock()
        dispose(detached)

        guard generation == lifecycleGeneration else { return false }
        do {
            let device = try prepareOutputDevice()
            let capacity = UInt32(config.sampleRate / 2)
            guard let newRing = auvol_ring_create(capacity),
                  let format = AVAudioFormat(
                    standardFormatWithSampleRate: config.sampleRate,
                    channels: AVAudioChannelCount(ALV2.stereoChannels)
                  ) else {
                throw AudioPlayerError.unsupportedFormat
            }

            let newEngine = AVAudioEngine()
            let newSource = AVAudioSourceNode(format: format) {
                _, _, frameCount, audioBufferList in
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
            let newVarispeed = AVAudioUnitVarispeed()
            newVarispeed.rate = 1

            do {
                try bind(newEngine.outputNode, to: device.id)
                newEngine.attach(newSource)
                newEngine.attach(newVarispeed)
                newEngine.connect(newSource, to: newVarispeed, format: format)
                newEngine.connect(newVarispeed, to: newEngine.mainMixerNode,
                                  format: format)
                newEngine.mainMixerNode.outputVolume = 1
                newEngine.prepare()
                try newEngine.start()
            } catch {
                if newEngine.isRunning { newEngine.stop() }
                newEngine.reset()
                auvol_ring_destroy(newRing)
                throw error
            }

            guard generation == lifecycleGeneration else {
                newEngine.stop()
                newEngine.reset()
                auvol_ring_destroy(newRing)
                return false
            }

            let observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: newEngine,
                queue: nil
            ) { [weak self] _ in
                self?.lifecycleQueue.async { [weak self] in
                    self?.scheduleDebouncedRebuild(reason: .engineConfigurationChanged)
                }
            }

            let now = DispatchTime.now().uptimeNanoseconds
            stateLock.lock()
            engine = newEngine
            sourceNode = newSource
            varispeedNode = newVarispeed
            ring = newRing
            configurationObserver = observer
            running = true
            engineRunning = true
            recovering = false
            primed = false
            firstPushUptime = nil
            outputDeviceBufferFrames = device.bufferFrames
            outputDeviceID = device.id
            outputDeviceName = device.name
            resetProgressAndControllerLocked(now: now)
            startControllerLocked()
            stateLock.unlock()

            retryAttempt = 0
            logger.notice("rebuilt stream=\(config.streamID) reason=\(reason.description, privacy: .public) sampleRate=\(config.sampleRate, privacy: .public) outputDeviceID=\(device.id) output=\(device.name, privacy: .public) outputBufferFrames=\(device.bufferFrames)")
            return true
        } catch {
            stateLock.lock()
            running = false
            engineRunning = false
            recovering = true
            stateLock.unlock()
            logger.error("audio rebuild failed generation=\(generation) reason=\(reason.description, privacy: .public): \(error.localizedDescription, privacy: .public)")
            scheduleRetry(generation: generation,
                          detail: error.localizedDescription)
            return false
        }
    }

    private func scheduleRetry(generation: UInt64, detail: String) {
        dispatchPrecondition(condition: .onQueue(lifecycleQueue))
        guard generation == lifecycleGeneration else { return }
        let index = min(retryAttempt, Self.retryDelays.count - 1)
        let delay = Self.retryDelays[index]
        retryAttempt += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == self.lifecycleGeneration else { return }
            self.pendingRebuild = nil
            _ = self.rebuildGraph(
                generation: generation,
                reason: .retry(detail)
            )
        }
        pendingRebuild?.cancel()
        pendingRebuild = item
        lifecycleQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func detachGraphLocked(clearOutputDevice: Bool) -> DetachedGraph {
        controllerToken &+= 1
        controllerTimer?.cancel()
        controllerTimer = nil

        let detached = DetachedGraph(
            engine: engine,
            sourceNode: sourceNode,
            varispeedNode: varispeedNode,
            ring: ring,
            configurationObserver: configurationObserver
        )
        engine = nil
        sourceNode = nil
        varispeedNode = nil
        ring = nil
        configurationObserver = nil
        running = false
        engineRunning = false
        primed = false
        firstPushUptime = nil
        resetProgressAndControllerLocked(now: 0)
        if clearOutputDevice {
            outputDeviceBufferFrames = 0
            outputDeviceID = 0
            outputDeviceName = ""
        }
        return detached
    }

    private func dispose(_ graph: DetachedGraph) {
        if let configurationObserver = graph.configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        guard let engine = graph.engine else {
            if let ring = graph.ring { auvol_ring_destroy(ring) }
            return
        }
        if engine.isRunning { engine.stop() }
        if let sourceNode = graph.sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        if let varispeedNode = graph.varispeedNode {
            engine.disconnectNodeOutput(varispeedNode)
            engine.detach(varispeedNode)
        }
        engine.reset()
        if let ring = graph.ring { auvol_ring_destroy(ring) }
    }

    private func startControllerLocked() {
        controllerToken &+= 1
        let token = controllerToken
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
              engineRunning,
              !recovering,
              primed,
              let ring,
              let configured,
              let varispeedNode else { return }

        let targetFrames = max(1, configured.sampleRate * Double(targetBufferMs) / 1_000)
        let available = Double(auvol_ring_available(ring))
        let error = min(2, max(-1, (available - targetFrames) / targetFrames))
        filteredFillError += (error - filteredFillError) * 0.08
        integralCorrection += filteredFillError * 0.000_005
        integralCorrection = min(0.001, max(-0.001, integralCorrection))

        let desired = filteredFillError * 0.001 + integralCorrection
        let clamped = min(0.0015, max(-0.0015, desired))
        rateCorrection += (clamped - rateCorrection) * 0.10
        varispeedNode.rate = Float(1 + rateCorrection)
    }

    private func resetProgressAndControllerLocked(now: UInt64) {
        lastObservedPushedFrames = 0
        lastObservedRenderedFrames = 0
        lastPushProgressUptime = now
        lastRenderProgressUptime = now
        filteredFillError = 0
        integralCorrection = 0
        rateCorrection = 0
        varispeedNode?.rate = 1
    }

    private func refreshProgressLocked(now: UInt64) {
        var raw = AuvolAudioRingStats()
        if let ring { auvol_ring_snapshot(ring, &raw) }
        refreshProgressLocked(raw: raw, now: now)
    }

    private func refreshProgressLocked(raw: AuvolAudioRingStats, now: UInt64) {
        if raw.pushedFrames != lastObservedPushedFrames {
            lastObservedPushedFrames = raw.pushedFrames
            lastPushProgressUptime = now
        }
        if raw.renderedFrames != lastObservedRenderedFrames {
            lastObservedRenderedFrames = raw.renderedFrames
            lastRenderProgressUptime = now
        }
    }

    private func graphIsHealthyLocked(now: UInt64,
                                      actualEngineRunning: Bool,
                                      currentOutputID: AudioDeviceID) -> Bool {
        engineRunning = actualEngineRunning
        guard running,
              actualEngineRunning,
              !recovering,
              engine != nil,
              ring != nil,
              outputDeviceID != 0,
              outputDeviceID == currentOutputID else { return false }
        guard primed else { return true }

        let inputIsAdvancing = lastPushProgressUptime != 0 &&
            now &- lastPushProgressUptime < Self.renderStallNanoseconds
        let renderIsStalled = lastRenderProgressUptime == 0 ||
            now &- lastRenderProgressUptime >= Self.renderStallNanoseconds
        return !(inputIsAdvancing && renderIsStalled)
    }

    private func currentEngineIsRunning() -> Bool {
        stateLock.lock()
        let currentEngine = engine
        stateLock.unlock()
        return currentEngine?.isRunning ?? false
    }

    private func lifecycleSync<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil {
            return operation()
        }
        return lifecycleQueue.sync(execute: operation)
    }

    private func prepareOutputDevice() throws -> OutputDevice {
        guard let id = Self.readDefaultOutputDeviceID(), id != 0 else {
            throw AudioPlayerError.noOutputDevice
        }
        let name = Self.readDeviceName(id) ?? "Audio device \(id)"
        let bufferFrames = requestLowLatencyBuffer(on: id)
        return OutputDevice(id: id, name: name, bufferFrames: bufferFrames)
    }

    private func requestLowLatencyBuffer(on deviceID: AudioDeviceID) -> UInt32 {
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var rangeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID, &rangeAddress, 0, nil, &size, &range
        ) == noErr else { return 0 }

        var current: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        var frameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(
            deviceID, &frameAddress, 0, nil, &size, &current
        )
        let requested = UInt32(min(range.mMaximum,
                                   max(range.mMinimum, 128)).rounded())
        if current != requested {
            var requestedCopy = requested
            _ = AudioObjectSetPropertyData(
                deviceID, &frameAddress, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &requestedCopy
            )
        }
        var actual = requested
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(
            deviceID, &frameAddress, 0, nil, &size, &actual
        )
        return actual
    }

    private func bind(_ outputNode: AVAudioOutputNode,
                      to deviceID: AudioDeviceID) throws {
        if #available(macOS 27.0, *) {
            try outputNode.withAUAudioUnit { audioUnit in
                try audioUnit.setDeviceID(deviceID)
            }
        } else {
            try outputNode.auAudioUnit.setDeviceID(deviceID)
        }
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readDefaultOutputDeviceID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultOutputAddress
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &id
        ) == noErr, id != 0 else { return nil }
        return id
    }

    private static func readDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &name
        ) == noErr else { return nil }
        return name?.takeUnretainedValue() as String?
    }

    deinit {
        lifecycleSync {
            beginNewGeneration()
            removeDefaultOutputListener()
            stateLock.lock()
            configured = nil
            recovering = false
            let detached = detachGraphLocked(clearOutputDevice: true)
            stateLock.unlock()
            dispose(detached)
        }
    }
}

private enum AudioPlayerError: LocalizedError {
    case noOutputDevice
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noOutputDevice: return "No default audio output is available"
        case .unsupportedFormat: return "The stream audio format is unsupported"
        }
    }
}
