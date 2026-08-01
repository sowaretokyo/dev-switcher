// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevSwitcher",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "DevSwitcher", targets: ["DevSwitcher"]),
        .library(name: "DevSwitcherCore", targets: ["DevSwitcherCore"]),
    ],
    targets: [
        // ドメイン、プロセス実行、永続化。UI へ依存しないためテスト対象にできる。
        .target(name: "DevSwitcherCore"),
        // SwiftUI アプリ本体。UI 以外のロジックは DevSwitcherCore に置く。
        .executableTarget(
            name: "DevSwitcher",
            dependencies: ["DevSwitcherCore"]
        ),
        .testTarget(
            name: "DevSwitcherCoreTests",
            dependencies: ["DevSwitcherCore"]
        ),
    ]
)
