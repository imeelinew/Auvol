import SwiftUI

@main
struct AuvolApp: App {
    @StateObject private var engine: ReceiverEngine

    init() {
        let arguments = CommandLine.arguments
        let role: TransportRole = arguments.contains("--send") ? .send : .receive
        let peerIndex = arguments.firstIndex(of: "--peer")
        let peer = peerIndex.flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        _engine = StateObject(wrappedValue: ReceiverEngine(initialRole: role,
                                                            initialPeerIP: peer))
    }

    var body: some Scene {
        MenuBarExtra {
            StatusView()
                .environmentObject(engine)
        } label: {
            Image(systemName: (engine.isPlaying || engine.isSending)
                  ? "waveform" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
