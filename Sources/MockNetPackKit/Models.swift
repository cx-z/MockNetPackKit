import Foundation

// ============================================================================
// MockNetPackKit 连接层模型（与 server/openapi/mocknetpack.yaml v0.1.0 对齐）
// ============================================================================

/// 设备连接状态（SDK 侧视角；服务端另有 derived offline 判定）。
public enum ConnectionState: Sendable, Equatable {
    /// 未配置服务器（M9.2）：无已保存地址，`start()` 无参直接进入，等待扫码连接。
    case unconfigured
    /// 启动/注册中，尚未确认在线。
    case connecting
    /// 心跳成功，服务端在线。
    case connected
    /// 心跳失败（网络/5xx），退避重连中。
    case offline
}

/// 抓包会话状态（由心跳响应 session 字段推导；SDK 据此启停采集）。
public enum SessionState: Sendable, Equatable {
    /// 待命：无激活会话。
    case idle
    /// 抓包中：服务端存在激活会话，SDK 应采集/执行 Mock（M2/M3 起）。
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
}

/// 抓包会话（契约 CaptureSession；M1.5 仅用于状态判断）。
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

/// 设备注册请求（契约 RegisterDeviceRequest；M9/v0.8.0 增可选 pairingToken/deviceName）。
struct RegisterDeviceRequest: Encodable {
    let app: String
    let did: String
    let platform: String
    let osVersion: String
    let sdkVersion: String
    let appVersion: String
    /// App 显示名（v0.9.0）：读宿主 CFBundleDisplayName（如 Dokimo）；可选，Web 显示回退 bundle id。
    let appName: String?
    /// 扫码配对令牌（M9）：来自二维码；有效时未知 (app, did) 自动注册（D1），已存在则复用（D7）。
    /// nil 时省略字段，服务端保持 M7.2.3 语义（未知设备 404）。
    let pairingToken: String?
    /// 扫码自动注册时的设备显示名（可选）；不提供则服务端回退 platform+did 前缀。
    let deviceName: String?
}

/// 设备注册响应（契约 RegisterDeviceResponse）。
struct RegisterDeviceResponse: Decodable {
    let device: DeviceView
    let serverConfig: ServerConfig
}

/// 设备视图（契约 Device schema 子集；M1.5 仅校验 app/did）。
struct DeviceView: Decodable {
    let app: String
    let did: String
    let status: String
    let lastSeenAt: String?
    let registeredAt: String?
}

// ============================================================================
// Traffic 模型（与 server/openapi/mocknetpack.yaml v0.2.0 对齐，M2.4）
// ============================================================================

/// 一条 HTTP 请求/响应的完整信息（契约 TrafficEntry）。
/// id / sessionId 由服务端生成，SDK 不携带；mocked 由服务端默认 false（M3 起标记）。
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
    /// 请求体经 App 注入的协议解码器解出的可读 UTF-8 文本（M8.1，与响应体同机制）；
    /// 仅作 Web 展示，存在时 Web 优先展示它，无则回退 requestBody 的占位文本。不参与回放。
    var requestBodyDecoded: String?
    /// 响应状态码；请求失败时为 nil。
    var statusCode: Int?
    var responseHeaders: [String: [String]]?
    var responseBody: String?
    /// 二进制响应体 base64（无法 UTF-8 解码时填充；否则 nil）。
    var responseBodyBase64: String?
    /// App 注入的协议解码器解出的可读响应体文本（M4）；仅展示用，回放仍走 base64。
    var responseBodyDecoded: String?
    /// 错误信息；成功时为 nil。
    var error: String?
    var durationMs: Int
    /// 命中 Mock 规则回包时为 true（契约 v0.3.0；服务端在 Web 请求流标注
    /// “Mock 命中”）。走真实网络时为 false。
    var mocked: Bool = false
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
// Mock 规则模型（与 server/openapi/mocknetpack.yaml v0.3.0 对齐，M3.4）
// ============================================================================

/// Mock 回包（契约 MockResponse）。
struct MockResponse: Codable, Equatable {
    let statusCode: Int
    var headers: [String: String]?
    var body: String?
    /// 二进制回包 base64；存在时按原始字节回包，body 仅作展示。
    var bodyBase64: String?
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
