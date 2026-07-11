import Foundation

struct AudioSenderStats {
    let capturedFrames: UInt64
    let packetsSent: UInt64
    let sendErrors: UInt64
    let callbackCount: UInt64
    let sampleRate: Double
    let capturePeriodFrames: UInt32
    let sourceOutputDeviceID: UInt32
    let currentOutputDeviceID: UInt32
    let capturePeak: Float
    let callbackAgeMs: Double
}

final class AudioSender {
    private var handle: OpaquePointer?

    var isRunning: Bool { handle != nil }

    @discardableResult
    func start(targetIP: String, port: UInt16) -> String? {
        stop()
        var error = [CChar](repeating: 0, count: 256)
        let newHandle = targetIP.withCString {
            auvol_system_audio_sender_start($0, port, &error,
                                            UInt32(error.count))
        }
        guard let newHandle else {
            return String(cString: error)
        }
        handle = newHandle
        return nil
    }

    func stop() {
        guard let handle else { return }
        auvol_system_audio_sender_stop(handle)
        self.handle = nil
    }

    func snapshot() -> AudioSenderStats {
        guard let handle else {
            return AudioSenderStats(capturedFrames: 0, packetsSent: 0,
                                    sendErrors: 0, callbackCount: 0,
                                    sampleRate: 0, capturePeriodFrames: 0,
                                    sourceOutputDeviceID: 0,
                                    currentOutputDeviceID: 0,
                                    capturePeak: 0, callbackAgeMs: -1)
        }
        var raw = AuvolSystemAudioSenderStats()
        auvol_system_audio_sender_snapshot(handle, &raw)
        return AudioSenderStats(
            capturedFrames: raw.capturedFrames,
            packetsSent: raw.packetsSent,
            sendErrors: raw.sendErrors,
            callbackCount: raw.callbackCount,
            sampleRate: Double(raw.sampleRate),
            capturePeriodFrames: raw.capturePeriodFrames,
            sourceOutputDeviceID: raw.sourceOutputDeviceID,
            currentOutputDeviceID: raw.currentOutputDeviceID,
            capturePeak: raw.capturePeak,
            callbackAgeMs: raw.callbackAgeMs
        )
    }

    deinit {
        stop()
    }
}
