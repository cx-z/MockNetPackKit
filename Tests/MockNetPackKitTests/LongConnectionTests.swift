import XCTest
@testable import MockNetPackKit

/// 长连接采集通道——开关、独立额度（丢最旧）、payload 截断、
/// snapshot 30s 兜底、多 channel 分组上传。
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

    private func bodyData(of request: URLRequest) -> Data {
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&chunk, maxLength: chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
        }
        return buffer
    }

    private func bodyOfRequest(_ request: URLRequest) -> [String: Any]? {
        let data = bodyData(of: request)
        guard !data.isEmpty else { return nil }
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

    private func makeRecord(channel: String = "srwebsocket",
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

    // MARK: - adapter 标识：API 注入未标来源 → unknown-inject；已标来源透传

    func testCollectorLabelsUnknownInjectAdapter() {
        let controller = TrafficCaptureController.shared

        // ① 纯 API 注入（未带 adapter）→ collector 统一标 unknown-inject。
        LongConnectionCollector.shared.record(makeRecord(msgId: "m-adapter-1"))
        // ② 适配器采集（带 adapter="srwebsocket"）→ 透传不覆盖。
        var adapterRecord = makeRecord(msgId: "m-adapter-2")
        adapterRecord.adapter = "srwebsocket"
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
        XCTAssertEqual(byMsg["m-adapter-2"]?["adapter"] as? String, "srwebsocket",
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

    // MARK: - 验收：payload 上限 50KB（超限保留前缀，不再降级 1KB 预览）

    /// 单条记录入队并上传后，按 msgId 取上传体里的记录 JSON。
    private func uploadRecord(msgId: String, _ configure: (inout LongConnectionRecordInput) -> Void) -> [String: Any] {
        let controller = TrafficCaptureController.shared
        var record = LongConnectionRecordInput(channelId: "srwebsocket",
                                               eventType: .packet,
                                               ts: Date(timeIntervalSince1970: 1_700_000_000),
                                               payloadText: nil)
        record.msgId = msgId
        configure(&record)
        controller.recordLongConnection(record)
        controller.flush()
        waitUntil {
            self.longConnUploads().contains { request in
                self.recordsInUpload(request).contains { $0["msgId"] as? String == msgId }
            }
        }
        let records = longConnUploads().flatMap(recordsInUpload)
        guard let rec = records.first(where: { $0["msgId"] as? String == msgId }) else {
            XCTFail("uploaded record \(msgId) not found")
            return [:]
        }
        return rec
    }

    func testLongConnPayloadTextBelowAndAtLimitKeptInFull() {
        // 旧 10KB 上限之上、新 50KB 之下的文本必须完整（修复「超 10KB 就只剩 1KB」）。
        let aboveOldLimit = String(repeating: "a", count: 11 * 1024)
        let rec1 = uploadRecord(msgId: "text-11k") { $0.payloadText = aboveOldLimit }
        XCTAssertEqual(rec1["payloadText"] as? String, aboveOldLimit)
        XCTAssertNil(rec1["payloadPreview"])

        // 恰好 51200 字节：原样保留。
        let atLimit = String(repeating: "b", count: 51200)
        let rec2 = uploadRecord(msgId: "text-at-limit") { $0.payloadText = atLimit }
        XCTAssertEqual(rec2["payloadText"] as? String, atLimit)
        XCTAssertNil(rec2["payloadPreview"])
    }

    func testLongConnPayloadTextOverLimitKeepsPrefix() {
        let over = String(repeating: "c", count: 51201)
        let rec = uploadRecord(msgId: "text-over-limit") { $0.payloadText = over }
        guard let text = rec["payloadText"] as? String else {
            return XCTFail("oversized payloadText must stay in payloadText, not be cleared")
        }
        XCTAssertEqual(text, String(repeating: "c", count: 51200), "keep the first 51200 bytes")
        XCTAssertLessThanOrEqual(text.utf8.count, 51200)
        XCTAssertNil(rec["payloadBase64"])
        XCTAssertNil(rec["payloadPreview"], "new capture must not fall back to 1KB preview")
        XCTAssertFalse(text.contains("\u{FFFD}"), "truncation must not introduce replacement chars")
    }

    func testLongConnPayloadTextOverLimitKeepsValidUTF8Prefix() {
        // 中文（3 字节）边界：17067 个汉字 = 51201 字节，只能保留 17066 个（51198 字节）。
        let chinese = String(repeating: "中", count: 17067)
        let rec = uploadRecord(msgId: "text-cjk-boundary") { $0.payloadText = chinese }
        let text = rec["payloadText"] as? String
        XCTAssertEqual(text, String(repeating: "中", count: 17066),
                       "must cut on a full scalar boundary, not mid-character")
        XCTAssertLessThanOrEqual(text?.utf8.count ?? .max, 51200)
        XCTAssertFalse(text?.contains("\u{FFFD}") ?? true)

        // emoji（4 字节）：51198 个 a + 😀 = 51202 字节，emoji 被边界切断 → 只留 51198 个 a。
        let emoji = String(repeating: "a", count: 51198) + "😀"
        let rec2 = uploadRecord(msgId: "text-emoji-boundary") { $0.payloadText = emoji }
        let text2 = rec2["payloadText"] as? String
        XCTAssertEqual(text2, String(repeating: "a", count: 51198))
        XCTAssertLessThanOrEqual(text2?.utf8.count ?? .max, 51200)
        XCTAssertFalse(text2?.contains("\u{FFFD}") ?? true)

        // 恰好落在字符边界（51196 个 a + 😀 = 51200 字节）：完整保留。
        let exactEmoji = String(repeating: "a", count: 51196) + "😀"
        let rec3 = uploadRecord(msgId: "text-emoji-exact") { $0.payloadText = exactEmoji }
        XCTAssertEqual(rec3["payloadText"] as? String, exactEmoji)
        XCTAssertNil(rec3["payloadPreview"])
    }

    func testLongConnPayloadBase64BelowAndAtLimitKeptInFull() {
        let below = Data((0..<51200).map { UInt8($0 % 251) })
        let rec1 = uploadRecord(msgId: "bin-at-limit") { $0.payloadBase64 = below.base64EncodedString() }
        XCTAssertEqual(rec1["payloadBase64"] as? String, below.base64EncodedString())
        XCTAssertNil(rec1["payloadText"])
        XCTAssertNil(rec1["payloadPreview"])

        let small = Data((0..<1024).map { UInt8($0 % 251) })
        let rec2 = uploadRecord(msgId: "bin-small") { $0.payloadBase64 = small.base64EncodedString() }
        XCTAssertEqual(rec2["payloadBase64"] as? String, small.base64EncodedString())
        XCTAssertNil(rec2["payloadPreview"])
    }

    func testLongConnPayloadBase64OverLimitKeepsDecodablePrefix() {
        let raw = Data((0..<51201).map { UInt8($0 % 251) })
        let rec = uploadRecord(msgId: "bin-over-limit") { $0.payloadBase64 = raw.base64EncodedString() }
        guard let b64 = rec["payloadBase64"] as? String else {
            return XCTFail("oversized payloadBase64 must stay in payloadBase64, not be cleared")
        }
        XCTAssertNotEqual(b64, raw.base64EncodedString(), "oversized base64 must be truncated")
        XCTAssertNil(rec["payloadText"])
        XCTAssertNil(rec["payloadPreview"], "new capture must not fall back to 1KB preview")

        guard let decoded = Data(base64Encoded: b64) else {
            return XCTFail("truncated base64 must remain decodable")
        }
        XCTAssertEqual(decoded.count, 51200)
        XCTAssertEqual(decoded, Data(raw.prefix(51200)),
                       "decoded prefix must equal the first 51200 raw bytes")
    }

    func testLongConnInvalidBase64KeptAsIs() {
        // 非法 base64 无从计算原始字节数：沿用既有约定（解码失败即保留原值），
        // 不静默清空、不伪造截断数据。
        let invalid = String(repeating: "not-base64!", count: 8 * 1024)
        let rec = uploadRecord(msgId: "bin-invalid") { $0.payloadBase64 = invalid }
        XCTAssertEqual(rec["payloadBase64"] as? String, invalid)
        XCTAssertNil(rec["payloadPreview"])
    }

    func testLongConnLegacyPayloadPreviewStillPassedThrough() {
        // 旧字段兼容：调用方仍可携带 payloadPreview（历史日志形态），采集层不清空、不改写。
        let rec = uploadRecord(msgId: "legacy-preview") { $0.payloadPreview = "(empty)" }
        XCTAssertEqual(rec["payloadPreview"] as? String, "(empty)")
        XCTAssertNil(rec["payloadText"])
        XCTAssertNil(rec["payloadBase64"])
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

    // MARK: - 批量上传：字节阈值须为 JSON 转义/信封留余量

    func testLongConnBatchByteThresholdKeepsRequestUnderServerCap() {
        // 用带引号/换行的类 JSON 文本（真实 push 形态，序列化时会被转义放大）验证：
        // 估算值虽不含转义，单批请求体仍须守住 6MB 阈值决定的余量（8MB 会超界）。
        let controller = TrafficCaptureController.shared
        // 关掉 0.1s 定时 flush，避免它在 200 条注入循环中间插入把批次拆碎，
        // 让分批只由字节阈值和末尾显式 flush() 决定。
        controller.flushInterval = 3600
        let line = "        \"message\": \"push payload with quotes, commas and spaces\",\n"
        let payload = String(repeating: line, count: 51200 / line.utf8.count + 24)
        for i in 0..<200 {
            controller.recordLongConnection(makeRecord(payloadText: payload, msgId: "cap-\(i)"))
        }
        controller.flush()
        waitUntil(timeout: 8) {
            let uploads = self.longConnUploads()
            return uploads.count >= 2
                && uploads.reduce(0) { $0 + self.recordsInUpload($1).count } == 200
        }

        let uploads = longConnUploads()
        XCTAssertGreaterThanOrEqual(uploads.count, 2,
                                    "200 条 50KB 记录在 6MB 阈值下必须拆成多批")
        let recordCounts = uploads.map { recordsInUpload($0).count }
        XCTAssertEqual(recordCounts.reduce(0, +), 200, "all injected records must be uploaded")
        XCTAssertTrue(recordCounts.contains { $0 < 200 },
                      "字节阈值必须在 200 条上限前触发")

        let bodyBytes = uploads.map { bodyData(of: $0).count }
        for bytes in bodyBytes {
            // 7.5MiB：6MB 阈值实测约 6.5MiB 通过；若回退到 8MB 实测约 8.6MiB 会红。
            XCTAssertLessThan(bytes, 7 * 1024 * 1024 + 512 * 1024,
                              "escaped batch body \(bytes) exceeds the 6MB-threshold margin (7.5MiB)")
        }
        XCTAssertGreaterThanOrEqual(bodyBytes.max() ?? 0, 5 * 1024 * 1024,
                                    "lower bound proves the byte threshold really accumulated a large batch, not a 1MB regression")
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
