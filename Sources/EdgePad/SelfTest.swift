import AppKit
import SwiftUI

// `EdgePad --selftest`: drives the gesture engine with synthetic touch frames.
enum SelfTest {
    private final class Driver {
        let engine = GestureEngine()
        var time = 100.0
        var actions: [EngineAction] = []

        init(_ configure: (inout EngineConfig) -> Void = { _ in }) {
            engine.config.acceleration = false
            configure(&engine.config)
        }

        func frame(_ touches: [Touch], dt: Double = 0.01, device: DeviceKind = .trackpad, mods: Modifiers = []) {
            time += dt
            actions += engine.process(touches, time: time, device: device, modifiers: mods)
        }

        /// One finger from (x, y0) to (x1, y1) over `frames` frames, then lifted.
        func drag(x: Double, y0: Double, x1: Double? = nil, y1: Double, frames: Int = 40, id: Int = 1,
                  device: DeviceKind = .trackpad, mods: Modifiers = [], dt: Double = 0.01, lift: Bool = true) {
            let xEnd = x1 ?? x
            for i in 0...frames {
                let f = Double(i) / Double(frames)
                frame([Touch(id: id, x: x + (xEnd - x) * f, y: y0 + (y1 - y0) * f)], dt: dt, device: device, mods: mods)
            }
            if lift { frame([], device: device); flushLater() }
        }

        func tap(x: Double, y: Double, id: Int = 1, gap: Double = 0.15, device: DeviceKind = .trackpad) {
            frame([Touch(id: id, x: x, y: y)], dt: gap, device: device)
            frame([Touch(id: id, x: x, y: y)], dt: 0.04, device: device)
            frame([], dt: 0.04, device: device)
        }

        func flushLater() {
            time += 0.3
            actions += engine.timeout(time: time)
        }

        func steps(_ control: Control) -> Int {
            actions.reduce(0) { sum, a in
                if case .adjust(let c, let s, _) = a, c == control { return sum + s }
                return sum
            }
        }

        var quarterFlags: Set<Bool> {
            Set(actions.compactMap { if case .adjust(_, _, let q) = $0 { return q }; return nil })
        }

        func count(_ action: EngineAction) -> Int { actions.filter { $0 == action }.count }
        var meaningful: [EngineAction] {
            actions.filter {
                if case .haptic = $0 { return false }
                if case .clickGuard = $0 { return false }
                return $0 != .touchStarted
            }
        }
    }

    static func run() -> Bool {
        var results: [(String, Bool, String)] = []
        func check(_ name: String, _ ok: Bool, _ info: @autoclosure () -> String = "") {
            results.append((name, ok, ok ? "" : info()))
        }

        // Volume on the right edge: 0.30 -> 0.50. Activation at +0.02, then 0.18 / 0.045 = 4 steps.
        var d = Driver()
        d.drag(x: 0.97, y0: 0.30, y1: 0.50)
        check("right edge slide up raises volume by 4 steps", d.steps(.volume) == 4 && d.steps(.brightness) == 0, "\(d.actions)")
        check("slide begins once and ends once", d.count(.beginSlide(.volume)) == 1 && d.count(.endSlide) == 1, "\(d.actions)")
        check("full steps when not precise", d.quarterFlags == [false], "\(d.quarterFlags)")
        check("haptic tick per step", d.count(.haptic(.tick)) == 4, "\(d.actions)")

        d = Driver()
        d.drag(x: 0.03, y0: 0.70, y1: 0.40)
        check("left edge slide down lowers brightness", d.steps(.brightness) < 0 && d.steps(.volume) == 0, "\(d.actions)")

        d = Driver { $0.swapSides = true }
        d.drag(x: 0.97, y0: 0.30, y1: 0.50)
        check("swap sides puts brightness on the right", d.steps(.brightness) == 4 && d.steps(.volume) == 0, "\(d.actions)")

        d = Driver { $0.preciseSliding = true }
        d.drag(x: 0.97, y0: 0.30, y1: 0.50)
        check("precise sliding gives quarter steps at the same speed", d.steps(.volume) == 16 && d.quarterFlags == [true], "\(d.actions)")

        d = Driver()
        d.drag(x: 0.97, y0: 0.30, y1: 0.50, mods: [.shift, .option])
        check("⇧⌥ gives fine quarter steps", d.steps(.volume) == 4 && d.quarterFlags == [true], "\(d.actions)")

        d = Driver { $0.bottomQuarterOnly = true }
        d.drag(x: 0.97, y0: 0.50, y1: 0.70)
        check("bottom quarter only ignores slides starting high", d.meaningful.isEmpty, "\(d.actions)")
        d = Driver { $0.bottomQuarterOnly = true }
        d.drag(x: 0.97, y0: 0.10, y1: 0.30)
        check("bottom quarter only allows slides starting low", d.steps(.volume) == 4, "\(d.actions)")

        d = Driver()
        d.drag(x: 0.5, y0: 0.3, y1: 0.7)
        check("middle of the trackpad does nothing", d.meaningful.isEmpty, "\(d.actions)")

        d = Driver()
        d.drag(x: 0.97, y0: 0.5, x1: 0.6, y1: 0.52)
        check("leaving the edge sideways does nothing", d.meaningful.isEmpty, "\(d.actions)")

        d = Driver()
        for i in 0...30 {
            let y = 0.3 + Double(i) * 0.01
            d.frame([Touch(id: 1, x: 0.97, y: y), Touch(id: 2, x: 0.5, y: y)])
        }
        d.frame([])
        check("two-finger movement is ignored", d.meaningful.isEmpty, "\(d.actions)")

        d = Driver()
        d.tap(x: 0.95, y: 0.95)
        d.tap(x: 0.95, y: 0.95, id: 2)
        check("double-tap top-right corner mutes", d.count(.corner(.topRight)) == 1 && d.count(.haptic(.strong)) == 1, "\(d.actions)")
        check("corner taps hold clicks, then release", d.count(.clickGuard(.arm)) == 2 && d.count(.clickGuard(.release)) == 2
              && d.actions.firstIndex(of: .corner(.topRight))! < d.actions.lastIndex(of: .clickGuard(.release))!, "\(d.actions)")

        d = Driver()
        d.tap(x: 0.95, y: 0.95)
        check("single corner tap does nothing", d.meaningful.isEmpty, "\(d.actions)")

        d = Driver()
        d.tap(x: 0.95, y: 0.95)
        d.tap(x: 0.95, y: 0.95, id: 2, gap: 0.8)
        check("slow corner taps don't mute", d.count(.corner(.topRight)) == 0, "\(d.actions)")

        d = Driver { $0.cornerActions = [:] }
        d.tap(x: 0.95, y: 0.95)
        d.tap(x: 0.95, y: 0.95, id: 2)
        check("quick mute can be turned off", d.meaningful.isEmpty && d.count(.clickGuard(.arm)) == 0, "\(d.actions)")

        d = Driver { $0.cornerActions = [.bottomLeft: .missionControl] }
        d.tap(x: 0.05, y: 0.05)
        d.tap(x: 0.05, y: 0.05, id: 2)
        check("other corners take their own action", d.meaningful == [.corner(.bottomLeft)], "\(d.actions)")

        d = Driver()
        d.drag(x: 0.95, y0: 0.95, x1: 0.6, y1: 0.95, frames: 20)
        check("dragging out of a corner releases held clicks", d.count(.clickGuard(.cancel)) == 1 && d.meaningful.isEmpty, "\(d.actions)")

        d = Driver()
        d.drag(x: 0.3, y0: 0.97, x1: 0.6, y1: 0.975, frames: 60)
        check("top edge slide right raises keyboard backlight", d.steps(.keyboard) == 6, "\(d.steps(.keyboard)) \(d.actions)")
        d = Driver()
        d.drag(x: 0.6, y0: 0.97, x1: 0.3, y1: 0.97, frames: 60)
        check("top edge slide left lowers keyboard backlight", d.steps(.keyboard) == -6, "\(d.steps(.keyboard))")
        d = Driver()
        d.drag(x: 0.5, y0: 0.97, y1: 0.6)
        check("pointer moving down from the top does nothing", d.meaningful.isEmpty, "\(d.actions)")
        d = Driver { $0.keyboardEdge = false }
        d.drag(x: 0.3, y0: 0.97, x1: 0.6, y1: 0.975, frames: 60)
        check("keyboard edge can be turned off", d.meaningful.isEmpty, "\(d.actions)")

        // Same 0.3 of travel: slow vs a quick flick.
        d = Driver { $0.acceleration = true }
        d.drag(x: 0.97, y0: 0.20, y1: 0.50, frames: 100)
        let slow = d.steps(.volume)
        d = Driver { $0.acceleration = true }
        d.drag(x: 0.97, y0: 0.20, y1: 0.50, frames: 10)
        let fast = d.steps(.volume)
        check("speed-sensitive: slow slide is exact", slow == 6, "slow=\(slow)")
        check("speed-sensitive: a flick goes further", fast > slow + 3, "slow=\(slow) fast=\(fast)")
        d = Driver { $0.acceleration = false }
        d.drag(x: 0.97, y0: 0.20, y1: 0.50, frames: 10)
        check("acceleration off: flick is exact too", d.steps(.volume) == 6, "\(d.steps(.volume))")

        check("detent at 50%", ActionPerformer.crossesDetent(from: 7.0 / 16, to: 8.0 / 16)
              && ActionPerformer.crossesDetent(from: 9.0 / 16, to: 8.0 / 16), "")
        check("detent at the limits", ActionPerformer.crossesDetent(from: 1.0 / 16, to: 0)
              && ActionPerformer.crossesDetent(from: 15.0 / 16, to: 1), "")
        check("no detent mid-range or leaving 50%", !ActionPerformer.crossesDetent(from: 3.0 / 16, to: 4.0 / 16)
              && !ActionPerformer.crossesDetent(from: 0.5, to: 9.0 / 16)
              && !ActionPerformer.crossesDetent(from: 0, to: 0), "")

        d = Driver()
        d.drag(x: 0.3, y0: 0.05, x1: 0.6, y1: 0.06, frames: 20)
        check("bottom swipe right skips forward", d.meaningful == [.nextTrack], "\(d.actions)")
        d = Driver()
        d.drag(x: 0.6, y0: 0.05, x1: 0.3, y1: 0.06, frames: 20)
        check("bottom swipe left goes back", d.meaningful == [.previousTrack], "\(d.actions)")
        d = Driver { $0.reverseSwipe = true }
        d.drag(x: 0.3, y0: 0.05, x1: 0.6, y1: 0.06, frames: 20)
        check("reverse swipe flips direction", d.meaningful == [.previousTrack], "\(d.actions)")
        d = Driver()
        d.drag(x: 0.3, y0: 0.05, x1: 0.9, y1: 0.06, frames: 20)
        check("one skip per swipe", d.count(.nextTrack) == 1, "\(d.actions)")
        d = Driver()
        d.drag(x: 0.3, y0: 0.05, x1: 0.6, y1: 0.06, frames: 100)
        check("slow drag along the bottom doesn't skip", d.meaningful.isEmpty, "\(d.actions)")
        d = Driver { $0.mediaStrip = false }
        d.drag(x: 0.3, y0: 0.05, x1: 0.6, y1: 0.06, frames: 20)
        check("media strip can be turned off", d.meaningful.isEmpty, "\(d.actions)")

        d = Driver()
        d.tap(x: 0.5, y: 0.05)
        d.tap(x: 0.5, y: 0.05, id: 2)
        check("double-tap bottom edge plays/pauses", d.meaningful == [.playPause], "\(d.actions)")
        d = Driver()
        d.tap(x: 0.5, y: 0.05)
        check("single bottom tap does nothing", d.meaningful.isEmpty, "\(d.actions)")
        d = Driver { $0.doubleTapPlayPause = false }
        d.tap(x: 0.5, y: 0.05)
        d.tap(x: 0.5, y: 0.05, id: 2)
        check("double-tap play can be turned off", d.meaningful.isEmpty, "\(d.actions)")

        // Finger drops out for a few frames and comes back under a new id.
        d = Driver()
        d.drag(x: 0.97, y0: 0.30, y1: 0.40, frames: 10, lift: false)
        d.frame([])
        d.frame([])
        for i in 0...10 { d.frame([Touch(id: 9, x: 0.97, y: 0.41 + Double(i) * 0.01)]) }
        d.frame([]); d.flushLater()
        check("slide survives a tracking dropout", d.count(.beginSlide(.volume)) == 1 && d.count(.endSlide) == 1 && d.steps(.volume) == 4,
              "\(d.actions)")

        d = Driver()
        d.drag(x: 0.97, y0: 0.30, y1: 0.40, frames: 10, lift: false)
        d.time += 0.5
        d.actions += d.engine.timeout(time: d.time)
        check("slide ends if frames stop arriving", d.count(.endSlide) == 1 && d.engine.isIdle, "\(d.actions)")

        d = Driver { $0.requiredModifier = .control }
        d.drag(x: 0.97, y0: 0.30, y1: 0.50)
        check("required modifier blocks without key", d.meaningful.isEmpty, "\(d.actions)")
        d = Driver { $0.requiredModifier = .control }
        d.drag(x: 0.97, y0: 0.30, y1: 0.50, mods: [.control])
        check("required modifier allows with key", d.steps(.volume) == 4, "\(d.actions)")

        d = Driver { $0.enabled = false }
        d.drag(x: 0.97, y0: 0.30, y1: 0.50)
        check("disabled does nothing", d.meaningful.isEmpty, "\(d.actions)")

        d = Driver()
        d.drag(x: 0.97, y0: 0.30, y1: 0.50, device: .mouse)
        d.tap(x: 0.5, y: 0.05, device: .mouse)
        d.tap(x: 0.5, y: 0.05, id: 2, device: .mouse)
        check("magic mouse: edges slide, no strip", d.steps(.volume) == 4 && d.count(.playPause) == 0, "\(d.actions)")

        d = Driver { $0.stepDistance = 0.025 }
        d.drag(x: 0.97, y0: 0.10, y1: 0.50)
        check("faster slide speed means more steps", d.steps(.volume) == 15, "\(d.steps(.volume))")

        let passed = results.filter(\.1).count
        for (name, ok, info) in results {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(info.isEmpty ? "" : "\n      \(info)")")
        }
        print("\n\(passed)/\(results.count) passed")
        return passed == results.count
    }
}

// `EdgePad --diagnose`: checks the real system pieces on this Mac.
enum Diagnostics {
    static func run() {
        print("Accessibility trusted: \(AXIsProcessTrusted())")
        print("MultitouchSupport loaded: \(MTSupport.handle != nil), symbols: \(MTSupport.createList != nil && MTSupport.registerCallback != nil)")

        let manager = MultitouchManager.shared
        manager.start()
        for d in manager.activeDevices {
            print("Device: \(d.label) family=\(d.family) builtIn=\(d.builtIn) id=\(d.id)")
        }
        print("Haptic actuator open: \(manager.performer.haptics.hasActuator)")
        if manager.performer.haptics.hasActuator {
            manager.performer.haptics.play(.tick, strength: .light, deviceID: nil)
        }
        print("Volume (CoreAudio): \(fmt(SystemControls.volume())) muted=\(SystemControls.isMuted())")
        print("Brightness (DisplayServices): \(fmt(SystemControls.brightness()))")
        if let k = KeyboardBacklight.level() {
            KeyboardBacklight.set(k > 0.5 ? k - 0.25 : k + 0.25)
            Thread.sleep(forTimeInterval: 0.3)
            let changed = KeyboardBacklight.level()
            KeyboardBacklight.set(k)
            Thread.sleep(forTimeInterval: 0.3)
            print("Keyboard backlight: \(fmt(k)) -> set \(fmt(changed)) -> restored \(fmt(KeyboardBacklight.level()))")
        } else {
            print("Keyboard backlight: unavailable")
        }

        if CommandLine.arguments.contains("--keys") {
            func probe(_ name: String, read: () -> Double?, up: MediaKey, down: MediaKey, quarter: Bool) {
                let before = read()
                SystemControls.press(up, quarter: quarter)
                Thread.sleep(forTimeInterval: 0.5)
                let after = read()
                SystemControls.press(down, quarter: quarter)
                Thread.sleep(forTimeInterval: 0.5)
                let restored = read()
                print("\(name) key\(quarter ? " (quarter)" : ""): \(fmt(before)) -> \(fmt(after)) -> \(fmt(restored))")
            }
            // Start away from the limits so a step up is measurable.
            let originalVolume = SystemControls.volume()
            let wasMuted = SystemControls.isMuted()
            defer { SystemControls.setMuted(wasMuted) }
            if let v = originalVolume, v > 0.9 { SystemControls.setVolume(0.5) }
            probe("Volume", read: SystemControls.volume, up: .soundUp, down: .soundDown, quarter: false)
            probe("Volume", read: SystemControls.volume, up: .soundUp, down: .soundDown, quarter: true)
            if let v = originalVolume { SystemControls.setVolume(v) }

            let originalBrightness = SystemControls.brightness()
            if let b = originalBrightness, b > 0.9 { SystemControls.setBrightness(0.7) }
            probe("Brightness", read: SystemControls.brightness, up: .brightnessUp, down: .brightnessDown, quarter: false)
            probe("Brightness", read: SystemControls.brightness, up: .brightnessUp, down: .brightnessDown, quarter: true)
            if let b = originalBrightness { SystemControls.setBrightness(b) }
        }

        if let i = CommandLine.arguments.firstIndex(of: "--listen"), i + 1 < CommandLine.arguments.count,
           let seconds = Double(CommandLine.arguments[i + 1]) {
            print("Listening for touches for \(seconds)s…")
            var frames = 0
            var lastPrint = 0.0
            manager.liveTouches = { _, touches in
                frames += 1
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPrint > 0.25, !touches.isEmpty {
                    lastPrint = now
                    print(touches.map { String(format: "  id=%d x=%.2f y=%.2f", $0.id, $0.x, $0.y) }.joined(separator: " |"))
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            print("Frames received: \(frames)")
        }
        manager.stop()
    }

    private static func fmt(_ v: Double?) -> String {
        v.map { String(format: "%.4f", $0) } ?? "n/a"
    }
}

// `EdgePad --snapshot <dir>`: renders the UI to PNGs.
enum Snapshot {
    static func run(to path: String) {
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = AppSettings.shared
        let levels = LevelsModel()
        levels.refresh()
        let live = LiveState()
        live.trusted = AXIsProcessTrusted()
        live.tried = ["volume", "mute"]
        live.touches = [Touch(id: 1, x: 0.96, y: 0.55)]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(MenuView(settings: settings, levels: levels, openSettings: {}, openSetup: {}, quit: {}),
                   appearance: appearance, to: dir.appendingPathComponent("menu-\(name).png"))
            render(SettingsView(settings: settings, live: live, devices: MultitouchManager.shared.activeDevices, openSetup: {}),
                   appearance: appearance, to: dir.appendingPathComponent("settings-\(name).png"))
            let model = OnboardingModel(settings: settings)
            for (i, step) in model.steps.enumerated() {
                render(OnboardingView(model: OnboardingModel(settings: settings, start: step), settings: settings,
                                      live: live, levels: levels, finish: {}),
                       appearance: appearance, to: dir.appendingPathComponent("onboarding-\(i)-\(name).png"))
            }
        }
        try? IconFactory.png(IconFactory.appIcon(size: 256), pixels: 256).write(to: dir.appendingPathComponent("icon.png"))
        print("Wrote snapshots to \(dir.path)")
    }

    private static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
