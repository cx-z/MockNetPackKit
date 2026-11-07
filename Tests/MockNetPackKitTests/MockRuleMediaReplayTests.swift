import XCTest
@testable import MockNetPackKit

/// M15（方案 D 阶段二）：大图规则回放——按 media 引用拉 blob、LRU 复用、fail-open。
///
/// 背景：服务端对 >1MiB 的 image 响应只存「占位 + 原 URL」，建规则时回源把字节存成
/// blob，规则响应里只带 `media{sha256,size,contentType}`。SDK 回放时按需拉取；
/// 拉不到则记一条带 error 的命中流量并 fail-open 转发真实请求（绝不静默吞掉）。
final class MockRuleMediaReplayTests: XCTestCase {

    private let serverURL = URL(string: "http://mock.local/api/v1")!
    private let appID = "com.test.app"
    private let did = "did-1"
    private let ruleID = "rule-m15"

    /// 独立快照 suite，避免读取本机残留快照。
    private static let mockSuiteName = "MockNetPackKitTests.MockRuleMedia"
    private var mockDefaults: UserDefaults { UserDefaults(suiteName: Self.mockSuiteName)! }

    /// 1x1 PNG 的最小字节（内容本身不重要，只要求二进制非空且可校验尺寸）。
    private let blobBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()
        MockNetPackURLProtocol.forwardingConfiguration = nil
        MockRuleController.shared.snapshotStore = MockRuleSnapshotStore(defaults: mockDefaults)
        mockDefaults.removePersistentDomain(forName: Self.mockSuiteName)
        MockRuleController.shared.reset()

        let controller = TrafficCaptureController.shared
        let uploadConfig = URLSessionConfiguration.ephemeral
        uploadConfig.protocolClasses = [MockURLProtocol.self]
        controller.clientFactory = { [uploadConfig] url in
            ConnectionClient(configuration: uploadConfig, baseURL: url)
        }
        controller.flushInterval = 0.1

        // media 下载走 MockURLProtocol；缓存清空避免跨用例串味。
        RuleMediaCache.shared.clientFactory = { [uploadConfig] url in
            ConnectionClient(configuration: uploadConfig, baseURL: url)
        }
        RuleMediaCache.shared.maxCacheBytes = 32 * 1024 * 1024
        RuleMediaCache.shared.reset()
    }

    override func tearDown() {
        TrafficCaptureController.shared.stop()
        MockRuleController.shared.reset()
        MockRuleController.shared.snapshotStore = MockRuleSnapshotStore()
        mockDefaults.removePersistentDomain(forName: Self.mockSuiteName)
        RuleMediaCache.shared.clientFactory = nil
        RuleMediaCache.shared.reset()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()
        MockNetPackURLProtocol.forwardingConfiguration = nil
        super.tearDown()
    }

    // MARK: - 辅助

    private func businessSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockNetPackURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func mediaRule(body: String = "", ref: MediaRef?) -> MockRule {
        MockRule(
            id: ruleID, method: "GET", path: "/img/big.png",
            response: MockResponse(
                statusCode: 200,
                headers: ["Content-Type": "image/png"],
                body: body,
                bodyBase64: nil,
                media: ref),
            enabled: true, effective: true)
    }

    private func startCapturing() {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")
    }

    private func get(_ path: String, completion: @escaping (Data?, Int) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.example.com" + path)!)
        req.httpMethod = "GET"
        businessSession().dataTask(with: req) { data, response, error in
            XCTAssertNil(error, "Mock 回包不应抛网络错误")
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            completion(data, code)
        }.resume()
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("condition not met within \(timeout)s")
    }

    private func mediaGets() -> [URLRequest] {
        MockURLProtocol.recordedRequests.filter { $0.url?.path.hasSuffix("/media") == true }
    }

    /// 转发配置：业务请求真由 MockURLProtocol 接管（模拟真实网络）。
    private func installForwarding() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = config
    }

    // MARK: - 用例

    /// ① media 规则：回放前拉 blob，业务请求拿到原始字节（而非规则里为空的 body）。
    func testMediaRuleReplaysBlobBytes() {
        startCapturing()
        let ref = MediaRef(sha256: "sha-big-1", size: Int64(blobBytes.count), contentType: "image/png")
        MockRuleController.shared.applyForTesting(rules: [mediaRule(ref: ref)], version: 1)

        MockURLProtocol.handler = { [blobBytes] request in
            if request.url?.path.hasSuffix("/media") == true {
                // 契约：media 端点返回原始字节；SDK 自身请求须带 skipHeader。
                XCTAssertEqual(request.value(forHTTPHeaderField: MockNetPackURLProtocol.skipHeader), "1")
                return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": "image/png"])!, blobBytes)
            }
            if request.url?.path.hasSuffix("/traffic") == true {
                return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"accepted":true,"count":1}"#.utf8))
            }
            XCTFail("非 media/traffic 请求不应发出: \(request.url?.absoluteString ?? "")")
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let received = expectation(description: "media replay")
        var gotBody: Data?
        var gotCode = -1
        get("/img/big.png") { data, code in
            gotBody = data
            gotCode = code
            received.fulfill()
        }
        wait(for: [received], timeout: 3)

        XCTAssertEqual(gotCode, 200)
        XCTAssertEqual(gotBody, blobBytes, "应回放 blob 原始字节")
        XCTAssertEqual(mediaGets().count, 1, "首次回放应拉一次 media")
        XCTAssertEqual(RuleMediaCache.shared.cachedByteCount, blobBytes.count)
    }

    /// 同一 sha256 第二次回放命中 LRU，不再发 media 请求。
    func testMediaRuleReusesCachedBlob() {
        startCapturing()
        let ref = MediaRef(sha256: "sha-big-2", size: Int64(blobBytes.count), contentType: "image/png")
        MockRuleController.shared.applyForTesting(rules: [mediaRule(ref: ref)], version: 1)
        MockURLProtocol.handler = { [blobBytes] request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"accepted":true,"count":1}"#.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "image/png"])!, blobBytes)
        }

        let first = expectation(description: "first")
        get("/img/big.png") { _, code in
            XCTAssertEqual(code, 200)
            first.fulfill()
        }
        wait(for: [first], timeout: 3)

        let second = expectation(description: "second")
        var secondBody: Data?
        get("/img/big.png") { data, _ in
            secondBody = data
            second.fulfill()
        }
        wait(for: [second], timeout: 3)

        XCTAssertEqual(secondBody, blobBytes)
        XCTAssertEqual(mediaGets().count, 1, "第二次应命中 LRU，不再拉 media")
    }

    /// stop 时若有在飞 blob 拉取，reset 必须把等待者按「失败」收口（回调 nil），
    /// 否则 URLProtocol 的 media 分支永远等不到完成回调，被拦请求既不回包也不转发，
    /// 只能干等宿主 URLSession 超时。
    func testResetDrainsInFlightMediaWaiters() {
        startCapturing()
        let ref = MediaRef(sha256: "sha-reset", size: Int64(blobBytes.count), contentType: "image/png")
        MockURLProtocol.handler = { [blobBytes] request in
            // 模拟慢 blob 端点：留出 reset 插进来的窗口。
            Thread.sleep(forTimeInterval: 0.25)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "image/png"])!, blobBytes)
        }

        let drained = expectation(description: "waiter drained")
        let box = ResultBox<Bool>()
        RuleMediaCache.shared.load(ruleID: ruleID, media: ref) { data in
            box.set(data == nil)   // 记录回调内容：true 表示按「取数失败」收口
            drained.fulfill()
        }
        XCTAssertNil(box.value, "网络路径应异步，先挂到 inflight（尚未回调）")

        RuleMediaCache.shared.reset()
        wait(for: [drained], timeout: 2)
        XCTAssertTrue(box.didCall, "reset 必须收口在飞请求")
        XCTAssertEqual(box.value, true, "reset 必须回调 nil（按取数失败 fail-open），而不是丢弃等待者")
        XCTAssertEqual(RuleMediaCache.shared.cachedByteCount, 0)
    }

    /// ② 取数失败：fail-open 转发真实请求，并留一条带 error 的命中流量（mocked=true）。
    func testMediaFetchFailureFailsOpenAndRecordsError() {
        startCapturing()
        installForwarding()
        let ref = MediaRef(sha256: "sha-big-3", size: Int64(blobBytes.count), contentType: "image/png")
        // body 留空：即服务端大图规则的占位形态。
        MockRuleController.shared.applyForTesting(rules: [mediaRule(ref: ref)], version: 1)
        let realBytes = Data([0x00, 0x11, 0x22])
        MockURLProtocol.handler = { [blobBytes, realBytes] request in
            if request.url?.path.hasSuffix("/media") == true {
                // 源站 blob 已失效（500）→ SDK 无法回放。
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        Data("boom".utf8))
            }
            if request.url?.path.hasSuffix("/traffic") == true {
                return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"accepted":true,"count":1}"#.utf8))
            }
            // 真实业务请求被 Fail-open 转发到网络。
            XCTAssertEqual(request.url?.path, "/img/big.png")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "image/png"])!, realBytes)
        }
        _ = blobBytes

        let received = expectation(description: "fail-open forward")
        var gotBody: Data?
        var gotCode = -1
        get("/img/big.png") { data, code in
            gotBody = data
            gotCode = code
            received.fulfill()
        }
        wait(for: [received], timeout: 3)

        XCTAssertEqual(gotCode, 200, "fail-open 后拿到真实响应")
        XCTAssertEqual(gotBody, realBytes, "取字节失败应转发真实请求，而不是回空 body")
        XCTAssertTrue(
            MockURLProtocol.recordedRequests.contains { $0.url?.host == "api.example.com" },
            "应真实转发业务请求")

        // 命中失败日志：一条 mocked=true + error=media_unavailable 的临时流量。
        TrafficCaptureController.shared.flush()
        waitUntil { MockURLProtocol.recordedRequests.contains { $0.url?.path.hasSuffix("/traffic") == true } }
        guard let upload = MockURLProtocol.recordedRequests.first(where: { $0.url?.path.hasSuffix("/traffic") == true }),
              let entries = Self.bodyOfRequest(upload)?["entries"] as? [[String: Any]] else {
            return XCTFail("traffic upload missing")
        }
        let mockedFailure = entries.first {
            ($0["mocked"] as? Bool) == true && ($0["error"] as? String) == "media_unavailable"
        }
        XCTAssertNotNil(mockedFailure, "media 取数失败必须留一条带 error 的命中流量")
    }

    /// ③ media 缺失时退回 bodyBase64（既有路径回归），且不发 media 请求。
    func testNonMediaRuleFallsBackToBodyBase64() {
        startCapturing()
        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "rule-plain", method: "GET", path: "/img/small.png",
            response: MockResponse(statusCode: 200,
                                   headers: ["Content-Type": "image/png"],
                                   body: "[binary 10 bytes]",
                                   bodyBase64: blobBytes.base64EncodedString()),
            enabled: true, effective: true)], version: 1)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"accepted":true,"count":1}"#.utf8))
            }
            XCTFail("非 media 规则不应请求 media: \(request.url?.absoluteString ?? "")")
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let received = expectation(description: "plain replay")
        var gotBody: Data?
        get("/img/small.png") { data, _ in
            gotBody = data
            received.fulfill()
        }
        wait(for: [received], timeout: 3)

        XCTAssertEqual(gotBody, blobBytes)
        XCTAssertEqual(mediaGets().count, 0)
    }

    /// 并发去重：同一 sha256 的两个请求同时命中只发一次 media 请求。
    func testConcurrentLoadsShareSingleMediaRequest() {
        startCapturing()
        let ref = MediaRef(sha256: "sha-big-4", size: Int64(blobBytes.count), contentType: "image/png")
        MockRuleController.shared.applyForTesting(rules: [mediaRule(ref: ref)], version: 1)
        MockURLProtocol.handler = { [blobBytes] request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"accepted":true,"count":1}"#.utf8))
            }
            Thread.sleep(forTimeInterval: 0.05) // 制造在飞窗口，让第二个请求挂到等待列表
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "image/png"])!, blobBytes)
        }

        let first = expectation(description: "first")
        let second = expectation(description: "second")
        get("/img/big.png") { _, _ in first.fulfill() }
        get("/img/big.png") { _, _ in second.fulfill() }
        wait(for: [first, second], timeout: 5)

        XCTAssertEqual(mediaGets().count, 1, "并发命中同一 sha256 只应发一次 media 请求")
    }

    // MARK: - 上传体解析

    private static func bodyOfRequest(_ request: URLRequest) -> [String: Any]? {
        let data = request.httpBody ?? request.httpBodyStream.flatMap(readAll)
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func readAll(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out.isEmpty ? nil : out
    }
}

/// 测试用线程安全盒：`RuleMediaCache.load` 的 completion 是 @Sendable，Swift 6
/// 不允许在并发闭包里直接改捕获的 var，用它记录回调结果。
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    private var called = false

    var value: T? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    var didCall: Bool {
        lock.lock(); defer { lock.unlock() }
        return called
    }

    func set(_ v: T) {
        lock.lock()
        stored = v
        called = true
        lock.unlock()
    }
}
