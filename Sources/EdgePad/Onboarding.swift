import AppKit
import SwiftUI

// First-run experience: welcome, permission, hands-on lessons that react to the real trackpad,
// personalization, and a cheat sheet.

let brightnessTint = Color(red: 1.0, green: 0.72, blue: 0.2)
let volumeTint = Color(red: 0.25, green: 0.6, blue: 1.0)
let keyboardTint = Color(red: 0.72, green: 0.45, blue: 1.0)
let muteTint = Color(red: 1.0, green: 0.38, blue: 0.4)
let mediaTint = Color(red: 0.25, green: 0.82, blue: 0.55)

enum OnboardingStep: Hashable {
    case welcome, permission, lesson(Int), personalize, finish
}

enum LessonZone: Equatable {
    case leftEdge, rightEdge, topEdge, corner(Corner), bottomStrip
}

struct Lesson: Identifiable, Equatable {
    let id: String // matches the action names the performer broadcasts
    let title: String
    let instruction: String
    let symbol: String
    let tint: Color
    let zone: LessonZone
    let needed: Int
}

final class OnboardingModel: ObservableObject {
    @Published var step: OnboardingStep
    @Published private(set) var lessons: [Lesson] = []
    @Published var progress = 0
    @Published var succeeded = false
    private var observer: NSObjectProtocol?
    private let settings: AppSettings

    init(settings: AppSettings, start: OnboardingStep = .welcome) {
        self.settings = settings
        self.step = start
        rebuildLessons()
    }

    func rebuildLessons() {
        let volumeSide = settings.swapSides ? "left" : "right"
        let brightnessSide = settings.swapSides ? "right" : "left"
        var list = [
            Lesson(id: "volume", title: "Volume", instruction: "Put one finger on the \(volumeSide) edge and slide up, then down.",
                   symbol: "speaker.wave.2.fill", tint: volumeTint,
                   zone: settings.swapSides ? .leftEdge : .rightEdge, needed: 4),
            Lesson(id: "brightness", title: "Brightness", instruction: "Now the \(brightnessSide) edge. Same move.",
                   symbol: "sun.max.fill", tint: brightnessTint,
                   zone: settings.swapSides ? .rightEdge : .leftEdge, needed: 4),
        ]
        if settings.keyboardEdge && KeyboardBacklight.isAvailable {
            list.append(Lesson(id: "keyboard", title: "Keyboard light", instruction: "Slide left or right along the very top edge.",
                               symbol: "light.max", tint: keyboardTint, zone: .topEdge, needed: 3))
        }
        if settings.quickMute {
            list.append(Lesson(id: "mute", title: "Quick Mute", instruction: "Double-tap the top-right corner. Do it again to unmute.",
                               symbol: "speaker.slash.fill", tint: muteTint, zone: .corner(.topRight), needed: 1))
        }
        if settings.mediaStrip {
            list.append(Lesson(id: "skip", title: "Media Strip", instruction: "Swipe quickly along the bottom edge to skip a track.",
                               symbol: "forward.fill", tint: mediaTint, zone: .bottomStrip, needed: 1))
        }
        lessons = list
    }

    var steps: [OnboardingStep] {
        [.welcome, .permission] + lessons.indices.map { .lesson($0) } + [.personalize, .finish]
    }

    var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }

    var currentLesson: Lesson? {
        if case .lesson(let i) = step, lessons.indices.contains(i) { return lessons[i] }
        return nil
    }

    func next() {
        if step == .permission { rebuildLessons() }
        let i = stepIndex
        if i + 1 < steps.count { go(steps[i + 1]) }
    }

    func back() {
        let i = stepIndex
        if i > 0 { go(steps[i - 1]) }
    }

    func go(_ s: OnboardingStep) {
        progress = 0
        succeeded = false
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { step = s }
    }

    func startListening() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .edgePadAction, object: nil, queue: .main) { [weak self] note in
            guard let names = note.userInfo?["names"] as? [String] else { return }
            self?.handle(names)
        }
    }

    func stopListening() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func handle(_ names: [String]) {
        guard let lesson = currentLesson, !succeeded else { return }
        let hits = names.filter { $0 == lesson.id }.count
        guard hits > 0 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            progress = min(progress + hits, lesson.needed)
        }
        guard progress >= lesson.needed else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { succeeded = true }
        MultitouchManager.shared.performer.haptics.playPattern("done")
        let current = step
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.step == current { self?.next() }
        }
    }
}

// MARK: - Container

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var live: LiveState
    @ObservedObject var levels: LevelsModel
    var finish: () -> Void

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()
            VStack(spacing: 0) {
                progressBar
                    .padding(.top, 18)
                ZStack {
                    content
                        .id(model.step)
                        .transition(.asymmetric(
                            insertion: .offset(x: 60).combined(with: .opacity),
                            removal: .offset(x: -60).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 800, height: 580)
        .onAppear {
            model.startListening()
            levels.startPolling()
        }
        .onDisappear {
            model.stopListening()
            levels.stopPolling()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:
            WelcomeStep(settings: settings, next: model.next)
        case .permission:
            PermissionStep(live: live, next: model.next)
        case .lesson:
            if let lesson = model.currentLesson {
                LessonStep(model: model, lesson: lesson, settings: settings, live: live, levels: levels)
            }
        case .personalize:
            PersonalizeStep(settings: settings, next: model.next)
        case .finish:
            FinishStep(settings: settings, finish: finish)
        }
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.steps.enumerated()), id: \.offset) { i, _ in
                Capsule()
                    .fill(i <= model.stepIndex ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: i == model.stepIndex ? 26 : 8, height: 6)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.stepIndex)
    }
}

// MARK: - Welcome

struct WelcomeStep: View {
    @ObservedObject var settings: AppSettings
    var next: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 40) {
            VStack(alignment: .leading, spacing: 18) {
                Image(nsImage: IconFactory.appIcon(size: 84))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your trackpad has edges.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Put them to work.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [brightnessTint, muteTint, keyboardTint, volumeTint],
                                                        startPoint: .leading, endPoint: .trailing))
                }
                Text("Slide the sides for volume and brightness, the top for your keyboard light, and the bottom for music. Double-tap a corner for anything else.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330, alignment: .leading)
                HStack(spacing: 6) {
                    Chip("Haptics", "hand.tap")
                    Chip("Quarter steps", "slider.vertical.3")
                    Chip("Corners", "square.dashed")
                }
                Spacer().frame(height: 6)
                Button("Get Started", action: next)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Label("Runs entirely on this Mac. No network, no tracking.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 340, alignment: .leading)

            DemoStage(swapSides: settings.swapSides)
                .frame(width: 340)
        }
        .padding(.horizontal, 44)
        .padding(.bottom, 20)
    }
}

/// Cycles through every gesture with a ghost finger.
struct DemoStage: View {
    var swapSides: Bool
    private static let period = 2.4
    private var demos: [(LessonZone, String, String, Color)] {
        [
            (swapSides ? .leftEdge : .rightEdge, "Volume", "speaker.wave.2.fill", volumeTint),
            (swapSides ? .rightEdge : .leftEdge, "Brightness", "sun.max.fill", brightnessTint),
            (.topEdge, "Keyboard light", "light.max", keyboardTint),
            (.corner(.topRight), "Quick Mute", "speaker.slash.fill", muteTint),
            (.bottomStrip, "Skip track", "forward.fill", mediaTint),
        ]
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let index = Int(t / Self.period) % demos.count
            let phase = (t / Self.period).truncatingRemainder(dividingBy: 1)
            let demo = demos[index]
            let ghost = Ghost.position(for: demo.0, phase: phase)
            VStack(spacing: 16) {
                StageCanvas(zone: demo.0, tint: demo.3, ghost: ghost, touches: [], trail: [],
                            levels: Self.simulatedLevels(zone: demo.0, ghost: ghost, swapSides: swapSides),
                            swapSides: swapSides, time: t)
                    .aspectRatio(1.55, contentMode: .fit)
                HStack(spacing: 8) {
                    Image(systemName: demo.2).foregroundStyle(demo.3)
                    Text(demo.1).font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                .id(index)
                .transition(.opacity)
            }
        }
    }

    static func simulatedLevels(zone: LessonZone, ghost: Ghost, swapSides: Bool) -> StageLevels {
        var levels = StageLevels(volume: 0.45, brightness: 0.62, keyboard: 0.35, showKeyboard: true)
        let edgeLevel = 0.25 + (ghost.y - 0.3) / 0.45 * 0.55
        switch zone {
        case .rightEdge, .leftEdge:
            let isVolume = (zone == .rightEdge) != swapSides
            if isVolume { levels.volume = edgeLevel } else { levels.brightness = edgeLevel }
        case .topEdge:
            levels.keyboard = 0.15 + (ghost.x - 0.35) / 0.3 * 0.6
        case .corner:
            if ghost.ripple != nil || ghost.opacity < 0.9 { levels.volume = 0 }
        case .bottomStrip:
            break
        }
        return levels
    }
}

struct Chip: View {
    let title: String
    let symbol: String
    init(_ title: String, _ symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - Permission

struct PermissionStep: View {
    @ObservedObject var live: LiveState
    var next: () -> Void
    @State private var toggleDemo = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.14)).frame(width: 92, height: 92)
                Image(systemName: live.trusted ? "checkmark.shield.fill" : "hand.raised.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(live.trusted ? Color.green : Color.accentColor)
                    .scaleEffect(live.trusted ? 1.08 : 1)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.55), value: live.trusted)

            VStack(spacing: 6) {
                Text(live.trusted ? "You're good to go." : "One permission, then you're in.")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("macOS calls it Accessibility. EdgePad uses it for exactly three things:")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Reason("speaker.wave.2", "Send the volume, brightness and media keys, so you get the real on-screen display.")
                Reason("cursorarrow", "Hold the pointer still while you slide.")
                Reason("hand.tap", "Hold back stray clicks when you double-tap a corner.")
            }
            .frame(width: 440, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))

            if live.trusted {
                Button("Continue", action: next)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                HStack(spacing: 14) {
                    Button("Open System Settings") {
                        Accessibility.prompt()
                        Accessibility.openSettings()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    HStack(spacing: 8) {
                        Text("then turn on").foregroundStyle(.secondary)
                        Image(nsImage: IconFactory.appIcon(size: 18))
                        Text("EdgePad").fontWeight(.medium)
                        MockSwitch(on: toggleDemo)
                    }
                    .font(.callout)
                }
                Button("Skip for now", action: next)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.bottom, 24)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).delay(0.6).repeatForever(autoreverses: true)) { toggleDemo = true }
        }
        .onChange(of: live.trusted) { trusted in
            guard trusted else { return }
            MultitouchManager.shared.performer.haptics.playPattern("done")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: next)
        }
    }
}

struct Reason: View {
    let symbol: String
    let text: String
    init(_ symbol: String, _ text: String) {
        self.symbol = symbol
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(Color.accentColor)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MockSwitch: View {
    var on: Bool
    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.2))
            Circle().fill(.white).padding(2).shadow(radius: 1)
        }
        .frame(width: 30, height: 18)
    }
}

// MARK: - Lesson

struct LessonStep: View {
    @ObservedObject var model: OnboardingModel
    let lesson: Lesson
    @ObservedObject var settings: AppSettings
    @ObservedObject var live: LiveState
    @ObservedObject var levels: LevelsModel
    @State private var trail: [CGPoint] = []
    @State private var start = Date()

    private var lessonNumber: Int { (model.lessons.firstIndex(of: lesson) ?? 0) + 1 }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(lesson.tint.opacity(0.18)).frame(width: 46, height: 46)
                    Image(systemName: lesson.symbol).font(.system(size: 19, weight: .semibold)).foregroundStyle(lesson.tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(lesson.title).font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(lesson.instruction).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Try it \(lessonNumber) of \(model.lessons.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 26) {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = (context.date.timeIntervalSince(start) / 2.4).truncatingRemainder(dividingBy: 1)
                    StageCanvas(zone: lesson.zone, tint: lesson.tint,
                                ghost: live.touches.isEmpty && !model.succeeded ? Ghost.position(for: lesson.zone, phase: phase) : nil,
                                touches: live.touches, trail: trail, levels: realLevels,
                                swapSides: settings.swapSides, time: t)
                }
                .aspectRatio(1.55, contentMode: .fit)
                .frame(width: 440)
                .overlay(successBadge)

                readout.frame(width: 190)
            }

            HStack {
                Button("Back", action: model.back).buttonStyle(.borderless)
                Spacer()
                if !model.succeeded {
                    Text(live.touches.count > 1 ? "Use just one finger" : (live.touches.isEmpty ? "Follow the ghost finger" : " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.succeeded ? "Continue" : "Skip", action: model.next)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 4)
        .padding(.bottom, 30)
        .onChange(of: live.touches) { touches in
            guard let t = touches.first else {
                trail = []
                return
            }
            trail.append(CGPoint(x: t.x, y: t.y))
            if trail.count > 26 { trail.removeFirst(trail.count - 26) }
        }
    }

    private var realLevels: StageLevels {
        StageLevels(volume: levels.muted ? 0 : levels.volume, brightness: levels.brightness ?? 0,
                    keyboard: levels.keyboard ?? 0, showKeyboard: lesson.id == "keyboard")
    }

    @ViewBuilder
    private var successBadge: some View {
        if model.succeeded {
            ZStack {
                Circle().fill(Color.green).frame(width: 78, height: 78).shadow(color: .green.opacity(0.5), radius: 18)
                Image(systemName: "checkmark").font(.system(size: 36, weight: .heavy)).foregroundStyle(.white)
            }
            .transition(.scale(scale: 0.3).combined(with: .opacity))
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch lesson.id {
            case "mute":
                Image(systemName: levels.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 34)).foregroundStyle(lesson.tint)
                Text(levels.muted ? "Muted" : "Sound on")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
            case "skip":
                Image(systemName: "forward.fill").font(.system(size: 34)).foregroundStyle(lesson.tint)
                Text(model.succeeded ? "Skipped!" : "Next track")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Swipe right for next, left for previous.").font(.caption).foregroundStyle(.secondary)
            default:
                Image(systemName: lesson.symbol).font(.system(size: 34)).foregroundStyle(lesson.tint)
                Text(percent)
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                Text(lesson.title).foregroundStyle(.secondary)
            }
            if lesson.needed > 1 {
                HStack(spacing: 5) {
                    ForEach(0..<lesson.needed, id: \.self) { i in
                        Capsule()
                            .fill(i < model.progress ? lesson.tint : Color.primary.opacity(0.12))
                            .frame(width: 22, height: 6)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var percent: String {
        let v: Double
        switch lesson.id {
        case "volume": v = levels.muted ? 0 : levels.volume
        case "brightness": v = levels.brightness ?? 0
        default: v = levels.keyboard ?? 0
        }
        return "\(Int((v * 100).rounded()))%"
    }
}

// MARK: - Personalize

struct PersonalizeStep: View {
    @ObservedObject var settings: AppSettings
    var next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Make it yours").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("You can change all of this later from the menu bar.").foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Volume on which side?").font(.headline)
                    HStack(spacing: 14) {
                        SideCard(volumeRight: true, selected: !settings.swapSides) { settings.swapSides = false }
                        SideCard(volumeRight: false, selected: settings.swapSides) { settings.swapSides = true }
                    }
                }

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Haptic feel").font(.headline)
                        HStack(spacing: 6) {
                            ForEach(HapticStrength.allCases) { strength in
                                Button(strength.label) {
                                    settings.hapticStrength = strength
                                    MultitouchManager.shared.performer.haptics.play(.tick, strength: strength, deviceID: nil)
                                }
                                .buttonStyle(PillButtonStyle(selected: settings.hapticStrength == strength))
                            }
                        }
                        Text("Rest a finger on the trackpad and tap each one to feel it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Slide speed").font(.headline)
                        HStack(spacing: 8) {
                            Image(systemName: "tortoise").foregroundStyle(.secondary)
                            Slider(value: $settings.slideSpeed, in: 0...1)
                            Image(systemName: "hare").foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Open EdgePad at login", isOn: Binding(get: { settings.openAtLogin },
                                                                  set: { settings.setOpenAtLogin($0) }))
                        .toggleStyle(.switch)
                }
                .frame(width: 300)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Extras").font(.headline)
                HStack(spacing: 12) {
                    FeatureCard(symbol: "hare.fill", tint: volumeTint, title: "Speed-sensitive",
                                detail: "Flicks go further", isOn: $settings.acceleration)
                    FeatureCard(symbol: "circle.grid.cross.fill", tint: brightnessTint, title: "Detents",
                                detail: "Feel 0%, 50% and 100%", isOn: $settings.detents)
                    FeatureCard(symbol: "light.max", tint: keyboardTint, title: "Keyboard light",
                                detail: "Slide the top edge", isOn: $settings.keyboardEdge)
                }
            }

            Spacer()
            HStack {
                Spacer()
                Button("Continue", action: next)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 26)
    }
}

struct FeatureCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(isOn ? 0.22 : 0.08))
                        .frame(width: 34, height: 34)
                    Image(systemName: symbol).foregroundStyle(isOn ? tint : .secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
            }
            .padding(12)
            .frame(width: 222)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(isOn ? 0.07 : 0.035)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: isOn)
    }
}

struct SideCard: View {
    var volumeRight: Bool
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07))
                    HStack {
                        Capsule().fill(volumeRight ? brightnessTint : volumeTint).frame(width: 6, height: 50)
                        Spacer()
                        Capsule().fill(volumeRight ? volumeTint : brightnessTint).frame(width: 6, height: 66)
                    }
                    .padding(.horizontal, 10)
                }
                .frame(width: 138, height: 90)
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(volumeRight ? "Volume right" : "Volume left").fontWeight(.medium)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: selected)
    }
}

// MARK: - Finish

struct FinishStep: View {
    @ObservedObject var settings: AppSettings
    var finish: () -> Void
    @State private var appeared = Date()
    @State private var popped = false

    var body: some View {
        ZStack {
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                ConfettiView(start: appeared).allowsHitTesting(false)
            }
            VStack(spacing: 18) {
                Image(nsImage: IconFactory.appIcon(size: 76))
                    .scaleEffect(popped ? 1 : 0.4)
                    .opacity(popped ? 1 : 0)
                VStack(spacing: 4) {
                    Text("You're all set.").font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Here's everything at a glance. It's also in the menu bar any time.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(210), spacing: 12), count: 3), spacing: 12) {
                    CheatCard(symbol: "speaker.wave.2.fill", tint: volumeTint, title: "Volume",
                              gesture: "Slide the \(settings.swapSides ? "left" : "right") edge")
                    CheatCard(symbol: "sun.max.fill", tint: brightnessTint, title: "Brightness",
                              gesture: "Slide the \(settings.swapSides ? "right" : "left") edge")
                    CheatCard(symbol: "light.max", tint: keyboardTint, title: "Keyboard light",
                              gesture: "Slide along the top edge", dim: !settings.keyboardEdge)
                    CheatCard(symbol: "speaker.slash.fill", tint: muteTint, title: "Quick Mute",
                              gesture: "Double-tap top-right corner", dim: !settings.quickMute)
                    CheatCard(symbol: "forward.fill", tint: mediaTint, title: "Skip · Play",
                              gesture: "Swipe · double-tap bottom", dim: !settings.mediaStrip)
                    CheatCard(symbol: "plusminus", tint: .gray, title: "Fine control",
                              gesture: "Hold ⇧⌥ while sliding")
                }
                HStack {
                    Label("EdgePad lives in your menu bar", systemImage: "arrow.up.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Start Using EdgePad", action: finish)
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
                .frame(width: 654)
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            appeared = Date()
            MultitouchManager.shared.performer.haptics.playPattern("attention")
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.1)) { popped = true }
        }
    }
}

struct CheatCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let gesture: String
    var dim = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: symbol).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(gesture).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(height: 60)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        .opacity(dim ? 0.4 : 1)
    }
}

struct ConfettiView: View {
    var start: Date
    private static let colors: [Color] = [brightnessTint, volumeTint, keyboardTint, muteTint, mediaTint, .pink]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { gc, size in
                guard t < 3.2 else { return }
                var rng = SeededRandom(seed: 7)
                for i in 0..<110 {
                    let x0 = size.width / 2 + rng.next(-60, 60)
                    let y0 = size.height * 0.42
                    let vx = rng.next(-360, 360)
                    let vy = rng.next(-620, -260)
                    let spin = rng.next(-8, 8)
                    let x = x0 + vx * t + sin(t * 3 + Double(i)) * 12
                    let y = y0 + vy * t + 0.5 * 700 * t * t
                    let fade = t > 2.4 ? max(0, 1 - (t - 2.4) / 0.8) : 1
                    var p = gc
                    p.translateBy(x: x, y: y)
                    p.rotate(by: .radians(spin * t))
                    p.opacity = fade
                    p.fill(Path(roundedRect: CGRect(x: -3.5, y: -5.5, width: 7, height: 11), cornerRadius: 2),
                           with: .color(Self.colors[i % Self.colors.count]))
                }
            }
        }
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next(_ low: Double, _ high: Double) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(state >> 11) / Double(1 << 53)
        return low + (high - low) * unit
    }
}

// MARK: - Stage

struct Ghost {
    var x: Double
    var y: Double
    var opacity: Double
    var ripple: Double? // 0...1 while a tap ripple expands

    static func position(for zone: LessonZone, phase p: Double) -> Ghost {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return Ghost(x: anchor(zone).x, y: anchor(zone).y, opacity: 0.8, ripple: nil)
        }
        let fade = p < 0.1 ? p / 0.1 : (p > 0.88 ? max(0, (1 - p) / 0.12) : 1)
        func ease(_ v: Double) -> Double { v * v * (3 - 2 * v) }
        func sweep(_ a: Double, _ b: Double) -> Double {
            switch p {
            case ..<0.1: return a
            case ..<0.5: return a + (b - a) * ease((p - 0.1) / 0.4)
            case ..<0.85: return b + (a - b) * ease((p - 0.5) / 0.35)
            default: return a
            }
        }
        switch zone {
        case .rightEdge: return Ghost(x: 0.955, y: sweep(0.3, 0.75), opacity: fade, ripple: nil)
        case .leftEdge: return Ghost(x: 0.045, y: sweep(0.3, 0.75), opacity: fade, ripple: nil)
        case .topEdge: return Ghost(x: sweep(0.35, 0.65), y: 0.975, opacity: fade, ripple: nil)
        case .corner:
            let a = anchor(zone)
            var ripple: Double?
            if p >= 0.42 && p < 0.7 { ripple = (p - 0.42) / 0.28 } else if p >= 0.25 && p < 0.53 { ripple = (p - 0.25) / 0.28 }
            return Ghost(x: a.x, y: a.y, opacity: fade, ripple: ripple)
        case .bottomStrip:
            let x: Double = p < 0.25 ? 0.3 : (p < 0.45 ? 0.3 + 0.4 * ease((p - 0.25) / 0.2) : 0.7)
            return Ghost(x: x, y: 0.06, opacity: fade, ripple: nil)
        }
    }

    private static func anchor(_ zone: LessonZone) -> (x: Double, y: Double) {
        switch zone {
        case .rightEdge: return (0.955, 0.5)
        case .leftEdge: return (0.045, 0.5)
        case .topEdge: return (0.5, 0.975)
        case .bottomStrip: return (0.5, 0.06)
        case .corner(let c):
            return (c == .topLeft || c == .bottomLeft ? 0.07 : 0.93, c == .bottomLeft || c == .bottomRight ? 0.08 : 0.92)
        }
    }
}

struct StageLevels {
    var volume: Double
    var brightness: Double
    var keyboard: Double
    var showKeyboard: Bool
}

/// A large trackpad: the highlighted zone pulses, a ghost finger demonstrates, real fingers glow
/// with a trail, and the level bars on the edges show the live values.
struct StageCanvas: View {
    var zone: LessonZone
    var tint: Color
    var ghost: Ghost?
    var touches: [Touch]
    var trail: [CGPoint]
    var levels: StageLevels
    var swapSides: Bool
    var time: Double

    var body: some View {
        Canvas { gc, size in
            let pad = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            let shape = Path(roundedRect: pad, cornerRadius: 22, style: .continuous)
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: pad.minX + x * pad.width, y: pad.minY + (1 - y) * pad.height)
            }

            gc.fill(shape, with: .linearGradient(Gradient(colors: [Color.primary.opacity(0.1), Color.primary.opacity(0.04)]),
                                                  startPoint: CGPoint(x: pad.midX, y: pad.minY),
                                                  endPoint: CGPoint(x: pad.midX, y: pad.maxY)))

            // Highlighted zone
            var clipped = gc
            clipped.clip(to: shape)
            let pulse = (sin(time * 3.2) + 1) / 2
            let zr = zoneRect(zone, in: pad)
            clipped.fill(Path(zr), with: .color(tint.opacity(0.16 + 0.16 * pulse)))
            clipped.stroke(Path(roundedRect: zr.insetBy(dx: 1, dy: 1), cornerRadius: 6), with: .color(tint.opacity(0.55)), lineWidth: 1.5)

            gc.stroke(shape, with: .color(Color.primary.opacity(0.16)), lineWidth: 1)

            // Level bars on the edges
            let barW: CGFloat = 5
            let inset: CGFloat = 12
            func vbar(x: CGFloat, value: Double, color: Color) {
                let track = CGRect(x: x, y: pad.minY + 26, width: barW, height: pad.height - 52)
                gc.fill(Path(roundedRect: track, cornerRadius: barW / 2), with: .color(Color.primary.opacity(0.1)))
                let h = track.height * min(max(value, 0), 1)
                gc.fill(Path(roundedRect: CGRect(x: x, y: track.maxY - h, width: barW, height: h), cornerRadius: barW / 2),
                        with: .color(color))
            }
            let leftIsVolume = swapSides
            vbar(x: pad.minX + inset, value: leftIsVolume ? levels.volume : levels.brightness,
                 color: leftIsVolume ? volumeTint : brightnessTint)
            vbar(x: pad.maxX - inset - barW, value: leftIsVolume ? levels.brightness : levels.volume,
                 color: leftIsVolume ? brightnessTint : volumeTint)
            if levels.showKeyboard {
                let track = CGRect(x: pad.midX - pad.width * 0.18, y: pad.minY + 12, width: pad.width * 0.36, height: barW)
                gc.fill(Path(roundedRect: track, cornerRadius: barW / 2), with: .color(Color.primary.opacity(0.1)))
                let w = track.width * min(max(levels.keyboard, 0), 1)
                gc.fill(Path(roundedRect: CGRect(x: track.minX, y: track.minY, width: w, height: barW), cornerRadius: barW / 2),
                        with: .color(keyboardTint))
            }

            // Trail
            if trail.count > 1 {
                for i in 1..<trail.count {
                    let f = Double(i) / Double(trail.count)
                    var seg = Path()
                    seg.move(to: point(trail[i - 1].x, trail[i - 1].y))
                    seg.addLine(to: point(trail[i].x, trail[i].y))
                    gc.stroke(seg, with: .color(tint.opacity(0.55 * f)), style: StrokeStyle(lineWidth: 3 + 9 * f, lineCap: .round))
                }
            }

            // Real fingers
            for t in touches {
                let c = point(t.x, t.y)
                var glow = gc
                glow.addFilter(.shadow(color: tint.opacity(0.9), radius: 12))
                glow.fill(Path(ellipseIn: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)), with: .color(tint))
                gc.stroke(Path(ellipseIn: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)),
                          with: .color(.white.opacity(0.7)), lineWidth: 2)
            }

            // Ghost finger
            if let ghost, touches.isEmpty, ghost.opacity > 0 {
                let c = point(ghost.x, ghost.y)
                let r: CGFloat = 14
                if let rp = ghost.ripple {
                    let rr = r + 22 * rp
                    gc.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                              with: .color(tint.opacity((1 - rp) * ghost.opacity)), lineWidth: 2)
                }
                let pressed = ghost.ripple.map { $0 < 0.25 } ?? false
                let size = pressed ? r * 1.7 : r * 2
                let rect = CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
                gc.fill(Path(ellipseIn: rect), with: .color(Color.primary.opacity(0.22 * ghost.opacity)))
                gc.stroke(Path(ellipseIn: rect), with: .color(Color.primary.opacity(0.5 * ghost.opacity)), lineWidth: 1.5)
            }
        }
    }

    private func zoneRect(_ zone: LessonZone, in pad: CGRect) -> CGRect {
        let edge = 0.12
        let cs = GestureEngine.cornerSize
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> CGRect {
            CGRect(x: pad.minX + x0 * pad.width, y: pad.minY + (1 - y1) * pad.height,
                   width: (x1 - x0) * pad.width, height: (y1 - y0) * pad.height)
        }
        switch zone {
        case .leftEdge: return rect(0, 0, edge, 1)
        case .rightEdge: return rect(1 - edge, 0, 1, 1)
        case .topEdge: return rect(edge, 0.92, 1 - edge, 1) // drawn a little taller than the real zone so it's visible
        case .bottomStrip: return rect(edge, 0, 1 - edge, GestureEngine.stripHeight)
        case .corner(let c):
            let right = c == .topRight || c == .bottomRight
            let bottom = c == .bottomLeft || c == .bottomRight
            return rect(right ? 1 - cs : 0, bottom ? 0 : 1 - cs, right ? 1 : cs, bottom ? cs : 1)
        }
    }
}

// MARK: - Styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(Capsule().fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                                      startPoint: .top, endPoint: .bottom)))
            .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct PillButtonStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
