// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Backlit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Backlit", targets: ["Backlit"])],
    targets: [
        .executableTarget(name: "Backlit", linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("IOKit"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("CoreAudio")]),
        .testTarget(name: "BacklitTests", dependencies: ["Backlit"])
    ]
)
