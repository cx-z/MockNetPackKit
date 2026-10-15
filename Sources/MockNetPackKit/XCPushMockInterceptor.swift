//
//  XCPushMockInterceptor.swift
//  MockNetPackKit
//
//  L7.2b：XCPush「模拟推送」引擎（Debug-only，为 L7 push mock 能力线）。
//
//  形态（技术方案 3.2 模拟推送版 + 决策 D0/D1/D4）：不再「拦截替换真实 push」——
//  真实 push 无法复现才是痛点，拦截替换必须先有真包到达。改为完全模拟：
//    Web 建推送模板 → 服务端存 pending 指令 → SDK 心跳 3s 拉取 →
//    SDK 构造假 push（模板 payload + 新 msgId 查集合去重）走真实 delegate 回调
//    → 业务无感收到"新 push" → 采集旁路打 mocked 标记。
//
//  本文件 = 引擎本体：
//    1) fakeMsgId 集合（双职责，决策 D4）：
//       a. 假 push 间唯一性注册表——generateUniqueMsgId 生成后查集合去重；
//       b. ACK 拦截判定表——业务对假包 ACK（send:tag: tag=12345）∈ 集合 → 丢弃
//          不上行（未知 msgId 的 ACK 对真实长连接服务端影响未知，必须隔离）；
//       c. 采集识别——recorder 收包时查集合区分真假包（假包不写去重表、
//          打 mocked 标记）。
//    2) 注入点根除（决策 D4 最终版③）：假包构造后经 adapter 直调
//       XCPushDelegateProxy.injectFakeTalk:（走完整转发链），不经过 XCPush
//       收包判重路径——假 msgId 永不进 vReceivedMessageIds，未来同值真 push
//       正常放行（数学级保证、与 msgId 数值无关、不依赖接入方 msgId 策略）。
//    3) 碰撞解除兜底：真实收包 msgId ∈ 集合（极端碰撞）→ 移除 + 放行 + 审计
//       （真包优先；假包不再参与 ACK 拦截与采集识别，已注入的假包由业务正常
//       消费，其 ACK 照常上行——真包已到，ACK 语义真实）。
//    4) 集合容量上限 100k LRU 兜内存（不设时间清理——业务 ACK 时机不可控）。
//
//  范围纪律：不做 out 包 Mock、连接级 Mock、业务消费链路修改。
//

import Foundation
#if canImport(MockNetPackKitObjC)
import MockNetPackKitObjC
#else
import MockNetPackKit
#endif

#if DEBUG

/// XCPush 模拟推送引擎（单例；Debug-only，Release 构建零残留）。
final class XCPushMockInterceptor: @unchecked Sendable {

    static let shared = XCPushMockInterceptor()

    /// 注入执行器（adapter 注入；测试注入 fake 记录）。
    /// - Parameters:
    ///   - packet: 构造好的假 Packet 实例（KVC 字段已写入）。
    /// - Returns: 是否注入成功（无活跃 socket / 注入失败 → false）。
    var injector: ((AnyObject) -> Bool)?

    /// 集合容量上限（决策 D4：不设时间清理，容量上限 LRU 兜内存）。
    static let fakeMsgIdCapacity = 100_000

    private let lock = NSLock()
    /// fakeMsgId 集合：msgId → ruleId（双职责注册表/判定表/采集识别表）。
    /// 插入顺序维护（LRU：满时淘汰最旧）。
    private var fakeMsgIds: [UInt64: String] = [:]
    private var insertionOrder: [UInt64] = []

    /// 记录注入的假 push 构造参数（Web/调试审计：bizType/ruleId/msgId）。
    /// 最近 N 条环形缓冲。
    private struct InjectedRecord {
        let msgId: UInt64
        let bizType: String
        let ruleId: String
        let at: Date
    }
    private var injectedHistory: [InjectedRecord] = []
    private static let injectedHistoryLimit = 64

    // MARK: - fakeMsgId 集合（决策 D4）

    /// 注册假 msgId → ruleId。已存在（与既有假 push 重复）→ false，调用方重生成。
    func register(msgId: UInt64, ruleId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fakeMsgIds[msgId] == nil else { return false }
        fakeMsgIds[msgId] = ruleId
        insertionOrder.append(msgId)
        trimIfNeeded()
        return true
    }

    /// 判定 msgId 是否为当前在册假 push（ACK 拦截 / 采集识别 / 碰撞解除共用）。
    func contains(msgId: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fakeMsgIds[msgId] != nil
    }

    /// 假 push 对应的 ruleId（采集识别用；不在册 → nil）。
    /// 注意：不消费不移除——假 push 在业务消费周期内一直有效（其 ACK 需持续
    /// 拦截），集合条目仅在碰撞解除 / LRU 淘汰时移除。
    func mockRuleId(for msgId: UInt64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return fakeMsgIds[msgId]
    }

    /// 注入中豁免集（决策 D4 注入点根除配套）：假包经 proxy 完整转发链时，
    /// recorder 的碰撞解除不得把假包当成"真实收包碰撞"移除。注入同步完成，
    /// mark→inject→unmark 在同一调用栈内。
    private var injectingMsgIds: Set<UInt64> = []

    /// 标记注入中（adapter.injectFakeTalk 转发前调用）。
    func markInjecting(msgId: UInt64) {
        lock.lock()
        injectingMsgIds.insert(msgId)
        lock.unlock()
    }

    /// 解除注入标记（转发完成后调用）。
    func unmarkInjecting(msgId: UInt64) {
        lock.lock()
        injectingMsgIds.remove(msgId)
        lock.unlock()
    }

    /// 是否正处于注入中（recorder 碰撞解除豁免判定）。
    func isInjecting(msgId: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return injectingMsgIds.contains(msgId)
    }

    /// 碰撞解除：真实收包 msgId ∈ 集合 → 移除（放行 + 审计），返回是否发生解除。
    /// 真包优先原则：移除后该 msgId 不再参与 ACK 拦截（真包 ACK 照常上行）、
    /// 不再被采集识别为假包（Web 按真实包展示）。
    @discardableResult
    func resolveCollision(msgId: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fakeMsgIds.removeValue(forKey: msgId) != nil else { return false }
        insertionOrder.removeAll { $0 == msgId }
        SDKLog.error("push mock collision resolved: real packet msgId=\(msgId) evicted from fake set", category: "mock")
        return true
    }

    /// 假 push 间唯一性：生成新 msgId，保证不在集合中且不在本会话已生成历史中
    /// （D4 双职责 a；同毫秒批量生成多条指令时低 16bit 随机位可能碰撞——
    /// 生成器自维护会话级去重历史，register 去重仅作最终兜底）。
    /// **不设 2^63 软隔离高位**（真机崩溃 2026-10-14：msgId ≥ 2^63 会被业务
    /// Swift 路径按有符号整数转换 → 'Not enough bits to represent the passed
    /// value' trap；且 D4 定义该位为"降概率加分、不承担正确性"，正确性由
    /// 注入点根除保证）。msgId 恒 < 2^63：毫秒时间戳 47bit + 16bit 随机，
    /// 在有符号/无符号 64 位解读下均为正值；与真实 msgId 的碰撞概率 2^-63，
    /// 且注入点根除保证同值真 push 未来正常放行。
    func generateUniqueMsgId() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        for _ in 0..<32 {
            let ts = UInt64(Date().timeIntervalSince1970 * 1000)
            let rand = UInt64.random(in: 0...0xFFFF_FFFF)
            // 47bit 时间戳左移 16 = 63bit，最高位恒 0（< 2^63）。
            let candidate = ((ts & 0x7FFF_FFFF_FFFF) << 16) | (rand & 0xFFFF)
            if fakeMsgIds[candidate] == nil, !generatedHistory.contains(candidate) {
                rememberGenerated(candidate)
                return candidate
            }
        }
        // 极端拥塞兜底：线性扫描最坏路径（理论上不会到）。限制 < 2^63。
        var fallback = UInt64.random(in: 0...(UInt64(1) << 63) - 1)
        while fakeMsgIds[fallback] != nil || generatedHistory.contains(fallback) {
            fallback = UInt64.random(in: 0...(UInt64(1) << 63) - 1)
        }
        rememberGenerated(fallback)
        return fallback
    }

    /// 会话级生成历史（防同毫秒批量碰撞；LRU 上限兜内存）。
    private var generatedHistory: Set<UInt64> = []
    private var generatedOrder: [UInt64] = []
    private static let generatedHistoryLimit = 4096

    private func rememberGenerated(_ msgId: UInt64) {
        generatedHistory.insert(msgId)
        generatedOrder.append(msgId)
        while generatedOrder.count > Self.generatedHistoryLimit {
            generatedHistory.remove(generatedOrder.removeFirst())
        }
    }

    /// LRU 淘汰：超出容量移除最旧（决策 D4：容量上限 100k 兜内存）。
    private func trimIfNeeded() {
        while insertionOrder.count > Self.fakeMsgIdCapacity {
            let oldest = insertionOrder.removeFirst()
            fakeMsgIds.removeValue(forKey: oldest)
        }
        // 注入历史同样限长（防无限增长）。
        while injectedHistory.count > Self.injectedHistoryLimit {
            injectedHistory.removeFirst()
        }
    }

    // MARK: - 构造与注入

    /// 目标 Packet 类名（真机 = FDSocketService 的 Packet；测试注入 fake 类名）。
    /// Debug-only 探测路径：NSClassFromString + KVC（SDK 不链接 FDSocketService）。
    var packetClassName: String = "Packet"

    /// 构造假 Packet（type=message=7；模板 payload + 新 msgId）。
    /// NSClassFromString + init + KVC 写字段（收包侧同款防御）；
    /// 类不存在 / 字段写入失败 → nil（注入失败，指令保留待下次心跳重试）。
    func makePacket(command: PushRuleCommand) -> AnyObject? {
        guard let bizData = payloadData(for: command) else { return nil }
        guard let cls = NSClassFromString(packetClassName) as? NSObject.Type else {
            SDKLog.error("push mock makePacket: class \(packetClassName) unavailable", category: "mock")
            return nil
        }
        // 必须先 init 再 KVC 写字段：真实 Packet 是 GPBMessage 子类，其字段
        // storage 在 init 时分配；alloc 后直接写字段触发 protobuf 断言崩溃
        // （真机实测 2026-10-14：'Packet: All messages should have storage
        // (from init)'，GPBSetInt32IvarWithFieldPrivate）。Swift 元类型可
        // 直接 cls.init() 完成 alloc+init 动态实例化。
        let pkt = cls.init()
        // KVC 写字段（防御：先 responds 再操作；真实 Packet 字段为 ObjC 属性）。
        let msgId = generateUniqueMsgId()
        guard setKv("type", pkt, NSNumber(value: 7)),
              setKv("msgId", pkt, NSNumber(value: msgId)),
              setKv("bizType", pkt, NSNumber(value: Int32(command.bizType) ?? 0)),
              setKv("bizData", pkt, bizData),
              setKv("zipType", pkt, NSNumber(value: 0)) else {
            SDKLog.error("push mock makePacket: KVC write failed command=\(command.id)", category: "mock")
            return nil
        }
        // 注册集合（假 push 间唯一性 + ACK 拦截判定 + 采集识别）。
        if !register(msgId: msgId, ruleId: command.ruleId) {
            SDKLog.error("push mock register failed msgId=\(msgId)", category: "mock")
            return nil
        }
        recordInjected(msgId: msgId, bizType: command.bizType, ruleId: command.ruleId)
        return pkt
    }

    /// 注入到当前活跃长连接（走 proxy 完整转发链；无活跃 socket → false）。
    /// 指令消费确认由 PushMockRuleController 在注入成功后发起。
    func inject(packet: AnyObject) -> Bool {
        guard let injector else { return false }
        return injector(packet)
    }

    /// 指令 payload 字节：payloadBase64 优先（原始字节），否则 payload 文本 UTF-8。
    private func payloadData(for command: PushRuleCommand) -> Data? {
        if let b64 = command.payloadBase64, let data = Data(base64Encoded: b64) {
            return data
        }
        if let text = command.payload, let data = text.data(using: .utf8) {
            return data
        }
        return nil
    }

    private func recordInjected(msgId: UInt64, bizType: String, ruleId: String) {
        lock.lock()
        injectedHistory.append(InjectedRecord(msgId: msgId, bizType: bizType,
                                              ruleId: ruleId, at: Date()))
        lock.unlock()
    }

    /// 最近注入记录（调试/测试断言）。
    func recentInjections(limit: Int = 10) -> [(msgId: UInt64, bizType: String, ruleId: String)] {
        lock.lock()
        defer { lock.unlock() }
        return injectedHistory.suffix(limit).map { ($0.msgId, $0.bizType, $0.ruleId) }
    }

    /// 集合当前规模（测试/健康检查）。
    func fakeMsgIdCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return fakeMsgIds.count
    }

    // MARK: - 测试注入点

    /// 清空集合与历史（测试用）。
    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        fakeMsgIds.removeAll()
        insertionOrder.removeAll()
        injectedHistory.removeAll()
        injectingMsgIds.removeAll()
        generatedHistory.removeAll()
        generatedOrder.removeAll()
    }

    // MARK: - KVC 读写（防御：先 responds 再操作；真实 Packet 字段为 ObjC 属性）

    private func kv(_ key: String, from obj: AnyObject) -> Any? {
        guard obj.responds(to: NSSelectorFromString(key)) else { return nil }
        return obj.value(forKey: key)
    }

    private func kvMsgId(_ talk: AnyObject) -> UInt64 {
        (kv("msgId", from: talk) as? NSNumber)?.uint64Value ?? 0
    }

    /// KVC 写字段；getter/setter 不存在则返回 false（防御）。
    private func setKv(_ key: String, _ obj: AnyObject, _ value: Any) -> Bool {
        guard obj.responds(to: NSSelectorFromString(key)) else { return false }
        let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        guard obj.responds(to: NSSelectorFromString(setter)) else { return false }
        obj.setValue(value, forKey: key)
        return true
    }
}

#endif
