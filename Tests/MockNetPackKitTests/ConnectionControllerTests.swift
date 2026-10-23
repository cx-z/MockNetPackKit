import XCTest
@testable import MockNetPackKit

final class ConnectionControllerTests: XCTestCase {

    /// 测试用可变状态容器（@Sendable 闭包内安全捕获）。
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private var controller: ConnectionController!
    private let serverURL = URL(string: "http://mock.local/api/v1")!
    private let appID = "com.test.app"

    /// iOS-AN9：Mock 快照隔离——独立 UserDefaults suite，避免读取真实设备残留快照干扰。
    private static let mockSuiteName = "MockNetPackKitTests.ConnectionController"
    private var mockDefaults: UserDefaults { UserDefaults(suiteName: Self.mockSuiteName)! }

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()

        // iOS-AN9：注入隔离快照 store（磁盘空）并重置，冷启动语义。
        MockRuleController.shared.snapshotStore = MockRuleSnapshotStore(defaults: mockDefaults)
        mockDefaults.removePersistentDomain(forName: Self.mockSuiteName)
        MockRuleController.shared.reset()

        controller = ConnectionController()
        // 加速：心跳间隔与退避基数都用极小值。
        controller.heartbeatIntervalOverride = 0.15
        controller.backoffBase = 0.05
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        controller.clientFactory = { [config] url in
            ConnectionClient(configuration: config, baseURL: url)
        }
    }

    override func tearDown() {
        controller?.stop()
        controller = nil
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()
        MockRuleController.shared.snapshotStore = MockRuleSnapshotStore() // 恢复 .standard
        mockDefaults.removePersistentDomain(forName: Self.mockSuiteName)
        TrafficCaptureController.shared.stop()
        super.tearDown()
    }

    // MARK: - 辅助

    /// 轮询等待条件成立。用单调时钟（systemUptime）计时：调度/定时器走 mach
    /// 时钟，墙钟（Date()）在系统时钟跳变（VM/NTP 校时）时会与定时器分离，
    /// 造成"定时器 3s 已到而断言测出 27s/277s"的假失败（4.20 验证期实锤）。
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("condition not met within \(timeout)s")
    }

    /// 返回指定 path 的请求体（JSON 解码为字典）。
    /// URLSession 可能把 httpBody 转为 httpBodyStream，需两者都读。
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

    private var registerCalls: Int {
        MockURLProtocol.recordedRequests.filter { $0.url?.path.hasSuffix("/devices/register") == true }.count
    }

    private var heartbeatCalls: Int {
        MockURLProtocol.recordedRequests.filter { $0.url?.path.hasSuffix("/heartbeat") == true }.count
    }

    // MARK: - 用例

    func testStart_RegistersThenHeartbeats_Idle() {
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: "com.test.app", did: "any"))
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil))
        }

        controller.start(server: serverURL, appID: appID, appVersion: "1.0", appName: "IntegratingApp", sdkVersion: "0.2.0-m9", osVersion: "17.5")

        // 先注册、再心跳。
        waitUntil { self.registerCalls >= 1 && self.heartbeatCalls >= 1 }

        // 注册请求体正确。
        let registerReq = MockURLProtocol.recordedRequests.first { $0.url?.path.hasSuffix("/devices/register") == true }
        let body = bodyOfRequest(registerReq!)
        XCTAssertEqual(body?["app"] as? String, appID)
        XCTAssertEqual(body?["platform"] as? String, "ios")
        XCTAssertEqual(body?["sdkVersion"] as? String, "0.2.0-m9")
        XCTAssertEqual(body?["appVersion"] as? String, "1.0")
        XCTAssertEqual(body?["appName"] as? String, "IntegratingApp", "SDK must report the host app display name")
        XCTAssertNotNil(body?["did"] as? String)

        // 心跳路径带 app/did。
        let hbReq = MockURLProtocol.recordedRequests.first { $0.url?.path.hasSuffix("/heartbeat") == true }
        XCTAssertTrue(hbReq!.url!.path.contains(appID), "心跳路径应包含 app")

        // 状态：connected + idle（无会话）。
        waitUntil { self.controller.connectionState == .connected }
        XCTAssertEqual(controller.sessionState, .idle)
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.did?.count, 36)
    }

    func testHeartbeatWithSession_SetsCapturingAndCallback() {
        let serverHasSession = Box(true)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: "com.test.app", did: "any"))
            }
            if serverHasSession.value {
                return jsonResponse(200, json: heartbeatResponseJSON(session: sessionJSON(id: "sess-1")))
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil))
        }

        let callback = expectation(description: "session state callback")
        let callbackStates = Box<[SessionState]>([])
        controller.onSessionStateChange = { state in
            callbackStates.value.append(state)
            if state == .capturing { callback.fulfill() }
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m2", osVersion: "17.5")

        wait(for: [callback], timeout: 3)
        XCTAssertEqual(controller.sessionState, .capturing)
        XCTAssertTrue(callbackStates.value.contains(.capturing))

        // 服务端会话结束 → 心跳返回无 session → 回到 idle。
        serverHasSession.value = false
        waitUntil { self.controller.sessionState == .idle }
    }

    /// 首次心跳 404 后停循环并结束启动暂存，不继续接管业务 HTTP。
    func testHeartbeat404_StopsQuietly() {
        let failNextHeartbeat = Box(true)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: "com.test.app", did: "any"))
            }
            if failNextHeartbeat.value {
                failNextHeartbeat.value = false
                // 契约错误码 device_not_registered = 404。
                return jsonResponse(404, json: ["error": "device_not_registered", "message": "not registered"])
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil))
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m2", osVersion: "17.5")

        // 注册成功、心跳一次后 404 → ：静默停循环，不再重新注册。
        waitUntil(timeout: 3) { self.registerCalls >= 1 && self.heartbeatCalls >= 1 }
        waitUntil { self.controller.connectionState == .offline }

        // 等一会确认不再产生新的 register/heartbeat（不再重连循环）。
        let frozenReg = registerCalls
        let frozenHb = heartbeatCalls
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(registerCalls, frozenReg, "404 后不应再重新注册")
        XCTAssertEqual(heartbeatCalls, frozenHb, "404 后不应再心跳")
        XCTAssertNil(TrafficCaptureController.shared.httpCaptureGeneration)
    }

    func testNetworkFailure_BackoffReconnects() {
        let failHeartbeat = Box(true)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: "com.test.app", did: "any"))
            }
            if failHeartbeat.value {
                throw URLError(.cannotConnectToHost)
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil))
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m2", osVersion: "17.5")

        // 网络失败 → offline + 重试（心跳多次）。
        waitUntil { self.controller.connectionState == .offline && self.heartbeatCalls >= 2 }

        // 网络恢复 → 重连成功。
        failHeartbeat.value = false
        waitUntil { self.controller.connectionState == .connected }
        waitUntil { self.controller.sessionState == .idle }
    }

    func testStop_StopsHeartbeating() {
        let heartbeatCount = Box(0)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: "com.test.app", did: "any"))
            }
            heartbeatCount.value += 1
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil))
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m2", osVersion: "17.5")
        waitUntil { heartbeatCount.value >= 2 }

        controller.stop()
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.connectionState, .offline)
        XCTAssertEqual(controller.sessionState, .idle)

        // 等待一小段，确认不再产生新心跳。
        let frozen = heartbeatCount.value
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(heartbeatCount.value, frozen, "stop 后不应再有心跳")
    }

    /// 4.7 回归：stop() 时心跳仍在途，旧心跳结果返回后不得把连接状态"翻活"
    /// （不得置 connected/capturing，也不得继续调度新循环）。
    func testStop_InFlightHeartbeatResultDiscarded() {
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: "com.test.app", did: "any"))
            }
            // 慢心跳：挂起直到 stop() 后放行，模拟"在途"的 await。
            gate.wait()
            return jsonResponse(200, json: heartbeatResponseJSON(session: sessionJSON(id: "sess-late")))
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m2", osVersion: "17.5")

        // 心跳请求已发出、handler 被 gate 阻塞（在途）。
        waitUntil { self.heartbeatCalls >= 1 }

        controller.stop()
        XCTAssertEqual(controller.connectionState, .offline)

        // 放行旧心跳 → 返回"成功 + 会话"。旧代结果必须被丢弃。
        gate.signal()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(controller.connectionState, .offline, "stop 后旧心跳结果不得翻活连接状态")
        XCTAssertEqual(controller.sessionState, .idle, "stop 后旧心跳结果不得置 capturing")
        XCTAssertFalse(controller.isRunning)

        // 旧代循环不得再调度新心跳。
        let frozen = heartbeatCalls
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(heartbeatCalls, frozen, "stop 后旧代循环不得再调度新心跳")
    }

    func testHeartbeatIntervalFollowsServerConfig() {
        // 不注入 override：注册响应下发 interval=5（4.12 后仍是服务端下发值、
        // 高于钳制下限 2s），验证 SDK 以服务端配置为准（而非固定/默认值）。
        controller.heartbeatIntervalOverride = nil
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                // 注册响应即携带服务端配置（interval=5）。
                return jsonResponse(200, json: [
                    "device": [
                        "app": "com.test.app", "did": "any", "status": "idle",
                        "lastSeenAt": "2026-09-19T00:00:00Z",
                        "registeredAt": "2026-09-19T00:00:00Z",
                    ],
                    "serverConfig": ["heartbeatIntervalSeconds": 5, "heartbeatTimeoutSeconds": 60],
                ])
            }
            return jsonResponse(200, json: [
                "ok": true, "serverTime": "2026-09-19T00:00:01Z",
                "serverConfig": ["heartbeatIntervalSeconds": 5, "heartbeatTimeoutSeconds": 60],
                "session": nil as Any?, "rulesVersion": 0,
            ])
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m2", osVersion: "17.5")

        //  fix：注册后首次心跳为快速 2s（启动首屏尽快拉规则），不验证首跳间隔；
        // 验证从第二次起按服务端配置 5s 节奏心跳。间隔用单调时钟测量（见 waitUntil）。
        waitUntil(timeout: 4) { self.heartbeatCalls >= 1 }
        let t1 = ProcessInfo.processInfo.systemUptime
        waitUntil(timeout: 10) { self.heartbeatCalls >= 2 }
        let gap = ProcessInfo.processInfo.systemUptime - t1
        XCTAssertGreaterThanOrEqual(gap, 4.0,
            "第二次起心跳间隔应采纳服务端配置 5s（实测 \(gap)s）")
        XCTAssertLessThanOrEqual(gap, 10.0)
    }

    // 4.12 回归：服务端契约下发 capturing 3s，SDK 不得把它钳制抬成 5s
    // （否则"快速感知规则变更"失效）。下限 2s 只挡误配，不挡契约值。
    func testHeartbeatIntervalAllowsCapturing3s() {
        controller.heartbeatIntervalOverride = nil
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: [
                    "device": [
                        "app": "com.test.app", "did": "any", "status": "idle",
                        "lastSeenAt": "2026-09-19T00:00:00Z",
                        "registeredAt": "2026-09-19T00:00:00Z",
                    ],
                    "serverConfig": ["heartbeatIntervalSeconds": 3, "heartbeatTimeoutSeconds": 60],
                ])
            }
            return jsonResponse(200, json: [
                "ok": true, "serverTime": "2026-09-19T00:00:01Z",
                "serverConfig": ["heartbeatIntervalSeconds": 3, "heartbeatTimeoutSeconds": 60],
                "session": nil as Any?, "rulesVersion": 0,
            ])
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m9", osVersion: "17.5")

        waitUntil(timeout: 4) { self.heartbeatCalls >= 1 }
        let t1 = ProcessInfo.processInfo.systemUptime
        waitUntil(timeout: 10) { self.heartbeatCalls >= 2 }
        let gap = ProcessInfo.processInfo.systemUptime - t1
        XCTAssertGreaterThanOrEqual(gap, 2.0,
            "第二次起心跳间隔应采纳服务端 capturing 3s（实测 \(gap)s）")
        XCTAssertLessThan(gap, 4.5,
            "3s 不得被钳制抬成 5s（旧钳制下限 5 会让 gap≈5s；实测 \(gap)s）")
    }

    /// 配对令牌注册 403 后停循环、上抛 tokenInvalid，并清除 HTTP 启动暂存。
    func testRegister403_WithPairingToken_StopsAndSurfacesTokenInvalid() {
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(403, json: ["error": "pairing_token_invalid", "message": "token expired"])
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil))
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil,
                         sdkVersion: "0.2.0-m9", osVersion: "17.5",
                         pairingToken: "stale-token", deviceName: "Test iPhone")

        waitUntil { self.controller.connectionState == .tokenInvalid }

        // 不再产生新的 register / heartbeat（不再无限退避重连）。
        let frozenReg = registerCalls
        let frozenHb = heartbeatCalls
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(registerCalls, frozenReg, "403 后不应再重新注册")
        XCTAssertEqual(heartbeatCalls, frozenHb, "403 后不应再心跳")
        XCTAssertNil(TrafficCaptureController.shared.httpCaptureGeneration)
    }

    // 4.13 对照：未携带配对令牌的 403 保持原有退避语义（不误伤其它 403 场景）。
    func testRegister403_WithoutPairingToken_KeepsBackoff() {
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(403, json: ["error": "forbidden"])
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil))
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil,
                         sdkVersion: "0.2.0-m9", osVersion: "17.5")

        // 无令牌 403 → 仍按退避重试（状态 offline，循环继续）。
        waitUntil { self.controller.connectionState == .offline && self.registerCalls >= 2 }
        XCTAssertNotEqual(controller.connectionState, .tokenInvalid)
    }

    // MARK: -  采集联动

    /// 心跳带会话 → 流量采集开启；会话结束 → 采集关闭。
    func testHeartbeatWithSession_DrivesTrafficCapture() {
        let serverHasSession = Box(true)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: "com.test.app", did: "any"))
            }
            if serverHasSession.value {
                return jsonResponse(200, json: heartbeatResponseJSON(session: sessionJSON(id: "sess-1")))
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil))
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m2", osVersion: "17.5")

        // 心跳确认 capturing → 采集开启（URLProtocol 注册并生效）。
        waitUntil { TrafficCaptureController.shared.isCapturing }

        // 会话结束 → 采集关闭。
        serverHasSession.value = false
        waitUntil { !TrafficCaptureController.shared.isCapturing }
    }

    /// stop 连接层 → 采集停止。
    func testStop_StopsTrafficCapture() {
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: "com.test.app", did: "any"))
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: sessionJSON(id: "sess-1")))
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m2", osVersion: "17.5")
        waitUntil { TrafficCaptureController.shared.isCapturing }

        controller.stop()
        XCTAssertFalse(TrafficCaptureController.shared.isCapturing)
    }

    /// 4.20 回归：默认构造复用进程级共享 URLSession（不再每次心跳 new
    /// session）；注入 configuration 的测试路径仍创建专用 session。
    func testConnectionClientReusesSharedSession() {
        let a = ConnectionClient(baseURL: serverURL)
        let b = ConnectionClient(baseURL: serverURL)
        XCTAssertTrue(a.session === b.session,
            "default clients must share the process-wide URLSession (4.20)")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let c = ConnectionClient(configuration: config, baseURL: serverURL)
        XCTAssertFalse(c.session === a.session,
            "injected configuration must keep its own session (test isolation)")
    }

    // MARK: - iOS-AN9 断连保护（Mock 规则快照）

    /// 注入一份「旧快照」到内存 + 磁盘（模拟上次会话同步并落盘；磁盘写入使
    /// 断连保护后的磁盘断言有意义——applyForTesting 本身只写内存）。
    private func seedOldSnapshot() {
        let rule = MockRule(
            id: "old-rule", method: "GET", path: "/old",
            response: MockResponse(statusCode: 503, headers: nil, body: "old", bodyBase64: nil, delayMs: nil),
            enabled: true, effective: true)
        MockRuleController.shared.reset()
        MockRuleController.shared.applyForTesting(rules: [rule], version: 1)
        MockRuleSnapshotStore(defaults: mockDefaults).save(MockRuleSnapshotStore.Snapshot(version: 1, rules: [rule]))
    }

    /// 旧规则 JSON（服务端下发用；静态避免 @Sendable handler 捕获 self）。
    private static func oldRuleJSON() -> [String: Any] {
        ["id": "old-rule", "method": "GET", "path": "/old",
         "response": ["statusCode": 503, "body": "old"],
         "enabled": true, "effective": true]
    }

    /// 新规则 JSON（服务端下发用；静态避免 @Sendable handler 捕获 self）。
    private static func newRuleJSON() -> [String: Any] {
        ["id": "new-rule", "method": "GET", "path": "/new",
         "response": ["statusCode": 201, "body": "new"],
         "enabled": true, "effective": true]
    }

    /// iOS-AN9：断连保护主路径——register 网络失败第 1 次快照仍生效、第 2 次清空、
    /// 恢复后 sinceVersion=0 全量重拉、旧规则不恢复。
    func testRegisterFailsTwice_ClearsMockSnapshot_ThenReconnects() {
        seedOldSnapshot()
        let registerFails = Box(2)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                if registerFails.value > 0 {
                    registerFails.value -= 1
                    throw URLError(.cannotConnectToHost) // 模拟断网
                }
                return jsonResponse(200, json: registerResponseJSON(app: "com.test.app", did: "any"))
            }
            if request.url?.path.hasSuffix("/mock-rules") == true {
                return jsonResponse(200, json: ["version": 2, "rules": [Self.newRuleJSON()]])
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil, rulesVersion: 2))
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m9", osVersion: "17.5")

        // 第 1 次失败：快照仍生效（不误清）。
        waitUntil { self.registerCalls >= 1 }
        XCTAssertNotNil(MockRuleController.shared.match(method: "GET", path: "/old"))

        // 第 2 次连续失败：清空内存+磁盘快照 → match nil。
        waitUntil { self.registerCalls >= 2 }
        XCTAssertNil(MockRuleController.shared.match(method: "GET", path: "/old"))
        XCTAssertNil(self.mockDefaults.data(forKey: MockRuleSnapshotStore.key), "磁盘快照应被清空")

        // 恢复（第 3 次注册成功）→ 心跳成功 → sinceVersion=0 全量重拉新规则。
        waitUntil { MockRuleController.shared.match(method: "GET", path: "/new") != nil }
        let pull = MockURLProtocol.recordedRequests.first { $0.url?.path.hasSuffix("/mock-rules") == true }
        XCTAssertEqual(pull?.url?.query, "sinceVersion=0", "清空后恢复应全量重拉（sinceVersion=0）")
        // 旧规则不恢复。
        XCTAssertNil(MockRuleController.shared.match(method: "GET", path: "/old"))
        XCTAssertNotNil(self.mockDefaults.data(forKey: MockRuleSnapshotStore.key), "恢复后新快照应重新落盘")
    }

    /// iOS-AN9 F1：heartbeat 网络失败 x2 同样受保护（注册成功后设备离开内网）。
    func testHeartbeatFailsTwice_ClearsMockSnapshot_ThenReconnects() {
        seedOldSnapshot()
        let failHeartbeats = Box(2)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: "com.test.app", did: "any"))
            }
            if request.url?.path.hasSuffix("/heartbeat") == true {
                if failHeartbeats.value > 0 {
                    failHeartbeats.value -= 1
                    throw URLError(.cannotConnectToHost)
                }
                return jsonResponse(200, json: heartbeatResponseJSON(session: sessionJSON(id: "s1"), rulesVersion: 2))
            }
            if request.url?.path.hasSuffix("/mock-rules") == true {
                return jsonResponse(200, json: ["version": 2, "rules": [Self.newRuleJSON()]])
            }
            return jsonResponse(404, json: ["error": "not_found"])
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m9", osVersion: "17.5")

        // 第 1 次心跳失败：快照仍生效。
        waitUntil { self.heartbeatCalls >= 1 }
        XCTAssertNotNil(MockRuleController.shared.match(method: "GET", path: "/old"))

        // 第 2 次连续失败：清空。
        waitUntil { self.heartbeatCalls >= 2 }
        XCTAssertNil(MockRuleController.shared.match(method: "GET", path: "/old"))
        XCTAssertNil(self.mockDefaults.data(forKey: MockRuleSnapshotStore.key))

        // 恢复 → 全量重拉新规则生效、旧不恢复。
        waitUntil { MockRuleController.shared.match(method: "GET", path: "/new") != nil }
        let pull = MockURLProtocol.recordedRequests.first { $0.url?.path.hasSuffix("/mock-rules") == true }
        XCTAssertEqual(pull?.url?.query, "sinceVersion=0")
        XCTAssertNil(MockRuleController.shared.match(method: "GET", path: "/old"))
    }

    /// iOS-AN9 连续失败语义：失败夹成功不误清——任意一次成功握手即重置计数。
    /// 7 次心跳 = 4 败 3 成（永不连续两次失败）→ 快照始终不被清空。
    func testInterleavedHeartbeatFailures_ResetCounter_WithoutClearing() {
        seedOldSnapshot()
        // false=失败（断网），true=成功；交替出现，永不连续两次失败。
        let hbSeq: [Bool] = [false, true, false, true, false, true, false]
        let hbIdx = Box(0)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: "com.test.app", did: "any"))
            }
            if request.url?.path.hasSuffix("/heartbeat") == true {
                let failed = hbIdx.value < hbSeq.count && !hbSeq[hbIdx.value]
                hbIdx.value += 1
                if failed { throw URLError(.cannotConnectToHost) }
                return jsonResponse(200, json: heartbeatResponseJSON(session: sessionJSON(id: "s1"), rulesVersion: 1))
            }
            if request.url?.path.hasSuffix("/mock-rules") == true {
                return jsonResponse(200, json: ["version": 1, "rules": []])
            }
            return jsonResponse(404, json: ["error": "not_found"])
        }

        let logs = Box<[String]>([])
        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m9", osVersion: "17.5",
                         logHandler: { logs.value.append($0) })

        waitUntil(timeout: 5) { self.heartbeatCalls >= hbSeq.count }
        XCTAssertNotNil(MockRuleController.shared.match(method: "GET", path: "/old"),
            "失败夹成功（交替）不应误清快照（连续失败语义）")
        XCTAssertNotNil(self.mockDefaults.data(forKey: MockRuleSnapshotStore.key))
        XCTAssertFalse(logs.value.contains { $0.contains("cleared local mock snapshot") },
            "交替失败/成功不应触发断连保护清空日志")
    }

    /// iOS-AN9 连续失败语义核心：第 1 段断连清空 → 恢复重拉（成功握手重置计数）→
    /// 第 2 段断连再次清空（累计语义下此处永不触发）。
    func testSecondDisconnectEpisode_ClearsSnapshotAgain() {
        seedOldSnapshot()
        let failSecondEpisode = Box(0)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: "com.test.app", did: "any"))
            }
            if request.url?.path.hasSuffix("/heartbeat") == true {
                if failSecondEpisode.value > 0 {
                    failSecondEpisode.value -= 1
                    throw URLError(.cannotConnectToHost)
                }
                return jsonResponse(200, json: heartbeatResponseJSON(session: sessionJSON(id: "s1"), rulesVersion: 2))
            }
            if request.url?.path.hasSuffix("/mock-rules") == true {
                return jsonResponse(200, json: ["version": 2, "rules": [Self.newRuleJSON()]])
            }
            return jsonResponse(404, json: ["error": "not_found"])
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m9", osVersion: "17.5")

        // 第 1 段：心跳成功（重置计数）→ 拉取新规则生效。
        waitUntil { MockRuleController.shared.match(method: "GET", path: "/new") != nil }
        // 第 2 段：连续 2 次心跳失败 → 新快照再次被清空。
        failSecondEpisode.value = 2
        waitUntil { MockRuleController.shared.match(method: "GET", path: "/new") == nil }
        XCTAssertNil(MockRuleController.shared.match(method: "GET", path: "/new"))
        XCTAssertNil(self.mockDefaults.data(forKey: MockRuleSnapshotStore.key))
    }

    /// iOS-AN9：register 404（设备未注册，永久拒绝）→ 立即清空 Mock 快照（不等 2 次）。
    func testRegister404_ClearsMockSnapshotImmediately() {
        seedOldSnapshot()
        MockURLProtocol.handler = { _ in
            jsonResponse(404, json: ["error": "device_not_registered"])
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m9", osVersion: "17.5")

        waitUntil { self.controller.connectionState == .offline }
        XCTAssertNil(MockRuleController.shared.match(method: "GET", path: "/old"), "404 永久拒绝应立即清空快照")
        XCTAssertNil(self.mockDefaults.data(forKey: MockRuleSnapshotStore.key))
    }

    /// iOS-AN9：heartbeat 404（设备未注册，永久拒绝）→ 立即清空 Mock 快照（不等 2 次）。
    func testHeartbeat404_ClearsMockSnapshotImmediately() {
        seedOldSnapshot()
        let failNextHeartbeat = Box(true)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: "com.test.app", did: "any"))
            }
            if failNextHeartbeat.value {
                failNextHeartbeat.value = false
                return jsonResponse(404, json: ["error": "device_not_registered"])
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil))
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil, sdkVersion: "0.2.0-m9", osVersion: "17.5")

        waitUntil { self.controller.connectionState == .offline }
        XCTAssertNil(MockRuleController.shared.match(method: "GET", path: "/old"), "心跳 404 应立即清空快照")
        XCTAssertNil(self.mockDefaults.data(forKey: MockRuleSnapshotStore.key))
    }

    /// iOS-AN9：register 403 + 配对令牌（令牌失效，永久拒绝）→ 立即清空 Mock 快照（不等 2 次）。
    func testRegister403_WithPairingToken_ClearsMockSnapshotImmediately() {
        seedOldSnapshot()
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(403, json: ["error": "pairing_token_invalid", "message": "token expired"])
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil))
        }

        controller.start(server: serverURL, appID: appID, appVersion: nil,
                         sdkVersion: "0.2.0-m9", osVersion: "17.5",
                         pairingToken: "stale-token", deviceName: "Test iPhone")

        waitUntil { self.controller.connectionState == .tokenInvalid }
        XCTAssertNil(MockRuleController.shared.match(method: "GET", path: "/old"), "403 令牌失效应立即清空快照")
        XCTAssertNil(self.mockDefaults.data(forKey: MockRuleSnapshotStore.key))
    }
}
