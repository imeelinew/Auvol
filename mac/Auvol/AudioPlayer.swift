import Foundation
import AVFoundation

/// 用 AVAudioEngine + AVAudioSourceNode 从 ring buffer 拉取音频。
/// 自适应 jitter buffer：根据缓冲水位动态调节消费速率，吸收双端时钟漂移。
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var ring: RingBuffer?
    private var format: AVAudioFormat?
    private var running = false
    private var primed = false
    private let lock = NSLock()
    private var configured: AudioConfig?
    private var channelCount = 2
    private var lastSample: [Float] = [0, 0]
    private var wasStarved = false
    /// 缓冲水位 EMA（1.0 = 达到 targetBufferMs）
    private var bufferFillEma = 1.0

    var targetBufferMs: Int = 150
    private(set) var underruns = 0
    private(set) var overflows = 0

    var isPlaying: Bool { running && engine.isRunning }

    var bufferLevelMs: Double {
        guard let r = ring, let sr = format?.sampleRate else { return 0 }
        return Double(r.availableFrames) / sr * 1000.0
    }

    func configure(sampleRate: Double, channels: UInt32, frameSize: UInt32) {
        lock.lock(); defer { lock.unlock() }

        let cfg = AudioConfig(sampleRate: sampleRate, channels: channels, frameSize: frameSize)
        if configured == cfg { return }
        configured = cfg
        channelCount = Int(channels)
        lastSample = Array(repeating: 0, count: channelCount)
        wasStarved = false
        bufferFillEma = 1.0

        teardownLocked()

        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels)) else { return }
        format = fmt
        ring = RingBuffer(capacityFrames: Int(sampleRate * 3), channels: channelCount)

        let ch = channelCount
        let node = AVAudioSourceNode(format: fmt) { [weak self] _, _, frameCount, abl -> OSStatus in
            guard let self else { return noErr }
            return self.render(frames: Int(frameCount), abl: abl, channels: ch)
        }
        sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
    }

    func push(_ data: UnsafePointer<Float>, frames: Int) {
        lock.lock()
        let r = ring
        let needStart = !primed
        lock.unlock()
        guard let r = r else { return }

        let written = r.write(data, frames: frames)
        if written < frames { overflows += 1 }

        trimBufferIfNeeded(r)

        if needStart { maybeStart() }
    }

    private func targetFrames() -> Int {
        guard let fmt = format else { return 0 }
        return Int(fmt.sampleRate * Double(targetBufferMs) / 1000.0)
    }

    private func trimBufferIfNeeded(_ r: RingBuffer) {
        let target = targetFrames()
        guard target > 0 else { return }
        let avail = r.availableFrames
        if avail > target * 5 / 2 {
            r.discard(frames: avail - target * 6 / 5)
        }
    }

    private func maybeStart() {
        lock.lock(); defer { lock.unlock() }
        guard !running, !primed, let r = ring, sourceNode != nil else { return }

        guard r.availableFrames >= targetFrames() else { return }

        do {
            try engine.start()
            running = true
            primed = true
            bufferFillEma = Double(r.availableFrames) / Double(max(targetFrames(), 1))
        } catch {
            running = false
        }
    }

    /// 根据缓冲水位决定相对硬件时钟的消费速率。
    private func playbackRate(for fill: Double) -> Double {
        switch fill {
        case ..<0.15:  return 0.88
        case ..<0.35:  return 0.94
        case ..<0.60:  return 0.98
        case ..<0.85:  return 0.995
        case ..<1.20:  return 1.0
        case ..<1.60:  return 1.015
        default:       return 1.03
        }
    }

    private func render(frames: Int, abl: UnsafeMutablePointer<AudioBufferList>, channels ch: Int) -> OSStatus {
        guard let r = ring, frames > 0 else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard buffers.count >= ch else { return noErr }

        let target = targetFrames()
        let avail = r.availableFrames
        let fill = Double(avail) / Double(max(target, 1))
        bufferFillEma = bufferFillEma * 0.92 + min(fill, 4.0) * 0.08

        let rate = playbackRate(for: bufferFillEma)
        let wantRead = max(1, Int((Double(frames) * rate).rounded()))
        let toRead = min(avail, wantRead)
        var temp = [Float](repeating: 0, count: frames * ch)

        if toRead > 0 {
            var src = [Float](repeating: 0, count: toRead * ch)
            let read = src.withUnsafeMutableBufferPointer { ptr in
                r.read(into: ptr.baseAddress!, frames: toRead)
            }
            if read > 0 {
                if read > frames {
                    compress(into: &temp, src: src, srcFrames: read, dstFrames: frames, ch: ch)
                } else if read < frames {
                    stretch(into: &temp, src: src, srcFrames: read, dstFrames: frames, ch: ch)
                } else {
                    for i in 0..<frames * ch { temp[i] = src[i] }
                }
            }
        } else {
            lock.lock()
            underruns += frames
            lock.unlock()
            for i in 0..<frames {
                for c in 0..<ch where c < lastSample.count {
                    temp[i * ch + c] = lastSample[c]
                }
            }
            wasStarved = true
        }

        if toRead > 0 && wasStarved {
            let fade = min(32, frames)
            for i in 0..<fade {
                let t = Float(i + 1) / Float(fade)
                for c in 0..<ch where c < lastSample.count {
                    let idx = i * ch + c
                    temp[idx] = lastSample[c] * (1 - t) + temp[idx] * t
                }
            }
            wasStarved = false
        }

        for c in 0..<ch where c < lastSample.count {
            lastSample[c] = temp[(frames - 1) * ch + c]
        }

        for c in 0..<ch {
            guard let dst = buffers[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<frames {
                dst[i] = temp[i * ch + c]
            }
        }
        return noErr
    }

    private func stretch(into dst: inout [Float], src: [Float], srcFrames: Int, dstFrames: Int, ch: Int) {
        guard srcFrames > 0, dstFrames > 0 else { return }
        if srcFrames == 1 || dstFrames == 1 {
            for i in 0..<dstFrames {
                for c in 0..<ch { dst[i * ch + c] = src[c] }
            }
            return
        }
        let denom = max(dstFrames - 1, 1)
        for i in 0..<dstFrames {
            let pos = Double(i) * Double(srcFrames - 1) / Double(denom)
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let idx2 = min(idx + 1, srcFrames - 1)
            for c in 0..<ch {
                let a = src[idx * ch + c]
                let b = src[idx2 * ch + c]
                dst[i * ch + c] = a + (b - a) * frac
            }
        }
    }

    private func compress(into dst: inout [Float], src: [Float], srcFrames: Int, dstFrames: Int, ch: Int) {
        guard srcFrames > 0, dstFrames > 0 else { return }
        if srcFrames == 1 || dstFrames == 1 {
            for i in 0..<dstFrames {
                for c in 0..<ch { dst[i * ch + c] = src[c] }
            }
            return
        }
        let denom = max(srcFrames - 1, 1)
        for i in 0..<dstFrames {
            let pos = Double(i) * Double(srcFrames - 1) / Double(max(dstFrames - 1, 1))
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let idx2 = min(idx + 1, srcFrames - 1)
            for c in 0..<ch {
                let a = src[idx * ch + c]
                let b = src[idx2 * ch + c]
                dst[i * ch + c] = a + (b - a) * frac
            }
        }
    }

    private func teardownLocked() {
        if engine.isRunning { engine.stop() }
        if let node = sourceNode {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            sourceNode = nil
        }
        engine.reset()
        running = false
        primed = false
        lastSample = Array(repeating: 0, count: channelCount)
        wasStarved = false
        bufferFillEma = 1.0
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        teardownLocked()
        configured = nil
        ring = nil
        format = nil
    }
}
