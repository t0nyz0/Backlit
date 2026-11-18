// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Backlit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Backlit", targets: ["Backlit"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1")
    ],
    targets: [
        .executableTarget(name: "Backlit", dependencies: [.product(name: "Sparkle", package: "Sparkle"), .product(name: "MCP", package: "swift-sdk")], resources: [.process("Resources")], linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("IOKit"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("CoreAudio"), .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "BacklitTests", dependencies: ["Backlit"])
    ]
)
