// swift-tools-version:5.10
// 小管家（StackChan Butler）：菜单栏应用。用 scripts/build_app.sh 拼成 .app 和 .dmg。
import PackageDescription

let package = Package(
    name: "StackChanButler",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Butler",
            path: "Sources/Butler",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))]
        )
    ]
)
