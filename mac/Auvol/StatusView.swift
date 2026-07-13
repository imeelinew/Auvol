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
        .frame(width: 300, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
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
        Picker("传输方向", selection: Binding(
            get: { engine.role },
            set: { engine.activate($0) }
        )) {
            ForEach(TransportRole.allCases, id: \.self) { role in
                Text(role == .receive ? "从 Windows 接收" : "发送到 Windows")
                    .tag(role)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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
            Text("Windows 地址")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("192.168.x.x", text: Binding(
                get: { engine.peerIP },
                set: { engine.setPeerIP($0) }
            ))
            .textFieldStyle(.roundedBorder)
            Text("地址修改后会自动应用。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var latencyControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("缓冲目标")
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
                statRow("当前缓冲", String(format: "%.1f ms", engine.bufferLevelMs))
                statRow("输出周期", String(format: "%.1f ms", engine.outputQuantumMs))
                statRow("时钟校正", String(format: "%+.0f ppm", engine.driftPPM))
            }
            statRow("源周期", String(format: "%.1f ms", engine.sourcePeriodMs))
        }
    }

    private var healthStats: some View {
        VStack(spacing: 4) {
            statRow("数据包", "\(engine.packetRate)/秒")
            statRow("信号", engine.hasSignal
                    ? String(format: "%.1f dBFS", engine.signalLevelDBFS)
                    : "静音")
            if !engine.outputDeviceName.isEmpty {
                statRow(engine.role == .receive ? "播放设备" : "采集设备",
                        engine.outputDeviceName)
            }
            if engine.role == .receive {
                statRow("丢失 / 迟到", "\(engine.lostPackets) / \(engine.latePackets)")
                statRow("音频欠载", "\(engine.starvedFramesPerSecond) 帧/秒")
                statRow("缓冲溢出", "\(engine.overflowFrames) 帧")
                if engine.captureGlitches > 0 {
                    statRow("采集异常", "\(engine.captureGlitches)")
                }
            } else if engine.captureCallbackAgeMs > 0 {
                statRow("采集回调",
                        String(format: "%.0f ms 前", engine.captureCallbackAgeMs))
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
                Text("ALV2 · \(Int(engine.sampleRate)) Hz · 双声道")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(engine.isActive ? "暂停" : "继续") {
                if engine.isActive {
                    engine.stop()
                } else {
                    engine.start()
                }
            }
                .buttonStyle(.borderless)
            Button("退出") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
    }

    private var connectionTitle: String {
        localizedStatus(engine.statusMessage)
    }

    private var statusColor: Color {
        if engine.isPaused { return .orange }
        if engine.isSending || engine.isPlaying { return .green }
        return .red
    }

    private func localizedStatus(_ status: String) -> String {
        switch status {
        case "Starting": return "正在启动"
        case "Paused": return "已暂停"
        case "Waiting for Windows audio": return "等待 Windows 音频"
        case "Starting system-audio capture": return "正在启动系统音频采集"
        case "Recovering Mac audio output", "Recovering audio output":
            return "正在恢复 Mac 音频输出"
        case "Sending Mac audio to Windows": return "正在向 Windows 发送 Mac 音频"
        case "Connected · Mac audio is silent": return "已连接 · Mac 当前静音"
        case "Playing Windows audio": return "正在播放 Windows 音频"
        case "Connected · incoming audio is silent": return "已连接 · 传入音频静音"
        case "Preparing Mac audio output": return "正在准备 Mac 音频输出"
        default:
            let prefix = "Recovering · "
            guard status.hasPrefix(prefix) else { return status }
            let reason = String(status.dropFirst(prefix.count))
            return "正在恢复 · \(localizedRecoveryReason(reason))"
        }
    }

    private func localizedRecoveryReason(_ reason: String) -> String {
        switch reason {
        case "Destination changed": return "目标地址已更改"
        case "Mac output device changed": return "Mac 输出设备已更改"
        case "System-audio capture stalled": return "系统音频采集已停止响应"
        case "UDP sender failed": return "UDP 发送失败"
        default: return reason
        }
    }
}
