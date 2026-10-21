import Foundation

// ============================================================================
// MockNetPackKit 连接层模型（与 server/openapi/mocknetpack.yaml 对齐）
// ============================================================================

/// 设备连接状态（SDK 侧视角；服务端另有 derived offline 判定）。
public enum ConnectionState: Sendable, Equatable {
    /// 未配置服务器：无已保存地址，`start()` 无参直接进入，等待扫码连接。
    case unconfigured
    /// 启动/注册中，尚未确认在线。
    case connecting
    /// 心跳成功，服务端在线。
    case connected
    /// 心跳失败（网络/5xx），退避重连中。
    case offline
    /// 配对令牌无效/过期（4.13）：携带配对令牌注册收到 403 → 停止连接循环并上抛
    /// 此状态，业务方可提示「二维码已过期，请刷新」；不再无限退避重连。
    case tokenInvalid
}

/// 抓包会话状态（由心跳响应 session 字段推导；SDK 据此启停采集）。
public enum SessionState: Sendable, Equatable {
    /// 待命：无激活会话。
    case idle
    /// 抓包中：服务端存在激活会话，SDK 应采集/执行 Mock。
    case capturing
}

/// 服务端下发的心跳配置（契约 ServerConfig）。
struct ServerConfig: Codable, Equatable {
    let heartbeatIntervalSeconds: Int
    let heartbeatTimeoutSeconds: Int
}

/// 心跳响应（契约 HeartbeatResponse）。
struct HeartbeatResponse: Codable {
    let ok: Bool
    let serverTime: String
    let serverConfig: ServerConfig
    let session: CaptureSession?
    let rulesVersion: Int?
    /// push mock 规则版本；老服务端不下发 → nil，按 0 处理。
    let pushRulesVersion: Int?
    /// pending「模拟推送」指令（模拟推送形态；无指令时省略 → nil）。
    let pushCommands: [PushRuleCommand]?
}

/// 抓包会话（契约 CaptureSession； 仅用于状态判断）。
struct CaptureSession: Codable {
    let id: String
    let app: String
    let did: String
    let status: String
    let startedAt: String
    let endedAt: String?
    let requestCount: Int
    let viewerCount: Int

    var isCapturing: Bool { status == "capturing" }
}

/// 心跳请求（契约 HeartbeatRequest；可选上报 sdkVersion）。
struct HeartbeatRequest: Encodable {
    let sdkVersion: String
}

/// 设备注册请求（契约 RegisterDeviceRequest；可选 pairingToken/deviceName）。
struct RegisterDeviceRequest: Encodable {
    let app: String
    let did: String
    let platform: String
    let osVersion: String
    let sdkVersion: String
    let appVersion: String
    /// App 显示名：读宿主 CFBundleDisplayName（如 IntegratingApp）；可选，Web 显示回退 bundle id。
    let appName: String?
    /// 扫码配对令牌：来自二维码；有效时未知 (app, did) 自动注册，已存在则复用。
    /// nil 时省略字段，服务端保持  语义（未知设备 404）。
    let pairingToken: String?
    /// 扫码自动注册时的设备显示名（可选）；不提供则服务端回退 platform+did 前缀。
    let deviceName: String?
}

/// 设备注册响应（契约 RegisterDeviceResponse）。
struct RegisterDeviceResponse: Decodable {
    let device: DeviceView
    let serverConfig: ServerConfig
}

/// 设备视图（契约 Device schema 子集； 仅校验 app/did）。
struct DeviceView: Decodable {
    let app: String
    let did: String
    let status: String
    let lastSeenAt: String?
    let registeredAt: String?
}

// ============================================================================
// Traffic 模型（与 server/openapi/mocknetpack.yaml 对齐）
// ============================================================================

/// 一条 HTTP 请求/响应的完整信息（契约 TrafficEntry）。
/// id / sessionId 由服务端生成，SDK 不携带；mocked 由服务端默认 false。
struct TrafficEntry: Encodable {
    /// 请求发起时间（RFC3339）。
    var timestamp: Date
    var method: String
    var url: String
    var path: String
    var query: String
    var requestHeaders: [String: [String]]
    var requestBody: String
    /// 二进制请求体 base64（无法 UTF-8 解码时填充；否则 nil）。
    var requestBodyBase64: String?
    /// 请求体经 App 注入的协议解码器解出的可读 UTF-8 文本；
    /// 仅作 Web 展示，存在时 Web 优先展示它，无则回退 requestBody 的占位文本。不参与回放。
    var requestBodyDecoded: String?
    /// 响应状态码；请求失败时为 nil。
    var statusCode: Int?
    var responseHeaders: [String: [String]]?
    var responseBody: String?
    /// 二进制响应体 base64（无法 UTF-8 解码时填充；否则 nil）。
    var responseBodyBase64: String?
    /// App 注入的协议解码器解出的可读响应体文本；仅展示用，回放仍走 base64。
    var responseBodyDecoded: String?
    /// 错误信息；成功时为 nil。
    var error: String?
    var durationMs: Int
    /// 命中 Mock 规则回包时为 true（服务端在 Web 请求流标注
    /// “Mock 命中”）。走真实网络时为 false。
    var mocked: Bool = false
    /// 命中的规则 ID：仅 mocked=true 时非空，用于确认请求究竟
    /// 命中哪一条规则；真实流量为 nil。
    var matchedRuleId: String?
}

/// 批量上传请求（契约 TrafficUploadRequest；单批 ≤500 条，由 SDK 攒批控制）。
struct TrafficUploadRequest: Encodable {
    let app: String
    let did: String
    let sessionId: String
    let entries: [TrafficEntry]
}

/// 上传响应（契约 TrafficUploadResponse；count 为实际接受数）。
struct TrafficUploadResponse: Decodable {
    let accepted: Bool
    let count: Int
}

// ============================================================================
// Mock 规则模型（与 server/openapi/mocknetpack.yaml 对齐）
// ============================================================================

/// Mock 回包（契约 MockResponse）。
struct MockResponse: Codable, Equatable {
    let statusCode: Int
    var headers: [String: String]?
    var body: String?
    /// 二进制回包 base64；存在时按原始字节回包，body 仅作展示。
    var bodyBase64: String?
    /// Mock 回包延迟毫秒数。nil/0 = 立即回包。
    /// 服务端 delayMs=0 时 omitempty 不下发该字段，Swift 解码为 nil，走立即回包路径；
    /// 故用 Optional 对齐老服务端（缺字段不 throw）。用 `var` 与结构体其它可选字段一致：
    /// 既让合成 Decodable 真正解码该 key（`let = nil` 常量会被合成解码跳过），
    /// 又让本地成员初始化器对既有构造点省略为 nil。
    var delayMs: Int?
    /// 命中该回包的规则 ID（ P1-1：match 时填充，随命中流量上报
    /// matchedRuleId）。解码自服务端时不携带，仅本地匹配后设置。
    var ruleId: String?
}

/// 一条设备级 Mock 规则（契约 MockRule）。SDK 侧只关心匹配与回包字段；
/// source/createdAt 等由服务端管理，SDK 解码后不使用。
struct MockRule: Codable, Equatable {
    let id: String
    let method: String
    let path: String
    let response: MockResponse
    let enabled: Bool
    /// 服务端计算的运行时生效态；SDK 只对 effective=true 的规则回包。
    let effective: Bool
}

/// 规则下发响应（契约 MockRuleList）。SDK 增量拉取时 version 为当前版本、
/// rules 为 effective=true 的规则集（版本未变时为空数组）。
struct MockRuleList: Decodable {
    let version: Int
    let rules: [MockRule]
}

// ============================================================================
// Push mock 规则模型（与 server/openapi/mocknetpack.yaml 对齐）
// ============================================================================

/// push 匹配条件（契约 PushMockMatch）。服务端全字段 omitempty，SDK 侧全
/// optional；实时拦截按「最多 1 条 JSONPath + 1 个子串」轻量子集执行。
struct PushMockMatch: Decodable, Equatable {
    let jsonPath: String?
    let jsonPathOp: String?
    let jsonPathValue: String?
    let keyword: String?
}

/// JSONPath 比较操作符取值（契约 PushMockMatch.jsonPathOp）。
enum PushMatchOp {
    static let equals = "equals"
    static let contains = "contains"
}

/// 一条设备级 push mock 规则（契约 PushMockRule，SDK 线格式 sdkPushRuleView：
/// owner/hitCount/source/note 等 Web-only 字段不下发）。SDK 只关心匹配与替换。
struct PushMockRule: Decodable, Equatable {
    let id: String
    let channelId: String
    /// 业务消息类型（契约可选：yaml 非 required；空 = 规则不限定 bizType）。
    /// 与 yaml 对齐为 Optional：服务端对空 bizType 的规则恒输出 bizType 字段
    /// （指令/规则非 Optional 缺字段 decode 失败、整批拉取失败；SDK 端均已对齐 Optional）。
    let bizType: String?
    let match: PushMockMatch
    /// 替换 payload 文本（JSON 字符串）；存在时使用。
    let replacePayload: String?
    /// 替换 payload base64（无法文本化的二进制）；与 replacePayload 二选一。
    let replacePayloadBase64: String?
    let enabled: Bool
    /// 服务端计算的运行时生效态；SDK 只对 effective=true 的规则执行替换。
    let effective: Bool
}

/// push 规则下发响应（契约 PushMockRuleList）。与 MockRuleList 同模式：
/// version 为当前版本、rules 为 effective=true 的规则集（版本未变时为空数组）。
struct PushMockRuleList: Decodable {
    let version: Int
    let rules: [PushMockRule]
}

/// 一条「模拟推送」pending 指令（契约 PushRuleCommandView，SDK 线）：
/// 心跳响应携带；SDK 注入后经 push-rule-commands/ack 回报消费。
/// 经 PushMockInjecting 协议（一步注入）消费本类型 → 公开。
public struct PushRuleCommand: Codable, Equatable, Sendable {
    public let id: String
    public let ruleId: String
    public let channelId: String
    /// 业务消息类型（契约可选：yaml 非 required；空 = 规则不限定 bizType）。
    /// 与 yaml 对齐为 Optional：服务端对空 bizType 的指令可省略该字段
    /// （非 Optional 缺字段 decode 失败、心跳整体失败、指令永不消费；服务端恒输出 bizType 字段）。
    public let bizType: String?
    /// 替换 payload 文本（与 payloadBase64 二选一）。
    public let payload: String?
    /// 替换 payload 原始字节（base64）。
    public let payloadBase64: String?

    public init(id: String, ruleId: String, channelId: String, bizType: String?,
                payload: String?, payloadBase64: String?) {
        self.id = id
        self.ruleId = ruleId
        self.channelId = channelId
        self.bizType = bizType
        self.payload = payload
        self.payloadBase64 = payloadBase64
    }
}
