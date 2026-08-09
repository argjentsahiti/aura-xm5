// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SonyXM5",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SonyXM5",
            path: "Sources/SonyXM5",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
