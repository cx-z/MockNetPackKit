// MockNetPackSmoke —— 连接层冒烟工具（本地 mockd 联调用）。
//
// 用法：
//   1. 启动 mockd（Admin :4290）：
//      mockd start --no-auth --detach --admin-port 4290 --port 4280
//   2. 运行：swift run MockNetPackSmoke [serverURL]
//      默认 server = http://localhost:4290/api/v1
//   3. 观察输出：did 生成、注册、心跳、连接状态变化。
//      运行期间可在 Web/curl 激活会话，观察 sessionState 变为 capturing。
import Foundation
import MockNetPackKit

let server = CommandLine.arguments.count > 1
    ? URL(string: CommandLine.arguments[1])!
    : URL(string: "http://localhost:4290/api/v1")!

MockNetPackKit.onConnectionStateChange = { state in
    print("[smoke] connectionState -> \(state)")
}
MockNetPackKit.onSessionStateChange = { state in
    print("[smoke] sessionState -> \(state)")
}

MockNetPackKit.start(server: server, appID: "com.mocknetpack.smoke", logHandler: { print("[sdk] \($0)") })

// 运行 30s，期间可外部激活会话验证状态切换。
RunLoop.main.run(until: Date().addingTimeInterval(30))
MockNetPackKit.stop()
print("[smoke] done. did=\(MockNetPackKit.did ?? "?")")
