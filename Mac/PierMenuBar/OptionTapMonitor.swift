import AppKit
import IOKit.hid
import ApplicationServices

/// ⌥ pressed twice, quickly and alone, in any app: "open Falar" (the detector is PierKit's `OptionDoubleTap`). Also
/// whether ⌥ is held right now (the toolbar shows its labels meanwhile).
///
/// Keyboard events of other apps reach a process only with the Input Monitoring permission (or Accessibility, which
/// implies it); without it the monitor still works while Pier itself is in front (a local monitor), and ⌃⌥Space (a
/// Carbon hot key, no permission) stays the way in from anywhere. Nothing here asks for the permission by itself:
/// `requestInputMonitoring` runs when the person turns the feature on in Ajustes.
@MainActor final class OptionTapMonitor {
    var onDoubleTap: (() -> Void)?
    var onOptionHeld: ((Bool) -> Void)?
    private var detector = OptionDoubleTap()
    private var global: [Any] = []
    private var local: Any?
    private var held = false
    private(set) var wantsGlobal = false

    /// Keyboard events of other apps may be read: Input Monitoring granted, or the app trusted for Accessibility.
    static var canListenGlobally: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted || AXIsProcessTrusted()
    }
    static var inputMonitoringGranted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS for Input Monitoring (the system dialog, once; later changes happen in System Settings).
    @discardableResult static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Starts (or restarts) the monitors; `global` only takes effect once the permission is there.
    func start(global wantGlobal: Bool) {
        stop()
        wantsGlobal = wantGlobal
        local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        guard wantGlobal, Self.canListenGlobally else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { global.append(g) }
    }

    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        local = nil
        for g in global { NSEvent.removeMonitor(g) }
        global = []
        if held { held = false; onOptionHeld?(false) }
    }

    var isGlobal: Bool { !global.isEmpty }

    private func handle(_ event: NSEvent) {
        let t = event.timestamp
        switch event.type {
        case .keyDown:
            detector.otherKey(at: t)
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let option = flags.contains(.option)
            let others = !flags.subtracting([.option, .capsLock]).isEmpty
            if option != held { held = option; onOptionHeld?(option) }
            if detector.modifiers(option: option, others: others, at: t) { onDoubleTap?() }
        default:
            break
        }
    }

    /// Tests and screenshots: the two taps, without a keyboard.
    func simulateDoubleTap() {
        let now = ProcessInfo.processInfo.systemUptime
        _ = detector.modifiers(option: true, others: false, at: now)
        _ = detector.modifiers(option: false, others: false, at: now + 0.08)
        _ = detector.modifiers(option: true, others: false, at: now + 0.2)
        if detector.modifiers(option: false, others: false, at: now + 0.28) { onDoubleTap?() }
    }
}
