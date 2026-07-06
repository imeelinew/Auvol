import SwiftUI

@main
struct AuvolApp: App {
    @StateObject private var engine = ReceiverEngine()

    var body: some Scene {
        MenuBarExtra {
            StatusView()
                .environmentObject(engine)
        } label: {
            Image(systemName: engine.isPlaying ? "waveform" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
