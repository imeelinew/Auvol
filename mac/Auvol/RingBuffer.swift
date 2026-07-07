import Foundation

/// 线程安全的环形缓冲区，存交错 float32 PCM。
final class RingBuffer {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    let channels: Int
    private var writePos: Int = 0
    private var readPos: Int = 0
    private let lock = NSLock()

    init(capacityFrames: Int, channels: Int) {
        var c = 1
        while c < capacityFrames { c <<= 1 }
        self.capacity = c
        self.mask = c - 1
        self.channels = channels
        self.storage = .allocate(capacity: c * channels)
        self.storage.initialize(repeating: 0, count: c * channels)
    }

    deinit {
        storage.deinitialize(count: capacity * channels)
        storage.deallocate()
    }

    @discardableResult
    func write(_ src: UnsafePointer<Float>, frames: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let avail = capacity - (writePos - readPos)
        let n = min(frames, avail)
        guard n > 0 else { return 0 }
        let start = writePos & mask
        let first = min(n, capacity - start)
        storage.advanced(by: start * channels).update(from: src, count: first * channels)
        if n > first {
            storage.update(from: src.advanced(by: first * channels), count: (n - first) * channels)
        }
        writePos += n
        return n
    }

    @discardableResult
    func discard(frames: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let avail = max(0, writePos - readPos)
        let n = min(frames, avail)
        readPos += n
        return n
    }

    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let avail = writePos - readPos
        let n = min(frames, max(0, avail))
        guard n > 0 else { return 0 }
        let start = readPos & mask
        let first = min(n, capacity - start)
        dst.update(from: storage.advanced(by: start * channels), count: first * channels)
        if n > first {
            dst.advanced(by: first * channels).update(from: storage, count: (n - first) * channels)
        }
        readPos += n
        return n
    }

    var availableFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return max(0, writePos - readPos)
    }

    var capacityFrames: Int { capacity }
}
