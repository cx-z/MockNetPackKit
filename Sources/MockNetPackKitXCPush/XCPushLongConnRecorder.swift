//
//  XCPushLongConnRecorder.swift
//  MockNetPackKit
//
//  L5.2：XCPush 长连接事件采集器（零侵入——代理层观察 → LongConnectionRecordInput）。
//
//  字段映射对齐 KK Debug 日志（PushService+Debug.swift）：
//  - 业务包：msgId / bizType（数字字符串，接入方自判断业务语义，决策 2026-10-13）/
//    zipType / payload（zipType=1 解压后 base64）/ duplicate（代理层自维护去重表）/
//    empty（bizData==nil → "(empty)" 占位）/ ackSent（收包转发栈内观察到 send tag=12345）。
//  - 生命周期：connect（didConnect）/ disconnect（disconnectedWithError）/ 超时 /
//    heartbeat 发送（sendHeartbeatPacket，direction=out；服务器 Heart 回包不单独成事件）/
//    router（connectToHost:onPort:）/ 心跳间隔（startHeartbeatWithTimeInterval:）。
//  - 快照自维护：state 状态机（starting→connected→ready→disconnected）+
//    routerHost/routerPort/heartbeatInterval/clientId（synack）/accountMid（packet.memId）/
//    receivedMessageCount（去重表计数）/lastConnectAt/lastDisconnectAt/lastPacketAt/
//    lastAckMsgId/lastError；状态变化立即上报，30s 兜底由 SDK 既有机制负责。
//
//  零侵入近似语义（决策已确认）：receiver/receiverResult 留空（Web 如实标注）；
//  duplicate 以代理层自维护去重表为准；ACK 关联覆盖 KK 同步 defer 主路径。
//

import Foundation
// 独立适配器模块（L6.1a 重做）：采集记录上送主 SDK 的 LongConnectionCollector。
import MockNetPackKit

/// XCPush 长连接事件采集器（单例；主线程调用为主，内部锁保护）。
final class XCPushLongConnRecorder: @unchecked Sendable {

    static let shared = XCPushLongConnRecorder()
    /// 通道标识（与一期 KK 桥接注册一致）。
    static let channelId = "xcpush_tcp"

    /// 记录接收器（默认走平台上报；测试注入 fake sink）。
    var recordSink: (LongConnectionRecordInput) -> Void = { MockNetPackKit.recordLongConnection($0) }

    // MARK: - 状态（锁保护）

    private let lock = NSLock()
    /// 自维护快照（对齐 KKPushServiceDebugSnapshot 字段子集）。
    private var snapshot = LongConnectionSnapshot()
    /// 去重表（对齐 KK vReceivedMessageIds 语义；connectToHost 时重置，代表新连接周期）。
    private var duplicateIDs: Set<UInt64> = []
    /// 正在转发中的业务包（didReadTalk will→did 同步窗口；ACK 关联目标）。
    private var pending: PendingPacket?

    /// 待完成收包的解析结果。
    struct PendingPacket {
        let msgId: UInt64
        let bizType: Int32
        let zipType: Int32
        let payload: Data?
        let empty: Bool
        let duplicate: Bool
        var ackSent: Bool = false
    }

    /// Packet type 常量（对齐 Push.pb.h Packet_PacketType；SDK 不依赖 FDSocketService）。
    private enum PacketType: Int32 {
        case syn = 1
        case synack = 2
        case reset = 3
        case reroute = 4
        case heart = 5
        case ack = 6
        case message = 7
        case close = 8
        case err = 100
        case echo = 101
    }

    // MARK: - proxy hooks（L5.1 代理转发旁路，Swift 侧注册）

    /// 连接成功。
    func onDidConnect(socket: AnyObject) {
        withLock {
            snapshot.state = "connected"
            snapshot.isSocketConnected = true
            snapshot.lastConnectAt = Date()
            snapshot.lastError = nil
            emit(.connect)
            recordSnapshot()
        }
    }

    /// 连接断开/失败。
    func onDisconnected(socket: AnyObject, error: AnyObject?) {
        withLock {
            snapshot.state = "disconnected"
            snapshot.isSocketConnected = false
            snapshot.lastDisconnectAt = Date()
            snapshot.lastError = (error as? NSError)?.localizedDescription ?? "socket disconnected"
            pending = nil
            emit(.disconnect)
            recordSnapshot()
        }
    }

    /// 读超时（对齐 KK debugDidTimeoutRead：仅更新快照，不单独成事件）。
    func onTimeoutRead(tag: Int) {
        withLock {
            snapshot.state = "disconnected"
            snapshot.isSocketConnected = false
            snapshot.lastDisconnectAt = Date()
            snapshot.lastError = "socket read timeout, tag=\(tag)"
            pending = nil
            recordSnapshot()
        }
    }

    /// 写超时（对齐 KK debugDidTimeoutWrite）。
    func onTimeoutWrite(tag: Int) {
        withLock {
            snapshot.state = "disconnected"
            snapshot.isSocketConnected = false
            snapshot.lastDisconnectAt = Date()
            snapshot.lastError = "socket write timeout, tag=\(tag)"
            pending = nil
            recordSnapshot()
        }
    }

    /// 收包转发前（同步栈内：解析并压栈；非 message 包就地处理）。
    /// L7.2b：模拟推送注入的假包同样经此链路（注入走 proxy 完整转发链），
    /// 先做碰撞解除（真实包 msgId ∈ fake 集合 → 移除放行，决策 D4）。
    func onWillForwardRead(sock: AnyObject, talk: AnyObject, tag: Int) {
        withLock {
            // accountMid：任一收包带 memId 即提取（对齐 "memId 从 Packet 提取"）。
            if let memId = packetMemId(talk), memId != 0 {
                snapshot.accountMid = String(memId)
            }
            switch packetType(talk) {
            case PacketType.message.rawValue:
                // L7.2b 碰撞解除：真实收包 msgId ∈ fake 集合 → 移除 + 放行 + 审计
                // （真包优先；移除后其 ACK 不再拦截、采集按真实包展示）。
                // 注入中的假包豁免（注入点根除配套——假包经完整转发链时不得
                // 被当成碰撞移除，集合需保留到业务 ACK 周期结束）。
                if let msgId = packetMsgId(talk),
                   !XCPushMockInterceptor.shared.isInjecting(msgId: msgId) {
                    XCPushMockInterceptor.shared.resolveCollision(msgId: msgId)
                }
                pending = makePendingPacket(talk)
                snapshot.receivedMessageCount = Int64(duplicateIDs.count)
            case PacketType.synack.rawValue:
                snapshot.state = "ready"
                snapshot.isSocketConnected = true
                snapshot.clientId = packetClientId(talk)
                pending = nil
                recordSnapshot()
            case PacketType.heart.rawValue:
                // 服务器心跳包（in）：仅清理栈，不单独成事件（2026-10-14 决策——
                // 心跳只记 out 发送一条，避免 out+in 同秒成对出现被视为重复）。
                pending = nil
            default:
                // syn/ack/reset/reroute/close/err/echo：KK Debug 无对应打点，忽略。
                pending = nil
            }
        }
    }

    /// 收包转发后（同步栈内：message 包生成记录；期间 ACK 发送已合并 ackSent）。
    func onDidForwardRead(sock: AnyObject, talk: AnyObject, tag: Int) {
        withLock {
            if let p = pending {
                snapshot.lastPacketAt = Date()
                recordPacket(p)
                pending = nil
            }
        }
    }

    // MARK: - swizzle 入口（XCPushSocket 方法，L5.2）

    /// 路由连接（connectToHost:onPort: 拦截）：新连接周期开始，重置去重表。
    func onConnectToHost(host: String, port: UInt16) {
        withLock {
            duplicateIDs.removeAll()
            pending = nil
            snapshot.routerHost = host
            snapshot.routerPort = Int(port)
            snapshot.state = "starting"
            recordSnapshot()
        }
    }

    /// 心跳开始（startHeartbeatWithTimeInterval: 拦截）。
    func onHeartbeatStart(interval: TimeInterval) {
        withLock {
            snapshot.heartbeatInterval = Int(interval)
            recordSnapshot()
        }
    }

    /// 心跳停止（stopHeartbeat 拦截；interval 保留）。
    func onHeartbeatStop() {
        withLock {
            // 无状态变化，不产生记录。
        }
    }

    /// 心跳发送（sendHeartbeatPacket 拦截；out 事件，不记 payload——首期不记 out 包）。
    func onHeartbeatSend() {
        withLock {
            emit(.heartbeat, direction: .out)
        }
    }

    /// 出站数据发送（send:tag: 拦截；仅 tag=12345 的 ACK 参与采集）。
    func onSend(data: AnyObject, tag: Int) {
        guard tag == 12345 else { return }
        withLock {
            if var p = pending {
                p.ackSent = true
                pending = p
                snapshot.lastAckMsgId = String(p.msgId)
            }
            // pending == nil（栈外 ACK）：KK 主路径为同步 defer，忽略。
        }
    }

    /// L7.2b：模拟推送 ACK 被拦截（业务对假包的 ACK，msgId ∈ fake 集合，
    /// adapter 已丢弃不上行）。旁路上报一条独立事件（Web「Mock ACK 拦截」），
    /// 供审计：假 push 的 ACK 未泄漏到真实长连接服务端。
    func onMockedAckIntercepted(msgId: UInt64) {
        withLock {
            snapshot.lastAckMsgId = String(msgId)
            var r = makeRecord(.ackBlocked)
            r.msgId = String(msgId)
            record(r)
        }
    }

    // MARK: - 内部

    private func makePendingPacket(_ talk: AnyObject) -> PendingPacket {
        let msgId = packetMsgId(talk) ?? 0
        let zipType = packetZipType(talk) ?? 0
        let raw = packetBizData(talk)
        // L7.2b：假 push（模拟推送注入）msgId ∈ fakeMsgId 集合 → 不进去重表
        // （未来同值真 push 不被误标 duplicate）、不重复计数。
        let isFake = XCPushMockInterceptor.shared.contains(msgId: msgId)
        let duplicate = !isFake && !duplicateIDs.insert(msgId).inserted
        // zipType=1 解压；失败回退原始字节。duplicate 包同样解压（Web 展示一致）。
        let payload: Data?
        if let raw, zipType == 1 {
            payload = Gzip.gunzip(raw) ?? raw
        } else {
            payload = raw
        }
        return PendingPacket(msgId: msgId,
                             bizType: packetBizType(talk) ?? 0,
                             zipType: zipType,
                             payload: payload,
                             empty: raw == nil,
                             duplicate: duplicate)
    }

    private func recordPacket(_ p: PendingPacket) {
        var r = makeRecord(.packet)
        r.msgId = String(p.msgId)
        r.bizType = String(p.bizType)          // 决策：数字字符串，接入方自判断业务语义
        r.zipType = String(p.zipType)
        r.duplicate = p.duplicate
        r.empty = p.empty
        r.ackSent = p.ackSent
        r.status = p.duplicate ? .duplicate : (p.empty ? .emptyData : .handled)
        // L7.2b/2c：假 push mocked 标记（Debug-only；Release 构建零残留，
        // 字段保持默认）。marker 表由注入注册（msgId → ruleId），采集识别复用。
        #if DEBUG
        if let ruleId = XCPushMockInterceptor.shared.mockRuleId(for: p.msgId) {
            r.mocked = true
            r.mockRuleId = ruleId
        }
        #endif
        if p.empty {
            r.payloadPreview = "(empty)"       // 对齐 F4：三选一占位
        } else if let payload = p.payload {
            r.payloadBase64 = payload.base64EncodedString()
        }
        record(r)
    }

    private func recordSnapshot() {
        var r = makeRecord(.snapshot)
        r.snapshot = snapshot
        record(r)
    }

    private func makeRecord(_ event: LongConnectionEventType,
                            direction: LongConnectionDirection = .in) -> LongConnectionRecordInput {
        var r = LongConnectionRecordInput(channelId: Self.channelId, eventType: event, ts: Date())
        r.direction = direction
        // L6.2：适配器采集记录如实标注能力来源（"xcpush"；与 registry adapterId 一致）。
        r.adapter = XCPushSocketAdapter.adapterId
        return r
    }

    /// 构造并上报一条事件记录（生命周期/心跳事件；packet 走 recordPacket）。
    private func emit(_ event: LongConnectionEventType,
                      direction: LongConnectionDirection = .in) {
        record(makeRecord(event, direction: direction))
    }

    private func record(_ r: LongConnectionRecordInput) {
        recordSink(r)
    }

    // MARK: - Packet 字段提取（KVC；SDK 不依赖 FDSocketService）

    // MARK: - Packet 字段提取（KVC；SDK 不依赖 FDSocketService）
    //
    // 防御：先 responds 再 value(forKey:)，避免对无字段对象（如 L5.1 测试的
    // 裸 NSObject）抛 NSUnknownKeyException。真实 Packet（GPBMessage）字段
    // 均为 ObjC 属性（getter 存在），提取不受影响。

    private func kv(_ key: String, from obj: AnyObject) -> Any? {
        guard obj.responds(to: NSSelectorFromString(key)) else { return nil }
        return obj.value(forKey: key)
    }

    private func packetType(_ talk: AnyObject) -> Int32? {
        (kv("type", from: talk) as? NSNumber)?.int32Value
    }

    private func packetMsgId(_ talk: AnyObject) -> UInt64? {
        (kv("msgId", from: talk) as? NSNumber)?.uint64Value
    }

    private func packetBizType(_ talk: AnyObject) -> Int32? {
        (kv("bizType", from: talk) as? NSNumber)?.int32Value
    }

    private func packetZipType(_ talk: AnyObject) -> Int32? {
        (kv("zipType", from: talk) as? NSNumber)?.int32Value
    }

    private func packetBizData(_ talk: AnyObject) -> Data? {
        kv("bizData", from: talk) as? Data
    }

    private func packetClientId(_ talk: AnyObject) -> String? {
        kv("clientId", from: talk) as? String
    }

    private func packetMemId(_ talk: AnyObject) -> Int64? {
        (kv("memId", from: talk) as? NSNumber)?.int64Value
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
