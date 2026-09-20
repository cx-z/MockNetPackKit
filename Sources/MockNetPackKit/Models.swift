import Foundation

// ============================================================================
// MockNetPackKit 连接层模型（与 server/openapi/mocknetpack.yaml v0.1.0 对齐）
// ============================================================================

/// 设备连接状态（SDK 侧视角；服务端另有 derived offline 判定）。
public enum ConnectionState: Sendable, Equatable {
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

/// 设备注册请求（契约 RegisterDeviceRequest）。
struct RegisterDeviceRequest: Encodable {
    let app: String
    let did: String
    let platform: String
    let osVersion: String
    let sdkVersion: String
    let appVersion: String
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
    /// 响应状态码；请求失败时为 nil。
    var statusCode: Int?
    var responseHeaders: [String: [String]]?
    var responseBody: String?
    /// 错误信息；成功时为 nil。
    var error: String?
    var durationMs: Int
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
