import XCTest
@testable import MockNetPackKit

/// L2.1：长连接采集通道——开关、独立额度（丢最旧）、payload 截断、
/// snapshot 30s 兜底、多 channel 分组上传（能力线 L1）。
final class LongConnectionTests: XCTestCase {

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
        controller.maxLongConnEntries = 1000
        controller.longConnectionCaptureEnabled = true
        controller.longConnSnapshotFallbackInterval = 30
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-1")
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
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("condition not met within \(timeout)s")
    }

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

    private func longConnUploads() -> [URLRequest] {
        MockURLProtocol.recordedRequests.filter { $0.url?.path.hasSuffix("/longconn") == true }
    }

    private func recordsInUpload(_ request: URLRequest) -> [[String: Any]] {
        guard let body = bodyOfRequest(request),
              let records = body["records"] as? [[String: Any]] else { return [] }
        return records
    }

    private func makeRecord(channel: String = "xcpush_tcp",
                            event: LongConnectionEventType = .packet,
                            payloadText: String? = "hello",
                            msgId: String? = nil) -> LongConnectionRecordInput {
        var r = LongConnectionRecordInput(channelId: channel,
                                          eventType: event,
                                          ts: Date(timeIntervalSince1970: 1_700_000_000),
                                          payloadText: payloadText)
        r.msgId = msgId
        return r
    }

    // MARK: - L6.2 adapter 标识：API 注入未标来源 → unknown-inject；已标来源透传

    func testCollectorLabelsUnknownInjectAdapter() {
        let controller = TrafficCaptureController.shared

        // ① 纯 API 注入（未带 adapter）→ collector 统一标 unknown-inject。
        LongConnectionCollector.shared.record(makeRecord(msgId: "m-adapter-1"))
        // ② 适配器采集（带 adapter="xcpush"）→ 透传不覆盖。
        var adapterRecord = makeRecord(msgId: "m-adapter-2")
        adapterRecord.adapter = "xcpush"
        LongConnectionCollector.shared.record(adapterRecord)

        controller.flush()
        waitUntil { self.longConnUploads().contains { !self.recordsInUpload($0).isEmpty } }

        let records = longConnUploads().flatMap(recordsInUpload)
        let byMsg = Dictionary(uniqueKeysWithValues: records.compactMap { r -> (String, [String: Any])? in
            guard let id = r["msgId"] as? String else { return nil }
            return (id, r)
        })
        XCTAssertEqual(byMsg["m-adapter-1"]?["adapter"] as? String, "unknown-inject",
                       "API 注入未标来源应如实标注 unknown-inject")
        XCTAssertEqual(byMsg["m-adapter-2"]?["adapter"] as? String, "xcpush",
                       "已带 adapter 标识的记录应原样透传")
    }

    // MARK: - 验收：开关关闭无上报

    func testLongConnDisabledDropsWithoutUpload() {
        let controller = TrafficCaptureController.shared
        controller.longConnectionCaptureEnabled = false
        controller.recordLongConnection(makeRecord(msgId: "m0"))
        controller.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(longConnUploads().contains { $0.url?.path.hasSuffix("/longconn") == true },
                       "capture disabled must not upload longconn records")

        // 重新开启后同一开关语义恢复（正向对照）。
        controller.longConnectionCaptureEnabled = true
        controller.recordLongConnection(makeRecord(msgId: "m1"))
        controller.flush()
        waitUntil { !self.longConnUploads().isEmpty }
        XCTAssertTrue(longConnUploads().contains { $0.url?.path.hasSuffix("/longconn") == true })
    }

    // MARK: - 验收：独立额度超限丢最旧

    func testLongConnQuotaDropsOldest() {
        let controller = TrafficCaptureController.shared
        controller.maxLongConnEntries = 3
        for i in 0..<5 {
            controller.recordLongConnection(makeRecord(msgId: "m\(i)"))
        }
        controller.flush()
        waitUntil { !self.longConnUploads().isEmpty }
        XCTAssertEqual(longConnUploads().count, 1, "single channel batches into one request")
        let records = recordsInUpload(longConnUploads()[0])
        XCTAssertEqual(records.count, 3, "quota 3 keeps only the newest 3")
        let msgIds = records.compactMap { $0["msgId"] as? String }
        XCTAssertEqual(msgIds, ["m2", "m3", "m4"], "oldest entries m0/m1 must be dropped")
    }

    // MARK: - 验收：payload 截断（完整 ≤10KB，超限仅存预览 ≤1KB）

    func testLongConnPayloadTruncation() {
        let controller = TrafficCaptureController.shared
        let big = String(repeating: "a", count: 11 * 1024) // > 10KB
        controller.recordLongConnection(makeRecord(payloadText: big, msgId: "big"))
        controller.flush()
        waitUntil { !self.longConnUploads().isEmpty }
        let records = recordsInUpload(longConnUploads()[0])
        let rec = records[0]
        XCTAssertNil(rec["payloadText"], "oversized payload must not be kept in full")
        guard let preview = rec["payloadPreview"] as? String else {
            return XCTFail("payloadPreview expected for oversized payload")
        }
        XCTAssertLessThanOrEqual(preview.utf8.count, 1024, "preview must be ≤1KB")
    }

    func testLongConnSmallPayloadKeptInFull() {
        let controller = TrafficCaptureController.shared
        controller.recordLongConnection(makeRecord(payloadText: "small", msgId: "s"))
        controller.flush()
        waitUntil { !self.longConnUploads().isEmpty }
        let rec = recordsInUpload(longConnUploads()[0])[0]
        XCTAssertEqual(rec["payloadText"] as? String, "small")
        XCTAssertNil(rec["payloadPreview"])
    }

    // MARK: - snapshot 30s 兜底（状态变化立即上报 + 周期性补发）

    func testLongConnSnapshotFallback() {
        let controller = TrafficCaptureController.shared
        controller.longConnSnapshotFallbackInterval = 0 // 注入：任何间隔都触发兜底
        var snap = makeRecord(event: .snapshot, payloadText: nil, msgId: "snap-1")
        snap.snapshot = LongConnectionSnapshot(state: "connected", clientId: "c1")
        controller.recordLongConnection(snap)
        controller.flush()
        waitUntil { self.longConnUploads().count >= 1 }
        // 无新记录再次 flush：缓存快照满足兜底条件 → 补发一条。
        controller.flush()
        waitUntil { self.longConnUploads().count >= 2 }
        let last = recordsInUpload(longConnUploads()[longConnUploads().count - 1])
        XCTAssertEqual(last.first?["msgId"] as? String, "snap-1",
                       "fallback re-sends the cached snapshot")
    }

    // MARK: - 多 channel 分组上传（多框架共存）

    func testLongConnMultiChannelGrouping() {
        let controller = TrafficCaptureController.shared
        controller.recordLongConnection(makeRecord(channel: "xcpush_tcp", msgId: "a"))
        controller.recordLongConnection(makeRecord(channel: "srwebsocket", msgId: "b"))
        controller.flush()
        waitUntil { self.longConnUploads().count >= 2 }
        let channelIDs = longConnUploads().compactMap { req -> String? in
            guard let body = bodyOfRequest(req) else { return nil }
            return body["channelId"] as? String
        }
        XCTAssertEqual(Set(channelIDs), Set(["xcpush_tcp", "srwebsocket"]),
                       "each channel uploads its own batch")
    }
}
