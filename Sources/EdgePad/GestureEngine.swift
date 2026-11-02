import Foundation

// Pure gesture logic. Feed it touch frames (normalized 0...1, y = 0 at the bottom edge)
// and it returns the actions to perform. No system calls here, so it is fully testable.

enum Control: String { case volume, brightness, keyboard }
enum DeviceKind: String { case trackpad, mouse }
enum HapticKind { case begin, tick, swipe, strong, detent }
enum ClickGuardEvent { case arm, cancel, release }

struct Touch: Equatable {
    var id: Int
    var x: Double
    var y: Double
}

struct Modifiers: OptionSet {
    let rawValue: Int
    static let shift = Modifiers(rawValue: 1 << 0)
    static let option = Modifiers(rawValue: 1 << 1)
    static let control = Modifiers(rawValue: 1 << 2)
    static let command = Modifiers(rawValue: 1 << 3)
    static let function = Modifiers(rawValue: 1 << 4)
}

enum RequiredModifier: String, CaseIterable, Identifiable {
    case none, control, option, command, function
    var id: String { rawValue }
    var modifiers: Modifiers {
        switch self {
        case .none: return []
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .function: return .function
        }
    }
    var label: String {
        switch self {
        case .none: return "None"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .function: return "fn"
        }
    }
}

enum HapticStrength: String, CaseIterable, Identifiable {
    case off, light, medium, strong
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum Corner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

enum CornerAction: String, CaseIterable, Identifiable {
    case none, mute, playPause, missionControl, appWindows, showDesktop, lockScreen, screenshot, spotlight, sleepDisplay, shortcut
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Nothing"
        case .mute: return "Mute"
        case .playPause: return "Play / Pause"
        case .missionControl: return "Mission Control"
        case .appWindows: return "App Windows"
        case .showDesktop: return "Show Desktop"
        case .lockScreen: return "Lock Screen"
        case .screenshot: return "Screenshot"
        case .spotlight: return "Spotlight"
        case .sleepDisplay: return "Sleep Display"
        case .shortcut: return "Run Shortcut…"
        }
    }
}

struct EngineConfig: Equatable {
    var enabled = true
    var edgeWidth = 0.12
    var swapSides = false
    var bottomQuarterOnly = false
    var requiredModifier: RequiredModifier = .none
    var cornerActions: [Corner: CornerAction] = [.topRight: .mute]
    var keyboardEdge = true
    var mediaStrip = true
    var doubleTapPlayPause = true
    var reverseSwipe = false
    var preciseSliding = false
    var acceleration = true
    /// Finger travel (fraction of trackpad size) per full step.
    var stepDistance = 0.045
    // Used by the performer, not the engine.
    var hapticStrength: HapticStrength = .medium
    var freezeCursor = true
    var detents = true
    var cornerShortcuts: [Corner: String] = [:]
}

enum EngineAction: Equatable {
    case touchStarted
    case beginSlide(Control)
    case adjust(Control, steps: Int, quarter: Bool)
    case endSlide
    case corner(Corner)
    case clickGuard(ClickGuardEvent)
    case playPause
    case nextTrack
    case previousTrack
    case haptic(HapticKind)
}

final class GestureEngine {
    var config = EngineConfig()

    static let activationDistance = 0.02
    static let crossAbort = 0.06
    static let cornerSize = 0.15
    static let topEdgeStart = 0.95
    static let stripHeight = 0.12
    static let bottomQuarter = 0.25
    static let swipeDistance = 0.12
    static let swipeMaxDuration = 0.35
    static let stripAbortRise = 0.1
    static let tapMaxDuration = 0.25
    static let tapMaxMove = 0.03
    static let doubleTapInterval = 0.35
    static let dropoutGrace = 0.15
    static let reacquireDistance = 0.12

    private struct Candidate {
        var id: Int
        var startX: Double, startY: Double, startTime: Double
        var slideControl: Control?
        var corner: Corner?
        var maxMove = 0.0
    }

    private struct Slide {
        var id: Int
        var control: Control
        var accumulated = 0.0
        var lastX: Double, lastY: Double, lastTime: Double
        var velocity = 0.0
        var missingSince: Double?
        var startX: Double, startY: Double
        var totalSteps = 0
    }

    private struct Strip {
        var id: Int
        var startX: Double, startY: Double, startTime: Double
        var fired = false
        var maxMove = 0.0
    }

    private enum Phase {
        case idle
        case ignored // wait until every finger lifts
        case candidate(Candidate)
        case sliding(Slide)
        case strip(Strip)
    }

    private var phase: Phase = .idle
    private var lastCornerTap: (corner: Corner, time: Double)?
    private var lastStripTapEnd: Double?
    /// A short description of the last decision, for the debug log.
    var note: String?

    var isIdle: Bool { if case .idle = phase { return true }; return false }
    var isSliding: Bool { if case .sliding = phase { return true }; return false }

    func process(_ touches: [Touch], time: Double, device: DeviceKind = .trackpad, modifiers: Modifiers = []) -> [EngineAction] {
        var out: [EngineAction] = []
        switch phase {
        case .idle:
            if touches.count == 1 && config.enabled {
                begin(touches[0], time: time, device: device, modifiers: modifiers, out: &out)
            } else if !touches.isEmpty {
                phase = .ignored
            }

        case .ignored:
            if touches.isEmpty { phase = .idle }

        case .candidate(var c):
            guard touches.count == 1, let t = touches.first(where: { $0.id == c.id }) else {
                if touches.isEmpty {
                    finishCornerTap(c, time: time, out: &out)
                    phase = .idle
                } else {
                    abort(c, "another finger landed", out: &out)
                }
                break
            }
            let dx = t.x - c.startX, dy = t.y - c.startY
            c.maxMove = max(c.maxMove, (dx * dx + dy * dy).squareRoot())
            if let control = c.slideControl {
                let along = control == .keyboard ? dx : dy
                let across = control == .keyboard ? dy : dx
                if abs(along) >= Self.activationDistance, abs(along) > abs(across) {
                    phase = .sliding(Slide(id: t.id, control: control, lastX: t.x, lastY: t.y, lastTime: time,
                                           startX: t.x, startY: t.y))
                    if c.corner != nil { out.append(.clickGuard(.cancel)) }
                    out += [.beginSlide(control), .haptic(.begin)]
                    break
                }
                if abs(across) > Self.crossAbort {
                    abort(c, String(format: "moved off the edge (dx=%.2f dy=%.2f)", dx, dy), out: &out)
                    break
                }
            } else if c.maxMove > Self.tapMaxMove {
                abort(c, "corner touch moved", out: &out)
                break
            }
            phase = .candidate(c)

        case .sliding(var s):
            if let t = touches.first(where: { $0.id == s.id }) {
                s.missingSince = nil
                move(&s, to: t, time: time, modifiers: modifiers, out: &out)
                phase = .sliding(s)
                break
            }
            // The tracked finger vanished. The trackpad sometimes drops a finger for a frame or
            // two and re-reports it under a new id; keep the slide alive through that.
            let since = s.missingSince ?? time
            if time - since > Self.dropoutGrace {
                end(s, out: &out)
                phase = touches.isEmpty ? .idle : .ignored
                break
            }
            if touches.count == 1, hypot(touches[0].x - s.lastX, touches[0].y - s.lastY) <= Self.reacquireDistance {
                let t = touches[0]
                s.id = t.id
                s.lastX = t.x
                s.lastY = t.y
                s.lastTime = time
                s.missingSince = nil
            } else {
                s.missingSince = since
            }
            phase = .sliding(s)

        case .strip(var s):
            guard touches.count == 1, let t = touches.first(where: { $0.id == s.id }) else {
                if touches.isEmpty {
                    finishStripTap(s, time: time, out: &out)
                    phase = .idle
                } else {
                    phase = .ignored
                }
                break
            }
            let dx = t.x - s.startX, dy = t.y - s.startY
            s.maxMove = max(s.maxMove, (dx * dx + dy * dy).squareRoot())
            if !s.fired {
                let elapsed = time - s.startTime
                if abs(dx) >= Self.swipeDistance, abs(dx) > 2 * abs(dy), elapsed <= Self.swipeMaxDuration {
                    s.fired = true
                    let forward = (dx > 0) != config.reverseSwipe
                    out += [forward ? .nextTrack : .previousTrack, .haptic(.swipe)]
                } else if dy > Self.stripAbortRise || elapsed > Self.swipeMaxDuration {
                    // Moving up out of the strip, or a slow drag: that's ordinary pointer use.
                    note = "bottom strip: ordinary pointer movement"
                    phase = .ignored
                    break
                }
            }
            phase = .strip(s)
        }
        return out
    }

    /// Called when no frames have arrived for a while (the last "finger up" frame can be lost).
    func timeout(time: Double) -> [EngineAction] {
        var out: [EngineAction] = []
        switch phase {
        case .sliding(let s): end(s, out: &out)
        case .candidate(let c): finishCornerTap(c, time: time, out: &out)
        case .strip(let s): finishStripTap(s, time: time, out: &out)
        case .idle, .ignored: break
        }
        phase = .idle
        return out
    }

    private func begin(_ t: Touch, time: Double, device: DeviceKind, modifiers: Modifiers, out: inout [EngineAction]) {
        let required = config.requiredModifier.modifiers
        if !required.isEmpty && !modifiers.contains(required) {
            note = "ignored: \(config.requiredModifier.label) not held"
            phase = .ignored
            return
        }
        let w = config.edgeWidth
        let inLeft = t.x < w
        let inRight = t.x > 1 - w
        var control: Control?
        if inLeft || inRight {
            if device == .mouse || !config.bottomQuarterOnly || t.y <= Self.bottomQuarter {
                control = (inRight != config.swapSides) ? .volume : .brightness
            }
        } else if device == .trackpad && config.keyboardEdge && t.y >= Self.topEdgeStart {
            control = .keyboard
        }
        let corner = device == .trackpad ? activeCorner(at: t) : nil
        let strip = device == .trackpad && config.mediaStrip && corner == nil
            && t.y <= Self.stripHeight && !inLeft && !inRight

        if strip {
            phase = .strip(Strip(id: t.id, startX: t.x, startY: t.y, startTime: time))
            out.append(.touchStarted)
        } else if control != nil || corner != nil {
            phase = .candidate(Candidate(id: t.id, startX: t.x, startY: t.y, startTime: time,
                                         slideControl: control, corner: corner))
            out.append(.touchStarted)
            if corner != nil { out.append(.clickGuard(.arm)) }
        } else {
            phase = .ignored
        }
    }

    private func activeCorner(at t: Touch) -> Corner? {
        let s = Self.cornerSize
        let left = t.x <= s, right = t.x >= 1 - s
        let top = t.y >= 1 - s, bottom = t.y <= s
        let corner: Corner?
        switch (left, right, top, bottom) {
        case (true, _, true, _): corner = .topLeft
        case (_, true, true, _): corner = .topRight
        case (true, _, _, true): corner = .bottomLeft
        case (_, true, _, true): corner = .bottomRight
        default: corner = nil
        }
        guard let corner, (config.cornerActions[corner] ?? .none) != .none else { return nil }
        return corner
    }

    private func abort(_ c: Candidate, _ reason: String, out: inout [EngineAction]) {
        note = "edge touch dropped: \(reason)"
        if c.corner != nil { out.append(.clickGuard(.cancel)) }
        phase = .ignored
    }

    private func move(_ s: inout Slide, to t: Touch, time: Double, modifiers: Modifiers, out: inout [EngineAction]) {
        let fine = modifiers.contains([.shift, .option])
        let quarter = fine || config.preciseSliding
        // Holding ⇧⌥ keeps the travel per step, so each step is finer. Precise Sliding keeps the
        // overall speed and simply moves in quarter steps.
        let unit = (config.preciseSliding && !fine) ? config.stepDistance / 4 : config.stepDistance
        let delta = s.control == .keyboard ? t.x - s.lastX : t.y - s.lastY
        let dt = max(time - s.lastTime, 0.004)
        s.velocity = s.velocity * 0.6 + abs(delta) / dt * 0.4
        var gain = 1.0
        if config.acceleration && !fine {
            // A quick flick covers more range; a slow slide stays exact.
            gain = min(max(1 + (s.velocity - 0.6) * 1.5, 1), 4)
        }
        s.accumulated += delta * gain
        let ratio = s.accumulated / unit
        let steps = Int(ratio + (ratio > 0 ? 1e-9 : -1e-9))
        if steps != 0 {
            s.accumulated -= Double(steps) * unit
            s.totalSteps += steps
            out += [.adjust(s.control, steps: steps, quarter: quarter), .haptic(.tick)]
        }
        s.lastX = t.x
        s.lastY = t.y
        s.lastTime = time
    }

    private func end(_ s: Slide, out: inout [EngineAction]) {
        note = String(format: "%@ slide ended: %d steps, travel dx=%.2f dy=%.2f",
                      s.control.rawValue, s.totalSteps, s.lastX - s.startX, s.lastY - s.startY)
        out.append(.endSlide)
    }

    private func finishCornerTap(_ c: Candidate, time: Double, out: inout [EngineAction]) {
        guard let corner = c.corner else { return }
        guard time - c.startTime <= Self.tapMaxDuration, c.maxMove <= Self.tapMaxMove else {
            out.append(.clickGuard(.cancel))
            return
        }
        if let last = lastCornerTap, last.corner == corner, c.startTime - last.time <= Self.doubleTapInterval {
            let heavy = config.cornerActions[corner] == .mute
            out += [.corner(corner), .haptic(heavy ? .strong : .swipe)]
            lastCornerTap = nil
        } else {
            lastCornerTap = (corner, time)
        }
        out.append(.clickGuard(.release))
    }

    private func finishStripTap(_ s: Strip, time: Double, out: inout [EngineAction]) {
        guard !s.fired, config.doubleTapPlayPause,
              time - s.startTime <= Self.tapMaxDuration, s.maxMove <= Self.tapMaxMove else { return }
        if let last = lastStripTapEnd, s.startTime - last <= Self.doubleTapInterval {
            out += [.playPause, .haptic(.swipe)]
            lastStripTapEnd = nil
        } else {
            lastStripTapEnd = time
        }
    }
}
