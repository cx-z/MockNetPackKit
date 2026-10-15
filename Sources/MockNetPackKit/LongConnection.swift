import Foundation

// ============================================================================
// 长连接日志（能力线 L1；与 server/openapi/mocknetpack.yaml v0.14.0 对齐）
//
// L1.3 草案：本文件仅定义「类型 + API 签名」——
//   LongConnectionRecordInput（必填 ≤4：channelId/eventType/ts + payload 三选一）、
//   LongConnectionCollector（通道注册 + 采集开关 + record 入口壳）。
// 采集实现（缓冲、独立额度 1000、payload 截断 10KB/预览 1KB、snapshot 合并 30s 兜底、
// 攒批上报 type=longconn）在 L2.1 落地；本阶段方法体为空实现，不采集、不改变业务行为。
// ============================================================================

/// 长连接日志方向（契约 LongConnectionRecordInput.direction）。
/// 首期仅 `in` + 生命周期事件（决策 #1：out 不记录）；out 预留保持模型完整。
public enum LongConnectionDirection: String, Codable, Sendable {
    /// 入站包 / 生命周期事件（首期唯一采集方向）。
    case `in` = "in"
    /// 出站包（预留，首期不记录）。
    case out = "out"
}

/// 长连接事件类型（契约 LongConnectionRecordInput.eventType，平台无关）。
public enum LongConnectionEventType: String, Codable, Sendable {
    /// 连接建立。
    case connect = "connect"
    /// 连接断开。
    case disconnect = "disconnect"
    /// 心跳事件。
    case heartbeat = "heartbeat"
    /// 收到业务包。
    case packet = "packet"
    /// 已发送 ACK。
    case ack = "ack"
    /// 模拟推送 ACK 被拦截（L7.2b：业务对假 push 的 ACK，丢弃不上行）。
    case ackBlocked = "ack_blocked"
    /// 连接快照（携带 snapshot）。
    case snapshot = "snapshot"
}

/// 通用处理状态（契约 LongConnectionRecordInput.status；对齐 KK 记录点语义）。
public enum LongConnectionStatus: String, Codable, Sendable {
    /// 已接收（默认）。
    case received = "received"
    /// 重复包。
    case duplicate = "duplicate"
    /// 空数据。
    case emptyData = "emptyData"
    /// 已由业务处理。
    case handled = "handled"
    /// 跳过 ACK。
    case ackSkipped = "ackSkipped"
}

/// 连接快照（契约 LongConnectionSnapshot；eventType=snapshot 时随记录上报；
/// 连接状态变化立即上报 + 30s 兜底）。对齐 KK `KKPushServiceDebugSnapshot`。
/// 字段全部可选：业务侧观察到什么就上报什么；未上报字段 Web 端缺省。
public struct LongConnectionSnapshot: Codable, Sendable {
    /// 连接状态（业务侧语义，如 connected/connecting/disconnected）。
    public var state: String?
    /// socket 是否已连接。
    public var isSocketConnected: Bool?
    /// 路由器地址（host）。
    public var routerHost: String?
    /// 路由器端口。
    public var routerPort: Int?
    /// 心跳间隔（秒）。
    public var heartbeatInterval: Int?
    /// 客户端 ID。
    public var clientId: String?
    /// 账号标识（mid）。
    public var accountMid: String?
    /// 是否持有连接令牌。
    public var hasToken: Bool?
    /// 累计收包数（消息数）。
    public var receivedMessageCount: Int64?
    /// 累计业务分发数。
    public var receiveServiceCount: Int64?
    /// 最近一次连接时间。
    public var lastConnectAt: Date?
    /// 最近一次断开时间。
    public var lastDisconnectAt: Date?
    /// 最近一次收包时间。
    public var lastPacketAt: Date?
    /// 最后一条 ACK 的 msgId。
    public var lastAckMsgId: String?
    /// 最后一条错误信息。
    public var lastError: String?

    public init(state: String? = nil,
                isSocketConnected: Bool? = nil,
                routerHost: String? = nil,
                routerPort: Int? = nil,
                heartbeatInterval: Int? = nil,
                clientId: String? = nil,
                accountMid: String? = nil,
                hasToken: Bool? = nil,
                receivedMessageCount: Int64? = nil,
                receiveServiceCount: Int64? = nil,
                lastConnectAt: Date? = nil,
                lastDisconnectAt: Date? = nil,
                lastPacketAt: Date? = nil,
                lastAckMsgId: String? = nil,
                lastError: String? = nil) {
        self.state = state
        self.isSocketConnected = isSocketConnected
        self.routerHost = routerHost
        self.routerPort = routerPort
        self.heartbeatInterval = heartbeatInterval
        self.clientId = clientId
        self.accountMid = accountMid
        self.hasToken = hasToken
        self.receivedMessageCount = receivedMessageCount
        self.receiveServiceCount = receiveServiceCount
        self.lastConnectAt = lastConnectAt
        self.lastDisconnectAt = lastDisconnectAt
        self.lastPacketAt = lastPacketAt
        self.lastAckMsgId = lastAckMsgId
        self.lastError = lastError
    }
}

/// 长连接日志上传条目（契约 LongConnectionRecordInput，业务侧桥接层注入；
/// 平台无关，不区分 iOS/Android 与具体长连接框架）。
///
/// 必填 ≤4：`channelId` / `eventType` / `ts` 必填；payload 三选一
/// （`payloadText` / `payloadBase64` / `payloadPreview`）对业务包事件
/// （packet/ack）必填其一（服务端校验），生命周期事件（connect/disconnect/
/// heartbeat/snapshot）可省略；其余字段全可选带默认。
///
/// 不含 id/sessionId/seq——由服务端生成（见契约 LongConnectionRecord）。
/// 构造示例（业务包）：`LongConnectionRecordInput(channelId: "xcpush_tcp",
/// eventType: .packet, ts: now, payloadBase64: raw)`。
public struct LongConnectionRecordInput: Codable, Sendable {
    /// 业务方注册的通道标识（如 "xcpush_tcp"），多框架共存区分维度。必填。
    public var channelId: String
    /// 通用事件类型（平台无关）。必填。
    public var eventType: LongConnectionEventType
    /// 记录时间（RFC3339，业务侧打点时间）。必填。
    public var ts: Date
    /// 可读 payload（UTF-8 或经业务侧解码）；packet/ack 事件三选一必填其一。
    public var payloadText: String? = nil
    /// 二进制 payload 的 base64（无法文本化时）；三选一之一。
    public var payloadBase64: String? = nil
    /// 截断预览（payload 超 10KB 时仅存预览 ≤1KB）；三选一之一。
    public var payloadPreview: String? = nil
    /// 方向；默认 `in`（首期仅 in + 生命周期事件）。
    public var direction: LongConnectionDirection = .`in`
    /// 消息 ID（字符串化，避免跨端 64 位溢出）。
    public var msgId: String? = nil
    /// 业务语义（chat/push/feedback/logRetrieval/command/businessPush…；
    /// 数字枚举由业务侧映射为字符串）。
    public var bizType: String? = nil
    /// 压缩类型。
    public var zipType: String? = nil
    /// 是否重复包（对齐 KK 记录点语义）。
    public var duplicate: Bool = false
    /// 是否空包（业务数据为空）。
    public var empty: Bool = false
    /// 是否已发送 ACK。
    public var ackSent: Bool = false
    /// 是否被 push mock 规则替换（能力线 L7：拦截命中后标记；Web 显示
    /// 「Mock 命中」）。未命中包保持 false，老 SDK 不携带（零副作用）。
    public var mocked: Bool = false
    /// 替换该包的 push mock 规则 ID（能力线 L7；服务端据此递增命中统计）。
    public var mockRuleId: String? = nil
    /// 业务接收方标识（业务层分发细节；零侵入模式下留空，Web 如实标注）。
    public var receiver: String? = nil
    /// 业务接收方处理返回值（业务层分发细节；零侵入模式下留空）。
    public var receiverResult: String? = nil
    /// 通用处理状态；默认 `received`。
    public var status: LongConnectionStatus = .received
    /// 连接快照（仅 eventType=snapshot 时携带）。
    public var snapshot: LongConnectionSnapshot? = nil

    /// 便捷构造：仅 4 个必填维度（channelId/eventType/ts + payload 三选一），
    /// 其余字段带默认值；注入后可按需修改属性（var）。
    public init(channelId: String,
                eventType: LongConnectionEventType,
                ts: Date,
                payloadText: String? = nil,
                payloadBase64: String? = nil,
                payloadPreview: String? = nil) {
        self.channelId = channelId
        self.eventType = eventType
        self.ts = ts
        self.payloadText = payloadText
        self.payloadBase64 = payloadBase64
        self.payloadPreview = payloadPreview
    }
}

/// 长连接通道编解码器（L4：业务层注入解码能力，SDK 自动匹配解析）。
///
/// 设计要点：
/// - 解码是业务知识（protobuf schema / 私有协议格式），SDK 不内嵌；
///   业务侧实现本协议，App 启动时按 channelId 注册一次。
/// - SDK 收到 raw packet（仅 payloadBase64、无 payloadText）时，按 channelId
///   查已注册 coder，在后台串行队列调 `decode`；返回值填入 payloadText 后入队。
/// - 返回 nil = 该包无法解码，SDK 降级保留 base64，不报错、不影响主流程。
public protocol MockNetPackChannelCoder: Sendable {
    /// 解码一条入站业务包。
    /// - Parameters:
    ///   - channelId: 所属通道（与注册时一致）。
    ///   - raw: socket 原始字节（payloadBase64 解出）。
    ///   - context: 附加上下文（bizType/msgId 等已解析的弱字段，可选）。
    /// - Returns: 可读文本（如格式化 JSON）；解不出返回 nil。
    func decode(channelId: String, raw: Data, context: [String: String]) -> String?
}

/// 长连接批量上传请求（契约 LongConnUploadRequest；会话归属由路径
/// /sessions/{id} 决定，请求体不含 app/did）。internal：仅 SDK 上传使用。
struct LongConnUploadRequest: Encodable {
    /// 本次上传所属通道（与 records 内条目 channelId 一致）。
    let channelId: String
    /// 一条批量上传的长连接记录（单批 ≤500，由 SDK 攒批控制）。
    let records: [LongConnectionRecordInput]
}

/// 长连接上传响应（契约 LongConnUploadResponse；count 为实际接受数）。
struct LongConnUploadResponse: Decodable {
    let accepted: Bool
    let count: Int
}

/// 长连接采集控制器（能力线 L1）。
///
/// 职责：通道注册表（多框架共存）；采集入口转发到 TrafficCaptureController
/// （L2.1 起：缓冲、独立额度 1000、payload 截断 10KB/预览 1KB、snapshot 合并
/// 30s 兜底、攒批上报 type=longconn 均在其上实现，与 HTTP 流量互不干扰）。
final class LongConnectionCollector: @unchecked Sendable {

    /// 进程内共享实例。
    static let shared = LongConnectionCollector()

    // MARK: - 状态（锁保护）

    private let lock = NSLock()
    /// 已注册通道 → 元信息（channelId 全局唯一，支持多框架共存）。
    private var channelsValue: [String: [String: String]] = [:]
    /// 已注册编解码器 → channelId（L4：SDK 自动解码 raw packet）。
    private var codersValue: [String: any MockNetPackChannelCoder] = [:]

    /// 长连接采集开关（默认开；关闭后仅丢弃、不影响业务侧打点）。
    /// 实现位于 TrafficCaptureController（与 HTTP 采集开关同域管理）。
    var captureEnabled: Bool {
        get { TrafficCaptureController.shared.longConnectionCaptureEnabled }
        set { TrafficCaptureController.shared.longConnectionCaptureEnabled = newValue }
    }

    /// 注册一条长连接通道（可多次调用，支持多框架共存）。
    /// - Parameters:
    ///   - channelId: 通道标识（全局唯一，如 "xcpush_tcp"）。
    ///   - metadata: 通道元信息（可选，如框架名/版本）。
    func registerChannel(_ channelId: String, metadata: [String: String]? = nil) {
        guard !channelId.isEmpty else { return }
        lock.lock()
        channelsValue[channelId] = metadata ?? [:]
        lock.unlock()
    }

    /// 注册通道编解码器（L4；业务层把私有协议解码能力注入 SDK）。
    /// 注册后 SDK 收到该通道的 raw packet（无 payloadText）会自动调 decode。
    /// - Parameters:
    ///   - channelId: 通道标识（与注入记录 channelId 一致，如 "xcpush_tcp"）。
    ///   - coder: 解码器实例；同通道重复注册覆盖旧实例。
    func registerCoder(_ channelId: String, coder: any MockNetPackChannelCoder) {
        guard !channelId.isEmpty else { return }
        lock.lock()
        codersValue[channelId] = coder
        lock.unlock()
    }

    /// 查询通道编解码器（TrafficCaptureController 解码管道调用）。
    func coder(for channelId: String) -> (any MockNetPackChannelCoder)? {
        lock.lock()
        defer { lock.unlock() }
        return codersValue[channelId]
    }

    /// 注入一条长连接记录（业务侧桥接层调用；线程安全，内部缓冲）。
    /// 采集实现（开关判断/截断/额度/上报）位于 TrafficCaptureController（L2.1）。
    /// - Parameter record: 上传条目（必填 ≤4，见 LongConnectionRecordInput）。
    func record(_ record: LongConnectionRecordInput) {
        TrafficCaptureController.shared.recordLongConnection(record)
    }
}
