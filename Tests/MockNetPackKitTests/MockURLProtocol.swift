import Foundation

/// 测试辅助：拦截 URLSession 请求，按预设 handler 返回响应。
/// 使用方式：注入 `URLSessionConfiguration.ephemeral.protocolClasses = [MockURLProtocol.self]`。
final class MockURLProtocol: URLProtocol {

    /// 全局 handler：由测试设置，返回 (HTTPURLResponse, Data) 或抛错（模拟网络失败）。
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    /// 记录所有被拦截的请求（顺序），供断言。
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.recordedRequests.append(request)
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// 构造 JSON 响应。
func jsonResponse(_ status: Int, json: Any) -> (HTTPURLResponse, Data) {
    let data = try! JSONSerialization.data(withJSONObject: json)
    let response = HTTPURLResponse(
        url: URL(string: "http://mock.local/api/v1")!,
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, data)
}

/// 标准注册响应（interval=20s / timeout=60s）。
func registerResponseJSON(app: String, did: String) -> [String: Any] {
    [
        "device": [
            "app": app,
            "did": did,
            "status": "idle",
            "lastSeenAt": "2026-09-19T00:00:00Z",
            "registeredAt": "2026-09-19T00:00:00Z",
        ],
        "serverConfig": [
            "heartbeatIntervalSeconds": 20,
            "heartbeatTimeoutSeconds": 60,
        ],
    ]
}

/// 标准心跳响应。
func heartbeatResponseJSON(session: [String: Any]?) -> [String: Any] {
    var json: [String: Any] = [
        "ok": true,
        "serverTime": "2026-09-19T00:00:00Z",
        "serverConfig": [
            "heartbeatIntervalSeconds": 20,
            "heartbeatTimeoutSeconds": 60,
        ],
        "rulesVersion": 0,
    ]
    if let session {
        json["session"] = session
    } else {
        json["session"] = NSNull()
    }
    return json
}

/// 会话 JSON。
func sessionJSON(id: String, status: String = "capturing") -> [String: Any] {
    [
        "id": id,
        "app": "com.test.app",
        "did": "did-1",
        "status": status,
        "startedAt": "2026-09-19T00:00:00Z",
        "requestCount": 0,
        "viewerCount": 1,
    ]
}
