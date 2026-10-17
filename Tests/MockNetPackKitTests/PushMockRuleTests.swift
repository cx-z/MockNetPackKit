import XCTest
@testable import MockNetPackKit

/// push mock 规则拉取——模型解码、activeRules 过滤、增量版本比对、
/// fail-open A（拉取失败沿用旧快照）。
final class PushMockRuleTests: XCTestCase {

    private let appID = "com.test.app"
    private let did = "did-1"
    private let baseURL = URL(string: "http://mock.local/api/v1")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()
        PushMockRuleController.shared.reset()
    }

    override func tearDown() {
        PushMockRuleController.shared.reset()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()
        super.tearDown()
    }

    private func client() -> ConnectionClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return ConnectionClient(configuration: config, baseURL: baseURL)
    }

    // MARK: - 模型解码（服务端 sdkPushRuleView 线格式）

    /// 完整线格式：含 jsonPath 条件与 replacePayloadBase64。
    func testDecodesFullSDKView() throws {
        let json = """
        {"version":3,"rules":[
          {"id":"R1","channelId":"xcpush_tcp","bizType":"1",
           "match":{"jsonPath":"$.data.tip","jsonPathOp":"contains","jsonPathValue":"hello"},
           "replacePayload":"{\\"type\\":\\"chat\\"}","enabled":true,"effective":true},
          {"id":"R2","channelId":"xcpush_tcp","bizType":"",
           "match":{"keyword":"tip"},
           "replacePayloadBase64":"aGVsbG8=","enabled":true,"effective":false}
        ]}
        """
        let list = try JSONDecoder().decode(PushMockRuleList.self, from: Data(json.utf8))
        XCTAssertEqual(list.version, 3)
        XCTAssertEqual(list.rules.count, 2)

        let r1 = list.rules[0]
        XCTAssertEqual(r1.id, "R1")
        XCTAssertEqual(r1.channelId, "xcpush_tcp")
        XCTAssertEqual(r1.bizType, "1")
        XCTAssertEqual(r1.match.jsonPath, "$.data.tip")
        XCTAssertEqual(r1.match.jsonPathOp, "contains")
        XCTAssertEqual(r1.match.jsonPathValue, "hello")
        XCTAssertEqual(r1.replacePayload, "{\"type\":\"chat\"}")
        XCTAssertNil(r1.replacePayloadBase64)
        XCTAssertTrue(r1.enabled && r1.effective)

        let r2 = list.rules[1]
        XCTAssertEqual(r2.match.keyword, "tip")
        XCTAssertNil(r2.match.jsonPath)
        XCTAssertEqual(r2.replacePayloadBase64, "aGVsbG8=")
        XCTAssertNil(r2.replacePayload)
        XCTAssertFalse(r2.effective)
    }

    /// match 全字段缺失（Go omitempty）→ optional 为 nil，解码不失败。
    func testDecodesEmptyMatch() throws {
        let json = """
        {"version":1,"rules":[
          {"id":"R","channelId":"xcpush_tcp","bizType":"1",
           "match":{},"replacePayload":"{}","enabled":true,"effective":true}
        ]}
        """
        let list = try JSONDecoder().decode(PushMockRuleList.self, from: Data(json.utf8))
        XCTAssertNil(list.rules[0].match.jsonPath)
        XCTAssertNil(list.rules[0].match.keyword)
    }

    /// 规则列表 bizType 字段缺失（旧服务端 omitempty）→ decode 不失败、bizType
    /// 为 nil。回归：PushMockRule.bizType 曾为非
    /// Optional String，缺字段令整批规则列表 decode 失败（keyNotFound）。
    func testDecodesRuleWithoutBizType() throws {
        let json = """
        {"version":1,"rules":[
          {"id":"R","channelId":"xcpush_tcp",
           "match":{},"replacePayload":"{}","enabled":true,"effective":true}
        ]}
        """
        let list = try JSONDecoder().decode(PushMockRuleList.self, from: Data(json.utf8))
        XCTAssertNil(list.rules[0].bizType, "缺省 bizType 应解码为 nil（契约非 required）")
    }

    // MARK: - PushRuleCommand 指令解码（心跳响应 pushCommands 线格式）

    /// bizType 字段缺失（空 bizType 规则 + 服务端 omitempty）→ decode 不失败、
    /// bizType 为 nil。回归：该字段曾为非 Optional String，
    /// 缺字段令整个心跳响应 decode 失败（keyNotFound），指令永不消费。
    func testDecodesCommandWithoutBizType() throws {
        let json = """
        {"id":"CMD1","ruleId":"RULE1","channelId":"xcpush_tcp",
         "payload":"{\\"content\\":\\"hi\\"}"}
        """
        let cmd = try JSONDecoder().decode(PushRuleCommand.self, from: Data(json.utf8))
        XCTAssertEqual(cmd.id, "CMD1")
        XCTAssertEqual(cmd.ruleId, "RULE1")
        XCTAssertEqual(cmd.channelId, "xcpush_tcp")
        XCTAssertNil(cmd.bizType, "缺省 bizType 应解码为 nil（契约非 required）")
        XCTAssertEqual(cmd.payload, "{\"content\":\"hi\"}")
        XCTAssertNil(cmd.payloadBase64)
    }

    /// 显式空串 bizType（服务端修复后恒输出字段）→ bizType == ""（非 nil）。
    func testDecodesCommandWithEmptyBizType() throws {
        let json = """
        {"id":"CMD1","ruleId":"RULE1","channelId":"xcpush_tcp","bizType":"",
         "payload":"{}"}
        """
        let cmd = try JSONDecoder().decode(PushRuleCommand.self, from: Data(json.utf8))
        XCTAssertEqual(cmd.bizType, "", "显式空串保持空串")
    }

    // MARK: - activeRules 过滤（channelId 必选 + bizType 可选 + effective）

    func testActiveRulesFiltering() {
        let rules = [
            PushMockRule(id: "A", channelId: "xcpush_tcp", bizType: "1",
                         match: PushMockMatch(jsonPath: nil, jsonPathOp: nil, jsonPathValue: nil, keyword: "a"),
                         replacePayload: "{}", replacePayloadBase64: nil, enabled: true, effective: true),
            // 同 channelId 不同 bizType → 不命中 bizType=1
            PushMockRule(id: "B", channelId: "xcpush_tcp", bizType: "2",
                         match: PushMockMatch(jsonPath: nil, jsonPathOp: nil, jsonPathValue: nil, keyword: "b"),
                         replacePayload: "{}", replacePayloadBase64: nil, enabled: true, effective: true),
            // bizType 空 = 匹配任意 bizType
            PushMockRule(id: "C", channelId: "xcpush_tcp", bizType: "",
                         match: PushMockMatch(jsonPath: nil, jsonPathOp: nil, jsonPathValue: nil, keyword: "c"),
                         replacePayload: "{}", replacePayloadBase64: nil, enabled: true, effective: true),
            // effective=false → 不进生效集
            PushMockRule(id: "D", channelId: "xcpush_tcp", bizType: "1",
                         match: PushMockMatch(jsonPath: nil, jsonPathOp: nil, jsonPathValue: nil, keyword: "d"),
                         replacePayload: "{}", replacePayloadBase64: nil, enabled: true, effective: false),
            // 不同 channelId → 不命中
            PushMockRule(id: "E", channelId: "other", bizType: "1",
                         match: PushMockMatch(jsonPath: nil, jsonPathOp: nil, jsonPathValue: nil, keyword: "e"),
                         replacePayload: "{}", replacePayloadBase64: nil, enabled: true, effective: true),
        ]
        PushMockRuleController.shared.applyForTesting(rules: rules, version: 7)

        let hit = PushMockRuleController.shared.activeRules(channelId: "xcpush_tcp", bizType: "1")
        let ids = hit.map(\.id).sorted()
        XCTAssertEqual(ids, ["A", "C"], "effective=true + channelId 匹配 + bizType 匹配或空")
    }

    // MARK: - 增量版本比对

    /// 版本一致 → 不发拉取请求（no-op）。
    func testSyncVersionMatchNoOp() async {
        PushMockRuleController.shared.applyForTesting(rules: [], version: 5)
        await PushMockRuleController.shared.syncIfNeeded(
            client: client(), app: appID, did: did, serverVersion: 5)
        XCTAssertTrue(MockURLProtocol.recordedRequests.isEmpty,
                      "version match must not pull")
    }

    /// 版本不一致 → 增量拉取并应用快照。
    func testSyncPullsAndApplies() async {
        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.contains("/push-mock-rules"))
            XCTAssertTrue(request.url!.query!.contains("sinceVersion=5"))
            let body = """
            {"version":6,"rules":[
              {"id":"R1","channelId":"xcpush_tcp","bizType":"1",
               "match":{"keyword":"tip"},"replacePayload":"{\\"tip\\":\\"mocked\\"}",
               "enabled":true,"effective":true}
            ]}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        PushMockRuleController.shared.applyForTesting(rules: [], version: 5)

        await PushMockRuleController.shared.syncIfNeeded(
            client: client(), app: appID, did: did, serverVersion: 6)

        let rules = PushMockRuleController.shared.activeRules(channelId: "xcpush_tcp", bizType: "1")
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].id, "R1")
        XCTAssertEqual(rules[0].replacePayload, "{\"tip\":\"mocked\"}")
    }

    // MARK: - fail-open A

    /// 拉取失败（HTTP 500）→ 沿用旧快照，继续 Mock。
    func testSyncFailureKeepsOldSnapshot() async {
        MockURLProtocol.handler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 500,
                                    httpVersion: nil, headerFields: nil)!,
                    Data("boom".utf8))
        }
        let old = PushMockRule(id: "OLD", channelId: "xcpush_tcp", bizType: "1",
                               match: PushMockMatch(jsonPath: nil, jsonPathOp: nil, jsonPathValue: nil, keyword: "old"),
                               replacePayload: "{}", replacePayloadBase64: nil, enabled: true, effective: true)
        PushMockRuleController.shared.applyForTesting(rules: [old], version: 5)

        await PushMockRuleController.shared.syncIfNeeded(
            client: client(), app: appID, did: did, serverVersion: 6)

        let rules = PushMockRuleController.shared.activeRules(channelId: "xcpush_tcp", bizType: "1")
        XCTAssertEqual(rules.map(\.id), ["OLD"], "failed pull keeps old snapshot")
    }
}
