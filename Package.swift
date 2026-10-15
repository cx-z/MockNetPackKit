// swift-tools-version: 6.0
//
// MockNetPackKit —— 仅 Debug 构建的 HTTP 抓包与 Mock SDK。
//  起包含连接层（注册/心跳/会话状态）；拦截器属 、Mock 客户端属 。
// macOS 平台声明仅用于在 macOS 上跑单元测试/冒烟（部署目标为 iOS 13）。
//
// L6.1a 重做（2026-10-15 决策 D-L6.4 全注册制）：XCPush 相关代码从主 SDK
// 拆出为独立适配器模块 MockNetPackKitXCPush（Swift + ObjC C target）。
// 依赖方向：MockNetPackKitXCPush → MockNetPackKit（主 SDK 不依赖任何具体
// 框架适配器；业务方显式注册适配器，见 MockNetPackKit.registerLongConnAdapter）。
import PackageDescription

let package = Package(
    name: "MockNetPackKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v12)
    ],
    products: [
        // 业务工程通过此 product 链接本 SDK（主模块，不含任何框架适配器）。
        .library(name: "MockNetPackKit", targets: ["MockNetPackKit"]),
        // XCPush 长连接框架适配器（独立模块；接入方引入后显式注册）。
        .library(name: "MockNetPackKitXCPush", targets: ["MockNetPackKitXCPush"]),
    ],
    targets: [
        // XCPush 的 ObjC 承载（XCPushDelegateProxy 消息兜底转发、Inbox 解码）。
        // SwiftPM 不支持同一 target 混合语言，故独立为 C target，Swift target 依赖它。
        .target(
            name: "MockNetPackKitXCPushObjC",
            publicHeadersPath: "include"
        ),
        // 主 SDK：协议 + registry + 通用采集/连接/HTTP mock。纯注册制——
        // 不内置、不依赖任何具体框架适配器。
        .target(
            name: "MockNetPackKit",
            dependencies: [],
            resources: []
        ),
        // XCPush 适配器模块：探测 XCPushSocket → 安装代理采集 + 挂载 L7 注入器。
        .target(
            name: "MockNetPackKitXCPush",
            dependencies: ["MockNetPackKit", "MockNetPackKitXCPushObjC"]
        ),
        .executableTarget(
            name: "MockNetPackSmoke",
            dependencies: ["MockNetPackKit"]
        ),
        .testTarget(
            name: "MockNetPackKitTests",
            dependencies: ["MockNetPackKit"]
        ),
        .testTarget(
            name: "MockNetPackKitXCPushTests",
            dependencies: ["MockNetPackKitXCPush", "MockNetPackKitXCPushObjC", "MockNetPackKit"]
        ),
    ]
)
