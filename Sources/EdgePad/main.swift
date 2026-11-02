import AppKit

let args = CommandLine.arguments

if args.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}
if let i = args.firstIndex(of: "--buzz") {
    // Haptic ping for scripts and agents: EdgePad --buzz [tap|done|attention|error]
    let pattern = i + 1 < args.count ? args[i + 1] : "done"
    DistributedNotificationCenter.default().postNotificationName(
        .init("com.rakshit.edgepad.buzz"), object: pattern, userInfo: nil, deliverImmediately: true)
    exit(0)
}
if args.contains("--diagnose") {
    _ = NSApplication.shared
    Diagnostics.run()
    exit(0)
}
if let i = args.firstIndex(of: "--make-iconset"), i + 1 < args.count {
    do { try IconFactory.writeIconset(to: args[i + 1]) } catch { print(error); exit(1) }
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Snapshot.run(to: args[i + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
