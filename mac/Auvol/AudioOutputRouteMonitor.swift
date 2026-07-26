import CoreAudio
import Foundation

struct AudioOutputRoute: Equatable {
    let deviceID: AudioObjectID
    let uid: String
    let name: String
    let isBluetooth: Bool
}

/// Observes the system output independently from the active audio transport.
/// A route is published only after it has remained unchanged for the debounce
/// interval, so transient built-in/no-device states during Bluetooth handoff do
/// not become direction decisions.
final class AudioOutputRouteMonitor {
    private static let debounceInterval = 1.0

    private let queue = DispatchQueue(
        label: "com.eli.Auvol.output-route",
        qos: .userInitiated
    )
    private var listener: AudioObjectPropertyListenerBlock?
    private var listenerInstalled = false
    private var pendingEvaluation: DispatchWorkItem?
    private var lastPublishedRoute: AudioOutputRoute?

    var onStableRoute: ((AudioOutputRoute?) -> Void)?

    func start() {
        queue.async { [weak self] in
            guard let self, !listenerInstalled else { return }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleEvaluation()
            }
            var address = Self.defaultOutputAddress
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            )
            guard status == noErr else { return }
            self.listener = listener
            listenerInstalled = true
            scheduleEvaluation()
        }
    }

    func stop() {
        queue.sync {
            pendingEvaluation?.cancel()
            pendingEvaluation = nil
            if listenerInstalled, let listener {
                var address = Self.defaultOutputAddress
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    queue,
                    listener
                )
            }
            listener = nil
            listenerInstalled = false
        }
    }

    func currentRoute() -> AudioOutputRoute? {
        Self.readDefaultRoute()
    }

    private func scheduleEvaluation() {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingEvaluation?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingEvaluation = nil
            let route = Self.readDefaultRoute()
            guard route != lastPublishedRoute else { return }
            lastPublishedRoute = route
            DispatchQueue.main.async { [weak self] in
                self?.onStableRoute?(route)
            }
        }
        pendingEvaluation = item
        queue.asyncAfter(deadline: .now() + Self.debounceInterval,
                         execute: item)
    }

    private static func readDefaultRoute() -> AudioOutputRoute? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var defaultAddress = defaultOutputAddress
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        guard let uid = stringProperty(
            deviceID,
            selector: kAudioDevicePropertyDeviceUID
        ) else {
            return nil
        }
        let name = stringProperty(
            deviceID,
            selector: kAudioObjectPropertyName
        ) ?? "Unknown output"

        var transport: UInt32 = kAudioDeviceTransportTypeUnknown
        size = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(
            deviceID,
            &transportAddress,
            0,
            nil,
            &size,
            &transport
        )

        return AudioOutputRoute(
            deviceID: deviceID,
            uid: uid,
            name: name,
            isBluetooth: transport == kAudioDeviceTransportTypeBluetooth ||
                transport == kAudioDeviceTransportTypeBluetoothLE
        )
    }

    private static func stringProperty(
        _ deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr, let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    deinit {
        stop()
    }
}
