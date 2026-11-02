import AppKit
import AudioToolbox
import CoreAudio

// Volume, brightness and media keys. Steps are sent as the same system key events the
// keyboard's F-keys produce, so macOS shows its own on-screen display.

enum MediaKey: Int32 {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case play = 16
    case next = 17
    case previous = 18
}

enum SystemControls {
    /// Posts a media key press. `quarter` adds ⇧⌥, which macOS turns into a quarter step.
    static func press(_ key: MediaKey, quarter: Bool = false) {
        let extra: UInt = quarter ? (NSEvent.ModifierFlags.shift.rawValue | NSEvent.ModifierFlags.option.rawValue) : 0
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: (down ? 0xa00 : 0xb00) | extra)
            let data1 = Int((key.rawValue << 16) | ((down ? 0xa : 0xb) << 8))
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static func adjust(_ control: Control, steps: Int, quarter: Bool) {
        let key: MediaKey
        switch control {
        case .volume: key = steps > 0 ? .soundUp : .soundDown
        case .brightness: key = steps > 0 ? .brightnessUp : .brightnessDown
        case .keyboard:
            KeyboardBacklight.adjust(by: Double(steps) * (quarter ? 1.0 / 64 : 1.0 / 16))
            return
        }
        for _ in 0..<abs(steps) { press(key, quarter: quarter) }
    }

    static func level(of control: Control) -> Double? {
        switch control {
        case .volume: return volume()
        case .brightness: return brightness()
        case .keyboard: return KeyboardBacklight.level()
        }
    }

    /// Posts an ordinary key combination, e.g. ⌃⌘Q.
    static func keyCombo(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    static func perform(_ action: CornerAction, shortcut: String?) {
        let missionControl = "/System/Applications/Mission Control.app"
        switch action {
        case .none: break
        case .mute: press(.mute)
        case .playPause: press(.play)
        case .missionControl: run(missionControl + "/Contents/MacOS/Mission Control", [])
        case .appWindows: run(missionControl + "/Contents/MacOS/Mission Control", ["2"])
        case .showDesktop: run(missionControl + "/Contents/MacOS/Mission Control", ["1"])
        case .lockScreen: keyCombo(12, [.maskCommand, .maskControl]) // ⌃⌘Q
        case .screenshot: keyCombo(23, [.maskCommand, .maskShift]) // ⇧⌘5
        case .spotlight: keyCombo(49, [.maskCommand]) // ⌘Space
        case .sleepDisplay: run("/usr/bin/pmset", ["displaysleepnow"])
        case .shortcut:
            guard let name = shortcut?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                Log.write("corner shortcut has no name set")
                return
            }
            run("/usr/bin/shortcuts", ["run", name])
        }
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run() } catch { Log.write("could not run \(path): \(error.localizedDescription)") }
    }

    // MARK: Volume (CoreAudio)

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    static func volume() -> Double? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = volumeAddress
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    static func setVolume(_ v: Double) {
        guard let device = defaultOutputDevice() else { return }
        var address = volumeAddress
        var value = Float32(min(max(v, 0), 1))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if v > 0, isMuted() { setMuted(false) }
    }

    static func isMuted() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = muteAddress
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = defaultOutputDevice() else { return }
        var address = muteAddress
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: Brightness (DisplayServices, private)

    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
        guard let h = displayServices, let p = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(p, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
    }()
    private static let setBrightnessFn: (@convention(c) (CGDirectDisplayID, Float) -> Int32)? = {
        guard let h = displayServices, let p = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(p, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
    }()

    static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func brightness() -> Double? {
        guard let display = builtInDisplay(), let getBrightness else { return nil }
        var value = Float(0)
        guard getBrightness(display, &value) == 0 else { return nil }
        return Double(value)
    }

    static func setBrightness(_ v: Double) {
        guard let display = builtInDisplay(), let setBrightnessFn else { return }
        _ = setBrightnessFn(display, Float(min(max(v, 0), 1)))
    }
}

// MARK: - Keyboard backlight (CoreBrightness, private)

enum KeyboardBacklight {
    private static let client: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    private static let keyboardID: UInt64 = {
        let sel = NSSelectorFromString("copyKeyboardBackLightIDs")
        guard let client, client.responds(to: sel),
              let ids = client.perform(sel)?.takeRetainedValue() as? [NSNumber],
              let first = ids.first else { return 1 }
        return first.uint64Value
    }()

    static var isAvailable: Bool { level() != nil }

    static func level() -> Double? {
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard let client, client.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt64) -> Float
        let fn = unsafeBitCast(client.method(for: sel), to: Fn.self)
        return Double(fn(client, sel, keyboardID))
    }

    static func set(_ value: Double) {
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let client, client.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        let fn = unsafeBitCast(client.method(for: sel), to: Fn.self)
        _ = fn(client, sel, Float(min(max(value, 0), 1)), keyboardID)
    }

    static func adjust(by delta: Double) {
        guard let current = level() else { return }
        set(current + delta)
    }
}

// MARK: - Haptics

/// Drives the Force Touch trackpad's actuator directly so strength can be chosen and it works
/// while another app is in front. Falls back to NSHapticFeedbackManager.
final class Haptics {
    private var actuators: [UInt64: CFTypeRef] = [:]
    private let lock = NSLock()

    func prepare(deviceID: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard actuators[deviceID] == nil, deviceID != 0,
              let create = MTSupport.actuatorCreate, let open = MTSupport.actuatorOpen,
              let actuator = create(deviceID)?.takeRetainedValue() else { return }
        if open(actuator) == 0 { actuators[deviceID] = actuator }
    }

    var hasActuator: Bool {
        lock.lock(); defer { lock.unlock() }
        return !actuators.isEmpty
    }

    private func actuate(_ id: Int32, deviceID: UInt64?) -> Bool {
        lock.lock()
        let actuator = deviceID.flatMap { actuators[$0] } ?? actuators.values.first
        lock.unlock()
        guard let actuator, let actuate = MTSupport.actuatorActuate else { return false }
        return actuate(actuator, id, 0, 0, 0) == 0
    }

    func play(_ kind: HapticKind, strength: HapticStrength, deviceID: UInt64?) {
        guard strength != .off else { return }
        let base: Int32
        switch strength {
        case .off: return
        case .light: base = 3
        case .medium: base = 4
        case .strong: base = 6
        }
        switch kind {
        case .tick, .begin:
            if !actuate(base, deviceID: deviceID) { fallback(.alignment) }
        case .swipe:
            if !actuate(min(base + 1, 6), deviceID: deviceID) { fallback(.levelChange) }
        case .detent:
            // A firmer bump than a tick, so 0%, 50% and 100% can be felt.
            if !actuate(6, deviceID: deviceID) { fallback(.generic) }
        case .strong:
            // Mute: a heavier double buzz you can tell apart without looking.
            if actuate(6, deviceID: deviceID) {
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.08) {
                    _ = self.actuate(6, deviceID: deviceID)
                }
            } else {
                fallback(.generic)
            }
        }
    }

    /// Named patterns for haptic pings (`EdgePad --buzz <name>`).
    static let patterns: [String: [(delay: Double, id: Int32)]] = [
        "tap": [(0, 4)],
        "done": [(0, 4), (0.14, 6)],
        "attention": [(0, 6), (0.12, 6), (0.24, 6)],
        "error": [(0, 6), (0.08, 6), (0.40, 6), (0.48, 6)],
    ]

    func playPattern(_ name: String) {
        let steps = Self.patterns[name] ?? Self.patterns["done"]!
        for step in steps {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + step.delay) {
                if !self.actuate(step.id, deviceID: nil) { self.fallback(.generic) }
            }
        }
    }

    private func fallback(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }
}

// MARK: - Cursor freeze

/// Keeps the pointer hidden and still while a slide is in progress.
final class CursorFreeze {
    static let shared = CursorFreeze()

    private let lock = NSLock()
    private var _active = false
    private var point: CGPoint?
    private var tap: CFMachPort?
    private var hidden = false // main thread only

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return _active
    }

    func begin(at start: CGPoint?) {
        lock.lock()
        if _active { lock.unlock(); return }
        _active = true
        point = start ?? CGEvent(source: nil)?.location
        let p = point
        lock.unlock()

        if let p { CGWarpMouseCursorPosition(p) } // undo the drift from before the slide engaged
        CGAssociateMouseAndMouseCursorPosition(0)
        DispatchQueue.main.async {
            self.installTapIfNeeded()
            if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            self.hideCursor()
        }
    }

    func end() {
        lock.lock()
        if !_active { lock.unlock(); return }
        _active = false
        let p = point
        lock.unlock()

        if let p { CGWarpMouseCursorPosition(p) }
        CGAssociateMouseAndMouseCursorPosition(1)
        DispatchQueue.main.async {
            if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: false) }
            self.showCursor()
        }
    }

    /// Swallows pointer movement while frozen. Needs Accessibility access.
    func installTapIfNeeded() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if CursorFreeze.shared.isActive, let tap = CursorFreeze.shared.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            return CursorFreeze.shared.isActive ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: nil) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
        self.tap = tap
    }

    private func hideCursor() {
        guard !hidden else { return }
        Self.allowBackgroundCursorControl()
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }

    private func showCursor() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }

    /// A background app can only hide the cursor after setting this connection property.
    private static let allowBackgroundCursorControl: () -> Void = {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let rtld = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let c = dlsym(rtld, "_CGSDefaultConnection"), let s = dlsym(rtld, "CGSSetConnectionProperty") else {
            return {}
        }
        let connection = unsafeBitCast(c, to: DefaultConnection.self)()
        let set = unsafeBitCast(s, to: SetProperty.self)
        var done = false
        return {
            guard !done else { return }
            done = true
            _ = set(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        }
    }()
}

// MARK: - Performer

extension Notification.Name {
    static let edgePadAction = Notification.Name("EdgePadAction")
}

final class ActionPerformer {
    let haptics = Haptics()
    private var cursorStart: CGPoint?
    /// Predicted level of the control being slid, for detents. The system applies key presses
    /// asynchronously, so reading the level back after every step would lag.
    private var level: Double?

    /// Runs on the touch queue.
    func perform(_ actions: [EngineAction], device: MTDevice?, config: EngineConfig) {
        for action in actions {
            switch action {
            case .touchStarted:
                cursorStart = CGEvent(source: nil)?.location
            case .beginSlide(let control):
                if config.freezeCursor { CursorFreeze.shared.begin(at: cursorStart) }
                level = SystemControls.level(of: control)
                Log.write("slide \(control.rawValue) began")
            case .adjust(let control, let steps, let quarter):
                SystemControls.adjust(control, steps: steps, quarter: quarter)
                Log.debug("\(control.rawValue) \(steps > 0 ? "+" : "")\(steps)\(quarter ? " (¼)" : "")")
                if config.detents, let before = level {
                    let after = min(max(before + Double(steps) * (quarter ? 1.0 / 64 : 1.0 / 16), 0), 1)
                    level = after
                    if Self.crossesDetent(from: before, to: after) {
                        haptics.play(.detent, strength: config.hapticStrength, deviceID: device?.id)
                    }
                }
            case .endSlide:
                CursorFreeze.shared.end()
                level = nil
            case .corner(let corner):
                ClickGuard.shared.consume()
                let cornerAction = config.cornerActions[corner] ?? .none
                SystemControls.perform(cornerAction, shortcut: config.cornerShortcuts[corner])
                Log.write("\(corner.rawValue) corner: \(cornerAction.label)")
            case .clickGuard(let event):
                switch event {
                case .arm: ClickGuard.shared.arm()
                case .cancel: ClickGuard.shared.cancel()
                case .release: ClickGuard.shared.release()
                }
            case .playPause:
                SystemControls.press(.play)
                Log.write("play/pause")
            case .nextTrack:
                SystemControls.press(.next)
                Log.write("next track")
            case .previousTrack:
                SystemControls.press(.previous)
                Log.write("previous track")
            case .haptic(let kind):
                haptics.play(kind, strength: config.hapticStrength, deviceID: device?.id)
            }
        }
        let names = actions.compactMap { a -> String? in
            switch a {
            case .adjust(let c, _, _): return c.rawValue
            case .corner(let c): return config.cornerActions[c] == .mute ? "mute" : "corner"
            case .playPause: return "play"
            case .nextTrack, .previousTrack: return "skip"
            default: return nil
            }
        }
        if !names.isEmpty {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .edgePadAction, object: nil, userInfo: ["names": names])
            }
        }
    }
}

extension ActionPerformer {
    /// True when moving from `a` to `b` lands on or passes 0%, 50% or 100%.
    static func crossesDetent(from a: Double, to b: Double) -> Bool {
        guard a != b else { return false }
        let eps = 1e-6
        if b <= eps && a > eps { return true }
        if b >= 1 - eps && a < 1 - eps { return true }
        let mid = 0.5
        return (a < mid - eps && b >= mid - eps) || (a > mid + eps && b <= mid + eps)
    }
}

// MARK: - Click guard

/// Holds back clicks that tap-to-click produces from a corner tap, so a double-tap that mutes
/// doesn't also double-click whatever is under the pointer. A lone tap's click is replayed
/// once it's clear no second tap is coming.
final class ClickGuard {
    static let shared = ClickGuard()
    private static let marker: Int64 = 0x4550_4144 // "EPAD", tags replayed events
    private static let window = 0.4

    private let lock = NSLock()
    private var armed = false
    private var holdUntil = 0.0
    private var dropUntil = 0.0
    private var buffer: [CGEvent] = []
    private var generation = 0
    fileprivate var tap: CFMachPort?

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func arm() {
        lock.lock(); defer { lock.unlock() }
        armed = true
        generation += 1
    }

    func cancel() {
        lock.lock()
        armed = false
        holdUntil = 0
        generation += 1
        let held = buffer
        buffer = []
        lock.unlock()
        replay(held)
    }

    func release() {
        lock.lock()
        armed = false
        holdUntil = now + Self.window
        generation += 1
        let gen = generation
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.window + 0.02) { self.flush(ifGeneration: gen) }
    }

    /// The corner gesture fired: drop the held clicks and any that are still on their way.
    func consume() {
        lock.lock(); defer { lock.unlock() }
        buffer = []
        dropUntil = now + Self.window
    }

    private func flush(ifGeneration gen: Int) {
        lock.lock()
        guard gen == generation, !armed else { lock.unlock(); return }
        let held = buffer
        buffer = []
        lock.unlock()
        replay(held)
    }

    /// Returns true when the event should be swallowed.
    fileprivate func intercept(_ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return false }
        lock.lock(); defer { lock.unlock() }
        let t = now
        if t < dropUntil { return true }
        if armed || t < holdUntil, let copy = event.copy() {
            buffer.append(copy)
            return true
        }
        return false
    }

    private func replay(_ events: [CGEvent]) {
        guard !events.isEmpty else { return }
        DispatchQueue.main.async {
            for e in events {
                e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    func installTapIfNeeded() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = ClickGuard.shared.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return ClickGuard.shared.intercept(event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: nil) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
    }
}

// MARK: - Log

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/EdgePad.log")
    private static let queue = DispatchQueue(label: "com.rakshit.edgepad.log", qos: .utility)
    static var verbose = UserDefaults.standard.bool(forKey: "verboseLog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func trimIfLarge() {
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func debug(_ message: String) {
        if verbose { write(message) }
    }

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
