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

setbuf(__stdoutp, nil)  // 行无缓冲，nohup 落盘实时可见

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
    startPolling()
}

/// 会话 capturing 期间，每 3s 发一组请求；观察状态码/响应体即可对比
/// 「走真实 engine」与「命中 Mock 回包」。
func startPolling() {
    print("[smoke] startPolling -> \(engineBase)")
    let session = URLSession(configuration: .default)
    var tick = 0
    Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { t in
        tick += 1
        for i in 0..<3 {
            var req = URLRequest(url: URL(string: "\(engineBase)/smoke-request-\(i)")!)
            req.httpMethod = i == 1 ? "POST" : "GET"
            session.dataTask(with: req) { data, response, error in
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("[smoke] tick=\(tick) req-\(i): status=\(code) body=\(String(body.prefix(60))) err=\(error?.localizedDescription ?? "-")")
            }.resume()
        }
    }
}

MockNetPackKit.start(server: server, appID: "com.mocknetpack.smoke", logHandler: { print("[sdk] \($0)") })

// 运行 180s，期间可外部激活会话验证状态切换与流量采集/规则命中。
RunLoop.main.run(until: Date().addingTimeInterval(180))
MockNetPackKit.stop()
print("[smoke] done. did=\(MockNetPackKit.did ?? "?")")
