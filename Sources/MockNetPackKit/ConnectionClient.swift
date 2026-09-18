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
}

/// 极简 JSON HTTP 客户端。
///
/// 设计为值类型（struct + Sendable，无共享状态），通过注入
/// `URLSessionConfiguration` 支持测试（MockURLProtocol）。
struct ConnectionClient: Sendable {
    let session: URLSession
    let baseURL: URL
    let requestTimeout: TimeInterval

    init(configuration: URLSessionConfiguration = .default,
         baseURL: URL,
         requestTimeout: TimeInterval = 10) {
        self.session = URLSession(configuration: configuration)
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
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
            (data, response) = try await session.data(for: request)
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
}
