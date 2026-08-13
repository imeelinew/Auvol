import AppKit
import SwiftUI

/// Transport state as the user reads it. Drives both the menu-bar glyph and the
/// status pill so the two can never disagree.
enum TransportTone {
    case streaming
    case paused
    case fault

    init(_ engine: ReceiverEngine) {
        if engine.isPaused {
            self = .paused
        } else if engine.isSending || engine.isPlaying {
            self = .streaming
        } else {
            self = .fault
        }
    }

    var label: String {
        switch self {
        case .streaming: return "传输中"
        case .paused: return "已暂停"
        case .fault: return "异常"
        }
    }

    var color: Color {
        switch self {
        case .streaming: return .blue
        case .paused: return .orange
        case .fault: return .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .streaming: return .systemBlue
        case .paused: return .systemOrange
        case .fault: return .systemRed
        }
    }
}

private enum Metrics {
    static let popoverWidth: CGFloat = 320
    static let blockSpacing: CGFloat = 10
    static let cardRadius: CGFloat = 11
    static let rowInset: CGFloat = 11
    static let tileSize: CGFloat = 22
    static let iconGap: CGFloat = 10
    static let rowMinHeight: CGFloat = 40
    /// Aligns row separators with the row title rather than the icon.
    static let separatorInset = rowInset + tileSize + iconGap
    static let meterFloorDBFS: Double = -60
}

struct StatusView: View {
    @EnvironmentObject var engine: ReceiverEngine
    @EnvironmentObject var updateService: UpdateService
    @Environment(\.colorScheme) private var colorScheme

    @State private var peakDBFS = Metrics.meterFloorDBFS
    @State private var peakHoldTicks = 0
    @State private var quitHovering = false
    @State private var updateHovering = false

    private var tone: TransportTone { TransportTone(engine) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
            hero
            if !engine.errorMessage.isEmpty {
                errorBanner
            }
            directionPicker
            controlCard
            statusCard
            footer
        }
        .frame(width: Metrics.popoverWidth, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onChange(of: engine.signalLevelDBFS) { _, level in
            advancePeak(to: level)
        }
        .onChange(of: engine.hasSignal) { _, has in
            if !has { resetPeak() }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                appTile
                Text("Auvol")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer(minLength: 8)
                statusPill
            }
            Text(connectionTitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 3)
                .padding(.leading, Metrics.tileSize + 8)
            levelMeter
                .padding(.top, 9)
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.top, 9)
        .padding(.bottom, 11)
        .background(
            tone.color.opacity(0.08),
            in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(tone.color.opacity(0.2), lineWidth: 0.5)
        )
    }

    private var appTile: some View {
        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tone.color.opacity(0.82), tone.color],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: Metrics.tileSize, height: Metrics.tileSize)
            .overlay(
                Image(systemName: "wave.3.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: tone.color.opacity(0.35), radius: 1.5, y: 1)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone.color)
                .frame(width: 5.5, height: 5.5)
            Text(tone.label)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .frame(height: 19)
        .foregroundStyle(tone.color)
        .background(tone.color.opacity(0.15), in: Capsule())
    }

    // MARK: - Level meter

    private var levelMeter: some View {
        HStack(spacing: 9) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.085))
                    if showsLevel {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [tone.color, tone.color.opacity(0.55)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * fraction(engine.signalLevelDBFS))
                        Capsule()
                            .fill(tone.color)
                            .frame(width: 1.5)
                            .offset(x: min(geometry.size.width - 1.5,
                                           geometry.size.width * fraction(peakDBFS)))
                    }
                }
            }
            .frame(height: 4)
            Text(levelText)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
        .animation(.linear(duration: 0.22), value: engine.signalLevelDBFS)
    }

    private var showsLevel: Bool { engine.isActive && engine.hasSignal }

    private var levelText: String {
        if !engine.isActive { return "—" }
        if !engine.hasSignal { return "静音" }
        return String(format: "%.1f dB", engine.signalLevelDBFS)
    }

    private func fraction(_ dbfs: Double) -> Double {
        let span = -Metrics.meterFloorDBFS
        return min(1, max(0, (dbfs - Metrics.meterFloorDBFS) / span))
    }

    /// Peak-hold decay is expressed in engine stat ticks, which arrive every 250 ms:
    /// five ticks of hold, then 6 dB per tick (24 dB/s).
    private func advancePeak(to level: Double) {
        if level >= peakDBFS {
            peakDBFS = level
            peakHoldTicks = 5
        } else if peakHoldTicks > 0 {
            peakHoldTicks -= 1
        } else {
            peakDBFS = max(level, peakDBFS - 6)
        }
    }

    private func resetPeak() {
        peakDBFS = Metrics.meterFloorDBFS
        peakHoldTicks = 0
    }

    // MARK: - Error

    private var errorBanner: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(engine.errorMessage)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.red)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.red.opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - Direction

    private var directionPicker: some View {
        HStack(spacing: 2) {
            directionSegment(.receive, "Windows → Mac")
            directionSegment(.send, "Mac → Windows")
        }
        .padding(2)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.085),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func directionSegment(_ target: TransportRole, _ title: String) -> some View {
        let selected = engine.role == target
        return Button {
            engine.selectRole(target)
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(raisedFill)
                            .shadow(color: .black.opacity(0.16), radius: 1, y: 0.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Controls

    private var controlCard: some View {
        Card {
            row(icon: "headphones",
                title: "自动跟随耳机",
                subtitle: autoFollowDescription,
                tinted: engine.autoFollowEnabled) {
                HStack(spacing: 8) {
                    if showsUseCurrentOutput {
                        Button("使用当前") {
                            engine.followCurrentBluetoothOutput()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                    Toggle("", isOn: Binding(
                        get: { engine.autoFollowEnabled },
                        set: { engine.setAutoFollowEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
            }
            RowSeparator()
            if engine.role == .receive {
                bufferRow
            } else {
                peerRow
            }
        }
    }

    private var showsUseCurrentOutput: Bool {
        engine.currentSystemOutputIsBluetooth &&
            engine.currentSystemOutputName != engine.followedOutputName
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

    private var bufferRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: Metrics.iconGap) {
                tile("timer", tinted: false)
                Text("缓冲目标")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 8)
                Text("\(engine.targetBufferMs) ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Slider(
                    value: Binding(
                        get: { Double(engine.targetBufferMs) },
                        set: { engine.setTargetBufferMs(Int($0.rounded())) }
                    ),
                    in: 8...80
                )
                .controlSize(.small)
                HStack(spacing: 8) {
                    Text("8 ms · 最低延迟")
                    Spacer(minLength: 0)
                    Text("80 ms · 最稳")
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }
            .padding(.leading, Metrics.tileSize + Metrics.iconGap)
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, 8)
    }

    private var peerRow: some View {
        row(icon: "globe", title: "Windows 地址") {
            TextField("192.168.x.x", text: Binding(
                get: { engine.peerIP },
                set: { engine.setPeerIP($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 11.5, design: .monospaced))
            .frame(width: 138)
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        Card {
            if !engine.outputDeviceName.isEmpty {
                row(icon: engine.role == .receive ? "speaker.wave.2.fill" : "waveform",
                    title: engine.role == .receive ? "播放设备" : "采集设备") {
                    value(engine.outputDeviceName)
                }
                RowSeparator()
            }
            row(icon: isWired ? "cable.connector" : "wifi",
                title: "链路",
                subtitle: peerAddress) {
                value(linkSummary, tint: linkIsHealthy ? nil : .red)
            }
        }
    }

    private var isWired: Bool {
        engine.networkPathName == NetworkPathKind.wired.title
    }

    private var pathTitle: String { isWired ? "有线" : "Wi-Fi" }

    private var peerAddress: String? {
        if engine.role == .receive && !engine.senderIP.isEmpty {
            return engine.senderIP
        }
        if engine.role == .send && !engine.peerIP.isEmpty {
            return engine.peerIP
        }
        return nil
    }

    private var linkSummary: String {
        guard engine.isActive else { return "—" }
        return "\(pathTitle) · \(linkQuality)"
    }

    private var linkIsHealthy: Bool {
        !engine.isActive || linkQuality == "正常"
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

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("退出") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(quitHovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .onHover { quitHovering = $0 }

            Button("检查更新") {
                updateService.checkForUpdates()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(updateHovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .disabled(!updateService.canCheckForUpdates)
            .onHover { updateHovering = $0 }

            Spacer(minLength: 8)

            Button {
                if engine.isActive {
                    engine.stop()
                } else {
                    engine.start()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: engine.isActive ? "pause.fill" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(engine.isActive ? "暂停" : "继续")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .frame(height: 25)
                .foregroundStyle(engine.isActive ? Color.primary : Color.white)
                .background {
                    if engine.isActive {
                        Capsule()
                            .fill(raisedFill)
                            .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
                    } else {
                        Capsule()
                            .fill(Color.accentColor)
                            .shadow(color: Color.accentColor.opacity(0.35), radius: 1.5, y: 1)
                    }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    // MARK: - Row building blocks

    private func row<Trailing: View>(
        icon: String,
        title: String,
        subtitle: String? = nil,
        tinted: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: Metrics.iconGap) {
            tile(icon, tinted: tinted)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, 8)
        .frame(minHeight: Metrics.rowMinHeight)
    }

    private func tile(_ symbol: String, tinted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tinted
                  ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                  : AnyShapeStyle(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055)))
            .frame(width: Metrics.tileSize, height: Metrics.tileSize)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tinted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            )
    }

    private func value(_ text: String, tint: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 12, weight: tint == nil ? .medium : .semibold).monospacedDigit())
            .foregroundStyle(tint ?? .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 172, alignment: .trailing)
    }

    private var raisedFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.white
    }

    // MARK: - Status text

    private var connectionTitle: String {
        localizedStatus(engine.statusMessage)
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

private struct Card<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            colorScheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.62),
            in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.055),
                    lineWidth: 0.5
                )
        )
    }
}

private struct RowSeparator: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.082 : 0.072))
            .frame(height: 0.5)
            .padding(.leading, Metrics.separatorInset)
    }
}
