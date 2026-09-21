import XCTest
@testable import MockNetPackKit

/// M2.4：URLProtocol 拦截/转发 + TrafficCaptureController 攒批上传。
final class TrafficCaptureTests: XCTestCase {

    /// 测试用可变状态容器（@Sendable 闭包内安全捕获）。
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private let serverURL = URL(string: "http://mock.local/api/v1")!
    private let appID = "com.test.app"
    private let did = "did-1"

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()
        MockNetPackURLProtocol.forwardingConfiguration = nil

        let controller = TrafficCaptureController.shared
        // 上传客户端：MockURLProtocol 拦截，返回固定响应。
        let uploadConfig = URLSessionConfiguration.ephemeral
        uploadConfig.protocolClasses = [MockURLProtocol.self]
        controller.clientFactory = { [uploadConfig] url in
            ConnectionClient(configuration: uploadConfig, baseURL: url)
        }
        controller.flushInterval = 0.1
    }

    override func tearDown() {
        TrafficCaptureController.shared.stop()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()
        MockNetPackURLProtocol.forwardingConfiguration = nil
        super.tearDown()
    }

    // MARK: - 辅助

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("condition not met within \(timeout)s")
    }

    /// 请求体（JSON 字典）。URLSession 可能转 httpBodyStream，两者都读。
    private func bodyOfRequest(_ request: URLRequest) -> [String: Any]? {
        let data: Data?
        if let httpBody = request.httpBody {
            data = httpBody
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&chunk, maxLength: chunk.count)
                if n <= 0 { break }
                buffer.append(chunk, count: n)
            }
            data = buffer
        } else {
            data = nil
        }
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 构造一条测试 TrafficEntry。
    private func makeEntry(method: String = "GET", url: String = "https://api.example.com/v1/users?page=2") -> TrafficEntry {
        TrafficEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            method: method,
            url: url,
            path: "/v1/users",
            query: "page=2",
            requestHeaders: ["Content-Type": ["application/json"]],
            requestBody: #"{"q":"1"}"#,
            statusCode: 200,
            responseHeaders: ["Content-Type": ["application/json"]],
            responseBody: #"{"ok":true}"#,
            error: nil,
            durationMs: 12
        )
    }

    // MARK: - 拦截与转发

    /// 全链路：capturing 时请求被 MockNetPackURLProtocol 拦截 → 转发到
    /// MockURLProtocol（模拟真实网络）→ 原请求者收到响应 → 条目攒批上传。
    func testCaptureForwardsResponseAndUploadsEntry() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")

        // 转发目标 = MockURLProtocol（模拟真实网络）；上传 = MockURLProtocol（记录请求）。
        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return jsonResponse(202, json: ["accepted": true, "count": 1])
            }
            return jsonResponse(200, json: ["ok": true])
        }

        // 发起请求：显式配置确保走 MockNetPackURLProtocol。
        let clientConfig = URLSessionConfiguration.ephemeral
        clientConfig.protocolClasses = [MockNetPackURLProtocol.self]
        let session = URLSession(configuration: clientConfig)
        var req = URLRequest(url: URL(string: "https://api.example.com/v1/users?page=2")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"name":"alice"}"#.utf8)

        let received = Box<Data?>(nil)
        let exp = expectation(description: "request completes")
        session.dataTask(with: req) { data, _, _ in
            received.value = data
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 3)

        // 原请求者收到转发后的响应（URLProtocol 链路完整）。
        XCTAssertEqual(received.value, Data(#"{"ok":true}"#.utf8))

        // 强制 flush → 上传请求出现。
        controller.flush()
        waitUntil { MockURLProtocol.recordedRequests.contains { $0.url?.path.hasSuffix("/traffic") == true } }

        guard let upload = MockURLProtocol.recordedRequests.first(where: { $0.url?.path.hasSuffix("/traffic") == true }),
              let body = bodyOfRequest(upload) else {
            return XCTFail("traffic upload request not found")
        }
        XCTAssertEqual(body["app"] as? String, appID)
        XCTAssertEqual(body["did"] as? String, did)
        XCTAssertEqual(body["sessionId"] as? String, "sess-1")
        let entries = body["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 1)
        let entry = entries?.first
        XCTAssertEqual(entry?["method"] as? String, "POST")
        XCTAssertEqual(entry?["url"] as? String, "https://api.example.com/v1/users?page=2")
        XCTAssertEqual(entry?["path"] as? String, "/v1/users")
        XCTAssertEqual(entry?["query"] as? String, "page=2")
        XCTAssertEqual(entry?["statusCode"] as? Int, 200)
        XCTAssertEqual(entry?["requestBody"] as? String, #"{"name":"alice"}"#)
        XCTAssertEqual(entry?["responseBody"] as? String, #"{"ok":true}"#)
        XCTAssertNil(entry?["error"])
        // URLProtocol 层 URLSession 会自动补充 Content-Length，断言仅校验业务头。
        let reqHeaders = entry?["requestHeaders"] as? [String: [String]]
        XCTAssertEqual(reqHeaders?["Content-Type"], ["application/json"])
        XCTAssertNotNil(entry?["timestamp"])
    }

    /// 会话 idle：不拦截、不采集（canInit fail-open，请求走系统网络）。
    func testNoCaptureWhenSessionIdle() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: false, sessionID: nil)

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { _ in
            throw URLError(.badServerResponse)  // 若被拦截转发，这里会抛错并被记录
        }

        let clientConfig = URLSessionConfiguration.ephemeral
        clientConfig.protocolClasses = [MockNetPackURLProtocol.self]
        let session = URLSession(configuration: clientConfig)
        let exp = expectation(description: "request completes (unintercepted)")
        session.dataTask(with: URL(string: "http://127.0.0.1:1/nope")!) { _, _, _ in
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 3)

        controller.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let trafficUploads = MockURLProtocol.recordedRequests.filter { $0.url?.path.hasSuffix("/traffic") == true }
        XCTAssertTrue(trafficUploads.isEmpty, "idle 状态不应有上传")
        // 转发目标（MockURLProtocol）不应收到任何转发请求（127.0.0.1 未拦截）。
        let forwarded = MockURLProtocol.recordedRequests.filter { $0.url?.host == "127.0.0.1" }
        XCTAssertTrue(forwarded.isEmpty, "idle 状态不应转发")
    }

    // MARK: - 攒批与清空

    /// 会话结束（idle）清空待上传批次。
    func testSessionEndClearsPending() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")
        controller.record(makeEntry())
        controller.record(makeEntry(method: "POST"))

        controller.updateSession(capturing: false, sessionID: nil)
        controller.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let trafficUploads = MockURLProtocol.recordedRequests.filter { $0.url?.path.hasSuffix("/traffic") == true }
        XCTAssertTrue(trafficUploads.isEmpty, "会话结束应清空并停止上传")
    }

    /// 上传失败：批次丢弃、不重试；后续新数据正常上传。
    func testUploadFailureDropsBatchWithoutRetry() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")

        let failCount = Box(0)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/traffic") == true {
                failCount.value += 1
                throw URLError(.badServerResponse)  // 500 类失败
            }
            return jsonResponse(200, json: ["ok": true])
        }

        controller.record(makeEntry())
        controller.flush()
        waitUntil { failCount.value >= 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(failCount.value, 1, "失败后不应重试")

        // 新批次可正常上传（handler 恢复成功）。
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return jsonResponse(202, json: ["accepted": true, "count": 1])
            }
            return jsonResponse(200, json: ["ok": true])
        }
        controller.record(makeEntry())
        controller.flush()
        waitUntil {
            MockURLProtocol.recordedRequests.contains {
                $0.url?.path.hasSuffix("/traffic") == true &&
                $0.url?.absoluteString.contains("mock.local") == true
            }
        }
        let uploads = MockURLProtocol.recordedRequests.filter { $0.url?.path.hasSuffix("/traffic") == true }
        XCTAssertEqual(uploads.count, 1, "第二次上传只含新批次")
        guard let body = bodyOfRequest(uploads[0]),
              let entries = body["entries"] as? [[String: Any]] else {
            return XCTFail("upload body missing")
        }
        XCTAssertEqual(entries.count, 1)
    }

    // MARK: - 跳过标记

    /// 带 skip header 的请求（SDK 自身流量）不被拦截。
    func testSkipHeaderNotIntercepted() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { _ in
            throw URLError(.badServerResponse)
        }

        let clientConfig = URLSessionConfiguration.ephemeral
        clientConfig.protocolClasses = [MockNetPackURLProtocol.self]
        let session = URLSession(configuration: clientConfig)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:1/self-traffic")!)
        req.setValue("1", forHTTPHeaderField: MockNetPackURLProtocol.skipHeader)

        let exp = expectation(description: "request completes (skip)")
        session.dataTask(with: req) { _, _, _ in
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 3)

        let forwarded = MockURLProtocol.recordedRequests.filter { $0.url?.host == "127.0.0.1" }
        XCTAssertTrue(forwarded.isEmpty, "skip header 请求不应被拦截转发")
    }

    // MARK: - 注入器

    /// install 后，新建 default/ephemeral 配置携带拦截器类（对业务 URLSession 生效）。
    func testInjectorAddsProtocolToDefaultAndEphemeral() {
        URLSessionConfigurationInjector.install()
        defer { URLSessionConfigurationInjector.uninstall() }

        let defaultHas = URLSessionConfiguration.default.protocolClasses?
            .contains(where: { $0 == MockNetPackURLProtocol.self }) ?? false
        XCTAssertTrue(defaultHas, "default 配置应携带拦截器类")
        let ephemeralHas = URLSessionConfiguration.ephemeral.protocolClasses?
            .contains(where: { $0 == MockNetPackURLProtocol.self }) ?? false
        XCTAssertTrue(ephemeralHas, "ephemeral 配置应携带拦截器类")
        // 幂等：重复 install 不重复追加。
        URLSessionConfigurationInjector.install()
        let count = URLSessionConfiguration.default.protocolClasses?
            .filter { $0 == MockNetPackURLProtocol.self }.count ?? 0
        XCTAssertEqual(count, 1, "重复 install 不应重复追加")
        // 顺序：必须位于最前（系统 http 处理器之前），否则 URLSession 不询问。
        let firstIsOurs = URLSessionConfiguration.default.protocolClasses?
            .first.map { ObjectIdentifier($0) == ObjectIdentifier(MockNetPackURLProtocol.self) } ?? false
        XCTAssertTrue(firstIsOurs, "拦截器必须插到 protocolClasses 最前")
    }

    /// uninstall 后还原：新建配置不再携带拦截器类。
    func testInjectorRestoresAfterUninstall() {
        URLSessionConfigurationInjector.install()
        XCTAssertTrue(URLSessionConfiguration.default.protocolClasses?
            .contains(where: { $0 == MockNetPackURLProtocol.self }) ?? false)

        URLSessionConfigurationInjector.uninstall()
        let has = URLSessionConfiguration.default.protocolClasses?
            .contains(where: { $0 == MockNetPackURLProtocol.self }) ?? false
        XCTAssertFalse(has, "uninstall 后应还原")
    }

    // MARK: - body 治理

    func testSanitizedBody() {
        // 空 body → 空串
        XCTAssertEqual(MockNetPackURLProtocol.sanitizedBody(nil), "")
        XCTAssertEqual(MockNetPackURLProtocol.sanitizedBody(Data()), "")
        // 文本 → 原样
        XCTAssertEqual(MockNetPackURLProtocol.sanitizedBody(Data("hello".utf8)), "hello")
        // 超 1MB → 截断为 1MB
        let big = Data(repeating: 0x61, count: MockNetPackURLProtocol.bodyLimit + 100)  // 'a'
        let truncated = MockNetPackURLProtocol.sanitizedBody(big)
        XCTAssertEqual(truncated.utf8.count, MockNetPackURLProtocol.bodyLimit)
        // 二进制 → 占位
        let binary = Data([0x00, 0xFF, 0x01, 0xFE])
        XCTAssertEqual(MockNetPackURLProtocol.sanitizedBody(binary), "[binary 4 bytes]")
    }

    // MARK: - 请求体解析（M8.1）

    /// xcp 二进制请求体：decoder 解出可读文本 → 上传条目携带 requestBodyDecoded，
    /// requestBody 保持 "[binary N bytes]" 占位、base64 保留原始字节（不参与回放，仅展示）。
    func testBinaryRequestBodyDecodedAndUploaded() throws {
        let controller = TrafficCaptureController.shared
        controller.registerBinaryCodec(
            for: "xcp", compression: .gzip,
            encrypt: { $0 },
            decrypt: { _ in Data(#"{"resp":true}"#.utf8) },
            requestDecrypt: { _ in Data(#"{"cmd":"login"}"#.utf8) })
        defer { controller.resetBinaryCodecs() }
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return jsonResponse(202, json: ["accepted": true, "count": 1])
            }
            return jsonResponse(200, json: ["ok": true])
        }

        // 请求体 = 非 UTF-8 二进制（xcp 密文），Content-Type: application/xcp。
        let clientConfig = URLSessionConfiguration.ephemeral
        clientConfig.protocolClasses = [MockNetPackURLProtocol.self]
        let session = URLSession(configuration: clientConfig)
        var req = URLRequest(url: URL(string: "https://api.example.com/v1/login")!)
        req.httpMethod = "POST"
        req.setValue("application/xcp", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data([0x00, 0xFF, 0x01, 0xFE, 0x10])

        let exp = expectation(description: "request completes")
        session.dataTask(with: req) { _, _, _ in exp.fulfill() }.resume()
        wait(for: [exp], timeout: 3)

        controller.flush()
        waitUntil {
            MockURLProtocol.recordedRequests.contains { $0.url?.path.hasSuffix("/traffic") == true }
        }
        guard let upload = MockURLProtocol.recordedRequests.first(where: { $0.url?.path.hasSuffix("/traffic") == true }),
              let body = bodyOfRequest(upload),
              let entries = body["entries"] as? [[String: Any]],
              let entry = entries.first else {
            return XCTFail("traffic upload not found")
        }
        XCTAssertEqual(entry["requestBody"] as? String, "[binary 5 bytes]")
        XCTAssertNotNil(entry["requestBodyBase64"])
        XCTAssertEqual(entry["requestBodyDecoded"] as? String, #"{"cmd":"login"}"#)
    }

    /// Mock 命中路径（M8.1，M3.4 修复）：不转发真实网络，但请求体仍被捕获上传
    /// （requestBody 有值；xcp 请求体经 decoder 解出 requestBodyDecoded）。
    func testMockHitCapturesRequestBody() throws {
        let controller = TrafficCaptureController.shared
        controller.registerBinaryCodec(
            for: "xcp", compression: .gzip,
            encrypt: { $0 },
            decrypt: { _ in Data(#"{"resp":true}"#.utf8) },
            requestDecrypt: { _ in Data(#"{"cmd":"feed"}"#.utf8) })
        defer { controller.resetBinaryCodecs() }
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")

        // 注册一条命中规则：POST /v1/feed。
        MockRuleController.shared.applyForTesting(rules: [
            MockRule(id: "r1", method: "POST", path: "/v1/feed",
                     response: MockResponse(statusCode: 200,
                                            headers: ["Content-Type": "application/xcp"],
                                            body: #"{"ok":true}"#),
                     enabled: true, effective: true),
        ], version: 1)
        defer { MockRuleController.shared.reset() }

        // 转发目标若被调用则失败（mock 命中不应转发真实网络）。
        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return jsonResponse(202, json: ["accepted": true, "count": 1])
            }
            throw URLError(.badServerResponse)
        }

        let clientConfig = URLSessionConfiguration.ephemeral
        clientConfig.protocolClasses = [MockNetPackURLProtocol.self]
        let session = URLSession(configuration: clientConfig)
        var req = URLRequest(url: URL(string: "https://api.example.com/v1/feed")!)
        req.httpMethod = "POST"
        req.setValue("application/xcp", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data([0xAA, 0xBB, 0x01])

        let exp = expectation(description: "mock request completes")
        session.dataTask(with: req) { data, resp, _ in
            XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
            // 回放链路：已注册 xcp codec 时文本回包按 gzip+encrypt 编码回协议字节。
            XCTAssertEqual(data, Data(#"{"ok":true}"#.utf8).gzipCompressed())
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 3)

        controller.flush()
        waitUntil {
            MockURLProtocol.recordedRequests.contains { $0.url?.path.hasSuffix("/traffic") == true }
        }
        guard let upload = MockURLProtocol.recordedRequests.first(where: { $0.url?.path.hasSuffix("/traffic") == true }),
              let body = bodyOfRequest(upload),
              let entries = body["entries"] as? [[String: Any]],
              let entry = entries.first else {
            return XCTFail("traffic upload not found")
        }
        XCTAssertEqual(entry["mocked"] as? Bool, true)
        XCTAssertEqual(entry["requestBody"] as? String, "[binary 3 bytes]")
        XCTAssertNotNil(entry["requestBodyBase64"])
        XCTAssertEqual(entry["requestBodyDecoded"] as? String, #"{"cmd":"feed"}"#)
    }

    /// 解码失败守卫（真机验收 bug 修复）：业务底层 decoder ungzip 失败时可能返回
    /// 错误描述文本 Data（如 "ZYZLIB_Z_MEM_ERROR or Z_DATA_ERROR"）而非 nil；
    /// SDK 应识别 zlib 错误宏名并拦截，不上传/展示该错误描述文本。
    func testDecoderErrorTextIsGuarded() throws {
        let controller = TrafficCaptureController.shared
        controller.registerBinaryCodec(
            for: "xcp", compression: .gzip,
            encrypt: { $0 },
            decrypt: { _ in Data(#"{"ok":true}"#.utf8) },
            requestDecrypt: { _ in Data("ZYZLIB_Z_MEM_ERROR or Z_DATA_ERROR".utf8) })
        defer { controller.resetBinaryCodecs() }
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return jsonResponse(202, json: ["accepted": true, "count": 1])
            }
            return jsonResponse(200, json: ["ok": true])
        }

        let clientConfig = URLSessionConfiguration.ephemeral
        clientConfig.protocolClasses = [MockNetPackURLProtocol.self]
        let session = URLSession(configuration: clientConfig)
        var req = URLRequest(url: URL(string: "https://api.example.com/v1/login")!)
        req.httpMethod = "POST"
        req.setValue("application/xcp", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data([0x00, 0xFF, 0x01])

        let exp = expectation(description: "request completes")
        session.dataTask(with: req) { _, _, _ in exp.fulfill() }.resume()
        wait(for: [exp], timeout: 3)

        controller.flush()
        waitUntil {
            MockURLProtocol.recordedRequests.contains { $0.url?.path.hasSuffix("/traffic") == true }
        }
        guard let upload = MockURLProtocol.recordedRequests.first(where: { $0.url?.path.hasSuffix("/traffic") == true }),
              let body = bodyOfRequest(upload),
              let entries = body["entries"] as? [[String: Any]],
              let entry = entries.first else {
            return XCTFail("traffic upload not found")
        }
        // 错误描述文本被守卫拦截：requestBodyDecoded 缺失，requestBody 保持占位。
        XCTAssertNil(entry["requestBodyDecoded"])
        XCTAssertEqual(entry["requestBody"] as? String, "[binary 3 bytes]")
    }

    /// 兼容性（M8.1）：只注册 decrypt（响应体）、未传 requestDecrypt 时，
    /// 请求体不解码（requestBodyDecoded 缺失），回退 `[binary]` 占位——兼容只注册
    /// 单解码器的旧 App。
    func testNoRequestDecryptFallsBackToPlaceholder() throws {
        let controller = TrafficCaptureController.shared
        controller.registerBinaryCodec(
            for: "xcp", compression: .gzip,
            encrypt: { $0 },
            decrypt: { _ in Data(#"{"resp":true}"#.utf8) })
        defer { controller.resetBinaryCodecs() }
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return jsonResponse(202, json: ["accepted": true, "count": 1])
            }
            return jsonResponse(200, json: ["ok": true])
        }

        let clientConfig = URLSessionConfiguration.ephemeral
        clientConfig.protocolClasses = [MockNetPackURLProtocol.self]
        let session = URLSession(configuration: clientConfig)
        var req = URLRequest(url: URL(string: "https://api.example.com/v1/login")!)
        req.httpMethod = "POST"
        req.setValue("application/xcp", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data([0x00, 0xFF, 0x01])

        let exp = expectation(description: "request completes")
        session.dataTask(with: req) { _, _, _ in exp.fulfill() }.resume()
        wait(for: [exp], timeout: 3)

        controller.flush()
        waitUntil {
            MockURLProtocol.recordedRequests.contains { $0.url?.path.hasSuffix("/traffic") == true }
        }
        guard let upload = MockURLProtocol.recordedRequests.first(where: { $0.url?.path.hasSuffix("/traffic") == true }),
              let body = bodyOfRequest(upload),
              let entries = body["entries"] as? [[String: Any]],
              let entry = entries.first else {
            return XCTFail("traffic upload not found")
        }
        XCTAssertNil(entry["requestBodyDecoded"])
        XCTAssertEqual(entry["requestBody"] as? String, "[binary 3 bytes]")
    }
}
