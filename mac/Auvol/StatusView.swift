import SwiftUI

struct StatusView: View {
    @EnvironmentObject var engine: ReceiverEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            connection
            Divider()
            latencyControl
            Divider()
            timingStats
            Divider()
            healthStats
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 292)
    }

    private var header: some View {
        HStack {
            Text("Auvol").font(.headline)
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(connectionTitle)
            if !engine.senderIP.isEmpty {
                Text(engine.senderIP)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if !engine.errorMessage.isEmpty {
                Text(engine.errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var latencyControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Jitter target")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(engine.targetBufferMs) ms")
                    .font(.caption.monospacedDigit())
            }
            Slider(
                value: Binding(
                    get: { Double(engine.targetBufferMs) },
                    set: { engine.setTargetBufferMs(Int($0.rounded())) }
                ),
                in: 8...80,
                step: 1
            )
            HStack {
                Text("8 ms")
                Spacer()
                Text("80 ms")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var timingStats: some View {
        VStack(spacing: 4) {
            statRow("Queued", String(format: "%.1f ms", engine.bufferLevelMs))
            statRow("Windows period", String(format: "%.1f ms", engine.capturePeriodMs))
            statRow("Mac quantum", String(format: "%.1f ms", engine.outputQuantumMs))
            statRow("Clock correction", String(format: "%+.0f ppm", engine.driftPPM))
        }
    }

    private var healthStats: some View {
        VStack(spacing: 4) {
            statRow("Packets", "\(engine.packetRate)/s")
            statRow("Lost / late", "\(engine.lostPackets) / \(engine.latePackets)")
            statRow("Starved", "\(engine.starvedFramesPerSecond) frames/s")
            statRow("Overflow", "\(engine.overflowFrames) frames")
            if engine.captureGlitches > 0 {
                statRow("Capture glitches", "\(engine.captureGlitches)")
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.caption.monospacedDigit())
    }

    private var footer: some View {
        HStack {
            if engine.sampleRate > 0 {
                Text("ALV2 · \(Int(engine.sampleRate)) Hz · stereo")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Quit") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
    }

    private var connectionTitle: String {
        if engine.isPlaying { return "Streaming" }
        if engine.isListening { return "Listening on UDP \(engine.port)" }
        return "Stopped"
    }

    private var statusColor: Color {
        if !engine.errorMessage.isEmpty { return .red }
        if engine.isPlaying { return .green }
        if engine.isListening { return .orange }
        return .gray
    }
}
