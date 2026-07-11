import SwiftUI

struct StatusView: View {
    @EnvironmentObject var engine: ReceiverEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            roleControl
            connection
            if engine.role == .send {
                peerControl
            } else {
                Divider()
                latencyControl
            }
            Divider()
            timingStats
            Divider()
            healthStats
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 310)
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

    private var roleControl: some View {
        Picker("Direction", selection: Binding(
            get: { engine.role },
            set: { engine.activate($0) }
        )) {
            ForEach(TransportRole.allCases, id: \.self) { role in
                Text(role.title).tag(role)
            }
        }
        .pickerStyle(.segmented)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(connectionTitle)
            if engine.role == .receive && !engine.senderIP.isEmpty {
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

    private var peerControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Windows IP")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("192.168.x.x", text: Binding(
                get: { engine.peerIP },
                set: { engine.setPeerIP($0) }
            ))
            .textFieldStyle(.roundedBorder)
            Text("Address changes are applied automatically.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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
        }
    }

    private var timingStats: some View {
        VStack(spacing: 4) {
            if engine.role == .receive {
                statRow("Queued", String(format: "%.1f ms", engine.bufferLevelMs))
                statRow("Output quantum", String(format: "%.1f ms", engine.outputQuantumMs))
                statRow("Clock correction", String(format: "%+.0f ppm", engine.driftPPM))
            }
            statRow("Source period", String(format: "%.1f ms", engine.sourcePeriodMs))
        }
    }

    private var healthStats: some View {
        VStack(spacing: 4) {
            statRow("Packets", "\(engine.packetRate)/s")
            statRow("Signal", engine.hasSignal
                    ? String(format: "%.1f dBFS", engine.signalLevelDBFS)
                    : "Silence")
            if !engine.outputDeviceName.isEmpty {
                statRow(engine.role == .receive ? "Playing on" : "Capturing from",
                        engine.outputDeviceName)
            }
            if engine.role == .receive {
                statRow("Lost / late", "\(engine.lostPackets) / \(engine.latePackets)")
                statRow("Starved", "\(engine.starvedFramesPerSecond) frames/s")
                statRow("Overflow", "\(engine.overflowFrames) frames")
                if engine.captureGlitches > 0 {
                    statRow("Capture glitches", "\(engine.captureGlitches)")
                }
            } else if engine.captureCallbackAgeMs > 0 {
                statRow("Capture callback",
                        String(format: "%.0f ms ago", engine.captureCallbackAgeMs))
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
            Button(engine.isActive ? "Pause" : "Resume") {
                if engine.isActive {
                    engine.stop()
                } else {
                    engine.start()
                }
            }
                .buttonStyle(.borderless)
            Button("Quit") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
    }

    private var connectionTitle: String {
        engine.statusMessage
    }

    private var statusColor: Color {
        if !engine.errorMessage.isEmpty { return .red }
        if engine.isRecovering { return .orange }
        if engine.isSending || engine.isPlaying { return .green }
        if engine.isListening { return .orange }
        return .gray
    }
}
