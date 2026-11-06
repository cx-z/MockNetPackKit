import Foundation

/// URLProtocol 全局拦截器。
///
/// 工作机制：
/// - 由 `TrafficCaptureController.start` 全局注册（URLProtocol.registerClass），
///   `stop` 注销；首次心跳前仅转发并有界暂存，已确认 idle 时不接管。
/// - 拦截的请求由本类转发到真实网络（转发 session 排除本类，避免递归），
///   完成后组装 `TrafficEntry` 交给 `TrafficCaptureController` 攒批上传。
/// - SDK 自身请求（注册/心跳/上传）带 `skipHeader`，`canInit` 直接放行。
///
/// 线程安全：URLProtocol 框架保证同一实例的 startLoading/stopLoading 不并发；
/// 转发完成回调内捕获 self 属受控访问，故声明 @unchecked Sendable。
final class MockNetPackURLProtocol: URLProtocol, @unchecked Sendable {

    /// SDK 自身请求的跳过标记 header（ConnectionClient 统一携带）。
    static let skipHeader = "X-MockNetPack-Skip"

    /// 请求/响应体截断上限（契约：固定 1MB，不做配置项）。
    static let bodyLimit = 1_048_576

    /// 请求体读取超时（4.21）：`readBody` 在 URL 加载线程上轮询
    /// `Thread.sleep(0.002)` 等待"数据未就绪"的流，若无界会挂死该线程。
    /// 2s 远超正常缓冲体（内存/文件流）的读取耗时（毫秒级）；触底即返回
    /// 已读部分，请求照常发出（尽力而为），绝不无限等待。
    static let readBodyTimeout: TimeInterval = 2

    /// 转发用 URLSessionConfiguration 注入点：测试用 MockURLProtocol 模拟真实网络。
    nonisolated(unsafe) static var forwardingConfiguration: URLSessionConfiguration?

    // MARK: - 302 回放放行缓存

    /// 302/301/303/307/308 回放后短期放行 Location URL，避免 App 跟随重定向时被
    /// SDK 再次拦截造成死循环。key = URL.absoluteString，value = 加入时间。
    /// 线程安全由 redirectWhitelistLock 保护。
    nonisolated(unsafe) private static var redirectWhitelist: [String: Date] = [:]
    private static let redirectWhitelistLock = NSLock()
    /// 放行缓存 TTL（秒）。App 跟随 302 通常在毫秒级内完成；5 秒足够覆盖正常
    /// 重定向生命周期，同时避免长期放行新的真实请求。
    static let redirectWhitelistTTL: TimeInterval = 5

    /// 把 URL 加入短期放行缓存（302 回放时调用）。
    static func addRedirectWhitelist(urlString: String) {
        redirectWhitelistLock.lock()
        defer { redirectWhitelistLock.unlock() }
        // 顺便清理过期条目，避免缓存无限增长。
        let now = Date()
        redirectWhitelist = redirectWhitelist.filter { now.timeIntervalSince($0.value) < redirectWhitelistTTL }
        redirectWhitelist[urlString] = now
    }

    /// 检查 URL 是否在放行缓存中（未过期）。
    static func isWhitelisted(urlString: String) -> Bool {
        redirectWhitelistLock.lock()
        defer { redirectWhitelistLock.unlock() }
        guard let added = redirectWhitelist[urlString] else { return false }
        return Date().timeIntervalSince(added) < redirectWhitelistTTL
    }

    // MARK: - URLProtocol

    /// 仅接管启动握手或有效会话中的 HTTP，SDK 自身请求始终放行。
    override class func canInit(with request: URLRequest) -> Bool {
        guard TrafficCaptureController.shared.httpCaptureGeneration != nil else { return false }
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        // SDK 自身请求（心跳/注册/上传）不拦截。
        if request.value(forHTTPHeaderField: skipHeader) != nil { return false }
        // 302 回放跟随的请求短期放行，避免死循环。
        if let urlString = request.url?.absoluteString, isWhitelisted(urlString: urlString) {
            return false
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var startTime = Date()
    private var forwardingTask: URLSessionDataTask?
    /// 全局共享的转发 session：每个请求新建 session 会导致 TLS 连接不复用、
    /// 每次都重新握手（~1s），是  真机"连 SDK 后所有请求慢 1s"的根因。
    /// URLSession 本身线程安全，completionHandler 模式可安全共享。
    nonisolated(unsafe) private static var sharedForwardingSession: URLSession?
    private static let sessionLock = NSLock()
    /// 在 init 阶段预读的请求体。URLSession 把 httpBody 转成 stream 传给 URLProtocol，
    /// 且 stream 在 startLoading 前已被 URLSession 预读过一次（算 Content-Length），
    /// 到 startLoading 时再读就是空的；必须在 init 时抢读。
    private var capturedBody: Data?
    /// 请求创建时绑定的采集代次；idle/stop/会话切换后到达的回包不能混入新会话。
    private let captureGeneration: UInt64?
    /// stopLoading 置位：Mock delay 等待期间被取消则不再回包、不再记录流量。
    private var cancelled = false
    /// 终态记录器：独立于本实例持有记录快照，避免 stopLoading 后实例释放导致超时/取消漏记。
    private let recorder: TrafficTerminalRecorder?

    /// 懒创建全局共享转发 session；创建前标记该配置为"SDK 自身转发"，
    /// 让会话级兜底注入跳过它，避免转发请求被拦截器再次拦截形成递归。
    private static func sharedSession() -> URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let s = sharedForwardingSession { return s }
        let config = forwardingConfiguration ?? defaultForwardingConfiguration()
        URLSessionConfigurationInjector.markAsForwardingSession(config)
        let s = URLSession(configuration: config)
        sharedForwardingSession = s
        return s
    }

    /// 绑定采集代次并在系统预读前保存请求体，同时创建独立终态记录器；
    /// 之后的会话变更只影响记录，不中断业务转发。
    override init(request: URLRequest, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        self.captureGeneration = TrafficCaptureController.shared.httpCaptureGeneration
        //  修复：在 init 阶段就读 stream，此时 stream 还未被 URLSession 预读。
        var rq = request
        let body = Self.readBody(of: request, rewriting: &rq)
        self.capturedBody = body
        self.recorder = TrafficTerminalRecorder(
            startTime: Date(),
            request: request,
            requestBody: body,
            captureGeneration: self.captureGeneration,
            controller: TrafficCaptureController.shared
        )
        super.init(request: rq, cachedResponse: cachedResponse, client: client)
    }

    /// 门闩接管期内尝试 Mock，否则立即转发真实请求；启动握手不等待平台、不应用旧规则。
    override func startLoading() {
        startTime = Date()

        // iOS-AN9：门闩期（capturing 或 启动缓冲）即匹配 Mock——canInit 已保证
        // httpCaptureGeneration != nil（startLoading 仅在 canInit 通过后调用）。
        // 去掉原 isCapturing 限定：启动握手期（注册/首心跳前）的请求也能命中磁盘
        // 快照 Mock；快照为空（从未同步 / 断连保护已清空）→ match 返回 nil →
        // 转发真实网络（fail-open A 不变）。
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        if let mock = MockRuleController.shared.match(method: method, path: path) {
            serve(mock: mock, method: method, path: path)
            return
        }

        // 请求体：init 阶段已抢读到 capturedBody。转发时重建 httpBody，保证不丢 body。
        var forwarded = request
        let bodyData = self.capturedBody
        if let bodyData = bodyData, forwarded.httpBody == nil {
            forwarded.httpBody = bodyData
        }

        // 转发请求去掉 SDK 跳过标记（不要发给真实服务器）。
        forwarded.setValue(nil, forHTTPHeaderField: Self.skipHeader)

        let session = Self.sharedSession()

        let task = session.dataTask(with: forwarded) { [weak self, recorder] data, response, error in
            // 终态记录不依赖 self：原请求超时/取消时 protocol 已先释放，弱引用会让整条记录丢失。
            recorder?.finish(response: response, data: data, error: error)
            guard let self else { return }

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

    /// 原请求超时或取消时由 URL 加载系统调用：标记中止原因并取消转发任务，
    /// 记录由转发完成回调落库（1s 兜底防极端情况下不回调）；Mock 路径不产生终态记录。
    override func stopLoading() {
        cancelled = true
        // 只有真正转发过的请求才有"客户端中止"终态；Mock 回包路径取消由 serve 自身处理，
        // 不生成流量记录（保持既有语义）。
        guard let forwardingTask, let recorder else {
            // 注意：不 invalidate 全局共享 session，否则会杀掉所有在飞的转发连接。
            return
        }
        // 先标记客户端中止并推断超时/取消，再取消转发任务；记录由转发完成回调兜底落库。
        recorder.markClientAborted(at: Date())
        forwardingTask.cancel()
        // 兜底：共享 session 被系统回收等极端情况下转发任务可能不再回调，1s 后强制补一条终态。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            recorder.finishWithoutCompletion()
        }
    }

    // MARK: - Mock 回包

    /// 命中本地 Mock 规则：合成 HTTP 响应直接回给原请求者，不转发真实网络，
    /// 同时按请求代次记一条 mocked=true 的临时流量（会话结束随临时流量清空）。
    private func serve(mock: MockResponse, method: String, path: String) {
        let url = request.url ?? URL(string: "http://localhost/")!
        var headerFields = mock.headers ?? [:]
        if headerFields["Content-Type"] == nil {
            headerFields["Content-Type"] = "application/json"
        }
        //  修复：删除动态密钥轮换 header（x-xc-proto-res）。
        // mock 快照是历史捕获的，其 x-xc-proto-res 是当时的旧密钥；
        // 若回放给接入方，responseComplete 会把旧密钥设为当前密钥，
        // 导致后续所有真实请求用过期密钥加密 → 服务器无法解密 → 全部 96 字节错误。
        // 删除后接入方收不到密钥更新指令，继续用当前密钥，不影响 mock 回放本身。
        headerFields = headerFields.filter { key, _ in
            !key.lowercased().contains("proto-res")
        }
        let response = HTTPURLResponse(
            url: url, statusCode: mock.statusCode,
            httpVersion: "HTTP/1.1", headerFields: headerFields)

        // 302 回放死循环修复：回放 3xx 重定向时，把 Location URL 加入短期放行缓存，
        // App 跟随重定向到该 URL 时 canInit 直接放行，不再匹配规则，避免无限 302 循环。
        // 注意：在 fire closure 里打标（实际投递时），而不是 serve() 阶段——否则
        // delayMs > 0 时 TTL 从 serve() 开始算，302 还没送到 App 缓存就过期了。
        // Location header 查找大小写不敏感（HTTP header 名本就大小写不敏感，
        // 历史快照里 key 可能是 location/Location/LOCATION）。
        let redirectCodes: Set<Int> = [301, 302, 303, 307, 308]
        let redirectLocation: String? = {
            guard redirectCodes.contains(mock.statusCode) else { return nil }
            // 大小写不敏感查找 Location header。
            for (key, value) in headerFields where key.lowercased() == "location" {
                return value
            }
            return nil
        }()
        //  回放三级 fallback：
        // ① bodyBase64 有原始字节 → 按原始字节回放（未编辑的二进制规则，"Mock 此请求"直接启用）
        // ② body 有编辑过的文本 + encoder 可用 → 编码回私有二进制协议字节（Web 编辑生效）
        // ③ 否则 → UTF-8 文本直传（纯文本 JSON 接口）
        // 调整原因：未编辑二进制规则的 body 是 "[binary N bytes]" 占位文本（非空），
        // 若 encoder 优先会把占位文本编码回放导致 App 解析失败；编辑保存时 Web 本就清除
        // bodyBase64，因此原始字节优先不影响已编辑规则（它们已无 bodyBase64）。
        let contentType = headerFields["Content-Type"]
        let data: Data
        if let b64 = mock.bodyBase64, let decoded = Data(base64Encoded: b64), !decoded.isEmpty {
            data = decoded
        } else if let text = mock.body, !text.isEmpty,
                  let encoder = TrafficCaptureController.shared.bodyEncoder,
                  let encoded = encoder(text, contentType) {
            data = encoded
        } else {
            data = Data((mock.body ?? "").utf8)
        }

        // Mock 回包延迟：命中规则后等待 delayMs 毫秒再回包。
        // durationMs = 实际回包时刻 - startTime（请求到达时刻），故自然包含 delay；
        // record 与 client 三段回包都放在 fire 里：延迟期间被 stopLoading 取消时，
        // 既不回包也不留这条流量。
        let delay = mock.delayMs ?? 0
        let fire: () -> Void = { [weak self] in
            guard let self, !self.cancelled else { return }

            // 记录一条 Mock 命中流量。：同时捕获真实请求体（ 已知行为修复）。
            //  修复：请求体在 init 阶段已抢读到 capturedBody（此后 stream 已耗尽），
            // 此处必须复用 capturedBody，不能重读 request（会读到空体）。
            let reqBodyData = self.capturedBody
            let reqParts = Self.bodyParts(reqBodyData)
            var reqHeaders: [String: [String]] = [:]
            for (key, value) in self.request.allHTTPHeaderFields ?? [:] {
                reqHeaders[key] = [value]
            }
            var entry = TrafficEntry(
                timestamp: self.startTime,
                method: method,
                url: url.absoluteString,
                path: path,
                query: url.query ?? "",
                requestHeaders: reqHeaders,
                requestBody: reqParts.text,
                requestBodyBase64: reqParts.base64,
                requestBodyDecoded: Self.decodedBody(reqBodyData, contentType: self.request.value(forHTTPHeaderField: "Content-Type"), isRequest: true),
                statusCode: mock.statusCode,
                responseHeaders: headerFields.mapValues { [$0] },
                responseBody: mock.body,
                responseBodyBase64: mock.bodyBase64,
                error: nil,
                durationMs: max(0, Int(Date().timeIntervalSince(self.startTime) * 1000)),
                mocked: true,
                matchedRuleId: mock.ruleId
            )
            // mock 命中流量同样尝试解码展示（与真实抓包一致，仅展示；回放仍为
            // bodyBase64 原始字节）。二进制规则（"Mock 此请求"创建）未编辑时 body 是
            // "[binary N bytes]" 占位，补上解码文本后请求流里也能看到 JSON 详情。
            if !data.isEmpty {
                entry.responseBodyDecoded = Self.decodedBody(data, contentType: contentType)
            }
            if let generation = self.captureGeneration {
                TrafficCaptureController.shared.record(entry, generation: generation)
            }

            guard let response else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            // 实际投递 3xx 响应时，才把 Location URL 加入放行缓存。
            // TTL 从投递时刻开始算，与 delayMs 解耦；取消投递则不打标。
            if let location = redirectLocation, !location.isEmpty {
                let resolvedURL = URL(string: location, relativeTo: url) ?? URL(string: location)
                if let resolved = resolvedURL?.absoluteString {
                    Self.addRedirectWhitelist(urlString: resolved)
                }
            }
            self.deliverMockResponse(response: response, data: data)
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delay), execute: fire)
        } else {
            fire()
        }
    }

    /// 把组装好的 Mock 回包三段式交给 URLProtocolClient（didReceive / didLoad /
    /// didFinishLoading）。delay 到期后异步调用，或 delayMs=0/nil 时立即同步调用。
    private func deliverMockResponse(response: HTTPURLResponse, data: Data) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    // MARK: - 辅助

    /// 默认转发配置：ephemeral（不缓存），并排除本类避免递归。
    private static func defaultForwardingConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = config.protocolClasses?.filter { $0 != MockNetPackURLProtocol.self } ?? []
        return config
    }

    /// 读取请求体；若 body 在 stream 中则重建为 httpBody（保证转发不丢）。
    ///  修复：用 hasBytesAvailable 判断是否还有数据，而不是 read 返回值。
    /// 原因：InputStream.read 在数据异步到达时会返回 0（非 EOF，只是"数据未就绪"），
    /// 之前用 n<=0 break 会导致只读到部分 body，服务器解密失败返回错误 key。
    /// 4.21 修复：轮询以 `readBodyTimeout` 为总预算（确定性上限），流始终不
    /// EOF 时在截止时间返回已读部分，不再无限 `Thread.sleep` 挂死 URL 加载
    /// 线程。不用异步读取：URLProtocol.init 签名固定为同步，startLoading 又
    /// 需要同步拿到重写后的 body（httpBodyStream 一经本类读取即被消耗），
    /// 异步方案会让"已读未转发"的 body 状态不可判定，故采用带超时的确定性读取。
    private static func readBody(of request: URLRequest, rewriting forwarded: inout URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(readBodyTimeout)
        while stream.hasBytesAvailable && Date() < deadline {
            let n = stream.read(&chunk, maxLength: chunk.count)
            if n > 0 {
                buffer.append(chunk, count: n)
            } else if n == 0 {
                // read 返回 0 但 hasBytesAvailable=yes：数据未就绪，短暂等待
                Thread.sleep(forTimeInterval: 0.002)
            } else {
                // n < 0：错误，跳出
                break
            }
        }
        if !buffer.isEmpty {
            forwarded.httpBody = buffer
            // 关键防御：stream 已被读出并 close，必须清空，否则 URLSession 可能误用
            // 这个已关闭的 stream 作为 body（引用类型拷贝仍指向同一 stream），导致转发空 body。
            forwarded.httpBodyStream = nil
        }
        return buffer
    }

    /// 响应头（HTTPURLResponse 的 [AnyHashable: Any] → [String: [String]]）。
    static func headerFields(_ fields: [AnyHashable: Any]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (key, value) in fields {
            guard let k = key as? String else { continue }
            out[k] = [String(describing: value)]
        }
        return out
    }

    /// body 治理：超 1MB 截断；无法 UTF-8 解码的二进制以 "[binary N bytes]" 占位（契约）。
    static func sanitizedBody(_ data: Data?) -> String {
        bodyParts(data).text
    }

    /// 用 App 注入的解码器把二进制 body（如 xcp AES+gzip）解成可读 UTF-8 文本
    /// （ 响应体 /  请求体；仅展示）。失败或未注册解码器返回 nil。
    /// 解码用与 base64 相同的截断样本（1MB 上限），入参可为未截断原始数据。
    /// - Parameter isRequest: true 走请求体专用解码槽位（业务请求体/响应体编码不对称时
    ///   由 registerBinaryCodec 的 requestDecrypt 单独提供）；false 走响应体解码槽位。
    static func decodedBody(_ data: Data?, contentType: String?, isRequest: Bool = false) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let decoder = isRequest
            ? TrafficCaptureController.shared.requestBodyDecoder
            : TrafficCaptureController.shared.bodyDecoder
        guard let decoder else { return nil }
        let sample = data.count > bodyLimit ? Data(data.prefix(bodyLimit)) : data
        return decoder(sample, contentType)
    }

    /// 返回 (展示文本, base64)。二进制时展示为占位文本、base64 携带原始字节；
    /// 文本时 base64 为 nil（无需额外体积）。
    static func bodyParts(_ data: Data?) -> (text: String, base64: String?) {
        guard let data, !data.isEmpty else { return ("", nil) }
        let sample = data.count > bodyLimit ? data.prefix(bodyLimit) : data[...]
        let truncated = Data(sample)
        if let text = String(data: truncated, encoding: .utf8) {
            return (text, nil)
        }
        // 二进制：保留原始字节的 base64（用于 Mock 回放）。
        return ("[binary \(data.count) bytes]", truncated.base64EncodedString())
    }
}
