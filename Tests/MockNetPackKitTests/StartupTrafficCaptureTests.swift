import XCTest
@testable import MockNetPackKit

/// 冷启首次心跳前的 HTTP 暂存、会话归属与有界内存回归。
final class StartupTrafficCaptureTests: XCTestCase {
    /// 上传回调与测试断言之间共享的数据；所有读写由同一把锁保护。
    private final class Uploads: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [[String: Any]] = []
        private var sizes: [Int] = []

        /// 保存一批已收到的上传，回调只在锁外解析 JSON。
        func append(_ body: [String: Any], byteCount: Int) {
            lock.lock(); defer { lock.unlock() }
            bodies.append(body)
            sizes.append(byteCount)
        }

        /// 返回不可变快照，避免断言与上传回调并发访问数组。
        var snapshot: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return bodies
        }

        /// 返回实际上传 JSON 的字节数，用于核对服务器 10MiB 请求体契约。
        var byteCounts: [Int] {
            lock.lock(); defer { lock.unlock() }
            return sizes
        }
    }

    /// 只持有首次心跳的协议实例，测试释放前连接层保持真实的在途心跳状态。
    private final class HeartbeatGate: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: MockURLProtocol?

        /// 在加载线程保存心跳，不阻塞其他 URLSession 请求。
        func hold(_ transport: MockURLProtocol) {
            lock.lock(); defer { lock.unlock() }
            pending = transport
        }

        /// 原子取出并在锁外交付首次有效心跳，避免重复回包或持锁调用框架。
        func release(sessionID: String) {
            lock.lock()
            let transport = pending
            pending = nil
            lock.unlock()
            transport?.respond(.success(jsonResponse(200, json: heartbeatResponseJSON(session: sessionJSON(id: sessionID)))))
        }
    }

    private let serverURL = URL(string: "http://mock.local/api/v1")!
    private var uploads: Uploads!

    /// iOS-AN9：Mock 快照隔离——独立 UserDefaults suite，避免读取真实设备残留快照干扰。
    private static let mockSuiteName = "MockNetPackKitTests.StartupTrafficCapture"
    private var mockDefaults: UserDefaults { UserDefaults(suiteName: Self.mockSuiteName)! }

    /// 注入确定性转发/上传响应；关闭自动刷批以显式控制首次心跳前后的边界。
    override func setUp() {
        super.setUp()
        TrafficCaptureController.shared.stop()
        TrafficCaptureController.shared.resetBinaryCodecs()
        // iOS-AN9：注入隔离快照 store（磁盘空）并重置，冷启动语义。
        MockRuleController.shared.snapshotStore = MockRuleSnapshotStore(defaults: mockDefaults)
        mockDefaults.removePersistentDomain(forName: Self.mockSuiteName)
        MockRuleController.shared.reset()
        let uploads = Uploads()
        self.uploads = uploads
        MockURLProtocol.recordedRequests = []
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/v1/traffic" {
                let data = Self.bodyData(of: request)
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                uploads.append(body, byteCount: data.count)
                return jsonResponse(202, json: ["accepted": true, "count": (body["entries"] as? [Any])?.count ?? 0])
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, Data(#"{"real":true}"#.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = config
        TrafficCaptureController.shared.clientFactory = { [config] url in
            ConnectionClient(configuration: config, baseURL: url)
        }
        TrafficCaptureController.shared.flushInterval = 3600
    }

    /// 结束采集并移除测试注入，不让规则或转发配置泄漏到其他测试。
    override func tearDown() {
        TrafficCaptureController.shared.stop()
        TrafficCaptureController.shared.resetBinaryCodecs()
        TrafficCaptureController.shared.clientFactory = nil
        TrafficCaptureController.shared.flushInterval = 2
        MockRuleController.shared.reset()
        MockRuleController.shared.snapshotStore = MockRuleSnapshotStore() // 恢复 .standard
        mockDefaults.removePersistentDomain(forName: Self.mockSuiteName)
        MockNetPackURLProtocol.forwardingConfiguration = nil
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    /// 读取完整上传字节，兼容 URLSession 将 httpBody 转成流的行为。
    private static func bodyData(of request: URLRequest) -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return data
    }

    /// 启动有服务器的采集；可在锁外日志边界插入并发操作，会话结果由用例显式下发。
    private func startCapture(logHandler: (@Sendable (String) -> Void)? = nil) {
        TrafficCaptureController.shared.start(serverURL: serverURL, appID: "app", did: "did", logHandler: logHandler)
    }

    /// 等待一个真实转发请求完成；旧实现可走兜底协议，因此失败只来自缺少采集记录。
    private func request(_ path: String) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockNetPackURLProtocol.self, MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let done = expectation(description: path)
        session.dataTask(with: URL(string: "https://business.local" + path)!) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, Data(#"{"real":true}"#.utf8))
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 3)
        session.finishTasksAndInvalidate()
    }

    /// 构造已完成记录，便于直接覆盖在飞请求晚于会话结果到达的边界。
    private func entry(_ path: String = "/character/get_discover_config") -> TrafficEntry {
        TrafficEntry(timestamp: Date(), method: "GET", url: "https://business.local" + path,
                     path: path, query: "", requestHeaders: [:], requestBody: "",
                     statusCode: 200, responseHeaders: [:], responseBody: "{}", error: nil, durationMs: 1)
    }

    /// 用单调时钟等待指定批数的异步上传；不依赖平台网络或固定延时。
    private func waitForUpload(count: Int = 1) {
        let end = ProcessInfo.processInfo.systemUptime + 3
        while uploads.snapshot.count < count && ProcessInfo.processInfo.systemUptime < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(uploads.snapshot.count, count)
    }

    /// 两个真实早期请求先返回业务数据，首次有效心跳后才进入平台上传批次。
    func testEarlyDiscoverRequestsUploadAfterFirstActiveHeartbeat() {
        startCapture()
        XCTAssertFalse(TrafficCaptureController.shared.isCapturing)
        request("/character/get_discover_config")
        request("/character/get_discover_list")
        TrafficCaptureController.shared.flush()
        XCTAssertTrue(uploads.snapshot.isEmpty)

        TrafficCaptureController.shared.updateSession(capturing: true, sessionID: "first-session")
        waitForUpload()
        let body = uploads.snapshot.first
        XCTAssertEqual(body?["sessionId"] as? String, "first-session")
        let entries = body?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.compactMap { $0["path"] as? String },
                       ["/character/get_discover_config", "/character/get_discover_list"])
    }

    /// iOS-AN9 反转（原用例：启动期不 Mock）：启动缓冲期（首次心跳前）请求命中
    /// 磁盘快照 → 直接 Mock 回包（不回真实网络、真实服务器 0 次请求）；首个有效
    /// 会话晋升后上传 mocked=true + matchedRuleId。
    func testStartupAppliesDiskSnapshotMock() throws {
        // 模拟上次进程同步落盘：写入 {version, rules} 到独立 suite。
        MockRuleSnapshotStore(defaults: mockDefaults).save(MockRuleSnapshotStore.Snapshot(
            version: 3,
            rules: [MockRule(
                id: "old-rule", method: "GET", path: "/character/get_discover_config",
                response: MockResponse(statusCode: 503, headers: nil, body: "old", bodyBase64: nil),
                enabled: true, effective: true)]))
        MockRuleController.shared.reset() // loaded=false：模拟冷启动进程

        startCapture()
        XCTAssertFalse(TrafficCaptureController.shared.isCapturing)

        // 启动缓冲期请求：命中磁盘快照直接 Mock，不转发真实网络。
        let done = expectation(description: "startup mock")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockNetPackURLProtocol.self, MockURLProtocol.self]
        let session = URLSession(configuration: config)
        session.dataTask(with: URL(string: "https://business.local/character/get_discover_config")!) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503, "应直接回 Mock 规则状态码")
            XCTAssertEqual(data, Data("old".utf8), "应直接回 Mock 规则 body，而非真实网络")
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 3)
        session.finishTasksAndInvalidate()
        // 真实服务器 0 次业务请求（未被转发）。
        XCTAssertFalse(MockURLProtocol.recordedRequests.contains { $0.url?.host == "business.local" },
                       "启动期命中快照 Mock 不应转发真实网络")

        // 晋升上传：mocked=true + matchedRuleId=old-rule。
        TrafficCaptureController.shared.updateSession(capturing: true, sessionID: "first-session")
        waitForUpload()
        let body = uploads.snapshot.first
        let entries = body?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.compactMap { $0["path"] as? String }, ["/character/get_discover_config"])
        XCTAssertEqual(entries?.first?["mocked"] as? Bool, true)
        XCTAssertEqual(entries?.first?["matchedRuleId"] as? String, "old-rule")

        // SDK 自身请求（skipHeader）不拦截。
        var internalRequest = URLRequest(url: serverURL)
        internalRequest.setValue("1", forHTTPHeaderField: MockNetPackURLProtocol.skipHeader)
        XCTAssertFalse(MockNetPackURLProtocol.canInit(with: internalRequest))
    }

    /// 首次 idle 结果丢弃启动缓存与在飞请求；以后激活会话也不能带回旧记录。
    func testFirstIdleHeartbeatDiscardsBufferedAndLateEntries() throws {
        startCapture()
        let generation = try XCTUnwrap(TrafficCaptureController.shared.httpCaptureGeneration)
        TrafficCaptureController.shared.record(entry(), generation: generation)
        TrafficCaptureController.shared.updateSession(capturing: false, sessionID: nil)
        XCTAssertNil(TrafficCaptureController.shared.httpCaptureGeneration)
        TrafficCaptureController.shared.updateSession(capturing: true, sessionID: "later-session")
        TrafficCaptureController.shared.record(entry("/late"), generation: generation)
        TrafficCaptureController.shared.record(entry("/current"))
        TrafficCaptureController.shared.flush()
        waitForUpload()
        let entries = uploads.snapshot.first?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.compactMap { $0["path"] as? String }, ["/current"])
    }

    /// 有效首次心跳保留在飞请求的代次，回包晚于心跳仍可被正常记录。
    func testLateStartupResponseBelongsToFirstActiveSession() throws {
        startCapture()
        let generation = try XCTUnwrap(TrafficCaptureController.shared.httpCaptureGeneration)
        TrafficCaptureController.shared.updateSession(capturing: true, sessionID: "first-session")
        TrafficCaptureController.shared.record(entry(), generation: generation)
        TrafficCaptureController.shared.flush()
        waitForUpload()
        XCTAssertEqual((uploads.snapshot.first?["entries"] as? [Any])?.count, 1)
    }

    /// stop/start 后旧的在飞响应不能写入新一次启动暂存或新会话。
    func testRestartInvalidatesInFlightStartupResponse() throws {
        startCapture()
        let generation = try XCTUnwrap(TrafficCaptureController.shared.httpCaptureGeneration)
        TrafficCaptureController.shared.stop()
        startCapture()
        TrafficCaptureController.shared.record(entry("/old"), generation: generation)
        TrafficCaptureController.shared.record(entry("/new"))
        TrafficCaptureController.shared.updateSession(capturing: true, sessionID: "new-session")
        waitForUpload()
        let entries = uploads.snapshot.first?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.compactMap { $0["path"] as? String }, ["/new"])
    }

    /// 首次握手被永久拒绝时停止暂存，且不能污染后续手动激活的会话。
    func testRejectedStartupDiscardsEntries() {
        startCapture()
        TrafficCaptureController.shared.record(entry())
        TrafficCaptureController.shared.cancelStartupCapture(generation: TrafficCaptureController.shared.httpCaptureGeneration)
        XCTAssertNil(TrafficCaptureController.shared.httpCaptureGeneration)
        TrafficCaptureController.shared.updateSession(capturing: true, sessionID: "later-session")
        TrafficCaptureController.shared.record(entry("/current"))
        TrafficCaptureController.shared.flush()
        waitForUpload()
        let entries = uploads.snapshot.first?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.compactMap { $0["path"] as? String }, ["/current"])
    }

    /// 长时间无法得到首个心跳时最多保留 200 条，优先保留最早请求。
    func testStartupBufferKeepsEarliestEntriesWithinCountLimit() {
        startCapture()
        for index in 0...TrafficCaptureController.shared.maxBatchCount {
            TrafficCaptureController.shared.record(entry("/request/\(index)"))
        }
        TrafficCaptureController.shared.updateSession(capturing: true, sessionID: "first-session")
        waitForUpload()
        let entries = uploads.snapshot.first?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, TrafficCaptureController.shared.maxBatchCount)
        XCTAssertEqual(entries?.first?["path"] as? String, "/request/0")
        XCTAssertEqual(entries?.last?["path"] as? String, "/request/199")
    }

    /// 8MB 额度包含 base64/解码副本；超限记录不挤掉最早请求，后续小记录仍可暂存。
    func testStartupBufferBoundsAllBodyRepresentations() {
        startCapture()
        TrafficCaptureController.shared.record(entry("/first"))
        var oversized = entry("/oversized")
        oversized.responseBodyBase64 = String(repeating: "A", count: TrafficCaptureController.shared.maxBatchBytes)
        TrafficCaptureController.shared.record(oversized)
        TrafficCaptureController.shared.record(entry("/last"))
        TrafficCaptureController.shared.updateSession(capturing: true, sessionID: "first-session")
        waitForUpload()
        let entries = uploads.snapshot.first?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.compactMap { $0["path"] as? String }, ["/first", "/last"])
    }

    /// 旧拒绝在新启动已经暂存后才清理，也只能匹配旧代次；B 的缓存与在飞响应都必须保留。
    func testOldRejectionCannotCancelNewStartupBuffer() throws {
        startCapture()
        let oldGeneration = try XCTUnwrap(TrafficCaptureController.shared.httpCaptureGeneration)
        TrafficCaptureController.shared.stop()
        startCapture()
        let newGeneration = try XCTUnwrap(TrafficCaptureController.shared.httpCaptureGeneration)
        TrafficCaptureController.shared.record(entry("/new-buffered"), generation: newGeneration)

        TrafficCaptureController.shared.cancelStartupCapture(generation: oldGeneration)
        TrafficCaptureController.shared.cancelStartupCapture(generation: nil)
        XCTAssertEqual(TrafficCaptureController.shared.httpCaptureGeneration, newGeneration)
        TrafficCaptureController.shared.record(entry("/new-inflight"), generation: newGeneration)
        TrafficCaptureController.shared.updateSession(capturing: true, sessionID: "new-session")
        waitForUpload()
        let entries = uploads.snapshot.first?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.compactMap { $0["path"] as? String }, ["/new-buffered", "/new-inflight"])
    }

    /// 激活日志处完成二进制请求，强制覆盖解锁到上传之间的窗口；启动批次必须已被独立取出。
    func testPromotionDetachesNearLimitBatchBeforeActiveCompletion() {
        var binary = entry("/binary-completion")
        let base64 = Data(repeating: 0xff, count: MockNetPackURLProtocol.bodyLimit).base64EncodedString()
        binary.requestBody = "[binary 1048576 bytes]"
        binary.responseBody = "[binary 1048576 bytes]"
        binary.requestBodyBase64 = base64
        binary.responseBodyBase64 = base64
        let completed = binary
        startCapture(logHandler: { message in
            if message.hasPrefix("capture session active") {
                TrafficCaptureController.shared.record(completed)
            }
        })
        for index in 0..<8 {
            var early = entry("/startup/\(index)")
            let bytes = index == 7 ? MockNetPackURLProtocol.bodyLimit * 9 / 10 : MockNetPackURLProtocol.bodyLimit
            early.responseBody = String(repeating: "a", count: bytes)
            TrafficCaptureController.shared.record(early)
        }
        TrafficCaptureController.shared.updateSession(capturing: true, sessionID: "first-session")
        waitForUpload(count: 2)
        let batches = uploads.snapshot.compactMap { $0["entries"] as? [[String: Any]] }
        let paths = batches.map { $0.compactMap { $0["path"] as? String } }
        XCTAssertTrue(paths.contains((0..<8).map { "/startup/\($0)" }))
        XCTAssertTrue(paths.contains(["/binary-completion"]))
        XCTAssertTrue(uploads.byteCounts.allSatisfy { $0 < 10 * 1024 * 1024 })
    }

    /// 真正执行注册/心跳，并扣住首次心跳响应；两个自动注入的加密 POST 必须先完成再上报。
    func testConnectionHandshakePreservesEncryptedPostsBeforeDelayedHeartbeat() throws {
        let controller = ConnectionController()
        let gate = HeartbeatGate()
        let heartbeatStarted = expectation(description: "first heartbeat held")
        let uploadHandler = try XCTUnwrap(MockURLProtocol.handler)
        let requestText = #"{"probe":"discover"}"#
        let responseText = #"{"real":true}"#
        let requestBytes = Data([0xff]) + Data(requestText.utf8)
        let responseBytes = Data([0xff]) + Data(responseText.utf8)
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/v1/devices/register" {
                return jsonResponse(200, json: registerResponseJSON(app: "app", did: "did"))
            }
            if request.url?.host == "business.local" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(Self.bodyData(of: request), requestBytes)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/x-startup-test"])!
                return (response, responseBytes)
            }
            return try uploadHandler(request)
        }
        MockURLProtocol.deferredHandler = { transport in
            guard transport.request.url?.path.hasSuffix("/heartbeat") == true else { return false }
            gate.hold(transport)
            heartbeatStarted.fulfill()
            return true
        }
        TrafficCaptureController.shared.registerBinaryCodec(
            for: "x-startup-test", compression: .none,
            responseEncrypt: { Data([0xff]) + $0 },
            responseDecrypt: { $0.first == 0xff ? Data($0.dropFirst()) : nil },
            requestDecrypt: { $0.first == 0xff ? Data($0.dropFirst()) : nil })
        let connectionConfig = URLSessionConfiguration.ephemeral
        connectionConfig.protocolClasses = [MockURLProtocol.self]
        controller.clientFactory = { [connectionConfig] url in
            ConnectionClient(configuration: connectionConfig, baseURL: url)
        }
        controller.heartbeatIntervalOverride = 3600
        controller.start(server: serverURL, appID: "app", externalDID: "did", appVersion: nil,
                         sdkVersion: "test", osVersion: "test")
        defer { controller.stop() }
        wait(for: [heartbeatStarted], timeout: 3)
        XCTAssertFalse(TrafficCaptureController.shared.isCapturing)

        let businessConfig = URLSessionConfiguration.default
        XCTAssertTrue(businessConfig.protocolClasses?.contains { $0 == MockNetPackURLProtocol.self } == true)
        let businessSession = URLSession(configuration: businessConfig)
        defer { businessSession.finishTasksAndInvalidate() }
        for path in ["/character/get_discover_config", "/character/get_discover_list"] {
            var request = URLRequest(url: URL(string: "https://business.local" + path)!)
            request.httpMethod = "POST"
            request.httpBody = requestBytes
            request.setValue("application/x-startup-test", forHTTPHeaderField: "Content-Type")
            let completed = expectation(description: path + " completed before heartbeat")
            businessSession.dataTask(with: request) { data, _, error in
                XCTAssertNil(error)
                XCTAssertEqual(data, responseBytes)
                completed.fulfill()
            }.resume()
            wait(for: [completed], timeout: 3)
        }
        XCTAssertTrue(uploads.snapshot.isEmpty)
        XCTAssertFalse(TrafficCaptureController.shared.isCapturing)
        gate.release(sessionID: "delayed-first-session")
        waitForUpload()
        let body = try XCTUnwrap(uploads.snapshot.first)
        XCTAssertEqual(body["sessionId"] as? String, "delayed-first-session")
        let entries = try XCTUnwrap(body["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.compactMap { $0["path"] as? String },
                       ["/character/get_discover_config", "/character/get_discover_list"])
        for entry in entries {
            XCTAssertEqual(entry["method"] as? String, "POST")
            XCTAssertEqual(entry["requestBodyBase64"] as? String, requestBytes.base64EncodedString())
            XCTAssertEqual(entry["responseBodyBase64"] as? String, responseBytes.base64EncodedString())
            XCTAssertEqual(entry["requestBodyDecoded"] as? String, requestText)
            XCTAssertEqual(entry["responseBodyDecoded"] as? String, responseText)
        }
    }
}
