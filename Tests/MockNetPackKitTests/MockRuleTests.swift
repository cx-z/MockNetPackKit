import XCTest
@testable import MockNetPackKit

/// ：本地 Mock 执行——规则匹配、回包合成、增量拉取、fail-open、会话门控。
final class MockRuleTests: XCTestCase {

    private let serverURL = URL(string: "http://mock.local/api/v1")!
    private let appID = "com.test.app"
    private let did = "did-1"

    /// iOS-AN9：Mock 快照隔离——独立 UserDefaults suite，避免读取真实设备残留快照干扰。
    private static let mockSuiteName = "MockNetPackKitTests.MockRule"
    private var mockDefaults: UserDefaults { UserDefaults(suiteName: Self.mockSuiteName)! }

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()
        MockNetPackURLProtocol.forwardingConfiguration = nil
        // iOS-AN9：注入隔离快照 store（磁盘空）并重置，冷启动语义。
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
    }

    override func tearDown() {
        TrafficCaptureController.shared.stop()
        TrafficCaptureController.shared.resetBinaryCodecs()
        MockRuleController.shared.reset()
        MockRuleController.shared.snapshotStore = MockRuleSnapshotStore() // 恢复 .standard
        mockDefaults.removePersistentDomain(forName: Self.mockSuiteName)
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

    /// 配置业务请求走 MockNetPackURLProtocol。
    private func businessSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockNetPackURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - 命中即回包

    /// 命中规则：直接返回 canned body，不转发真实网络；且记一条 mocked 流量。
    func testMockServesCannedResponseWithoutForwarding() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")

        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r1", method: "POST", path: "/api/feed",
            response: MockResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: #"{"mocked":true}"#),
            enabled: true, effective: true)], version: 1)

        // 转发目标绝不应被调用。
        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return jsonResponse(202, json: ["accepted": true, "count": 1])
            }
            XCTFail("命中 Mock 不应转发真实网络: \(request.url?.absoluteString ?? "")")
            return jsonResponse(200, json: ["real": true])
        }

        var req = URLRequest(url: URL(string: "https://api.example.com/api/feed?page=1")!)
        req.httpMethod = "POST"
        req.httpBody = Data(#"{"q":1}"#.utf8)

        let received = Box<Data?>(nil)
        let exp = expectation(description: "mock response")
        businessSession().dataTask(with: req) { data, _, _ in
            received.value = data
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 3)

        XCTAssertEqual(received.value, Data(#"{"mocked":true}"#.utf8))

        // 强制 flush：应上传一条 mocked=true 的流量。
        controller.flush()
        waitUntil {
            MockURLProtocol.recordedRequests.contains { $0.url?.path.hasSuffix("/traffic") == true }
        }
        guard let upload = MockURLProtocol.recordedRequests.first(where: { $0.url?.path.hasSuffix("/traffic") == true }) else {
            return XCTFail("traffic upload missing")
        }
        let body = Self.bodyOfRequest(upload)
        let entries = body?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.first?["mocked"] as? Bool, true)
        XCTAssertEqual(entries?.first?["statusCode"] as? Int, 200)
    }

    /// delayMs 解码契约：对齐 Go `omitempty` 语义。
    /// - 老服务端 / delayMs=0：JSON 里没有 delayMs key → Swift 解为 nil（立即回包）。
    /// - 新规则 delayMs=5000：JSON 里有 delayMs → 解为 5000。
    /// 若字段误用非可选 Int，缺 key 会直接 decode 失败、整批规则拉取崩掉。
    func testMockResponseDelayMsDecodingContract() throws {
        let decoder = JSONDecoder()

        // ① 老服务端：完全不带 delayMs key。
        let oldJSON = """
        {"id":"r1","method":"GET","path":"/a","response":{"statusCode":200,"body":"ok"},"enabled":true,"effective":true}
        """
        let oldRule = try decoder.decode(MockRule.self, from: Data(oldJSON.utf8))
        XCTAssertNil(oldRule.response.delayMs, "缺省 delayMs 必须解为 nil（立即回包）")

        // ② 新规则：显式 delayMs=5000。
        let newJSON = """
        {"id":"r2","method":"GET","path":"/b","response":{"statusCode":200,"body":"ok","delayMs":5000},"enabled":true,"effective":true}
        """
        let newRule = try decoder.decode(MockRule.self, from: Data(newJSON.utf8))
        XCTAssertEqual(newRule.response.delayMs, 5000)

        // ③ 显式 delayMs=0（服务端极少这样下发，但字段在时应解出 0）。
        let zeroJSON = """
        {"id":"r3","method":"GET","path":"/c","response":{"statusCode":200,"body":"ok","delayMs":0},"enabled":true,"effective":true}
        """
        let zeroRule = try decoder.decode(MockRule.self, from: Data(zeroJSON.utf8))
        XCTAssertEqual(zeroRule.response.delayMs, 0)
    }

    /// delayMs 行为：命中规则后等待指定毫秒数再回包，且 durationMs 自然包含延迟。
    func testMockResponseDelayDeliversAfterWait() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")

        // 用 200ms 小延迟：测试快、且能断言"不是立即返回"。
        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r-delay", method: "GET", path: "/api/slow",
            response: MockResponse(statusCode: 200, headers: nil, body: "slow-ok", delayMs: 200),
            enabled: true, effective: true)], version: 1)

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return jsonResponse(202, json: ["accepted": true])
            }
            XCTFail("命中 Mock 不应转发真实网络")
            return jsonResponse(200, json: ["real": true])
        }

        var req = URLRequest(url: URL(string: "https://api.example.com/api/slow")!)
        req.httpMethod = "GET"

        let start = Date()
        let received = Box<Data?>(nil)
        let exp = expectation(description: "delayed mock response")
        businessSession().dataTask(with: req) { data, _, _ in
            received.value = data
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 5)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(received.value, Data("slow-ok".utf8))
        XCTAssertGreaterThanOrEqual(elapsed, 0.15, "延迟回包耗时必须包含 delayMs（≥150ms）")
        XCTAssertLessThan(elapsed, 2.0, "延迟不应异常放大（<2s）")
    }

    /// delayMs 取消：延迟等待期间 stopLoading 被调用时，不回包、也不记录流量。
    func testMockResponseCancelledDuringDelayDoesNotDeliver() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")

        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r-cancel", method: "GET", path: "/api/cancel",
            response: MockResponse(statusCode: 200, headers: nil, body: "never-delivered", delayMs: 500),
            enabled: true, effective: true)], version: 1)

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return jsonResponse(202, json: ["accepted": true])
            }
            return jsonResponse(200, json: ["real": true])
        }

        var req = URLRequest(url: URL(string: "https://api.example.com/api/cancel")!)
        req.httpMethod = "GET"

        let task = businessSession().dataTask(with: req)
        task.resume()
        // 延迟启动后立即取消（20ms 后，远小于 500ms 延迟）。
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
            task.cancel()
        }

        // 等足够久，确保如果不取消的话 fire 早就跑完了。
        let cancelExp = expectation(description: "wait for cancel window")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            cancelExp.fulfill()
        }
        wait(for: [cancelExp], timeout: 2)

        // 强制 flush。
        controller.flush()
        Thread.sleep(forTimeInterval: 0.1)

        // 不应有任何 mocked 流量上传。
        let trafficUploads = MockURLProtocol.recordedRequests.filter {
            $0.url?.path.hasSuffix("/traffic") == true
        }
        // 注意：TrafficCaptureController 可能在 start 时已经上传过心跳等，
        // 我们只关心是否有 /api/cancel 的 mock 命中流量。
        // 这里通过 upload body 里的 entries 断言：没有 path=/api/cancel 的记录。
        for upload in trafficUploads {
            let body = Self.bodyOfRequest(upload)
            let entries = body?["entries"] as? [[String: Any]]
            let hasCancel = entries?.contains { $0["path"] as? String == "/api/cancel" } ?? false
            XCTAssertFalse(hasCancel, "延迟期间取消的请求不应记录流量")
        }
    }

    /// 未命中：正常转发真实网络，走原始链路。
    func testNoMatchForwardsRealNetwork() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")

        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r1", method: "POST", path: "/api/other",
            response: MockResponse(statusCode: 200, headers: nil, body: "mocked"),
            enabled: true, effective: true)], version: 1)

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/real" {
                return jsonResponse(200, json: ["real": true])
            }
            return jsonResponse(200, json: ["ok": true])
        }

        var req = URLRequest(url: URL(string: "https://api.example.com/api/real")!)
        req.httpMethod = "GET"
        let received = Box<Data?>(nil)
        let exp = expectation(description: "real response")
        businessSession().dataTask(with: req) { data, _, _ in
            received.value = data
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 3)
        XCTAssertEqual(received.value, try! JSONSerialization.data(withJSONObject: ["real": true]))
    }

    /// 方法不同 / 路径不同都不命中（Method+路径匹配）。
    func testMatchRequiresMethodAndPath() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")
        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r1", method: "POST", path: "/api/a",
            response: MockResponse(statusCode: 200, headers: nil, body: "m"),
            enabled: true, effective: true)], version: 1)

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { _ in jsonResponse(200, json: ["real": true]) }

        // GET /api/a -> 方法不匹配，走真实。
        var req = URLRequest(url: URL(string: "https://api.example.com/api/a")!)
        req.httpMethod = "GET"
        let exp = expectation(description: "forwarded")
        businessSession().dataTask(with: req) { _, _, _ in exp.fulfill() }.resume()
        wait(for: [exp], timeout: 3)
        let forwardedPaths = MockURLProtocol.recordedRequests.map { $0.url?.path ?? "" }
        XCTAssertTrue(forwardedPaths.contains("/api/a"), "GET /api/a 应转发")
    }

    // MARK: - 增量拉取 / fail-open

    /// 服务端版本变化 → 拉取 mock-rules?sinceVersion= 并应用快照。
    func testSyncPullsWhenVersionChanges() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = ConnectionClient(configuration: config, baseURL: serverURL)
        let appID = self.appID
        let did = self.did

        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix("/mock-rules") == true)
            XCTAssertEqual(request.url?.query, "sinceVersion=0")
            return jsonResponse(200, json: [
                "version": 3,
                "rules": [[
                    "id": "r1", "app": appID, "did": did,
                    "method": "GET", "path": "/api/x",
                    "response": ["statusCode": 200, "body": "m"],
                    "enabled": true, "effective": true,
                ]],
            ])
        }

        await MockRuleController.shared.syncIfNeeded(client: client, app: appID, did: did, serverVersion: 3)

        XCTAssertEqual(MockRuleController.shared.match(method: "GET", path: "/api/x")?.body, "m")
        // 版本未再变化 → 不重复拉取。
        MockURLProtocol.recordedRequests.removeAll()
        await MockRuleController.shared.syncIfNeeded(client: client, app: appID, did: did, serverVersion: 3)
        XCTAssertTrue(MockURLProtocol.recordedRequests.isEmpty, "版本未变不应重复拉取")
    }

    /// fail-open A：拉取失败时已有快照被保留。
    func testSyncFailureKeepsExistingSnapshot() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = ConnectionClient(configuration: config, baseURL: serverURL)

        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r1", method: "GET", path: "/api/old",
            response: MockResponse(statusCode: 200, headers: nil, body: "old"),
            enabled: true, effective: true)], version: 1)

        MockURLProtocol.handler = { _ in throw URLError(.badServerResponse) }
        await MockRuleController.shared.syncIfNeeded(client: client, app: appID, did: did, serverVersion: 9)

        XCTAssertEqual(MockRuleController.shared.match(method: "GET", path: "/api/old")?.body, "old",
                       "拉取失败应保留旧快照")
    }

    /// 会话未激活（idle）：canInit 返回 false，即使有规则也不拦截。
    func testNoMockWhenSessionIdle() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: false, sessionID: nil)
        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r1", method: "GET", path: "/api/a",
            response: MockResponse(statusCode: 200, headers: nil, body: "m"),
            enabled: true, effective: true)], version: 1)

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { _ in throw URLError(.badServerResponse) }

        let req = URLRequest(url: URL(string: "http://127.0.0.1:1/api/a")!)
        let exp = expectation(description: "unintercepted")
        businessSession().dataTask(with: req) { _, _, _ in exp.fulfill() }.resume()
        wait(for: [exp], timeout: 3)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let hit = MockURLProtocol.recordedRequests.contains { $0.url?.path == "/api/a" }
        XCTAssertFalse(hit, "idle 时即使有规则也不应拦截/转发")
    }

    // MARK: -  encoder: 文本→二进制回放

    /// 有 encoder + 编辑过的文本 body → 回放 encoder 输出的二进制（Web 编辑生效）。
    func testEncoderEncodesEditedTextToBinary() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-enc")

        // 模拟业务方的 xcp encoder：给文本加个魔数头，假装编码成二进制。
        TrafficCaptureController.shared.bodyEncoder = { text, contentType in
            XCTAssertEqual(contentType, "application/x-xcp")
            return Data("ENC:".utf8) + Data(text.utf8)
        }

        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r1", method: "POST", path: "/api/xcp",
            response: MockResponse(statusCode: 200,
                headers: ["Content-Type": "application/x-xcp"],
                body: #"{"name":"沈淮行test"}"#),
            enabled: true, effective: true)], version: 1)

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { _ in XCTFail("命中 Mock 不应转发"); return jsonResponse(200, json: [:]) }

        var req = URLRequest(url: URL(string: "https://api.example.com/api/xcp")!)
        req.httpMethod = "POST"
        let received = Box<Data?>(nil)
        let exp = expectation(description: "encoded mock")
        businessSession().dataTask(with: req) { data, _, _ in
            received.value = data
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 3)

        XCTAssertEqual(received.value, Data("ENC:".utf8) + Data(#"{"name":"沈淮行test"}"#.utf8),
                       "应回放 encoder 输出的二进制，而非原文")
    }

    /// encoder 返回 nil → 回退到 bodyBase64 原始字节（未编辑的二进制规则不崩）。
    func testEncoderNilFallsBackToBodyBase64() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-fb")

        TrafficCaptureController.shared.bodyEncoder = { _, _ in return nil }

        let origBytes = Data([0x00, 0x01, 0xAA, 0xBB])
        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r1", method: "GET", path: "/api/bin",
            response: MockResponse(statusCode: 200,
                headers: ["Content-Type": "application/x-xcp"],
                body: "[binary 4 bytes]",
                bodyBase64: origBytes.base64EncodedString()),
            enabled: true, effective: true)], version: 1)

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { _ in XCTFail("命中 Mock 不应转发"); return jsonResponse(200, json: [:]) }

        let req = URLRequest(url: URL(string: "https://api.example.com/api/bin")!)
        let received = Box<Data?>(nil)
        let exp = expectation(description: "base64 fallback")
        businessSession().dataTask(with: req) { data, _, _ in
            received.value = data
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 3)

        XCTAssertEqual(received.value, origBytes, "encoder 返回 nil 应回退到 bodyBase64 原始字节")
    }

    /// 纯文本 JSON 接口（无 encoder、无 bodyBase64）→ 直传 UTF-8 文本。
    func testPlainTextFallsBackToUTF8() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-txt")
        // 不配 encoder（nil）
        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r1", method: "GET", path: "/api/json",
            response: MockResponse(statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"ok":true}"#),
            enabled: true, effective: true)], version: 1)

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { _ in XCTFail("命中 Mock 不应转发"); return jsonResponse(200, json: [:]) }

        let req = URLRequest(url: URL(string: "https://api.example.com/api/json")!)
        let received = Box<Data?>(nil)
        let exp = expectation(description: "plain text")
        businessSession().dataTask(with: req) { data, _, _ in
            received.value = data
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 3)

        XCTAssertEqual(received.value, Data(#"{"ok":true}"#.utf8))
    }

    // MARK: - 手填规则回放

    /// 手填规则（response 纯文本 body、无 bodyBase64）controller 级命中，
    /// 状态码/body 原样返回。
    func testHandAuthoredRuleControllerMatch() throws {
        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r-hand", method: "GET", path: "/api/hello",
            response: MockResponse(statusCode: 201,
                headers: ["Content-Type": "application/json"],
                body: #"{"msg":"hand-written"}"#),
            enabled: true, effective: true)], version: 1)

        let resp = try XCTUnwrap(
            MockRuleController.shared.match(method: "get", path: "/api/hello"),
            "手填规则应命中（method 大小写不敏感）")
        XCTAssertEqual(resp.statusCode, 201)
        XCTAssertEqual(resp.body, #"{"msg":"hand-written"}"#)
        XCTAssertNil(resp.bodyBase64, "手填规则不带 bodyBase64")
    }

    /// 手填规则（文本 body）与二进制规则（bodyBase64）共存于同一快照时，
    /// 各自按自己的回放分支出字节，互不串味（① 原始字节优先不被 ③ 文本路径破坏）。
    func testHandAuthoredAndBinaryRulesCoexist() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-m11")
        // 不配 encoder：手填规则走 ③ UTF-8 文本；二进制规则走 ① bodyBase64 原始字节。

        let binBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        MockRuleController.shared.applyForTesting(rules: [
            MockRule(
                id: "r-hand", method: "GET", path: "/api/hello",
                response: MockResponse(statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: #"{"msg":"hand-written"}"#),
                enabled: true, effective: true),
            MockRule(
                id: "r-bin", method: "GET", path: "/api/bin",
                response: MockResponse(statusCode: 200,
                    headers: ["Content-Type": "application/octet-stream"],
                    body: "[binary 4 bytes]",
                    bodyBase64: binBytes.base64EncodedString()),
                enabled: true, effective: true),
        ], version: 1)

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { _ in XCTFail("命中 Mock 不应转发"); return jsonResponse(200, json: [:]) }

        func fetch(_ path: String) -> Data? {
            let req = URLRequest(url: URL(string: "https://api.example.com\(path)")!)
            let received = Box<Data?>(nil)
            let exp = expectation(description: path)
            businessSession().dataTask(with: req) { data, _, _ in
                received.value = data
                exp.fulfill()
            }.resume()
            wait(for: [exp], timeout: 3)
            return received.value
        }

        XCTAssertEqual(fetch("/api/hello"), Data(#"{"msg":"hand-written"}"#.utf8),
                       "手填规则应回 UTF-8 文本")
        XCTAssertEqual(fetch("/api/bin"), binBytes,
                       "二进制规则应回 bodyBase64 原始字节，不被手填分支影响")
    }

    // MARK: - 19 位整数 ID 精度（回归）

    /// 增量拉取解码：body 字符串中的大整数 ID 必须逐位保留，不被
    /// 数值类型转换舍入（复现：1473156146373935104 → 1473156146373935000）。
    func testSyncDecodePreservesBigIntIDs() async throws {
        let exactStoryID = "1473156146373935104"
        let exactChatID = "1576844185645694976"
        let roundedStory = "1473156146373935000"
        let roundedChat = "1576844185645695000"
        let body = #"{"ret":1,"data":{"sessions":[{"session_id":1473156146373935104,"unread":0}],"active_session_list":[1576844185645694976],"wangliao_active_list":[1576844185645694976]}}"#

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = ConnectionClient(configuration: config, baseURL: serverURL)
        let appID = self.appID
        let did = self.did

        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix("/mock-rules") == true)
            return jsonResponse(200, json: [
                "version": 7,
                "rules": [[
                    "id": "r1", "app": appID, "did": did,
                    "method": "POST", "path": "/chat/sessions_v2",
                    "response": ["statusCode": 200, "body": body],
                    "enabled": true, "effective": true,
                ]],
            ])
        }

        await MockRuleController.shared.syncIfNeeded(client: client, app: appID, did: did, serverVersion: 7)

        guard let served = MockRuleController.shared.match(method: "POST", path: "/chat/sessions_v2") else {
            return XCTFail("规则应已入快照")
        }
        XCTAssertTrue(served.body?.contains(exactStoryID) == true, "故事会话 ID 必须逐位保留")
        XCTAssertTrue(served.body?.contains(exactChatID) == true, "网聊会话 ID 必须逐位保留")
        XCTAssertFalse(served.body?.contains(roundedStory) == true, "不得出现舍入形态 \(roundedStory)")
        XCTAssertFalse(served.body?.contains(roundedChat) == true, "不得出现舍入形态 \(roundedChat)")
    }

    /// 实际 Mock 下发（无 encoder 的纯文本 JSON 接口）：下发的字节必须与
    /// 规则体原文逐字节一致，ID 仍是数字字面量（不转字符串、不舍入）。
    func testServeDeliversBigIntIDsByteExact() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-prec")

        // 不配 encoder（纯文本 JSON 直传路径）。
        let body = #"{"ret":1,"data":{"sessions":[{"session_id":1473156146373935104,"unread":0}],"active_session_list":[1576844185645694976],"wangliao_active_list":[1576844185645694976]}}"#
        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r1", method: "POST", path: "/chat/sessions_v2",
            response: MockResponse(statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: body),
            enabled: true, effective: true)], version: 1)

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { _ in XCTFail("命中 Mock 不应转发"); return jsonResponse(200, json: [:]) }

        var req = URLRequest(url: URL(string: "https://api.example.com/chat/sessions_v2")!)
        req.httpMethod = "POST"
        let received = Box<Data?>(nil)
        let exp = expectation(description: "bigint mock")
        businessSession().dataTask(with: req) { data, _, _ in
            received.value = data
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 3)

        XCTAssertEqual(received.value, Data(body.utf8), "下发字节必须与规则体原文逐字节一致")
        // 附加语义断言：接收方可按完整 Int64 精确匹配两个会话 ID。
        let parsed = try? JSONSerialization.jsonObject(with: received.value ?? Data()) as? [String: Any]
        let sessions = (parsed?["data"] as? [String: Any])?["sessions"] as? [[String: Any]]
        let sessionID = sessions?.first?["session_id"] as? NSNumber
        XCTAssertEqual(sessionID?.int64Value, Int64("1473156146373935104"), "客户端按完整 Int64 匹配的 ID 必须等于原值")
        let activeList = (parsed?["data"] as? [String: Any])?["active_session_list"] as? [NSNumber]
        XCTAssertEqual(activeList?.first?.int64Value, Int64("1576844185645694976"), "active_session_list 首项必须等于原值")
    }

    // MARK: - iOS-AN9 快照持久化 / 断连保护 / 并发

    /// 快照 roundtrip：Store.save → 新 Store.load → 字段等值；
    /// ruleId 不落盘（MockResponse.ruleId 为匹配时瞬态字段，序列化 JSON 中不存在该 key；
    /// 规则自身 id 落盘——冷启动 matchedRuleId 上报依赖它，与安卓规则一致）。
    func testSnapshotRoundTrip_PreservesFieldsWithoutRuleIdKey() throws {
        let store = MockRuleSnapshotStore(defaults: mockDefaults)
        let rules = [
            MockRule(
                id: "r1", method: "POST", path: "/api/v1/business",
                response: MockResponse(statusCode: 503,
                    headers: ["Content-Type": "application/json", "X-Mock": "1"],
                    body: "old", bodyBase64: nil, delayMs: 250),
                enabled: true, effective: true),
            MockRule(
                id: "r2", method: "GET", path: "/x/y",
                response: MockResponse(statusCode: 200,
                    headers: nil, body: nil, bodyBase64: "aGVsbG8=", delayMs: nil),
                enabled: false, effective: false),
        ]
        store.save(MockRuleSnapshotStore.Snapshot(version: 7, rules: rules))

        // 读回 → 等值。
        let loaded = try XCTUnwrap(store.load(), "快照应可读回")
        XCTAssertEqual(loaded.version, 7)
        XCTAssertEqual(loaded.rules, rules)

        // ruleId 不落盘：序列化 JSON 中规则 response 不得含 ruleId key。
        let data = try JSONEncoder().encode(MockRuleSnapshotStore.Snapshot(version: 7, rules: rules))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rulesArr = try XCTUnwrap(json["rules"] as? [[String: Any]])
        for r in rulesArr {
            let resp = try XCTUnwrap(r["response"] as? [String: Any])
            XCTAssertNil(resp["ruleId"], "ruleId（瞬态匹配字段）不得落盘")
        }

        // 加载后匹配：matchedRuleId 由规则自身 id 填充（规则 id 落盘保障冷启动上报）。
        MockRuleController.shared.snapshotStore = store
        MockRuleController.shared.reset()
        let resp = try XCTUnwrap(MockRuleController.shared.match(method: "POST", path: "/api/v1/business"))
        XCTAssertEqual(resp.statusCode, 503)
        XCTAssertEqual(resp.headers?["X-Mock"], "1")
        XCTAssertEqual(resp.body, "old")
        XCTAssertEqual(resp.delayMs, 250)
        XCTAssertEqual(resp.ruleId, "r1", "命中后 ruleId 由规则 id 填充（冷启动 matchedRuleId 上报依赖）")
    }

    /// ensureLoaded 懒加载：磁盘预写快照 + reset（模拟冷启动进程）→ 首次 match 命中磁盘快照；
    /// 磁盘为空 → match nil（fail-open，不 Mock）。
    func testEnsureLoadedLoadsDiskSnapshotOnFirstMatch() throws {
        MockRuleController.shared.snapshotStore = MockRuleSnapshotStore(defaults: mockDefaults)
        mockDefaults.removePersistentDomain(forName: Self.mockSuiteName)

        // 预写磁盘快照（模拟上次进程同步落盘）。
        MockRuleSnapshotStore(defaults: mockDefaults).save(MockRuleSnapshotStore.Snapshot(
            version: 5,
            rules: [MockRule(
                id: "r-disk", method: "GET", path: "/api/disk",
                response: MockResponse(statusCode: 200, headers: nil, body: "from-disk"),
                enabled: true, effective: true)]))
        MockRuleController.shared.reset() // loaded=false：模拟冷启动

        // 首次 match 触发 ensureLoaded → 磁盘快照生效。
        let hit = MockRuleController.shared.match(method: "GET", path: "/api/disk")
        XCTAssertEqual(hit?.body, "from-disk")
        XCTAssertEqual(hit?.ruleId, "r-disk")

        // 磁盘为空 → match nil。
        mockDefaults.removePersistentDomain(forName: Self.mockSuiteName)
        MockRuleController.shared.reset()
        XCTAssertNil(MockRuleController.shared.match(method: "GET", path: "/api/disk"),
                     "磁盘无快照时不应 Mock（fail-open）")
    }

    /// F5：损坏快照 → match nil（fail-open）、坏数据被清、后续 apply 可正常重写磁盘。
    func testCorruptSnapshotIsClearedAndFailsOpen() throws {
        MockRuleController.shared.snapshotStore = MockRuleSnapshotStore(defaults: mockDefaults)
        mockDefaults.removePersistentDomain(forName: Self.mockSuiteName)
        mockDefaults.set(Data("not-json".utf8), forKey: MockRuleSnapshotStore.key)
        MockRuleController.shared.reset()

        XCTAssertNil(MockRuleController.shared.match(method: "GET", path: "/api/x"),
                     "损坏快照应 fail-open（不 Mock）")
        XCTAssertNil(mockDefaults.data(forKey: MockRuleSnapshotStore.key), "坏快照应被清除")

        // 后续同步可正常重写磁盘。
        MockRuleController.shared.reset()
        let store = MockRuleSnapshotStore(defaults: mockDefaults)
        store.save(MockRuleSnapshotStore.Snapshot(version: 9,
            rules: [MockRule(id: "r9", method: "GET", path: "/api/x",
                response: MockResponse(statusCode: 200, headers: nil, body: "ok"),
                enabled: true, effective: true)]))
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.version, 9, "清坏文件后下次同步应能正常重写磁盘")
    }

    /// 增量拉取基于磁盘版本：磁盘快照 version=5 + reset（冷启动）→ 服务端 5 → no-op；
    /// 服务端 6 → sinceVersion=5 增量拉取。
    func testSyncIncrementalPullUsesDiskSnapshotVersion() async throws {
        MockRuleController.shared.snapshotStore = MockRuleSnapshotStore(defaults: mockDefaults)
        mockDefaults.removePersistentDomain(forName: Self.mockSuiteName)
        MockRuleSnapshotStore(defaults: mockDefaults).save(MockRuleSnapshotStore.Snapshot(
            version: 5, rules: [MockRule(
                id: "r5", method: "GET", path: "/api/disk",
                response: MockResponse(statusCode: 200, headers: nil, body: "from-disk"),
                enabled: true, effective: true)]))
        MockRuleController.shared.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = ConnectionClient(configuration: config, baseURL: serverURL)
        let appID = self.appID
        let did = self.did

        // 服务端 6 → sinceVersion=5 增量拉取。
        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix("/mock-rules") == true)
            XCTAssertEqual(request.url?.query, "sinceVersion=5", "应基于磁盘快照版本增量拉取")
            return jsonResponse(200, json: ["version": 6, "rules": []])
        }
        await MockRuleController.shared.syncIfNeeded(client: client, app: appID, did: did, serverVersion: 6)
        let pulls = MockURLProtocol.recordedRequests.filter { $0.url?.path.hasSuffix("/mock-rules") == true }
        XCTAssertEqual(pulls.count, 1)

        // 服务端 6（与已落盘版本一致，再次冷启动）→ no-op。
        MockURLProtocol.recordedRequests.removeAll()
        MockRuleController.shared.reset() // 重新冷启动，磁盘 version=6（上一步已落盘）
        await MockRuleController.shared.syncIfNeeded(client: client, app: appID, did: did, serverVersion: 6)
        XCTAssertTrue(MockURLProtocol.recordedRequests.filter { $0.url?.path.hasSuffix("/mock-rules") == true }.isEmpty,
                      "版本一致不应拉取")
    }

    /// F2/D2：并发 match / clearSnapshot / applyForTesting 不抛异常、不撕裂。
    func testConcurrentMatchAndClearDoesNotTearOrCrash() throws {
        MockRuleController.shared.snapshotStore = MockRuleSnapshotStore(defaults: mockDefaults)
        mockDefaults.removePersistentDomain(forName: Self.mockSuiteName)
        MockRuleController.shared.reset()

        // 线程安全收集器。
        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func append(_ s: String) { lock.lock(); defer { lock.unlock() }; items.append(s) }
            var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return items }
        }
        let errors = Collector()

        let ruleA = MockRule(id: "A", method: "GET", path: "/a",
            response: MockResponse(statusCode: 200), enabled: true, effective: true)
        let queue = DispatchQueue(label: "concurrent-match-clear", attributes: .concurrent)
        let group = DispatchGroup()

        // 写线程：交替 applyForTesting / clearSnapshot。
        group.enter()
        queue.async {
            for i in 0..<200 {
                if i % 2 == 0 {
                    MockRuleController.shared.applyForTesting(rules: [ruleA], version: i + 1)
                } else {
                    MockRuleController.shared.clearSnapshot()
                }
            }
            group.leave()
        }
        // 读线程：并发 match。
        for _ in 0..<3 {
            group.enter()
            queue.async {
                for _ in 0..<2000 {
                    let m = MockRuleController.shared.match(method: "GET", path: "/a")
                    if let m, m.ruleId != "A" {
                        errors.append("unexpected ruleId \(m.ruleId ?? "nil")")
                    }
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertTrue(errors.snapshot.isEmpty, "并发 match/clear 不得返回撕裂快照：\(errors.snapshot)")
    }

    // MARK: - 辅助

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private static func bodyOfRequest(_ request: URLRequest) -> [String: Any]? {
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
}
