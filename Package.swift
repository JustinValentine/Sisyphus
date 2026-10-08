// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sisyphus",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Sisyphus", targets: ["Sisyphus"])],
    targets: [
        .target(name: "SisyphusCore"),
        .executableTarget(name: "Sisyphus", dependencies: ["SisyphusCore"]),
        .executableTarget(name: "SisyphusCoreChecks", dependencies: ["SisyphusCore"], path: "Tests/SisyphusCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
