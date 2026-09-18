# MockNetPackKit

MockNetPack 的 iOS Debug SDK —— App 进程内 HTTP 抓包上传与远端 Mock 客户端。

> **M0 状态**：当前为**空骨架**（SwiftPM 包），仅含版本占位，无任何抓包/拦截/连接实现（属 M1+）。
> 上游无第三方代码依赖；服务端见 `server/`。

## 集成方式：由业务方决定，SDK 不做自控制

本 SDK **自身不做 Debug/Release 判断，也不强制任何隔离策略**——是否集成、在哪个配置集成，完全由接入的业务 App 自行决定。

接入方 Knocknock（KK）的要求是：**Release 产物中不包含本 SDK 的代码/符号**（是"不携带"，不只是"不生效"）。这一要求由 KK 的构建集成层保证，不在 SDK 内部实现。推荐做法见 `tasks/M0-SDK接入要点.md`，要点是：

1. 业务侧所有对 `MockNetPackKit` 的调用用 `#if DEBUG` 包裹（Release 编译后对本库零引用）；
2. 出包后由 KK 侧校验 Release Archive 不含本库符号（M5 落 CI）。

## 包结构

```
MockNetPackKit/
├── Package.swift
├── Sources/MockNetPackKit/     # 产品实现（M1 起填充）
└── Tests/MockNetPackKitTests/
```

## 本地验证

```bash
cd iOS/MockNetPackKit
swift build          # 编译骨架
swift test           # 跑占位测试
```

## 接入方式（与 CocoaPods 工程共存）

接入测试工程 Knocknock 为 CocoaPods（`use_frameworks! :linkage => :static` + modular_headers）。共存评估与推荐方案见 `tasks/M0-SDK接入要点.md`。
