// MockNetPackSmoke —— 连接层冒烟工具（本地 mockd 联调用）。
//
// 用法：
//   1. 启动 mockd（Admin :4290 / Engine :4280）：
//      mockd start --no-auth --detach --admin-port 4290 --port 4280
//   2. 运行：swift run MockNetPackSmoke [serverURL] [engineBase]
//      默认 server = http://localhost:4290/api/v1，engineBase = http://localhost:4280
//   3. 外部激活会话（Web/curl）→ sessionState 变为 capturing →
//      SDK 自动发起 4 个模拟请求（3 成功 + 1 失败），观察 SDK 上传日志；
//      Web/服务端可查询到流量条目。
//   4. 结束会话 → sessionState 回 idle → 采集停止。
import Foundation
import MockNetPackKit

// 顶层代码为 MainActor 隔离，@Sendable 闭包内用 Box 承载可变状态。
final class SmokeBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

let server = CommandLine.arguments.count > 1
    ? URL(string: CommandLine.arguments[1])!
    : URL(string: "http://localhost:4290/api/v1")!
let engineBase = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "http://localhost:4280"

/// 已发起过模拟请求（只触发一次）。
let didFire = SmokeBox(false)

MockNetPackKit.onConnectionStateChange = { state in
    print("[smoke] connectionState -> \(state)")
}
MockNetPackKit.onSessionStateChange = { state in
    print("[smoke] sessionState -> \(state)")
    guard state == .capturing, !didFire.value else { return }
    didFire.value = true
    fireSampleRequests()
}

/// 发起模拟请求：3 个发往 mockd engine（本地可达，验证成功采集）+ 1 个不可达
/// 端口（验证 error/失败采集）。URLSession 必须在 SDK start 之后创建，
/// 才会包含全局注册的 MockNetPackURLProtocol。
func fireSampleRequests() {
    print("[smoke] fireSampleRequests -> \(engineBase)")
    let session = URLSession(configuration: .default)
    for i in 0..<3 {
        var req = URLRequest(url: URL(string: "\(engineBase)/smoke-request-\(i)")!)
        req.httpMethod = i == 1 ? "POST" : "GET"
        if i == 1 {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{\"sample\":1,\"seq\":\(i)}".utf8)
        }
        print("[smoke] firing req-\(i) \(req.httpMethod ?? "GET") \(req.url?.absoluteString ?? "?")")
        session.dataTask(with: req) { _, response, error in
            print("[smoke] req-\(i): status=\((response as? HTTPURLResponse)?.statusCode ?? -1) error=\(error?.localizedDescription ?? "nil")")
        }.resume()
    }
    print("[smoke] firing req-unreachable")
    session.dataTask(with: URL(string: "http://127.0.0.1:59999/unreachable")!) { _, _, error in
        print("[smoke] req-unreachable: error=\(error?.localizedDescription ?? "nil")")
    }.resume()
}

MockNetPackKit.start(server: server, appID: "com.mocknetpack.smoke", logHandler: { print("[sdk] \($0)") })

// 运行 60s，期间可外部激活会话验证状态切换与流量采集（心跳默认 20s，留足窗口）。
RunLoop.main.run(until: Date().addingTimeInterval(60))
MockNetPackKit.stop()
print("[smoke] done. did=\(MockNetPackKit.did ?? "?")")
