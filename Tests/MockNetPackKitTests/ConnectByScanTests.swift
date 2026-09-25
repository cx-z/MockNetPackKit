import XCTest
@testable import MockNetPackKit

/// M9.2 扫码连接门面测试：mock 扫码结果 + MockURLProtocol 模拟注册/心跳。
@MainActor
final class ConnectByScanTests: XCTestCase {

    /// 测试用可变状态容器（@Sendable 闭包内安全捕获）。
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// mock 扫码提供者：返回预置结果或抛出预置错误。
    @MainActor
    private final class MockQRScanner: QRScanProviding {
        private let result: String?
        private let error: QRScanError?
        init(result: String?, error: QRScanError? = nil) {
            self.result = result
            self.error = error
        }
        func scanQRCode() async throws -> String? {
            if let error { throw error }
            return result
        }
    }

    private var config: URLSessionConfiguration!

    /// 测试宿主进程的 bundle id（与门面 bundleID 同源：Bundle.main ?? "unknown.app"）。
    private var testAppID: String { Bundle.main.bundleIdentifier ?? "unknown.app" }

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()
        MockNetPackKit.stop()
        MockNetPackKit.resetServer()
        // 测试宿主无 main bundle id → 门面 bundleID = testAppID。
        config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        // 扫码成功后 start(server:) 的连接也走 mock（注册 + 心跳）。
        ConnectionController.shared.clientFactory = { [config] url in
            ConnectionClient(configuration: config, baseURL: url)
        }
        ConnectionController.shared.heartbeatIntervalOverride = 0.15
        ConnectionController.shared.backoffBase = 0.05
    }

    override func tearDown() {
        MockNetPackKit.stop()
        MockNetPackKit.resetServer()
        TrafficCaptureController.shared.stop()
        MockRuleController.shared.reset()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()
        super.tearDown()
    }

    // MARK: - 辅助

    /// 断言扫码结果为指定失败分类（Result<Void, _> 无 Equatable，需 switch）。
    private func assertFailure(_ result: Result<Void, MockNetPackKit.ConnectByScanError>,
                               _ expected: MockNetPackKit.ConnectByScanError,
                               file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success:
            XCTFail("expected failure \(expected), got success", file: file, line: line)
        case .failure(let e):
            XCTAssertEqual(e, expected, file: file, line: line)
        }
    }

    /// 断言扫码成功。
    private func assertSuccess(_ result: Result<Void, MockNetPackKit.ConnectByScanError>,
                               file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success:
            break
        case .failure(let e):
            XCTFail("expected success, got failure \(e)", file: file, line: line)
        }
    }

    /// 轮询等待条件成立。
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("condition not met within \(timeout)s")
    }

    /// 构造符合协议的二维码文本（Web 端同款编码：base64url 去 padding）。
    private func qr(server: String = "http://mock.local/api/v1",
                    appID: String? = nil,
                    token: String = "tok-abc") -> String {
        let app = appID ?? testAppID
        let u = Data(server.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "mocknetpack://connect?v=1&u=\(u)&a=\(app)&t=\(token)"
    }

    /// 返回指定 path 的请求体（JSON 解码为字典）。
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

    // MARK: - 用例

    /// A2 前提：无已保存地址时 `start()` 无参 → .unconfigured（不发起网络）。
    func testStart_NoSavedAddress_Unconfigured() {
        MockNetPackKit.start()
        XCTAssertEqual(ConnectionController.shared.connectionState, .unconfigured)
        XCTAssertTrue(ConnectionController.shared.isRunning)
    }

    /// 有已保存地址时 `start()` 无参 → 直连（免扫码，A2）。
    func testStart_WithSavedAddress_ConnectsDirectly() {
        ServerAddressStore.save(URL(string: "http://mock.local/api/v1")!, forApp: testAppID)
        let appID = testAppID
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: appID, did: "any"))
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil))
        }
        MockNetPackKit.start()
        waitUntil { ConnectionController.shared.connectionState == .connected }
        XCTAssertEqual(MockNetPackKit.savedServerURL?.absoluteString, "http://mock.local/api/v1")
    }

    /// D1/D4/D7 主路径：扫码 → 解析 → 令牌注册 → 持久化地址 → 连接。
    /// 注册请求携带 pairingToken，且 did 复用启动时解析的 did（不新生成）。
    func testScanSuccess_RegistersWithToken_PersistsAndConnects() async {
        // 先启动无参（未配置）→ did 已解析（D7：扫码注册复用同一 did）。
        MockNetPackKit.start()
        let did = ConnectionController.shared.did!
        XCTAssertFalse(did.isEmpty)

        let appID = testAppID
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: appID, did: did))
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil))
        }

        let clientConfig: URLSessionConfiguration = config
        let scanner = MockQRScanner(result: qr(token: "tok-abc"))
        let result = await MockNetPackKit.connectByScan(scanner: scanner,
                                        makeClient: { url in
                                            ConnectionClient(configuration: clientConfig, baseURL: url)
                                        })
        assertSuccess(result)

        // 地址已持久化（后续 start() 无参直连）。
        XCTAssertEqual(MockNetPackKit.savedServerURL?.absoluteString, "http://mock.local/api/v1")

        // 注册请求：携带令牌 + 复用启动 did（D7 幂等复用关键）。
        let registerReq = MockURLProtocol.recordedRequests.first { $0.url?.path.hasSuffix("/devices/register") == true }
        XCTAssertNotNil(registerReq, "扫码流程应发起注册")
        let body = bodyOfRequest(registerReq!)
        XCTAssertEqual(body?["pairingToken"] as? String, "tok-abc")
        XCTAssertEqual(body?["did"] as? String, did, "扫码注册必须复用启动 did，不得新生成")

        // 注册成功后连接建立（心跳 200 → connected）。
        waitUntil { ConnectionController.shared.connectionState == .connected }
    }

    /// D6：已连接时扫码新服务器 → 直接切换（旧地址被替换，连接指向新服务器）。
    func testScanWhileConnected_SwitchesServer() async {
        // 先连上旧服务器。
        ServerAddressStore.save(URL(string: "http://old.local/api/v1")!, forApp: testAppID)
        let appID = testAppID
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/devices/register") == true {
                return jsonResponse(200, json: registerResponseJSON(app: appID, did: "any"))
            }
            return jsonResponse(200, json: heartbeatResponseJSON(session: nil))
        }
        MockNetPackKit.start()
        waitUntil { ConnectionController.shared.connectionState == .connected }

        // 扫码新服务器 → 注册成功 → 地址切换。
        let clientConfig: URLSessionConfiguration = config
        let scanner = MockQRScanner(result: qr(server: "http://new.local/api/v1", token: "tok-new"))
        let result = await MockNetPackKit.connectByScan(scanner: scanner,
                                        makeClient: { url in
                                            ConnectionClient(configuration: clientConfig, baseURL: url)
                                        })
        assertSuccess(result)
        XCTAssertEqual(MockNetPackKit.savedServerURL?.absoluteString, "http://new.local/api/v1",
                       "D6：扫码切换应替换持久化地址")
    }

    /// R1.6：非法二维码 → invalidPayload，已保存地址不被覆盖。
    func testScan_InvalidPayload_KeepsSavedAddress() async {
        ServerAddressStore.save(URL(string: "http://good.local/api/v1")!, forApp: testAppID)
        let clientConfig: URLSessionConfiguration = config
        let scanner = MockQRScanner(result: "not-a-mocknetpack-qr")
        let result = await MockNetPackKit.connectByScan(scanner: scanner,
                                        makeClient: { url in
                                            ConnectionClient(configuration: clientConfig, baseURL: url)
                                        })
        assertFailure(result, .invalidPayload)
        XCTAssertEqual(MockNetPackKit.savedServerURL?.absoluteString, "http://good.local/api/v1")
    }

    /// D4 防错扫：appID 不匹配 → appMismatch。
    func testScan_AppMismatch() async {
        let clientConfig: URLSessionConfiguration = config
        let scanner = MockQRScanner(result: qr(appID: "com.other.app"))
        let result = await MockNetPackKit.connectByScan(scanner: scanner,
                                        makeClient: { url in
                                            ConnectionClient(configuration: clientConfig, baseURL: url)
                                        })
        assertFailure(result, .appMismatch)
    }

    /// R1.6 + 令牌校验：注册 403 pairing_token_invalid → tokenInvalid，地址不覆盖。
    func testScan_Register403_TokenInvalid_KeepsSavedAddress() async {
        ServerAddressStore.save(URL(string: "http://good.local/api/v1")!, forApp: testAppID)
        MockURLProtocol.handler = { request in
            return jsonResponse(403, json: ["error": "pairing_token_invalid", "message": "expired"])
        }
        let clientConfig: URLSessionConfiguration = config
        let scanner = MockQRScanner(result: qr(server: "http://bad.local/api/v1"))
        let result = await MockNetPackKit.connectByScan(scanner: scanner,
                                        makeClient: { url in
                                            ConnectionClient(configuration: clientConfig, baseURL: url)
                                        })
        assertFailure(result, .tokenInvalid)
        XCTAssertEqual(MockNetPackKit.savedServerURL?.absoluteString, "http://good.local/api/v1")
    }

    /// 服务器不可达 → unreachable，地址不覆盖。
    func testScan_NetworkError_Unreachable() async {
        ServerAddressStore.save(URL(string: "http://good.local/api/v1")!, forApp: testAppID)
        MockURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        let clientConfig: URLSessionConfiguration = config
        let scanner = MockQRScanner(result: qr(server: "http://down.local/api/v1"))
        let result = await MockNetPackKit.connectByScan(scanner: scanner,
                                        makeClient: { url in
                                            ConnectionClient(configuration: clientConfig, baseURL: url)
                                        })
        assertFailure(result, .unreachable)
        XCTAssertEqual(MockNetPackKit.savedServerURL?.absoluteString, "http://good.local/api/v1")
    }

    /// 用户取消扫码 → cancelled。
    func testScan_Cancelled() async {
        let clientConfig: URLSessionConfiguration = config
        let scanner = MockQRScanner(result: nil)
        let result = await MockNetPackKit.connectByScan(scanner: scanner,
                                        makeClient: { url in
                                            ConnectionClient(configuration: clientConfig, baseURL: url)
                                        })
        assertFailure(result, .cancelled)
    }

    /// 相机权限被拒 → cameraDenied。
    func testScan_CameraDenied() async {
        let clientConfig: URLSessionConfiguration = config
        let scanner = MockQRScanner(result: nil, error: .cameraDenied)
        let result = await MockNetPackKit.connectByScan(scanner: scanner,
                                        makeClient: { url in
                                            ConnectionClient(configuration: clientConfig, baseURL: url)
                                        })
        assertFailure(result, .cameraDenied)
    }

    /// 相机不可用（模拟器）→ cameraUnavailable。
    func testScan_CameraUnavailable() async {
        let clientConfig: URLSessionConfiguration = config
        let scanner = MockQRScanner(result: nil, error: .cameraUnavailable)
        let result = await MockNetPackKit.connectByScan(scanner: scanner,
                                        makeClient: { url in
                                            ConnectionClient(configuration: clientConfig, baseURL: url)
                                        })
        assertFailure(result, .cameraUnavailable)
    }
}
