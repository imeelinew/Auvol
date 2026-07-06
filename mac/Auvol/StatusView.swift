import SwiftUI

struct StatusView: View {
    @EnvironmentObject var engine: ReceiverEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusText
            Divider()
            statsGrid
            Divider()
            bufferControl
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
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
                Text("Receiving from \(engine.senderIP)")
            } else if engine.isListening {
                Text("Listening on port \(engine.port)…")
            } else {
                Text("Stopped")
            }
            if engine.sampleRate > 0 {
                Text("\(Int(engine.sampleRate)) Hz · \(engine.channels) ch")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var statsGrid: some View {
        VStack(spacing: 6) {
            statRow("Buffer", String(format: "%.0f ms", engine.bufferLevelMs))
            statRow("Packets", "\(engine.totalPackets)")
            statRow("Underruns", "\(engine.underruns)")
            statRow("Overflows", "\(engine.overflows)")
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 12))
    }

    private var bufferControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Target buffer").font(.caption)
                Spacer()
                Text("\(engine.targetBufferMs) ms").font(.caption).monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(engine.targetBufferMs) },
                    set: { engine.targetBufferMs = Int($0) }
                ),
                in: 100...800, step: 50
            )
        }
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
