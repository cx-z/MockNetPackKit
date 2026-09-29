// swift-tools-version: 6.0
//
// MockNetPackKit —— 仅 Debug 构建的 HTTP 抓包与 Mock SDK。
// M1.5 起包含连接层（注册/心跳/会话状态）；拦截器属 M2、Mock 客户端属 M3。
// macOS 平台声明仅用于在 macOS 上跑单元测试/冒烟（部署目标为 iOS 13）。
import PackageDescription

let package = Package(
    name: "MockNetPackKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v12)
    ],
    products: [
        // 业务工程通过此 product 链接本 SDK
        .library(name: "MockNetPackKit", targets: ["MockNetPackKit"]),
    ],
    targets: [
        .target(
            name: "MockNetPackKit",
            resources: []
        ),
        .executableTarget(
            name: "MockNetPackSmoke",
            dependencies: ["MockNetPackKit"]
        ),
        .testTarget(
            name: "MockNetPackKitTests",
            dependencies: ["MockNetPackKit"]
        ),
    ]
)
