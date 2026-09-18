# MockNetPackKit

MockNetPack 的 iOS Debug SDK —— App 进程内 HTTP 抓包上传与远端 Mock 客户端。

> **M0 状态**：当前为**空骨架**（SwiftPM 包），仅含版本占位，无任何抓包/拦截/连接实现（属 M1+）。
> 上游无第三方代码依赖；服务端见 `server/`。

## 硬约束：仅 Debug 携带

本 SDK **只能存在于 Debug 构建产物中，Release 产物不得包含本 SDK**（需求文档 §7.2 / F7.2，项目级验收门）。

接入时务必同时满足两层：

1. **编译层（业务代码）**：业务侧所有对 `MockNetPackKit` 的调用必须用 `#if DEBUG` 包裹，Release 编译后对本库零引用：
   ```swift
   #if DEBUG
   import MockNetPackKit
   // ... 初始化 / 启动抓包 ...
   #endif
   ```
2. **链接/产物层（验收门）**：Release Archive 中不得出现本库符号。正式校验脚本/CI 检查在 M5 落地；M0/M1 先用 `nm`/`strings` 抽检。

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
