// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "LocalPrompter", platforms: [.macOS(.v13)],
    products: [.executable(name: "LocalPrompter", targets: ["TeleprompterApp"]),
               .library(name: "TeleprompterCore", targets: ["TeleprompterCore"])],
    targets: [
        .target(name: "TeleprompterCore"),
        .executableTarget(name: "TeleprompterApp", dependencies: ["TeleprompterCore"]),
        .testTarget(name: "TeleprompterCoreTests", dependencies: ["TeleprompterCore"]),
        .testTarget(name: "TeleprompterAppTests", dependencies: ["TeleprompterApp", "TeleprompterCore"])
    ])
