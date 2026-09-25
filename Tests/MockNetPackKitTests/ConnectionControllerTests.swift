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

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()

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
        TrafficCaptureController.shared.stop()
        super.tearDown()
    }

    // MARK: - 辅助

    /// 轮询等待条件成立。
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
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

        controller.start(server: serverURL, appID: appID, appVersion: "1.0", appName: "Dokimo", sdkVersion: "0.2.0-m9", osVersion: "17.5")

        // 先注册、再心跳。
        waitUntil { self.registerCalls >= 1 && self.heartbeatCalls >= 1 }

        // 注册请求体正确。
        let registerReq = MockURLProtocol.recordedRequests.first { $0.url?.path.hasSuffix("/devices/register") == true }
        let body = bodyOfRequest(registerReq!)
        XCTAssertEqual(body?["app"] as? String, appID)
        XCTAssertEqual(body?["platform"] as? String, "ios")
        XCTAssertEqual(body?["sdkVersion"] as? String, "0.2.0-m9")
        XCTAssertEqual(body?["appVersion"] as? String, "1.0")
        XCTAssertEqual(body?["appName"] as? String, "Dokimo", "v0.9.0: SDK must report the host app display name")
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

        // 注册成功、心跳一次后 404 → M7.2.3：静默停循环，不再重新注册。
        waitUntil(timeout: 3) { self.registerCalls >= 1 && self.heartbeatCalls >= 1 }
        waitUntil { self.controller.connectionState == .offline }

        // 等一会确认不再产生新的 register/heartbeat（不再重连循环）。
        let frozenReg = registerCalls
        let frozenHb = heartbeatCalls
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(registerCalls, frozenReg, "404 后不应再重新注册")
        XCTAssertEqual(heartbeatCalls, frozenHb, "404 后不应再心跳")
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

    func testHeartbeatIntervalFollowsServerConfig() {
        // 不注入 override：注册响应下发 interval=5（钳制下限），
        // 验证 SDK 以服务端配置为准（而非固定/默认值）。
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

        // M3 fix：注册后首次心跳为快速 2s（启动首屏尽快拉规则），不验证首跳间隔；
        // 验证从第二次起按服务端配置 5s 节奏心跳。
        waitUntil(timeout: 4) { self.heartbeatCalls >= 1 }
        let t1 = Date()
        waitUntil(timeout: 10) { self.heartbeatCalls >= 2 }
        let gap = Date().timeIntervalSince(t1)
        XCTAssertGreaterThanOrEqual(gap, 4.0,
            "第二次起心跳间隔应采纳服务端配置 5s（实测 \(gap)s）")
        XCTAssertLessThanOrEqual(gap, 10.0)
    }

    // MARK: - M2.4 采集联动

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
}
