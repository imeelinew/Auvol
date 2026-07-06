import Foundation
import AVFoundation

/// 用 AVAudioEngine + AVAudioPlayerNode 播放网络收到的音频。
/// engine 的 mainMixerNode 自动重采样到硬件格式，无需手动处理采样率转换。
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var ring: RingBuffer?
    private var format: AVAudioFormat?
    private var running = false
    private var primed = false
    private let lock = NSLock()
    private var configured: AudioConfig?

    var targetBufferMs: Int = 300
    private(set) var underruns = 0
    private(set) var overflows = 0

    var isPlaying: Bool { running && player.isPlaying }

    var bufferLevelMs: Double {
        guard let r = ring, let sr = format?.sampleRate else { return 0 }
        return Double(r.availableFrames) / sr * 1000.0
    }

    /// 配置/重新配置音频格式。相同配置重复调用会被忽略（Windows 每秒重发 config）。
    func configure(sampleRate: Double, channels: UInt32) {
        lock.lock(); defer { lock.unlock() }

        let cfg = AudioConfig(sampleRate: sampleRate, channels: channels, frameSize: 120)
        if configured == cfg { return }
        configured = cfg

        if running {
            player.stop()
            engine.stop()
        }

        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                 sampleRate: sampleRate,
                                 channels: channels,
                                 interleaved: false)!
        format = fmt
        ring = RingBuffer(capacityFrames: Int(sampleRate * 3), channels: Int(channels))

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        running = false
        primed = false
    }

    /// 网络线程调用：写入收到的音频数据。
    func push(_ data: UnsafePointer<Float>, frames: Int) {
        lock.lock()
        let r = ring
        let needStart = !primed
        lock.unlock()
        guard let r = r else { return }

        let written = r.write(data, frames: frames)
        if written < frames { overflows += 1 }

        if needStart { maybeStart() }
    }

    private func maybeStart() {
        lock.lock(); defer { lock.unlock() }
        guard !running, !primed, let r = ring, let fmt = format else { return }

        let primeFrames = Int(fmt.sampleRate * Double(targetBufferMs * 2) / 1000.0)
        guard r.availableFrames >= primeFrames else { return }

        do {
            try engine.start()
        } catch {
            return
        }
        player.play()
        running = true
        primed = true
        for _ in 0..<4 { scheduleNext() }
    }

    private func scheduleNext() {
        guard running, let r = ring, let fmt = format else { return }

        let chunk = 1024
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk)) else { return }
        buf.frameLength = AVAudioFrameCount(chunk)

        let ch = Int(fmt.channelCount)
        var temp = [Float](repeating: 0, count: chunk * ch)
        let read = temp.withUnsafeMutableBufferPointer { ptr in
            r.read(into: ptr.baseAddress!, frames: chunk)
        }

        if read < chunk {
            underruns += 1
            // 欠载时保持最后一个样本值，避免硬跳变爆音
            let lastIdx = max(0, read - 1) * ch
            for i in (read * ch)..<chunk * ch {
                temp[i] = read > 0 ? temp[lastIdx + (i % ch)] : 0
            }
        }

        // ring 是交错的；AVAudioPCMBuffer 要非交错
        if ch == 2 {
            let l = buf.floatChannelData![0]
            let rCh = buf.floatChannelData![1]
            for i in 0..<chunk {
                l[i] = temp[i * 2]
                rCh[i] = temp[i * 2 + 1]
            }
        } else {
            for c in 0..<ch {
                let p = buf.floatChannelData![c]
                for i in 0..<chunk {
                    p[i] = temp[i * ch + c]
                }
            }
        }

        player.scheduleBuffer(buf) { [weak self] in
            DispatchQueue.global().async { self?.scheduleNext() }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if player.isPlaying { player.stop() }
        if engine.isRunning { engine.stop() }
        running = false
        primed = false
    }
}
