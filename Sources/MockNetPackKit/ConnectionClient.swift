import Foundation

/// 连接层 HTTP 错误。
enum ConnectionClientError: Error {
    /// 非 2xx 响应。
    case httpStatus(Int)
    /// 请求体编码失败。
    case encoding(Error)
    /// 响应解码失败。
    case decoding(Error)
    /// 无法构造 URL。
    case invalidURL
    /// 响应数据与错误均为空（正常路径不应出现）。
    case invalidResponse
}

/// 极简 JSON HTTP 客户端。
///
/// 设计为值类型（struct + Sendable，无共享状态），通过注入
/// `URLSessionConfiguration` 支持测试（MockURLProtocol）。
///
/// 所有 SDK 自身请求（注册/心跳/流量上传）携带跳过标记 header：
/// `MockNetPackURLProtocol.canInit` 据此放行，避免抓包器递归拦截自身流量。
///
/// 4.20：默认复用进程级单一 `URLSession`（`sharedSession`），不再每次
/// 心跳/刷包 `new URLSession`——每个 session 都有独立 delegate 队列与连接
/// 池，3~5s 一次的创建频率纯属浪费。测试仍可通过 `configuration:` 注入
/// 专用 session（MockURLProtocol）。
struct ConnectionClient: Sendable {
    let session: URLSession
    let baseURL: URL
    let requestTimeout: TimeInterval

    init(configuration: URLSessionConfiguration? = nil,
         baseURL: URL,
         requestTimeout: TimeInterval = 10) {
        if let configuration = configuration {
            self.session = URLSession(configuration: configuration)
        } else {
            self.session = ConnectionClient.sharedSession
        }
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }

    /// 进程级共享会话（4.20）：注册/心跳/流量上传/规则拉取全部复用一个
    /// 连接池。惰性创建；即便 App 层抓包注入已启用，SDK 自身请求带
    /// skipHeader，`MockNetPackURLProtocol.canInit` 会放行，不会递归抓自身。
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// 发起 URLSession 请求并以 async/await 返回原始响应。
    ///
    /// 统一走 completion-handler 版 `dataTask(with:)` 并桥接 Continuation：
    /// `URLSession.data(for:)`（async 版）仅 iOS 15+ 可用，而 SDK 最低部署
    /// 目标为 iOS 13，低版本设备经此路径执行；超时与网络错误原样上抛。
    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: ConnectionClientError.invalidResponse)
                }
            }.resume()
        }
    }

    /// 发起 JSON POST 并解码响应。
    func post<Body: Encodable, Resp: Decodable>(
        _ path: String,
        body: Body?,
        as type: Resp.Type
    ) async throws -> Resp {
        // 注意：不能用 URL(string:relativeTo:) 直接拼接——base 路径
        // "…/api/v1" 会被相对路径 "devices/register" 的末段替换。手工拼绝对 URL。
        let base = baseURL.absoluteString.hasSuffix("/")
            ? baseURL.absoluteString
            : baseURL.absoluteString + "/"
        guard let url = URL(string: base + path) else {
            throw ConnectionClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: MockNetPackURLProtocol.skipHeader)

        if let body = body {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw ConnectionClientError.encoding(error)
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch {
            throw error  // 网络层错误原样上抛（ConnectionController 据此退避重连）
        }

        guard let http = response as? HTTPURLResponse else {
            throw ConnectionClientError.httpStatus(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ConnectionClientError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw ConnectionClientError.decoding(error)
        }
    }

    /// 发起 JSON GET 并解码响应（M3：规则增量拉取）。
    func get<Resp: Decodable>(_ path: String, as type: Resp.Type) async throws -> Resp {
        let base = baseURL.absoluteString.hasSuffix("/")
            ? baseURL.absoluteString
            : baseURL.absoluteString + "/"
        guard let url = URL(string: base + path) else {
            throw ConnectionClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: MockNetPackURLProtocol.skipHeader)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch {
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw ConnectionClientError.httpStatus(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ConnectionClientError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw ConnectionClientError.decoding(error)
        }
    }

    /// 轻量可达性探测（M11-2）：GET 一个必然 404 的路径，收到任何 HTTP 响应
    /// （含 404）即视为连通——用于扫码连接前触发/验证 iOS「本地网络」权限
    /// （首次访问局域网地址的连接会因未授权被系统拒绝，传输层错误在此上抛）。
    func probe() async throws {
        let base = baseURL.absoluteString.hasSuffix("/")
            ? baseURL.absoluteString
            : baseURL.absoluteString + "/"
        guard let url = URL(string: base + "__mocknetpack_probe__") else {
            throw ConnectionClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        request.setValue("1", forHTTPHeaderField: MockNetPackURLProtocol.skipHeader)
        _ = try await perform(request)
    }
}
