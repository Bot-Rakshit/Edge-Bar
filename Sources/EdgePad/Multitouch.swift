import AppKit
import IOKit

// Raw trackpad access through Apple's private MultitouchSupport framework, loaded at runtime.

typealias MTDeviceRef = UnsafeMutableRawPointer
typealias MTContactCallback = @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

enum MTSupport {
    static let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)

    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static let createList = sym("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFMutableArray>?).self)
    static let registerCallback = sym("MTRegisterContactFrameCallback", (@convention(c) (MTDeviceRef, MTContactCallback) -> Void).self)
    static let unregisterCallback = sym("MTUnregisterContactFrameCallback", (@convention(c) (MTDeviceRef, MTContactCallback) -> Void).self)
    static let start = sym("MTDeviceStart", (@convention(c) (MTDeviceRef, Int32) -> Int32).self)
    static let stop = sym("MTDeviceStop", (@convention(c) (MTDeviceRef) -> Int32).self)
    static let isBuiltIn = sym("MTDeviceIsBuiltIn", (@convention(c) (MTDeviceRef) -> Bool).self)
    static let familyID = sym("MTDeviceGetFamilyID", (@convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>) -> Int32).self)
    static let deviceID = sym("MTDeviceGetDeviceID", (@convention(c) (MTDeviceRef, UnsafeMutablePointer<UInt64>) -> Int32).self)

    static let actuatorCreate = sym("MTActuatorCreateFromDeviceID", (@convention(c) (UInt64) -> Unmanaged<CFTypeRef>?).self)
    static let actuatorOpen = sym("MTActuatorOpen", (@convention(c) (CFTypeRef) -> Int32).self)
    static let actuatorActuate = sym("MTActuatorActuate", (@convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32).self)

    // Layout of one finger record (96 bytes).
    static let fingerStride = 96
    static let offsetIdentifier = 16
    static let offsetState = 20
    static let offsetX = 32
    static let offsetY = 36
    static let touchingStates: Set<Int32> = [3, 4] // makeTouch, touching

    /// Magic Mouse family IDs. Everything else is treated as a trackpad.
    static let mouseFamilies: Set<Int32> = [112, 113]
}

struct MTDevice {
    let ref: MTDeviceRef
    let id: UInt64
    let family: Int32
    let builtIn: Bool
    let kind: DeviceKind

    var label: String {
        switch kind {
        case .mouse: return "Magic Mouse"
        case .trackpad: return builtIn ? "Built-in Trackpad" : "Magic Trackpad"
        }
    }
}

private let contactCallback: MTContactCallback = { device, fingers, count, _, _ in
    MultitouchManager.shared.receive(device: device, fingers: fingers, count: Int(count))
    return 0
}

final class MultitouchManager {
    static let shared = MultitouchManager()

    let queue = DispatchQueue(label: "com.rakshit.edgepad.touch", qos: .userInteractive)
    let performer = ActionPerformer()

    private let lock = NSLock()
    private var list: CFMutableArray?
    private var devices: [MTDevice] = []
    private var byRef: [MTDeviceRef: MTDevice] = [:]

    // Confined to `queue`.
    private var engines: [UInt64: GestureEngine] = [:]
    private var lastFrame: [UInt64: Double] = [:]
    private var idleCheckPending: Set<UInt64> = []
    private var config = EngineConfig()
    private var lastLivePublish = 0.0
    private var lastLiveWasEmpty = true

    private(set) var includeMagicMouse = false
    /// Called on the touch queue with every frame, throttled. Used by the setup guide visualizer.
    var liveTouches: ((DeviceKind, [Touch]) -> Void)?

    var activeDevices: [MTDevice] {
        lock.lock(); defer { lock.unlock() }
        return devices
    }

    func apply(_ config: EngineConfig, magicMouse: Bool) {
        queue.async { self.config = config }
        if magicMouse != includeMagicMouse {
            includeMagicMouse = magicMouse
            restart()
        }
    }

    func start() {
        guard let createList = MTSupport.createList, let register = MTSupport.registerCallback,
              let startDevice = MTSupport.start else {
            Log.write("MultitouchSupport is unavailable")
            return
        }
        guard let array = createList()?.takeRetainedValue() else {
            Log.write("No multitouch devices found")
            return
        }
        var found: [MTDevice] = []
        for i in 0..<CFArrayGetCount(array) {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            let ref = UnsafeMutableRawPointer(mutating: raw)
            var family: Int32 = 0
            _ = MTSupport.familyID?(ref, &family)
            var id: UInt64 = 0
            _ = MTSupport.deviceID?(ref, &id)
            let builtIn = MTSupport.isBuiltIn?(ref) ?? false
            let kind: DeviceKind = MTSupport.mouseFamilies.contains(family) ? .mouse : .trackpad
            if kind == .mouse && !includeMagicMouse { continue }
            found.append(MTDevice(ref: ref, id: id, family: family, builtIn: builtIn, kind: kind))
        }
        lock.lock()
        list = array
        devices = found
        byRef = Dictionary(uniqueKeysWithValues: found.map { ($0.ref, $0) })
        lock.unlock()
        for d in found {
            register(d.ref, contactCallback)
            _ = startDevice(d.ref, 0)
            performer.haptics.prepare(deviceID: d.id)
        }
        Log.write("Listening to \(found.count) device(s): " + found.map { "\($0.label) family=\($0.family)" }.joined(separator: ", "))
    }

    func stop() {
        lock.lock()
        let old = devices
        devices = []
        byRef = [:]
        list = nil
        lock.unlock()
        for d in old {
            MTSupport.unregisterCallback?(d.ref, contactCallback)
            _ = MTSupport.stop?(d.ref)
        }
        queue.async {
            for engine in self.engines.values where engine.isSliding {
                self.performer.perform(engine.timeout(time: ProcessInfo.processInfo.systemUptime), device: nil, config: self.config)
            }
            self.engines = [:]
        }
    }

    func restart() {
        stop()
        start()
    }

    // MARK: Frames

    fileprivate func receive(device: MTDeviceRef?, fingers: UnsafeMutableRawPointer?, count: Int) {
        guard let device else { return }
        lock.lock()
        let dev = byRef[device]
        lock.unlock()
        guard let dev else { return }

        var touches: [Touch] = []
        if let fingers, count > 0 {
            for i in 0..<count {
                let base = fingers + i * MTSupport.fingerStride
                let state = base.load(fromByteOffset: MTSupport.offsetState, as: Int32.self)
                guard MTSupport.touchingStates.contains(state) else { continue }
                let id = base.load(fromByteOffset: MTSupport.offsetIdentifier, as: Int32.self)
                let x = base.load(fromByteOffset: MTSupport.offsetX, as: Float.self)
                let y = base.load(fromByteOffset: MTSupport.offsetY, as: Float.self)
                touches.append(Touch(id: Int(id), x: Double(x), y: Double(y)))
            }
        }
        let modifiers = Modifiers.current()
        let now = ProcessInfo.processInfo.systemUptime
        queue.async { self.handle(dev, touches, modifiers, now) }
    }

    private func handle(_ dev: MTDevice, _ touches: [Touch], _ modifiers: Modifiers, _ now: Double) {
        let engine: GestureEngine
        if let existing = engines[dev.id] {
            engine = existing
        } else {
            engine = GestureEngine()
            engines[dev.id] = engine
        }
        engine.config = config
        let wasIdle = engine.isIdle
        let actions = engine.process(touches, time: now, device: dev.kind, modifiers: modifiers)
        if wasIdle, let t = touches.first {
            Log.debug(String(format: "touch down x=%.2f y=%.2f fingers=%d", t.x, t.y, touches.count))
        }
        if let note = engine.note {
            Log.debug(note)
            engine.note = nil
        }
        if !actions.isEmpty { performer.perform(actions, device: dev, config: config) }
        lastFrame[dev.id] = now
        if !engine.isIdle { scheduleIdleCheck(dev) }

        if let liveTouches {
            let empty = touches.isEmpty
            if now - lastLivePublish > 1.0 / 40 || empty != lastLiveWasEmpty {
                lastLivePublish = now
                lastLiveWasEmpty = empty
                liveTouches(dev.kind, touches)
            }
        }
    }

    private func scheduleIdleCheck(_ dev: MTDevice) {
        guard !idleCheckPending.contains(dev.id) else { return }
        idleCheckPending.insert(dev.id)
        queue.asyncAfter(deadline: .now() + 0.2) { [self] in
            idleCheckPending.remove(dev.id)
            guard let engine = engines[dev.id], !engine.isIdle else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - (lastFrame[dev.id] ?? 0) >= 0.18 {
                let actions = engine.timeout(time: now)
                if let note = engine.note {
                    Log.debug(note)
                    engine.note = nil
                }
                if !actions.isEmpty { performer.perform(actions, device: dev, config: config) }
                liveTouches?(dev.kind, [])
            } else {
                scheduleIdleCheck(dev)
            }
        }
    }
}

extension Modifiers {
    static func current() -> Modifiers {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var m: Modifiers = []
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        if flags.contains(.maskSecondaryFn) { m.insert(.function) }
        return m
    }
}

/// Watches for trackpads being connected/disconnected so a reconnected Magic Trackpad is picked up.
final class DeviceWatcher {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            while case let obj = IOIteratorNext(iterator), obj != 0 { IOObjectRelease(obj) }
            guard let refcon else { return }
            Unmanaged<DeviceWatcher>.fromOpaque(refcon).takeUnretainedValue().changed()
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let match = IOServiceMatching("AppleMultitouchDevice")
            if IOServiceAddMatchingNotification(port, type, match, callback, context, &iterator) == KERN_SUCCESS {
                // Drain the initial set so the notification arms; we already started the existing devices.
                while case let obj = IOIteratorNext(iterator), obj != 0 { IOObjectRelease(obj) }
                iterators.append(iterator)
            }
        }
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
