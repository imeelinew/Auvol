import ApplicationServices
import AppKit
import Foundation

struct MouseHotkey: Equatable {
    var keyCode: UInt16
    var control: Bool
    var option: Bool
    var shift: Bool
    var command: Bool

    static let `default` = MouseHotkey(keyCode: 46, control: true, option: true,
                                       shift: false, command: false)

    var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        text += Self.name(for: keyCode)
        return text
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if control { flags.insert(.control) }
        if option { flags.insert(.option) }
        if shift { flags.insert(.shift) }
        if command { flags.insert(.command) }
        return flags
    }

    static func name(for keyCode: UInt16) -> String {
        let letters: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 50: "`"
        ]
        let extras: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        return letters[keyCode] ?? extras[keyCode] ?? "Key\(keyCode)"
    }
}

final class MouseShareController: ObservableObject {
    private static let magic: Int64 = 0x4155_564C
    private static let hotkeyKeyCodeKey = "ali1HotkeyKeyCode"
    private static let hotkeyFlagsKey = "ali1HotkeyFlags"
    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    @Published private(set) var enabled = false
    @Published private(set) var cursorHost: CursorHost = .windows
    @Published private(set) var hotkey = MouseHotkey.default
    @Published private(set) var capturingHotkey = false
    @Published private(set) var needsPermission = false

    private let channel: MouseControlChannel
    private var applyingRemote = false
    private var peerAvailable = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapRecoveryToken: UInt64 = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private var terminateObserver: NSObjectProtocol?
    private var buttons: UInt8 = 0
    private var injectedButtons: UInt8 = 0
    private var injectLocation = CGPoint.zero
    private var hasInjectLocation = false
    private var cursorHidden = false
    private var stopped = false

    init(peerIP: String) {
        let defaults = UserDefaults.standard
        let savedCode = defaults.object(forKey: Self.hotkeyKeyCodeKey) as? Int
        let savedFlags = defaults.integer(forKey: Self.hotkeyFlagsKey)
        if let savedCode {
            hotkey = MouseHotkey(keyCode: UInt16(savedCode),
                                 control: (savedFlags & 1) != 0,
                                 option: (savedFlags & 2) != 0,
                                 shift: (savedFlags & 4) != 0,
                                 command: (savedFlags & 8) != 0)
        }

        channel = MouseControlChannel(
            peerIP: peerIP,
            initial: MouseShareState(enabled: false, host: .windows)
        )
        let initial = channel.current
        enabled = initial.enabled
        cursorHost = initial.host

        channel.onState = { [weak self] state in
            DispatchQueue.main.async { self?.applyRemote(state) }
        }
        channel.onPeerAvailability = { [weak self] available in
            DispatchQueue.main.async { self?.applyPeerAvailability(available) }
        }
        channel.onEvent = { [weak self] event in
            self?.inject(event)
        }
        channel.onInputReset = { [weak self] in
            self?.resetInjectedInput()
        }

        installHotkeyMonitors()
        refreshPermission()
        startPermissionTimer()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
        if let error = channel.start() {
            NSLog("Auvol mouse channel: %@", error)
        }
    }

    deinit {
        stop()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        permissionTimer?.invalidate()
        permissionTimer = nil
        tapRecoveryToken &+= 1
        stopTap()
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        channel.stop()
        restoreCursor()
    }

    func setPeerIP(_ value: String) { channel.setPeerIP(value) }
    func setLocalIP(_ value: String?) { channel.setLocalIP(value) }

    func setEnabled(_ value: Bool) {
        guard !applyingRemote, enabled != value else { return }
        if value { promptPermissionIfNeeded() }
        enabled = value
        publish()
        refreshInput()
    }

    func setCursorHost(_ host: CursorHost) {
        guard !applyingRemote, cursorHost != host else { return }
        cursorHost = host
        publish()
        refreshInput()
    }

    func beginHotkeyCapture() { capturingHotkey = true }
    func cancelHotkeyCapture() { capturingHotkey = false }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url { NSWorkspace.shared.open(url) }
        promptPermissionIfNeeded()
    }

    private func publish() {
        channel.publish(MouseShareState(enabled: enabled, host: cursorHost))
    }

    private func applyRemote(_ state: MouseShareState) {
        guard !stopped else { return }
        applyingRemote = true
        enabled = state.enabled
        cursorHost = state.host
        applyingRemote = false
        refreshInput()
    }

    private func applyPeerAvailability(_ available: Bool) {
        guard !stopped, peerAvailable != available else { return }
        peerAvailable = available
        refreshInput()
    }

    private func refreshInput() {
        refreshPermission()
        let shouldCapture = enabled && cursorHost == .windows && peerAvailable &&
            channel.peerLeaseIsValid
        if shouldCapture {
            startTap()
        } else {
            stopTap()
        }
    }

    private func refreshPermission() {
        needsPermission = !AXIsProcessTrusted()
    }

    private func promptPermissionIfNeeded() {
        if AXIsProcessTrusted() { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        refreshPermission()
    }

    private func startPermissionTimer() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, enabled else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != !needsPermission {
                needsPermission = !trusted
                refreshInput()
            }
        }
    }

    private func startTap() {
        guard tap == nil,
              !stopped,
              enabled,
              cursorHost == .windows,
              peerAvailable,
              channel.peerLeaseIsValid else { return }
        refreshPermission()
        guard !needsPermission else { return }

        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel
        ]
        var mask: CGEventMask = 0
        for type in types { mask |= 1 << type.rawValue }
        mask |= 1 << CGEventType.tapDisabledByTimeout.rawValue
        mask |= 1 << CGEventType.tapDisabledByUserInput.rawValue

        let unmanaged = Unmanaged.passUnretained(self)
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let share = Unmanaged<MouseShareController>.fromOpaque(refcon)
                    .takeUnretainedValue()
                return share.handleTap(type: type, event: event)
            },
            userInfo: unmanaged.toOpaque()
        ) else {
            needsPermission = true
            return
        }

        tap = created
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        if let tapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        buttons = 0
        CGEvent.tapEnable(tap: created, enable: true)
    }

    private func stopTap() {
        tapRecoveryToken &+= 1
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        tapSource = nil
        tap = nil
        buttons = 0
        restoreCursor()
    }

    private func recoverTapAfterDisable() {
        stopTap()
        let token = tapRecoveryToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self,
                  tapRecoveryToken == token,
                  enabled,
                  cursorHost == .windows,
                  peerAvailable,
                  channel.peerLeaseIsValid else { return }
            startTap()
        }
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in self?.recoverTapAfterDisable() }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.magic {
            return Unmanaged.passUnretained(event)
        }
        let leaseIsValid = channel.peerLeaseIsValid
        guard tap != nil, enabled, cursorHost == .windows, peerAvailable,
              leaseIsValid else {
            if !leaseIsValid {
                restoreCursor()
                DispatchQueue.main.async { [weak self] in self?.refreshInput() }
            }
            return Unmanaged.passUnretained(event)
        }

        updateButtons(type: type, event: event)
        hideCursor()
        let dx = Int16(clamping: event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Int16(clamping: event.getIntegerValueField(.mouseEventDeltaY))
        var wheel: Int16 = 0
        var hwheel: Int16 = 0
        if type == .scrollWheel {
            let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let pixel = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let horizontalLine = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            let horizontalPixel = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            wheel = Int16(clamping: line != 0 ? line * 120 : pixel)
            hwheel = Int16(clamping: horizontalLine != 0 ? horizontalLine * 120 : horizontalPixel)
        }
        channel.sendEvent(buttons: buttons, dx: dx, dy: dy,
                          wheel: wheel, hwheel: hwheel)
        return nil
    }

    private func updateButtons(type: CGEventType, event: CGEvent) {
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        let otherBit = UInt8(1 << min(4, 2 + max(0, number - 2)))
        switch type {
        case .leftMouseDown, .leftMouseDragged:
            buttons |= 1
        case .leftMouseUp:
            buttons &= ~1
        case .rightMouseDown, .rightMouseDragged:
            buttons |= 2
        case .rightMouseUp:
            buttons &= ~2
        case .otherMouseDown, .otherMouseDragged:
            buttons |= number == 2 ? 4 : otherBit
        case .otherMouseUp:
            buttons &= ~(number == 2 ? 4 : otherBit)
        default:
            break
        }
    }

    /// Runs on the mouse channel queue, never on the Quartz event-tap callback.
    private func inject(_ event: MouseWireEvent) {
        if !hasInjectLocation {
            injectLocation = CGEvent(source: nil)?.location ?? .zero
            hasInjectLocation = true
        }
        injectLocation.x += CGFloat(event.dx)
        injectLocation.y += CGFloat(event.dy)
        injectLocation = clamp(injectLocation)

        let source = CGEventSource(stateID: .privateState)
        source?.userData = Self.magic
        if event.dx != 0 || event.dy != 0 {
            let movement: (CGEventType, CGMouseButton)
            if injectedButtons & 1 != 0 {
                movement = (.leftMouseDragged, .left)
            } else if injectedButtons & 2 != 0 {
                movement = (.rightMouseDragged, .right)
            } else if injectedButtons & 4 != 0 {
                movement = (.otherMouseDragged, .center)
            } else if injectedButtons & 8 != 0 {
                movement = (.otherMouseDragged, CGMouseButton(rawValue: 3)!)
            } else if injectedButtons & 16 != 0 {
                movement = (.otherMouseDragged, CGMouseButton(rawValue: 4)!)
            } else {
                movement = (.mouseMoved, .left)
            }
            postMouse(movement.0, at: injectLocation, source: source,
                      dx: event.dx, dy: event.dy, button: movement.1)
        }
        applyInjectedButtons(event.buttons, at: injectLocation, source: source)

        if event.wheel != 0 || event.hwheel != 0 {
            let vertical = Int32(event.wheel / 120)
            let horizontal = Int32(event.hwheel / 120)
            let wheel1 = vertical == 0 && event.wheel != 0
                ? Int32(event.wheel.signum()) : vertical
            let wheel2 = horizontal == 0 && event.hwheel != 0
                ? Int32(event.hwheel.signum()) : horizontal
            if let scroll = CGEvent(scrollWheelEvent2Source: source, units: .line,
                                    wheelCount: 2, wheel1: wheel1,
                                    wheel2: wheel2, wheel3: 0) {
                scroll.setIntegerValueField(.eventSourceUserData, value: Self.magic)
                scroll.post(tap: .cghidEventTap)
            }
        }
    }

    /// Runs on the same serial channel queue as `inject`.
    private func resetInjectedInput() {
        guard injectedButtons != 0 else {
            hasInjectLocation = false
            return
        }
        if !hasInjectLocation {
            injectLocation = CGEvent(source: nil)?.location ?? .zero
            hasInjectLocation = true
        }
        let source = CGEventSource(stateID: .privateState)
        source?.userData = Self.magic
        applyInjectedButtons(0, at: injectLocation, source: source)
        hasInjectLocation = false
    }

    private func applyInjectedButtons(_ next: UInt8, at point: CGPoint,
                                      source: CGEventSource?) {
        let changed = injectedButtons ^ next
        if changed & 1 != 0 {
            postMouse(next & 1 != 0 ? .leftMouseDown : .leftMouseUp,
                      at: point, source: source, dx: 0, dy: 0, button: .left)
        }
        if changed & 2 != 0 {
            postMouse(next & 2 != 0 ? .rightMouseDown : .rightMouseUp,
                      at: point, source: source, dx: 0, dy: 0, button: .right)
        }
        if changed & 4 != 0 {
            postMouse(next & 4 != 0 ? .otherMouseDown : .otherMouseUp,
                      at: point, source: source, dx: 0, dy: 0, button: .center)
        }
        if changed & 8 != 0 {
            postMouse(next & 8 != 0 ? .otherMouseDown : .otherMouseUp,
                      at: point, source: source, dx: 0, dy: 0,
                      button: CGMouseButton(rawValue: 3)!)
        }
        if changed & 16 != 0 {
            postMouse(next & 16 != 0 ? .otherMouseDown : .otherMouseUp,
                      at: point, source: source, dx: 0, dy: 0,
                      button: CGMouseButton(rawValue: 4)!)
        }
        injectedButtons = next & 0x1f
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint,
                           source: CGEventSource?, dx: Int16, dy: Int16,
                           button: CGMouseButton) {
        guard let mouse = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point,
                                  mouseButton: button) else { return }
        mouse.setIntegerValueField(.eventSourceUserData, value: Self.magic)
        mouse.setIntegerValueField(.mouseEventButtonNumber,
                                   value: Int64(button.rawValue))
        mouse.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        mouse.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        mouse.post(tap: .cghidEventTap)
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return point
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let result = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(count, buffer.baseAddress, &count)
        }
        guard result == .success else { return point }
        var bounds = CGRect.null
        for display in displays.prefix(Int(count)) {
            bounds = bounds.union(CGDisplayBounds(display))
        }
        guard !bounds.isNull, !bounds.isEmpty else { return point }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }

    private func hideCursor() {
        guard !cursorHidden else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        cursorHidden = true
    }

    private func restoreCursor() {
        guard cursorHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        cursorHidden = false
    }

    private func installHotkeyMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            DispatchQueue.main.async { [weak self] in
                _ = self?.handleKey(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            return handleKey(event) ? nil : event
        }
    }

    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        if capturingHotkey {
            if Self.modifierKeyCodes.contains(event.keyCode) { return true }
            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
            guard !flags.isEmpty else { return true }
            hotkey = MouseHotkey(keyCode: event.keyCode,
                                 control: flags.contains(.control),
                                 option: flags.contains(.option),
                                 shift: flags.contains(.shift),
                                 command: flags.contains(.command))
            persistHotkey()
            capturingHotkey = false
            return true
        }
        guard enabled, matchesHotkey(event) else { return false }
        setCursorHost(cursorHost == .mac ? .windows : .mac)
        return true
    }

    private func matchesHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        return event.keyCode == hotkey.keyCode && flags == hotkey.modifierFlags
    }

    private func persistHotkey() {
        var flags = 0
        if hotkey.control { flags |= 1 }
        if hotkey.option { flags |= 2 }
        if hotkey.shift { flags |= 4 }
        if hotkey.command { flags |= 8 }
        UserDefaults.standard.set(Int(hotkey.keyCode), forKey: Self.hotkeyKeyCodeKey)
        UserDefaults.standard.set(flags, forKey: Self.hotkeyFlagsKey)
    }
}
