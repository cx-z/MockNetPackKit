import XCTest
@testable import MockNetPackKit

/// L5.5：注入模式（L4 业务桥接）与代理模式（L5 自动采集）并存去重——
/// 同一通道（channelId）同一包（msgId）在去重窗口内不重复上报；
/// 窗口外重复（服务端真实重发）保持现有 duplicate 标记语义不受影响。
final class LongConnectionDedupTests: XCTestCase {

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
        let uploadConfig = URLSessionConfiguration.ephemeral
        uploadConfig.protocolClasses = [MockURLProtocol.self]
        controller.clientFactory = { [uploadConfig] url in
            ConnectionClient(configuration: uploadConfig, baseURL: url)
        }
        controller.flushInterval = 0.1
        controller.maxLongConnEntries = 1000
        controller.longConnectionCaptureEnabled = true
        controller.longConnSnapshotFallbackInterval = 30
        controller.longConnDedupWindowInterval = 2
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

    private func makeRecord(channel: String = "dedup_tcp",
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

    private func collectAllRecords(minCount: Int) -> [[String: Any]] {
        // 等待汇总记录数达到预期（flushInterval 自动 flush 可能产生多个请求；
        // 第二条的上传请求可能在首次 waitUntil 后仍未完成，故按条数而非请求数等待）。
        TrafficCaptureController.shared.flush()
        waitUntil {
            self.longConnUploads().flatMap { self.recordsInUpload($0) }.count >= minCount
        }
        return longConnUploads().flatMap { recordsInUpload($0) }
    }

    // MARK: - 验收：窗口内双路径重复只上报一条

    func testDedupSameChannelSameMsgIdWithinWindow() {
        let controller = TrafficCaptureController.shared
        // 模拟并存：注入模式与代理模式先后上报同一通道同一包（毫秒级时差）。
        controller.recordLongConnection(makeRecord(channel: "xcpush_tcp", msgId: "d1"))
        controller.recordLongConnection(makeRecord(channel: "xcpush_tcp", msgId: "d1"))
        let records = collectAllRecords(minCount: 1)
        XCTAssertEqual(records.count, 1, "same channel+msgId within window must dedup to one record")
        XCTAssertEqual(records[0]["msgId"] as? String, "d1")
    }

    // MARK: - 验收：窗口外重复（服务端真实重发）保留

    func testDedupOutsideWindowKeepsBoth() {
        let controller = TrafficCaptureController.shared
        controller.longConnDedupWindowInterval = 0.05
        controller.recordLongConnection(makeRecord(channel: "xcpush_tcp", msgId: "d2"))
        // 超过窗口再上报同 msgId（真实重发场景）——窗口表过期条目应被清理且不去重。
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        controller.recordLongConnection(makeRecord(channel: "xcpush_tcp", msgId: "d2"))
        let records = collectAllRecords(minCount: 2)
        XCTAssertEqual(records.count, 2, "same msgId outside window must be kept (server redelivery)")
        let msgIds = records.compactMap { $0["msgId"] as? String }
        XCTAssertEqual(msgIds, ["d2", "d2"])
    }

    // MARK: - 验收：跨通道不去重（不同通道同 msgId 是不同会话）

    func testDedupDifferentChannelSameMsgId() {
        let controller = TrafficCaptureController.shared
        controller.recordLongConnection(makeRecord(channel: "xcpush_tcp", msgId: "d3"))
        controller.recordLongConnection(makeRecord(channel: "other_tcp", msgId: "d3"))
        let records = collectAllRecords(minCount: 2)
        XCTAssertEqual(records.count, 2, "same msgId on different channels must not dedup")
    }

    // MARK: - 验收：同通道不同 msgId 不去重

    func testDedupSameChannelDifferentMsgId() {
        let controller = TrafficCaptureController.shared
        controller.recordLongConnection(makeRecord(channel: "xcpush_tcp", msgId: "d4"))
        controller.recordLongConnection(makeRecord(channel: "xcpush_tcp", msgId: "d5"))
        let records = collectAllRecords(minCount: 2)
        XCTAssertEqual(records.count, 2, "different msgIds on same channel must not dedup")
    }

    // MARK: - 验收：生命周期事件（snapshot 等无 msgId）不去重

    func testSnapshotEventsNotDeduped() {
        let controller = TrafficCaptureController.shared
        controller.recordLongConnection(makeRecord(channel: "xcpush_tcp", event: .snapshot, payloadText: nil, msgId: nil))
        controller.recordLongConnection(makeRecord(channel: "xcpush_tcp", event: .snapshot, payloadText: nil, msgId: nil))
        let records = collectAllRecords(minCount: 2)
        XCTAssertEqual(records.count, 2, "snapshot events carry no msgId and must not be deduped")
    }

    // MARK: - 验收：packet 但无 msgId 不去重

    func testPacketWithoutMsgIdNotDeduped() {
        let controller = TrafficCaptureController.shared
        controller.recordLongConnection(makeRecord(channel: "xcpush_tcp", msgId: nil))
        controller.recordLongConnection(makeRecord(channel: "xcpush_tcp", msgId: nil))
        let records = collectAllRecords(minCount: 2)
        XCTAssertEqual(records.count, 2, "packet without msgId must not be deduped")
    }
}
