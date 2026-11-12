// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevSwitcher",
    defaultLocalization: "ja",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "DevSwitcher", targets: ["DevSwitcherMain"]),
        .library(name: "DevSwitcherCore", targets: ["DevSwitcherCore"]),
    ],
    targets: [
        // ドメイン、プロセス実行、永続化。UI へ依存しないためテスト対象にできる。
        .target(name: "DevSwitcherCore"),
        // SwiftUI アプリ本体。実行可能ターゲットはテストから import できないため、
        // 画面状態の判断もテストできるようライブラリとして分けている。
        .target(
            name: "DevSwitcherApp",
            dependencies: ["DevSwitcherCore"],
            path: "Sources/DevSwitcher",
            resources: [.process("Resources")]
        ),
        // 起動エントリだけを持つ薄い実行可能ターゲット。
        .executableTarget(
            name: "DevSwitcherMain",
            dependencies: ["DevSwitcherApp"]
        ),
        .testTarget(
            name: "DevSwitcherCoreTests",
            dependencies: ["DevSwitcherCore"]
        ),
        .testTarget(
            name: "DevSwitcherTests",
            dependencies: ["DevSwitcherApp", "DevSwitcherCore"]
        ),
    ]
)
