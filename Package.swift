// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "VideoWallpaper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VideoWallpaper",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
