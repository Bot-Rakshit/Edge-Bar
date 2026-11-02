import AppKit
import ServiceManagement
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum EdgeWidth: String, CaseIterable, Identifiable {
    case narrow, standard, wide
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var value: Double {
        switch self {
        case .narrow: return 0.09
        case .standard: return 0.12
        case .wide: return 0.16
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var hapticStrength: HapticStrength { didSet { d.set(hapticStrength.rawValue, forKey: "hapticStrength") } }
    @Published var keyboardEdge: Bool { didSet { d.set(keyboardEdge, forKey: "keyboardEdge") } }
    @Published var detents: Bool { didSet { d.set(detents, forKey: "detents") } }
    @Published var acceleration: Bool { didSet { d.set(acceleration, forKey: "acceleration") } }
    @Published var hapticPings: Bool { didSet { d.set(hapticPings, forKey: "hapticPings") } }
    @Published var cornerActions: [Corner: CornerAction] {
        didSet { for c in Corner.allCases { d.set((cornerActions[c] ?? .none).rawValue, forKey: "corner.\(c.rawValue)") } }
    }
    @Published var cornerShortcuts: [Corner: String] {
        didSet { for c in Corner.allCases { d.set(cornerShortcuts[c] ?? "", forKey: "cornerShortcut.\(c.rawValue)") } }
    }
    @Published var mediaStrip: Bool { didSet { d.set(mediaStrip, forKey: "mediaStrip") } }
    @Published var doubleTapPlayPause: Bool { didSet { d.set(doubleTapPlayPause, forKey: "doubleTapPlayPause") } }
    @Published var reverseSwipe: Bool { didSet { d.set(reverseSwipe, forKey: "reverseSwipe") } }
    @Published var preciseSliding: Bool { didSet { d.set(preciseSliding, forKey: "preciseSliding") } }
    /// 0 = slow (more travel per step), 1 = fast.
    @Published var slideSpeed: Double { didSet { d.set(slideSpeed, forKey: "slideSpeed") } }
    @Published var swapSides: Bool { didSet { d.set(swapSides, forKey: "swapSides") } }
    @Published var bottomQuarterOnly: Bool { didSet { d.set(bottomQuarterOnly, forKey: "bottomQuarterOnly") } }
    @Published var requiredModifier: RequiredModifier { didSet { d.set(requiredModifier.rawValue, forKey: "requiredModifier") } }
    @Published var freezeCursor: Bool { didSet { d.set(freezeCursor, forKey: "freezeCursor") } }
    @Published var edgeWidth: EdgeWidth { didSet { d.set(edgeWidth.rawValue, forKey: "edgeWidth") } }
    @Published var magicMouse: Bool { didSet { d.set(magicMouse, forKey: "magicMouse") } }
    @Published var appearance: AppearanceMode {
        didSet { d.set(appearance.rawValue, forKey: "appearance"); applyAppearance() }
    }
    @Published var hasCompletedSetup: Bool { didSet { d.set(hasCompletedSetup, forKey: "hasCompletedSetup") } }
    @Published private(set) var openAtLogin = false
    @Published var loginItemError: String?

    private init() {
        d.register(defaults: [
            "enabled": true, "hapticStrength": HapticStrength.medium.rawValue,
            "keyboardEdge": true, "detents": true, "acceleration": true, "hapticPings": true,
            "corner.topRight": CornerAction.mute.rawValue,
            "mediaStrip": true, "doubleTapPlayPause": true, "reverseSwipe": false, "preciseSliding": false,
            "slideSpeed": 0.5, "swapSides": false, "bottomQuarterOnly": false,
            "requiredModifier": RequiredModifier.none.rawValue, "freezeCursor": true,
            "edgeWidth": EdgeWidth.standard.rawValue, "magicMouse": false,
            "appearance": AppearanceMode.system.rawValue, "hasCompletedSetup": false,
        ])
        enabled = d.bool(forKey: "enabled")
        hapticStrength = HapticStrength(rawValue: d.string(forKey: "hapticStrength") ?? "") ?? .medium
        keyboardEdge = d.bool(forKey: "keyboardEdge")
        detents = d.bool(forKey: "detents")
        acceleration = d.bool(forKey: "acceleration")
        hapticPings = d.bool(forKey: "hapticPings")
        var actions: [Corner: CornerAction] = [:]
        var shortcuts: [Corner: String] = [:]
        for c in Corner.allCases {
            actions[c] = CornerAction(rawValue: d.string(forKey: "corner.\(c.rawValue)") ?? "") ?? CornerAction.none
            shortcuts[c] = d.string(forKey: "cornerShortcut.\(c.rawValue)") ?? ""
        }
        cornerActions = actions
        cornerShortcuts = shortcuts
        mediaStrip = d.bool(forKey: "mediaStrip")
        doubleTapPlayPause = d.bool(forKey: "doubleTapPlayPause")
        reverseSwipe = d.bool(forKey: "reverseSwipe")
        preciseSliding = d.bool(forKey: "preciseSliding")
        slideSpeed = d.double(forKey: "slideSpeed")
        swapSides = d.bool(forKey: "swapSides")
        bottomQuarterOnly = d.bool(forKey: "bottomQuarterOnly")
        requiredModifier = RequiredModifier(rawValue: d.string(forKey: "requiredModifier") ?? "") ?? .none
        freezeCursor = d.bool(forKey: "freezeCursor")
        edgeWidth = EdgeWidth(rawValue: d.string(forKey: "edgeWidth") ?? "") ?? .standard
        magicMouse = d.bool(forKey: "magicMouse")
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        hasCompletedSetup = d.bool(forKey: "hasCompletedSetup")
        refreshLoginItem()
    }

    /// Quick Mute is the top-right corner set to Mute.
    var quickMute: Bool {
        get { cornerActions[.topRight] == .mute }
        set { cornerActions[.topRight] = newValue ? .mute : CornerAction.none }
    }

    var engineConfig: EngineConfig {
        var c = EngineConfig()
        c.enabled = enabled
        c.edgeWidth = edgeWidth.value
        c.swapSides = swapSides
        c.bottomQuarterOnly = bottomQuarterOnly
        c.requiredModifier = requiredModifier
        c.cornerActions = cornerActions
        c.cornerShortcuts = cornerShortcuts
        c.keyboardEdge = keyboardEdge
        c.acceleration = acceleration
        c.detents = detents
        c.mediaStrip = mediaStrip
        c.doubleTapPlayPause = doubleTapPlayPause
        c.reverseSwipe = reverseSwipe
        c.preciseSliding = preciseSliding
        c.stepDistance = 0.07 - slideSpeed * 0.045 // 0.07 (slow) ... 0.025 (fast)
        c.hapticStrength = hapticStrength
        c.freezeCursor = freezeCursor
        return c
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func refreshLoginItem() {
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItem()
    }
}

/// Live volume and brightness for the menu.
final class LevelsModel: ObservableObject {
    @Published var volume: Double = 0
    @Published var muted = false
    @Published var brightness: Double?
    @Published var keyboard: Double?
    private var timer: Timer?

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let v = SystemControls.volume() ?? 0
        let m = SystemControls.isMuted()
        let b = SystemControls.brightness()
        let k = KeyboardBacklight.level()
        if k != keyboard { keyboard = k }
        if abs(v - volume) > 0.001 { volume = v }
        if m != muted { muted = m }
        if b != brightness { brightness = b }
    }

    func setVolume(_ v: Double) {
        SystemControls.setVolume(v)
        refresh()
    }

    func setBrightness(_ v: Double) {
        SystemControls.setBrightness(v)
        refresh()
    }

    func setKeyboard(_ v: Double) {
        KeyboardBacklight.set(v)
        refresh()
    }

    func toggleMute() {
        SystemControls.setMuted(!SystemControls.isMuted())
        refresh()
    }
}

/// State for the setup guide: live finger positions and which gestures have been tried.
final class LiveState: ObservableObject {
    @Published var touches: [Touch] = []
    @Published var deviceKind: DeviceKind = .trackpad
    @Published var trusted = AXIsProcessTrusted()
    @Published var tried: Set<String> = []
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    func start() {
        trusted = AXIsProcessTrusted()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let t = AXIsProcessTrusted()
            if self?.trusted != t { self?.trusted = t }
        }
        observer = NotificationCenter.default.addObserver(forName: .edgePadAction, object: nil, queue: .main) { [weak self] note in
            guard let names = note.userInfo?["names"] as? [String] else { return }
            self?.tried.formUnion(names)
        }
        MultitouchManager.shared.liveTouches = { [weak self] kind, touches in
            DispatchQueue.main.async {
                self?.deviceKind = kind
                self?.touches = touches
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        MultitouchManager.shared.liveTouches = nil
    }
}

enum Accessibility {
    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
