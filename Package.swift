// swift-tools-version: 6.0
//
// MockNetPackKit —— 仅 Debug 构建的 HTTP 抓包与 Mock SDK。
//  起包含连接层（注册/心跳/会话状态）；拦截器属 、Mock 客户端属 。
// macOS 平台声明仅用于在 macOS 上跑单元测试/冒烟（部署目标为 iOS 13）。
//
// 公开仓库零框架痕迹——本包只含
// 主 SDK（MockNetPackKit）：通用采集/连接/HTTP mock + LongConnHook 通用
// 声明式长连接接入层。业务方以 ≤20 行声明接入，框架特有协议逻辑由业务方
// 自己的工具提供；无任何具体框架适配器模块。
import PackageDescription

let package = Package(
    name: "MockNetPackKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v12)
    ],
    products: [
        // 业务工程通过此 product 链接本 SDK（唯一产品；不含任何框架适配器）。
        .library(name: "MockNetPackKit", targets: ["MockNetPackKit"]),
    ],
    targets: [
        // 主 SDK：协议 + registry + 通用采集/连接/HTTP mock + LongConnHook
        // 声明式长连接接入层。纯声明制——不内置、不依赖任何具体框架。
        .target(
            name: "MockNetPackKit",
            dependencies: [],
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
