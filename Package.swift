// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EdgePad",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "EdgePad",
            path: "Sources/EdgePad",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
