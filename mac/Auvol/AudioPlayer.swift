import Foundation
import AVFoundation

/// 用 AVAudioEngine + AVAudioSourceNode 从 ring buffer 拉取音频。
/// 正常路径 1:1 直通；仅在真正缺帧时 stretch，避免持续 resample 引入杂音。
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

    var targetBufferMs: Int = 80
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

    /// UDP 丢包时用上一帧样本填充 gap，避免波形硬断。
    func pushConcealment(frames: Int) {
        guard frames > 0 else { return }
        lock.lock()
        let samples = lastSample
        let ch = channelCount
        lock.unlock()

        var buf = [Float](repeating: 0, count: frames * ch)
        for i in 0..<frames {
            for c in 0..<ch where c < samples.count {
                buf[i * ch + c] = samples[c]
            }
        }
        buf.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            push(base, frames: frames)
        }
    }

    private func targetFrames() -> Int {
        guard let fmt = format else { return 0 }
        return Int(fmt.sampleRate * Double(targetBufferMs) / 1000.0)
    }

    private func trimBufferIfNeeded(_ r: RingBuffer) {
        let target = targetFrames()
        guard target > 0 else { return }
        let avail = r.availableFrames
        if avail > target * 2 {
            r.discard(frames: avail - target)
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
        } catch {
            running = false
        }
    }

    private func render(frames: Int, abl: UnsafeMutablePointer<AudioBufferList>, channels ch: Int) -> OSStatus {
        guard let r = ring, frames > 0 else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard buffers.count >= ch else { return noErr }

        let avail = r.availableFrames
        var temp = [Float](repeating: 0, count: frames * ch)

        if avail >= frames {
            let read = temp.withUnsafeMutableBufferPointer { ptr in
                r.read(into: ptr.baseAddress!, frames: frames)
            }
            if read < frames {
                stretchPartialRead(into: &temp, read: read, frames: frames, ch: ch)
            }
        } else if avail > 0 {
            var src = [Float](repeating: 0, count: avail * ch)
            let read = src.withUnsafeMutableBufferPointer { ptr in
                r.read(into: ptr.baseAddress!, frames: avail)
            }
            if read > 0 {
                stretch(into: &temp, src: src, srcFrames: read, dstFrames: frames, ch: ch)
            }
            lock.lock()
            underruns += frames - read
            lock.unlock()
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

        if avail > 0 && wasStarved {
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

    private func stretchPartialRead(into temp: inout [Float], read: Int, frames: Int, ch: Int) {
        lock.lock()
        underruns += frames - read
        lock.unlock()
        let base = max(0, read - 1) * ch
        for i in read..<frames {
            for c in 0..<ch {
                temp[i * ch + c] = read > 0 ? temp[base + c] : lastSample[c]
            }
        }
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
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        teardownLocked()
        configured = nil
        ring = nil
        format = nil
    }
}
