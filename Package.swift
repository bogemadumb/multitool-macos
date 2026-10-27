// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Multitul",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MultitulUI", targets: ["MultitulUI"]),
        .library(name: "MultitulCore", targets: ["MultitulCore"]),
        .executable(name: "Vitrina", targets: ["Vitrina"]),
        .library(name: "MultitulCtlCore", targets: ["MultitulCtlCore"]),
        .executable(name: "Multitul", targets: ["Multitul"]),
        .executable(name: "multitul-ctl", targets: ["MultitulCtl"])
    ],
    targets: [
        .target(name: "CMixAtomics", path: "Sources/CMixAtomics"),
        .target(name: "MultitulUI", path: "Sources/MultitulUI", swiftSettings: v5),
        .target(name: "MultitulCtlCore", path: "Sources/MultitulCtlCore", swiftSettings: v5),
        .target(name: "MultitulCore", dependencies: ["MultitulUI", "MultitulCtlCore", "CMixAtomics"], path: "Sources/MultitulCore", swiftSettings: v5),
        .executableTarget(name: "MultitulCtl", dependencies: ["MultitulCtlCore"], path: "Sources/MultitulCtl", swiftSettings: v5),
        .executableTarget(name: "Vitrina", dependencies: ["MultitulUI"], path: "Sources/Vitrina", swiftSettings: v5),
        .executableTarget(name: "Multitul", dependencies: ["MultitulUI", "MultitulCore", "MultitulCtlCore"], path: "Sources/Multitul", swiftSettings: v5),
        .testTarget(name: "MultitulCoreTests", dependencies: ["MultitulCore"], path: "Tests/MultitulCoreTests", swiftSettings: v5),
        .testTarget(name: "MultitulCtlCoreTests", dependencies: ["MultitulCtlCore"], path: "Tests/MultitulCtlCoreTests", swiftSettings: v5)
    ]
)
