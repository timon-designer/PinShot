// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PinShot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PinShot", targets: ["PinShot"]),
        .library(name: "PinShotCore", targets: ["PinShotCore"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PinShotCore",
            dependencies: [],
            path: "Sources/PinShotCore"
        ),
        .testTarget(
            name: "PinShotCoreTests",
            dependencies: ["PinShotCore"],
            path: "Tests/PinShotCoreTests"
        ),
        // ObjC 小目标：只为提供 @try/@catch 能力（Swift 语言层面无法捕获 NSException）。
        // 见 Sources/PSExceptionGuard/include/PSExceptionGuard.h 的注释。
        .target(
            name: "PSExceptionGuard",
            path: "Sources/PSExceptionGuard",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "PinShot",
            dependencies: ["PinShotCore", "PSExceptionGuard"],
            path: "Sources/PinShot"
        )
    ]
)
