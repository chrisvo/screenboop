// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Screenboop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Screenboop", targets: ["Screenboop"])],
    targets: [
        .executableTarget(name: "Screenboop"),
        .testTarget(name: "ScreenboopTests", dependencies: ["Screenboop"])
    ],
    swiftLanguageModes: [.v5]
)
