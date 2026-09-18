// swift-tools-version: 6.0
//
// MockNetPackKit —— 仅 Debug 构建的 HTTP 抓包与 Mock SDK。
// M0 阶段仅为空骨架：不含拦截器/连接实现（属 M1+）。
import PackageDescription

let package = Package(
    name: "MockNetPackKit",
    platforms: [
        .iOS(.v15)
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
        .testTarget(
            name: "MockNetPackKitTests",
            dependencies: ["MockNetPackKit"]
        ),
    ]
)
