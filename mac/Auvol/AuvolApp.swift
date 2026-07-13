import AppKit
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
            MenuBarStatusLabel(engine: engine)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var engine: ReceiverEngine

    var body: some View {
        Image(nsImage: menuBarImage)
            .renderingMode(.original)
        .accessibilityLabel(accessibilityLabel)
    }

    private var menuBarImage: NSImage {
        let arrowName = engine.role == .send ? "arrow.up" : "arrow.down"
        let dotColor: NSColor
        if engine.isPaused {
            dotColor = .systemOrange
        } else if engine.isSending || engine.isPlaying {
            dotColor = .systemGreen
        } else {
            dotColor = .systemRed
        }

        let image = NSImage(size: NSSize(width: 37, height: 18), flipped: false) { _ in
            drawSymbol(arrowName,
                       pointSize: 9,
                       weight: .bold,
                       in: NSRect(x: 0, y: 4, width: 9, height: 10))
            drawSymbol("waveform",
                       pointSize: 15,
                       weight: .medium,
                       in: NSRect(x: 12, y: 2, width: 16, height: 14))
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 31, y: 6, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func drawSymbol(_ name: String,
                            pointSize: CGFloat,
                            weight: NSFont.Weight,
                            in rect: NSRect) {
        let size = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let color = NSImage.SymbolConfiguration(paletteColors: [.labelColor])
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(size.applying(color))?
            .draw(in: rect)
    }

    private var accessibilityLabel: String {
        let direction = engine.role == .send ? "Mac 发送到 Windows" : "Windows 发送到 Mac"
        let status: String
        if engine.isPaused {
            status = "已暂停"
        } else if engine.isSending || engine.isPlaying {
            status = "正在工作"
        } else {
            status = "当前未工作"
        }
        return "Auvol，\(direction)，\(status)"
    }
}
