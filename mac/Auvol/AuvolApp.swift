import AppKit
import SwiftUI

@main
struct AuvolApp: App {
    @StateObject private var engine: ReceiverEngine
    @StateObject private var updateService = UpdateService()

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
                .environmentObject(updateService)
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
        let color = TransportTone(engine).nsColor
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: "wave.3.forward",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return NSImage(size: NSSize(width: 14, height: 14))
        }

        // Keep the natural glyph, then compress height slightly for menu-bar balance.
        let verticalScale: CGFloat = 0.88
        let drawSize = NSSize(width: symbol.size.width,
                              height: symbol.size.height * verticalScale)
        let image = NSImage(size: drawSize, flipped: false) { bounds in
            symbol.draw(in: bounds,
                        from: NSRect(origin: .zero, size: symbol.size),
                        operation: .sourceOver,
                        fraction: 1,
                        respectFlipped: true,
                        hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
            return true
        }
        image.isTemplate = false
        return image
    }

    private var accessibilityLabel: String {
        let direction = engine.role == .send ? "Windows" : "Mac"
        return "Auvol，\(direction)，\(TransportTone(engine).label)"
    }
}
