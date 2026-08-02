import SwiftUI

struct StatusView: View {
    @EnvironmentObject var engine: ReceiverEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            roleControl
            autoFollowControl
            connection
            if engine.role == .send {
                peerControl
            } else {
                Divider()
                latencyControl
            }
            Divider()
            statusStats
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
            set: { engine.selectRole($0) }
        )) {
            ForEach(TransportRole.allCases, id: \.self) { role in
                Text(role == .receive ? "Windows → Mac" : "Mac → Windows")
                    .tag(role)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var autoFollowControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("自动跟随耳机", isOn: Binding(
                get: { engine.autoFollowEnabled },
                set: { engine.setAutoFollowEnabled($0) }
            ))
            HStack {
                Text(autoFollowDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Spacer()
                if engine.currentSystemOutputIsBluetooth &&
                    engine.currentSystemOutputName != engine.followedOutputName {
                    Button("使用当前") {
                        engine.followCurrentBluetoothOutput()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                }
            }
        }
    }

    private var autoFollowDescription: String {
        if !engine.autoFollowEnabled {
            return "未启用"
        }
        if engine.followedOutputName.isEmpty {
            return "等待耳机成为默认输出"
        }
        return engine.followedOutputName
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(connectionTitle)
            Text(connectionDetail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if !engine.errorMessage.isEmpty {
                Text(engine.errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var connectionDetail: String {
        let path = engine.networkPathName == NetworkPathKind.wired.title
            ? "有线" : "Wi-Fi"
        if engine.role == .receive && !engine.senderIP.isEmpty {
            return "\(engine.senderIP) · \(path)"
        }
        if engine.role == .send && !engine.peerIP.isEmpty {
            return "\(engine.peerIP) · \(path)"
        }
        return path
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

    private var statusStats: some View {
        VStack(spacing: 4) {
            if !engine.outputDeviceName.isEmpty {
                statRow(engine.role == .receive ? "播放设备" : "采集设备",
                        engine.outputDeviceName)
            }
            statRow("信号", engine.hasSignal
                    ? String(format: "%.1f dBFS", engine.signalLevelDBFS)
                    : (engine.isActive ? "静音" : "—"))
            statRow("链路", linkQuality)
        }
    }

    private var linkQuality: String {
        if !engine.errorMessage.isEmpty {
            return "异常"
        }
        if !engine.isActive {
            return "—"
        }
        if engine.role == .receive {
            if engine.lostPackets == 0 &&
                engine.latePackets == 0 &&
                engine.starvedFramesPerSecond == 0 &&
                engine.overflowFrames == 0 {
                return "正常"
            }
            var parts: [String] = []
            if engine.lostPackets > 0 {
                parts.append("丢包 \(engine.lostPackets)")
            }
            if engine.latePackets > 0 {
                parts.append("迟到 \(engine.latePackets)")
            }
            if engine.starvedFramesPerSecond > 0 {
                parts.append("欠载")
            }
            if engine.overflowFrames > 0 {
                parts.append("溢出")
            }
            return parts.joined(separator: " · ")
        }
        if engine.captureGlitches > 0 {
            return "采集异常 \(engine.captureGlitches)"
        }
        return "正常"
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
        if engine.isSending || engine.isPlaying { return .blue }
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
        case "Sending Mac audio to Windows": return "正在向 Windows 发送"
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
        case "Network path changed": return "网络路径已切换"
        default: return reason
        }
    }
}
