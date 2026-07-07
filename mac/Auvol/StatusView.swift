import SwiftUI

struct StatusView: View {
    @EnvironmentObject var engine: ReceiverEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusText
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 220)
    }

    private var header: some View {
        HStack {
            Text("Auvol").font(.headline)
            Spacer()
            statusDot
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        if engine.isPlaying { return .green }
        if engine.isListening { return .orange }
        return .gray
    }

    private var statusText: some View {
        VStack(alignment: .leading, spacing: 2) {
            if engine.isPlaying {
                Text("Receiving")
            } else if engine.isListening {
                Text("Listening")
            } else {
                Text("Stopped")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(.borderless)
    }
}
