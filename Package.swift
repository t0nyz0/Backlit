// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Backlit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Backlit", targets: ["Backlit"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .executableTarget(name: "Backlit", dependencies: [.product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("IOKit"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("CoreAudio"), .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "BacklitTests", dependencies: ["Backlit"])
    ]
)
