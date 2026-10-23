import Foundation

/// 测试辅助：拦截 URLSession 请求，按预设 handler 返回响应。
/// 使用方式：注入 `URLSessionConfiguration.ephemeral.protocolClasses = [MockURLProtocol.self]`。
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var handlerValue: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var deferredHandlerValue: (@Sendable (MockURLProtocol) -> Bool)?
    nonisolated(unsafe) private static var requestsValue: [URLRequest] = []
    private let completionLock = NSLock()
    private var finished = false

    /// 全局 handler：由测试设置，返回 (HTTPURLResponse, Data) 或抛错（模拟网络失败）。
    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return handlerValue }
        set { stateLock.lock(); defer { stateLock.unlock() }; handlerValue = newValue }
    }

    /// 可选异步响应入口：返回 true 表示测试持有请求，稍后通过 respond 回包，不阻塞加载线程。
    static var deferredHandler: (@Sendable (MockURLProtocol) -> Bool)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return deferredHandlerValue }
        set { stateLock.lock(); defer { stateLock.unlock() }; deferredHandlerValue = newValue }
    }

    /// 记录所有被拦截的请求（顺序），供断言。
    static var recordedRequests: [URLRequest] {
        get { stateLock.lock(); defer { stateLock.unlock() }; return requestsValue }
        set { stateLock.lock(); defer { stateLock.unlock() }; requestsValue = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// 锁内记录请求并取得处理器快照；锁外执行测试闭包，允许并发上传或延迟首次心跳。
    override func startLoading() {
        Self.stateLock.lock()
        Self.requestsValue.append(request)
        let handler = Self.handlerValue
        let deferred = Self.deferredHandlerValue
        Self.stateLock.unlock()
        if deferred?(self) == true { return }
        guard let handler else {
            respond(.failure(URLError(.unsupportedURL)))
            return
        }
        do {
            respond(.success(try handler(request)))
        } catch {
            respond(.failure(error))
        }
    }

    /// 只交付一次响应；取消与异步释放心跳共享同一完成标记，回调在锁外执行。
    func respond(_ result: Result<(HTTPURLResponse, Data), Error>) {
        completionLock.lock()
        guard !finished else { completionLock.unlock(); return }
        finished = true
        completionLock.unlock()
        switch result {
        case .success(let (response, data)):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    /// 取消后忽略测试稍后释放的延迟响应。
    override func stopLoading() {
        completionLock.lock(); defer { completionLock.unlock() }
        finished = true
    }
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
func heartbeatResponseJSON(session: [String: Any]?, rulesVersion: Int = 0) -> [String: Any] {
    var json: [String: Any] = [
        "ok": true,
        "serverTime": "2026-09-19T00:00:00Z",
        "serverConfig": [
            "heartbeatIntervalSeconds": 20,
            "heartbeatTimeoutSeconds": 60,
        ],
        "rulesVersion": rulesVersion,
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
