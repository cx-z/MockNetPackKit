import Foundation

/// URLProtocol 全局拦截器（M2.4，决策 D-M2-2：URLProtocol 注入，不改业务代码）。
///
/// 工作机制：
/// - 由 `TrafficCaptureController.start` 全局注册（URLProtocol.registerClass），
///   `stop` 注销；是否拦截由静态捕获开关（跟随会话状态）决定，会话未激活时
///   `canInit` 返回 false，对业务零干预（fail-open）。
/// - 拦截的请求由本类转发到真实网络（转发 session 排除本类，避免递归），
///   完成后组装 `TrafficEntry` 交给 `TrafficCaptureController` 攒批上传。
/// - SDK 自身请求（注册/心跳/上传）带 `skipHeader`，`canInit` 直接放行。
///
/// 线程安全：URLProtocol 框架保证同一实例的 startLoading/stopLoading 不并发；
/// 转发完成回调内捕获 self 属受控访问，故声明 @unchecked Sendable。
final class MockNetPackURLProtocol: URLProtocol, @unchecked Sendable {

    /// SDK 自身请求的跳过标记 header（ConnectionClient 统一携带）。
    static let skipHeader = "X-MockNetPack-Skip"

    /// 请求/响应体截断上限（契约 v0.2.0：M2 固定 1MB，不做配置项）。
    static let bodyLimit = 1_048_576

    /// 转发用 URLSessionConfiguration 注入点：测试用 MockURLProtocol 模拟真实网络。
    nonisolated(unsafe) static var forwardingConfiguration: URLSessionConfiguration?

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        guard TrafficCaptureController.shared.isCapturing else { return false }
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        // SDK 自身请求（心跳/注册/上传）不拦截。
        if request.value(forHTTPHeaderField: skipHeader) != nil { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var startTime = Date()
    private var forwardingTask: URLSessionDataTask?
    private var forwardingSession: URLSession?

    override func startLoading() {
        startTime = Date()

        // M3.4：先查本地 Mock 快照。命中则直接合成回包，不转发真实网络。
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        if let mock = MockRuleController.shared.match(method: method, path: path) {
            serve(mock: mock, method: method, path: path)
            return
        }

        // 请求体：URLSession 可能把 httpBody 转为 httpBodyStream。先取 body 用于
        // 采集；若为 stream 则读出来重建 httpBody，保证转发请求不丢 body。
        var forwarded = request
        let bodyData = Self.readBody(of: request, rewriting: &forwarded)

        // 转发请求去掉 SDK 跳过标记（不要发给真实服务器）。
        forwarded.setValue(nil, forHTTPHeaderField: Self.skipHeader)

        let session = URLSession(configuration: Self.forwardingConfiguration ?? Self.defaultForwardingConfiguration())
        forwardingSession = session

        let task = session.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            self.forwardingSession = nil
            self.record(bodyData: bodyData, data: data, response: response, error: error)

            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data, !data.isEmpty {
                self.client?.urlProtocol(self, didLoad: data)
            }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        forwardingTask = task
        task.resume()
    }

    override func stopLoading() {
        forwardingTask?.cancel()
        forwardingSession?.invalidateAndCancel()
        forwardingSession = nil
    }

    // MARK: - Mock 回包（M3.4）

    /// 命中本地 Mock 规则：合成 HTTP 响应直接回给原请求者，不转发真实网络，
    /// 同时记一条 mocked=true 的临时流量（会话结束随临时流量清空）。
    private func serve(mock: MockResponse, method: String, path: String) {
        let url = request.url ?? URL(string: "http://localhost/")!
        var headerFields = mock.headers ?? [:]
        if headerFields["Content-Type"] == nil {
            headerFields["Content-Type"] = "application/json"
        }
        let response = HTTPURLResponse(
            url: url, statusCode: mock.statusCode,
            httpVersion: "HTTP/1.1", headerFields: headerFields)
        let data = Data((mock.body ?? "").utf8)

        // 记录一条 Mock 命中流量。
        var reqHeaders: [String: [String]] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            reqHeaders[key] = [value]
        }
        let entry = TrafficEntry(
            timestamp: startTime,
            method: method,
            url: url.absoluteString,
            path: path,
            query: url.query ?? "",
            requestHeaders: reqHeaders,
            requestBody: "",
            statusCode: mock.statusCode,
            responseHeaders: headerFields.mapValues { [$0] },
            responseBody: mock.body,
            error: nil,
            durationMs: max(0, Int(Date().timeIntervalSince(startTime) * 1000)),
            mocked: true
        )
        TrafficCaptureController.shared.record(entry)

        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    // MARK: - 采集

    /// 组装 TrafficEntry 并交给采集器（攒批/上传）。
    private func record(bodyData: Data?, data: Data?, response: URLResponse?, error: Error?) {
        let durationMs = max(0, Int(Date().timeIntervalSince(startTime) * 1000))
        let http = response as? HTTPURLResponse

        var headers: [String: [String]] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            headers[key] = [value]
        }

        var entry = TrafficEntry(
            timestamp: startTime,
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            path: request.url?.path ?? "",
            query: request.url?.query ?? "",
            requestHeaders: headers,
            requestBody: Self.sanitizedBody(bodyData),
            statusCode: http?.statusCode,
            responseHeaders: http.map { Self.headerFields($0.allHeaderFields) },
            responseBody: data.map(Self.sanitizedBody),
            error: error?.localizedDescription,
            durationMs: durationMs
        )
        // 失败请求不保留状态码/响应字段（契约：statusCode 等为空）。
        if error != nil {
            entry.statusCode = nil
            entry.responseHeaders = nil
            entry.responseBody = nil
        }
        TrafficCaptureController.shared.record(entry)
    }

    // MARK: - 辅助

    /// 默认转发配置：ephemeral（不缓存），并排除本类避免递归。
    private static func defaultForwardingConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = config.protocolClasses?.filter { $0 != MockNetPackURLProtocol.self } ?? []
        return config
    }

    /// 读取请求体；若 body 在 stream 中则重建为 httpBody（保证转发不丢）。
    private static func readBody(of request: URLRequest, rewriting forwarded: inout URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&chunk, maxLength: chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
        }
        if !buffer.isEmpty {
            forwarded.httpBody = buffer
        }
        return buffer
    }

    /// 响应头（HTTPURLResponse 的 [AnyHashable: Any] → [String: [String]]）。
    private static func headerFields(_ fields: [AnyHashable: Any]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (key, value) in fields {
            guard let k = key as? String else { continue }
            out[k] = [String(describing: value)]
        }
        return out
    }

    /// body 治理：超 1MB 截断；无法 UTF-8 解码的二进制以 "[binary N bytes]" 占位（契约）。
    static func sanitizedBody(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "" }
        let sample = data.count > bodyLimit ? data.prefix(bodyLimit) : data[...]
        if let text = String(data: Data(sample), encoding: .utf8) {
            return text
        }
        return "[binary \(data.count) bytes]"
    }
}
