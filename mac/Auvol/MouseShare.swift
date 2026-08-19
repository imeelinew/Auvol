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
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private var lastEventSequence: UInt32 = 0
    private var buttons: UInt8 = 0
    private var injectedButtons: UInt8 = 0
    private var cursorHidden = false
    private var lastPhysicalEvent = Date.distantPast
    private var injectLocation = CGPoint.zero
    private var launchFinished = false
    private var captureArmed = false
    private var armGlobalMonitor: Any?
    private var armLocalMonitor: Any?
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    static func restoreSystemPointerState() {
        // Session-wide: a previous force-quit can leave the pointer detached.
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        CGDisplayShowCursor(CGMainDisplayID())
    }

    init(peerIP: String) {
        Self.restoreSystemPointerState()
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
        channel.onEvent = { [weak self] event in
            self?.inject(event)
        }
        installHotkeyMonitors()
        refreshPermission()
        startPermissionTimer()
        launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleLaunch()
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MouseShareController.restoreSystemPointerState()
        }
        DispatchQueue.main.async { [weak self] in
            self?.handleLaunch()
        }
    }

    deinit {
        stop()
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        stopTap()
        removeArmMonitors()
        if let launchObserver {
            NotificationCenter.default.removeObserver(launchObserver)
            self.launchObserver = nil
        }
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
        DispatchQueue.main.async { [weak self] in
            self?.armCapture()
        }
        refreshInput()
    }

    func setCursorHost(_ host: CursorHost) {
        guard !applyingRemote, cursorHost != host else { return }
        cursorHost = host
        publish()
        DispatchQueue.main.async { [weak self] in
            self?.armCapture()
        }
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
        applyingRemote = true
        enabled = state.enabled
        cursorHost = state.host
        applyingRemote = false
        refreshInput()
    }

    private func handleLaunch() {
        guard !launchFinished else { return }
        launchFinished = true
        Self.restoreSystemPointerState()
        if let error = channel.start() {
            NSLog("Auvol mouse channel: %@", error)
        }
        installArmMonitor()
        refreshInput()
    }

    private func installArmMonitor() {
        guard !captureArmed else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        armGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            DispatchQueue.main.async { self?.armCapture() }
        }
        armLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            DispatchQueue.main.async { self?.armCapture() }
            return event
        }
    }

    private func removeArmMonitors() {
        if let armGlobalMonitor { NSEvent.removeMonitor(armGlobalMonitor) }
        if let armLocalMonitor { NSEvent.removeMonitor(armLocalMonitor) }
        armGlobalMonitor = nil
        armLocalMonitor = nil
    }

    private func armCapture() {
        guard !captureArmed else { return }
        captureArmed = true
        removeArmMonitors()
        refreshInput()
    }

    private func refreshInput() {
        refreshPermission()
        let shouldTap = launchFinished && captureArmed && enabled && cursorHost != .mac
        if shouldTap { startTap() } else { stopTap() }
        updateCursorVisibility()
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
            guard let self, self.enabled else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != !self.needsPermission {
                self.needsPermission = !trusted
                if trusted { self.refreshInput() }
            }
        }
    }

    private func startTap() {
        if tap != nil { return }
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
            tap: .cghidEventTap,
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
        CGEvent.tapEnable(tap: created, enable: true)
        injectLocation = CGEvent(source: nil)?.location ?? .zero
    }

    private func stopTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        tapSource = nil
        tap = nil
        restoreCursor()
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.magic {
            return Unmanaged.passUnretained(event)
        }
        guard enabled, captureArmed, cursorHost != .mac else {
            return Unmanaged.passUnretained(event)
        }
        lastPhysicalEvent = Date()
        updateButtons(type: type, event: event)
        updateCursorVisibility()
        let dx = Int16(clamping: event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Int16(clamping: event.getIntegerValueField(.mouseEventDeltaY))
        var wheel: Int16 = 0
        var hwheel: Int16 = 0
        if type == .scrollWheel {
            let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let pixel = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let hLine = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            let hPixel = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            wheel = Int16(clamping: line != 0 ? line * 120 : pixel)
            hwheel = Int16(clamping: hLine != 0 ? hLine * 120 : hPixel)
        }
        channel.sendEvent(buttons: buttons, dx: dx, dy: dy, wheel: wheel, hwheel: hwheel)
        return nil
    }

    private func updateButtons(type: CGEventType, event: CGEvent) {
        let other = UInt8(1 << min(4, 2 + max(0, event.getIntegerValueField(.mouseEventButtonNumber) - 2)))
        switch type {
        case .leftMouseDown, .leftMouseDragged: buttons |= 1
        case .leftMouseUp: buttons &= ~1
        case .rightMouseDown, .rightMouseDragged: buttons |= 2
        case .rightMouseUp: buttons &= ~2
        case .otherMouseDown, .otherMouseDragged:
            if event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
                buttons |= 4
            } else {
                buttons |= other
            }
        case .otherMouseUp:
            if event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
                buttons &= ~4
            } else {
                buttons &= ~other
            }
        default:
            break
        }
    }

    private func inject(_ event: MouseWireEvent) {
        guard enabled, cursorHost == .mac else { return }
        if lastEventSequence != 0 {
            let delta = Int32(bitPattern: event.sequence &- lastEventSequence)
            if delta <= 0 { return }
        }
        lastEventSequence = event.sequence
        let source = CGEventSource(stateID: .privateState)
        source?.userData = Self.magic
        injectLocation.x += CGFloat(event.dx)
        injectLocation.y += CGFloat(event.dy)
        injectLocation = clamp(injectLocation)
        if event.dx != 0 || event.dy != 0 {
            postMouse(.mouseMoved, at: injectLocation, source: source,
                      dx: event.dx, dy: event.dy, button: .left)
            if injectedButtons & 1 != 0 {
                postMouse(.leftMouseDragged, at: injectLocation, source: source,
                          dx: event.dx, dy: event.dy, button: .left)
            } else if injectedButtons & 2 != 0 {
                postMouse(.rightMouseDragged, at: injectLocation, source: source,
                          dx: event.dx, dy: event.dy, button: .right)
            }
        }
        applyInjectedButtons(event.buttons, at: injectLocation, source: source)
        if event.wheel != 0 || event.hwheel != 0 {
            let vertical = Int32(event.wheel / 120)
            let horizontal = Int32(event.hwheel / 120)
            let wheel1 = vertical == 0 && event.wheel != 0 ? Int32(event.wheel.signum()) : vertical
            let wheel2 = horizontal == 0 && event.hwheel != 0 ? Int32(event.hwheel.signum()) : horizontal
            if let scroll = CGEvent(scrollWheelEvent2Source: source, units: .line,
                                    wheelCount: 2, wheel1: wheel1, wheel2: wheel2, wheel3: 0) {
                scroll.setIntegerValueField(.eventSourceUserData, value: Self.magic)
                scroll.post(tap: .cghidEventTap)
            }
        }
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
        injectedButtons = next
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint,
                           source: CGEventSource?, dx: Int16, dy: Int16,
                           button: CGMouseButton) {
        guard let mouse = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        mouse.setIntegerValueField(.eventSourceUserData, value: Self.magic)
        mouse.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        mouse.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        mouse.post(tap: .cghidEventTap)
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        var bounds = CGRect.null
        for screen in NSScreen.screens {
            bounds = bounds.union(screen.frame)
        }
        if bounds.isNull { return point }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }

    private func updateCursorVisibility() {
        let hide = enabled && captureArmed && cursorHost != .mac
            && Date().timeIntervalSince(lastPhysicalEvent) < 0.8
        if hide, !cursorHidden {
            CGDisplayHideCursor(CGMainDisplayID())
            cursorHidden = true
        } else if !hide, cursorHidden {
            restoreCursor()
        }
    }

    private func restoreCursor() {
        Self.restoreSystemPointerState()
        cursorHidden = false
    }

    private func installHotkeyMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleKey(event) { return nil }
            return event
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
