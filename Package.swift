// swift-tools-version: 6.0
//
// MockNetPackKit —— 仅 Debug 构建的 HTTP 抓包与 Mock SDK。
//  起包含连接层（注册/心跳/会话状态）；拦截器属 、Mock 客户端属 。
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
        // L5.1：XCPushDelegateProxy 为 ObjC 承载（消息兜底转发 API 仅 ObjC 可用）。
        // SwiftPM 不支持同一 target 混合语言，故独立为 C target，Swift target 依赖它。
        .target(
            name: "MockNetPackKitObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MockNetPackKit",
            dependencies: ["MockNetPackKitObjC"],
            resources: []
        ),
        .executableTarget(
            name: "MockNetPackSmoke",
            dependencies: ["MockNetPackKit"]
        ),
        .testTarget(
            name: "MockNetPackKitTests",
            dependencies: ["MockNetPackKit", "MockNetPackKitObjC"]
        ),
    ]
)
