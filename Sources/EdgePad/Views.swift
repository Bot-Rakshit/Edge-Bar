import SwiftUI


// MARK: - Menu

struct MenuView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var levels: LevelsModel
    var openSettings: () -> Void
    var openSetup: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("EdgePad").font(.headline)
                Spacer()
                Text(settings.enabled ? "On" : "Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            TrackpadPreview(settings: settings, levels: levels)
                .opacity(settings.enabled ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Haptics")
                    Spacer()
                    Picker("", selection: $settings.hapticStrength) {
                        ForEach(HapticStrength.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                }
                OptionRow(title: "Quick Mute", detail: "Double-tap the top-right corner",
                          isOn: Binding(get: { settings.quickMute }, set: { settings.quickMute = $0 }))
                OptionRow(title: "Keyboard Backlight", detail: "Slide along the top edge", isOn: $settings.keyboardEdge)
                OptionRow(title: "Media Strip", detail: "Swipe the bottom edge to skip", isOn: $settings.mediaStrip)
                if settings.mediaStrip {
                    OptionRow(title: "Double-tap to Play/Pause", detail: nil, isOn: $settings.doubleTapPlayPause, indent: true)
                    OptionRow(title: "Reverse Swipe", detail: nil, isOn: $settings.reverseSwipe, indent: true)
                }
                OptionRow(title: "Precise Sliding", detail: "Quarter steps without holding ⇧⌥", isOn: $settings.preciseSliding)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Slide Speed")
                    HStack(spacing: 8) {
                        Image(systemName: "tortoise").foregroundStyle(.secondary)
                        Slider(value: $settings.slideSpeed, in: 0...1)
                        Image(systemName: "hare").foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            HStack {
                Button("Settings…", action: openSettings)
                Button("Welcome Tour", action: openSetup)
                Spacer()
                Button("Quit", action: quit)
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 340)
    }
}

struct OptionRow: View {
    var title: String
    var detail: String?
    @Binding var isOn: Bool
    var indent = false

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.leading, indent ? 14 : 0)
    }
}

/// A small trackpad with the live levels drawn on the edges that control them.
struct TrackpadPreview: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var levels: LevelsModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)

            HStack(alignment: .top) {
                edge(settings.swapSides ? .volume : .brightness)
                Spacer()
                VStack(spacing: 6) {
                    Spacer()
                    Text(settings.enabled ? "Slide the edges" : "Paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if settings.bottomQuarterOnly {
                        Text("Start in the bottom quarter")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    mediaStrip
                }
                Spacer()
                edge(settings.swapSides ? .brightness : .volume)
            }
            .padding(12)

            if settings.keyboardEdge, let keyboard = levels.keyboard {
                VStack {
                    KeyboardLevelBar(value: keyboard, onChange: levels.setKeyboard)
                        .frame(width: 120)
                    Spacer()
                }
                .padding(.top, 10)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: levels.toggleMute) {
                        Image(systemName: levels.muted ? "speaker.slash.fill" : "speaker.fill")
                            .font(.system(size: 11))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(levels.muted ? Color.red.opacity(0.25) : Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Quick Mute: double-tap the top-right corner")
                    .opacity(settings.quickMute ? 1 : 0.35)
                    .padding(.trailing, 0)
                }
                Spacer()
            }
            .padding(.top, 8)
            .padding(.trailing, 72)
        }
        .frame(height: 176)
    }

    @ViewBuilder
    private func edge(_ control: Control) -> some View {
        let isVolume = control == .volume
        let value = isVolume ? (levels.muted ? 0 : levels.volume) : (levels.brightness ?? 0)
        VStack(spacing: 6) {
            Image(systemName: isVolume ? (levels.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") : "sun.max.fill")
                .font(.system(size: 12))
                .foregroundStyle(isVolume ? volumeTint : brightnessTint)
                .frame(height: 14)
            EdgeLevelBar(value: value, tint: isVolume ? volumeTint : brightnessTint) { v in
                if isVolume { levels.setVolume(v) } else { levels.setBrightness(v) }
            }
            .disabled(!isVolume && levels.brightness == nil)
            Text(isVolume ? (levels.muted ? "Muted" : percent(value)) : (levels.brightness == nil ? "—" : percent(value)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: 52)
        .help(isVolume ? "Volume: slide this edge" : "Brightness: slide this edge")
    }

    private var mediaStrip: some View {
        HStack(spacing: 14) {
            Button { SystemControls.press(.previous) } label: { Image(systemName: "backward.fill") }
            Button { SystemControls.press(.play) } label: { Image(systemName: "playpause.fill") }
            Button { SystemControls.press(.next) } label: { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .opacity(settings.mediaStrip ? 1 : 0.35)
        .help("Media Strip: swipe the bottom edge to skip")
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

struct KeyboardLevelBar: View {
    var value: Double
    var onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "light.max").font(.system(size: 10)).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Color.primary.opacity(0.55))
                        .frame(width: value <= 0 ? 0 : max(geo.size.height, geo.size.width * value))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    onChange(min(max(Double(g.location.x / geo.size.width), 0), 1))
                })
            }
            .frame(height: 6)
        }
        .help("Keyboard backlight: slide along the top edge")
        .animation(.easeOut(duration: 0.12), value: value)
    }
}

struct EdgeLevelBar: View {
    var value: Double
    var tint: Color
    var onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(tint)
                    .frame(height: value <= 0 ? 0 : max(geo.size.width, geo.size.height * value))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let fraction = Double(1 - g.location.y / geo.size.height)
                onChange(min(max(fraction, 0), 1))
            })
        }
        .frame(width: 12)
        .animation(.easeOut(duration: 0.12), value: value)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var live: LiveState
    var devices: [MTDevice]
    var openSetup: () -> Void

    var body: some View {
        Form {
            Section("Layout") {
                Toggle("Swap sides", isOn: $settings.swapSides)
                Text(settings.swapSides ? "Brightness on the right, volume on the left." : "Volume on the right, brightness on the left.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Bottom quarter only", isOn: $settings.bottomQuarterOnly)
                Text("Slides only start from the lower part of the trackpad edges.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Edge width", selection: $settings.edgeWidth) {
                    ForEach(EdgeWidth.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Activation") {
                Picker("Require modifier", selection: $settings.requiredModifier) {
                    ForEach(RequiredModifier.allCases) { Text($0.label).tag($0) }
                }
                Text("When set, edges only respond while this key is held.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Feel") {
                Toggle("Speed-sensitive sliding", isOn: $settings.acceleration)
                Text("A quick flick covers more range; a slow slide stays exact.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Detents at 0%, 50% and 100%", isOn: $settings.detents)
                Text("A firmer bump when the level hits empty, half or full.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Corners (double-tap)") {
                ForEach(Corner.allCases) { corner in
                    Picker(corner.label, selection: Binding(
                        get: { settings.cornerActions[corner] ?? CornerAction.none },
                        set: { settings.cornerActions[corner] = $0 })) {
                        ForEach(CornerAction.allCases) { Text($0.label).tag($0) }
                    }
                    if settings.cornerActions[corner] == .shortcut {
                        TextField("Shortcut name", text: Binding(
                            get: { settings.cornerShortcuts[corner] ?? "" },
                            set: { settings.cornerShortcuts[corner] = $0 }))
                    }
                }
                Text("Clicks from tapping an active corner are held back briefly, so a double-tap doesn't also double-click.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Edges") {
                Toggle("Keyboard backlight on the top edge", isOn: $settings.keyboardEdge)
                Text("Slide left or right along the very top of the trackpad.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("While sliding") {
                Toggle("Freeze cursor", isOn: $settings.freezeCursor)
                Toggle("Precise sliding (quarter steps)", isOn: $settings.preciseSliding)
                Text("Or hold ⇧⌥ while sliding for fine quarter steps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Devices") {
                Toggle("Magic Mouse support", isOn: $settings.magicMouse)
                Text(devices.isEmpty ? "No multitouch devices detected." : "Listening to: " + devices.map(\.label).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Open at login", isOn: Binding(get: { settings.openAtLogin }, set: { settings.setOpenAtLogin($0) }))
                if let error = settings.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Haptic pings") {
                Toggle("Allow haptic pings", isOn: $settings.hapticPings)
                Text("Scripts and AI agents can tap your trackpad when they finish:")
                    .font(.caption).foregroundStyle(.secondary)
                Text("~/Applications/EdgePad.app/Contents/MacOS/EdgePad --buzz done")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("Patterns: tap, done, attention, error.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                HStack {
                    Image(systemName: live.trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(live.trusted ? .green : .orange)
                    Text(live.trusted ? "Accessibility access granted" : "Accessibility access needed")
                    Spacer()
                    if !live.trusted {
                        Button("Grant…") {
                            Accessibility.prompt()
                            Accessibility.openSettings()
                        }
                    }
                }
                HStack {
                    Button("Replay Welcome Tour…", action: openSetup)
                    Spacer()
                    Button("Show Log") { NSWorkspace.shared.open(Log.url) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 680)
    }
}
