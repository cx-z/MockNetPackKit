import XCTest
@testable import MockNetPackKit

/// M3.4：本地 Mock 执行——规则匹配、回包合成、增量拉取、fail-open、会话门控。
final class MockRuleTests: XCTestCase {

    private let serverURL = URL(string: "http://mock.local/api/v1")!
    private let appID = "com.test.app"
    private let did = "did-1"

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()
        MockNetPackURLProtocol.forwardingConfiguration = nil
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
        TrafficCaptureController.shared.bodyEncoder = nil
        TrafficCaptureController.shared.bodyDecoder = nil
        MockRuleController.shared.reset()
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

    // MARK: - M5 encoder: 文本→二进制回放

    /// 有 encoder + 编辑过的文本 body → 回放 encoder 输出的二进制（Web 编辑生效）。
    func testEncoderEncodesEditedTextToBinary() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-enc")

        // 模拟 KK 的 xcp encoder：给文本加个魔数头，假装编码成二进制。
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
